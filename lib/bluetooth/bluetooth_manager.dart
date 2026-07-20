// lib/bluetooth/bluetooth_manager.dart
//
// Gestión de Bluetooth Clásico (RFCOMM / SPP) — conversación P2P bidireccional.
//
// El socket RFCOMM es full-duplex (como un socket TCP): lo que un lado
// escribe llega al stream de entrada del otro sin interferir con lo que
// éste escribe de vuelta. Por eso ambos extremos ejecutan el MISMO pipeline:
//
//   · Anfitrión (servidor SPP nativo — flutter_bluetooth_serial no soporta
//     modo servidor, así que MainActivity.kt implementa listen+accept()):
//     escucha una conexión entrante.
//   · Participante (cliente SPP): escanea/conecta al anfitrión.
//
// Una vez conectados, CUALQUIERA de los dos lados que tenga el micrófono
// habilitado captura voz en ráfagas de 2 s y las transmite; y AMBOS lados
// reciben, detectan pérdidas, aplican DSP y reproducen lo que llegue —
// de ahí que ambos puedan hablar y escuchar, como una radio de dos vías.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:logger/logger.dart';

import '../models/app_models.dart';
import '../dsp/companding.dart';
import '../dsp/dsp_processor.dart';
import '../dsp/information_theory.dart';
import 'audio_capture_service.dart';
import 'rfcomm_server.dart';
import 'rssi_channel.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTES DE PROTOCOLO
// ─────────────────────────────────────────────────────────────────────────────

/// Intervalo entre paquetes en modo archivo WAV (ms).
const int kPacketIntervalMs = 11;

/// Período de consulta de RSSI (ms). Cada lectura real implica una conexión
/// GATT completa (conectar → leer → cerrar, ~0.5-1.5 s) que además COMPITE
/// por la radio con el enlace RFCOMM de audio — sondear seguido no solo no
/// gana resolución: le roba ancho de banda a la voz.
const int kRssiPollIntervalMs = 5000;

/// Umbral de energía RMS (normalizada 0-1) por debajo del cual una ráfaga
/// se considera silencio y NO se transmite (VAD — detección de actividad
/// de voz por energía). Sin esto, cada teléfono con micrófono activo
/// enviaba 8 KB/s CONSTANTES aunque nadie hablara: silencio codificado que
/// (a) cargaba el canal sin aportar nada y (b) mantenía el parlante del
/// otro lado reproduciendo clips de silencio sin parar, lo que a su vez
/// dejaba SU micrófono bloqueado en semi-dúplex permanente (con AEC
/// activo). ~0.006 ≈ -44 dBFS: probado en campo — 0.010 recortaba
/// fragmentos de voz suave.
const double kVadRmsThreshold = 0.006;

/// Hangover del VAD: cuántos frames EXTRA (~128 ms c/u) se transmiten
/// después del último con voz. Sin esto el VAD cortaba "por fragmentos":
/// la cola suave de una frase caía bajo el umbral y llegaba amputada. Con
/// hangover, al detectar voz se transmite hasta que el fragmento termine
/// de verdad (~0.5 s de gracia) — el mismo diseño de los VAD de telefonía.
const int kVadHangoverFrames = 4;

/// Número máximo de paquetes perdidos consecutivos antes de limitar el conteo
/// (protege los contadores ante un SEQ corrupto que parezca un salto gigante).
const int kMaxConsecutiveLostPackets = 126;

/// Período del PING de medición de latencia (ms) — ver PING/PONG en
/// app_models.dart: 12 bytes cada 2 s, despreciable para el canal.
const int kPingIntervalMs = 2000;

/// UUID del perfil SPP (Serial Port Profile) — estándar Bluetooth Classic.
const String kSppUuid = '00001101-0000-1000-8000-00805F9B34FB';

// ─────────────────────────────────────────────────────────────────────────────
// CLASE PRINCIPAL
// ─────────────────────────────────────────────────────────────────────────────

class BluetoothManager {
  final Logger _log = Logger();
  final DspProcessor _dsp;
  final RfcommSppServer _sppServer = RfcommSppServer();
  final AudioCaptureService _capture = AudioCaptureService();

  BluetoothManager({DspProcessor? dspProcessor})
      : _dsp = dspProcessor ?? DspProcessor();

  // ── Estado de conexión ────────────────────────────────────────────────────
  BluetoothConnection? _connection;
  bool _serverTxActive = false; // anfitrión: hay un cliente conectado
  StreamSubscription<SppServerEvent>? _serverEventsSub;

  // ── Estado de TX (captura y envío del micrófono propio) ──────────────────
  StreamSubscription<Uint8List>? _pcmSub;
  final BytesBuilder _frameBuilder = BytesBuilder(copy: true);
  int _txSeq = 0;
  Future<void> _sendChain = Future.value();

  // HISTORIA DEL AEC (dos experimentos retirados, ver README dif. 14-16):
  // 1) NLMS propio en Dart (dsp/echo_canceller.dart, conservado como
  //    anexo): sin estimación de retardo no podía alinear la referencia
  //    (~300-600 ms reales vs. 16 ms de cobertura) — no cancelaba y
  //    añadía artefactos.
  // 2) Semi-dúplex por software (gate del micrófono mientras el parlante
  //    sonaba): funcionaba, pero sus transiciones (estimación del fin de
  //    reproducción + hangover) dejaban escapar ráfagas del arranque de
  //    cada frase ajena — se percibía como eco JUSTO al activarlo.
  // La solución definitiva es el AEC DE HARDWARE del teléfono: el toggle
  // AEC conmuta la FUENTE de captura (micrófono crudo ↔ camino de
  // comunicación VOICE_COMMUNICATION) — ver AudioCaptureService.

  /// Mitigaciones de canal activas en vivo (panel "Optimizar señal" de la
  /// UI). AppState lo reasigna directamente; se lee de nuevo en cada
  /// paquete/chunk, así que un cambio en la UI se siente de inmediato sin
  /// reiniciar la sesión. Arranca en [SignalOptimizationSettings.raw]
  /// (todo apagado) para poder escuchar primero la señal cruda.
  SignalOptimizationSettings signalSettings = SignalOptimizationSettings.raw;

  /// Demo de canal degradado: fuerza el pipeline DSP a comportarse como si
  /// el RSSI estuviera en -85 dBm (AWGN + bit-errores simulados activos)
  /// aunque los teléfonos estén juntos con señal excelente. Sin esto, en
  /// una demo a corta distancia el canal real es tan bueno que los toggles
  /// de Filtro/FEC no tienen nada que corregir y "no se sienten". Solo
  /// afecta la degradación SIMULADA — las métricas (RSSI mostrado, pérdida
  /// real) siguen reportando la verdad del canal físico.
  bool forceDegradedChannel = false;

  /// RSSI efectivo que ve el pipeline DSP (no el que reportan las métricas).
  double get _effectiveRssi =>
      forceDegradedChannel ? math.min(_currentRssi, -85.0) : _currentRssi;

  // ── PING/PONG (medición de RTT desacoplada del audio) ─────────────────────
  Timer? _pingTimer;
  int _pingId = 0;

  // ── VAD (no transmitir silencio) ──────────────────────────────────────────
  bool _vadWasSilent = false;
  int _vadSkippedBursts = 0;
  int _vadHangoverRemaining = 0;


  /// Estrés reciente del enlace (pérdidas + saturación TX), con decaimiento.
  /// Alimenta la simulación de RSSI: cuando la lectura real por GATT no está
  /// disponible, el valor simulado persigue la salud REAL observable del
  /// enlace en vez de pasearse aleatoriamente mostrando una señal "sana"
  /// mientras el canal agoniza.
  double _recentLinkStress = 0.0;

  // ── Estado de RX (formato de audio entrante y reproducción) ──────────────
  int _rxSampleRate = kMicSampleRate;
  int _rxNumChannels = kMicNumChannels;
  int _rxBitsPerSample = kMicBitsPerSample;

  /// true si el stream entrante viene comprimido con μ-law (modo voz);
  /// false si es PCM lineal tal cual (modo laboratorio .wav). Lo anuncia el
  /// emisor en el byte 8 del meta-paquete.
  bool _rxIsMuLaw = false;

  /// Tamaño de un bloque DESPUÉS de decodificar: el payload al aire siempre
  /// es de [kPayloadSize] bytes, pero si viene en μ-law se expande al doble
  /// de bytes de PCM lineal — el PLC necesita generar bloques de sustitución
  /// de ese mismo tamaño para que el reloj de reproducción no se desfase.
  int get _rxBlockSizeDecoded =>
      _rxIsMuLaw ? kPayloadSize * 2 : kPayloadSize;

  void Function(int sr, int nc, int bps)? _onWavInfoCallback;

  /// Drena el Jitter Buffer hacia el reproductor STREAMING nativo cada
  /// [kPlaybackBatchTickMs] ms — sin esperar acumulaciones grandes: el
  /// AudioTrack nativo consume a tiempo real exacto y sin costo por chunk,
  /// así que aquí solo se vacía todo lo disponible en cada tick.
  Timer? _playbackBatchTimer;
  static const int kPlaybackBatchTickMs = 250;

  /// Acumulador para las métricas de teoría de la información: se calcula
  /// entropía/capacidad cada ~1 s de audio drenado (muestras suficientes
  /// para el histograma y sin spamear el log 4 veces por segundo).
  final BytesBuilder _entropyAccum = BytesBuilder(copy: false);

  // ── Rate-limit del log de FEC (a ~8 paquetes/s el log por paquete
  //    saturaría la UI): acumula y reporta cada ~2 s. ────────────────────────
  int _fecLogCounter = 0;
  int _fecBitsAccum = 0;

  // ── Métricas de recepción ──────────────────────────────────────────────────
  int _lastSequenceNumber = -1;
  int _totalPacketsReceived = 0;
  int _totalPacketsLost = 0;
  double _currentRssi = -60.0;
  bool _rssiIsReal = false;
  Timer? _rssiTimer;
  bool _rssiPollBusy = false;
  int _rssiFailStreak = 0;
  int _rssiTickCount = 0;
  final math.Random _rssiRng = math.Random();

  // ── Buffer de reensamblado de paquetes (el socket BT puede fragmentar) ─────
  final List<int> _receiveBuffer = [];

  // ── Streams públicos para la UI ───────────────────────────────────────────
  final StreamController<ChannelMetrics> _metricsController =
      StreamController<ChannelMetrics>.broadcast();

  final StreamController<Uint8List> _audioChunkController =
      StreamController<Uint8List>.broadcast();

  final StreamController<String> _statusController =
      StreamController<String>.broadcast();

  final StreamController<LatencyMetric> _latencyController =
      StreamController<LatencyMetric>.broadcast();

  final StreamController<InfoTheoryMetrics> _infoTheoryController =
      StreamController<InfoTheoryMetrics>.broadcast();

  final StreamController<String> _algorithmLogController =
      StreamController<String>.broadcast();

  /// Stream de métricas en tiempo real (RSSI, packet loss, buffer fill).
  Stream<ChannelMetrics> get metricsStream => _metricsController.stream;

  /// Stream de bloques de audio PCM procesados para el motor de reproducción.
  Stream<Uint8List> get audioChunkStream => _audioChunkController.stream;

  /// Stream de mensajes de estado para la UI.
  Stream<String> get statusStream => _statusController.stream;

  /// Stream de latencias por ráfaga (RTT de los paquetes propios enviados).
  Stream<LatencyMetric> get latencyStream => _latencyController.stream;

  /// Stream de métricas de Teoría de la Información (capacidad de Shannon
  /// del canal, entropía de la fuente) — se recalcula cada vez que se
  /// completa un clip de audio (ver _drainToPlaybackQueue).
  Stream<InfoTheoryMetrics> get infoTheoryStream => _infoTheoryController.stream;

  /// Log textual de actividad de los algoritmos DSP en vivo (PLC, AWGN,
  /// filtro IIR/FIR, entropía/capacidad por clip) — para verificar en la
  /// propia UI que el procesamiento realmente se está ejecutando, no solo
  /// contar paquetes.
  Stream<String> get algorithmLogStream => _algorithmLogController.stream;

  /// Instancia DSP expuesta para acceso al Jitter Buffer desde la UI.
  DspProcessor get dsp => _dsp;

  // ──────────────────────────────────────────────────────────────────────────
  // ESCANEO Y LISTADO DE DISPOSITIVOS
  // ──────────────────────────────────────────────────────────────────────────

  Future<List<BluetoothDevice>> getPairedDevices() async {
    try {
      return await FlutterBluetoothSerial.instance.getBondedDevices();
    } catch (e) {
      _log.e('Error obteniendo dispositivos: $e');
      return [];
    }
  }

  Stream<BluetoothDiscoveryResult> startDiscovery() {
    return FlutterBluetoothSerial.instance.startDiscovery();
  }

  Future<void> cancelDiscovery() async {
    await FlutterBluetoothSerial.instance.cancelDiscovery();
  }

  Future<bool> requestEnable() async {
    return await FlutterBluetoothSerial.instance.requestEnable() ?? false;
  }

  Future<void> requestDiscoverable() async {
    await FlutterBluetoothSerial.instance.requestDiscoverable(120);
  }

  Future<bool> bondDevice(String address) async {
    try {
      return await FlutterBluetoothSerial.instance
              .bondDeviceAtAddress(address) ??
          false;
    } catch (e) {
      _log.e('Error emparejando $address: $e');
      return false;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // SESIÓN — ANFITRIÓN (escucha una conexión entrante)
  // ──────────────────────────────────────────────────────────────────────────

  /// Inicia la sesión como anfitrión.
  ///
  /// · Si [wavFilePath]/[wavHeader] se proveen: transmite ese archivo una vez
  ///   conectado (modo laboratorio, señal de prueba controlada).
  /// · En caso contrario, si [micEnabled]: captura y transmite el micrófono
  ///   propio en ráfagas de 2 s.
  ///
  /// La recepción y reproducción de audio entrante (del otro lado) SIEMPRE
  /// está activa — así el anfitrión también escucha lo que el participante
  /// le hable de vuelta.
  Future<void> startAsHost({
    required void Function(int sampleRate, int numChannels, int bitsPerSample)
        onWavInfo,
    bool micEnabled = true,
    String? wavFilePath,
    WavHeader? wavHeader,
  }) async {
    _onWavInfoCallback = onWavInfo;
    _resetRxState();
    _resetTxState();

    _serverEventsSub = _sppServer.events().listen(
      (event) async {
        switch (event.type) {
          case SppServerEventType.waiting:
            _statusController.add(
                'Esperando conexión entrante… (hazte visible si no apareces)');
            break;

          case SppServerEventType.connected:
            _serverTxActive = true;
            _log.i(
                'Participante conectado: ${event.deviceName} (${event.deviceAddress})');
            _statusController.add('Conectado: ${event.deviceName}');
            // Antes SOLO el participante (cliente) sondeaba RSSI; el
            // anfitrión se quedaba con el valor por defecto toda la sesión.
            if (event.deviceAddress != null) {
              _startRssiPolling(event.deviceAddress!);
            }
            _startPingTimer();
            try {
              // La reproducción (ver _beginPlayback) se configura cuando
              // llega el meta-paquete que el otro lado envía al empezar a
              // transmitir (ver _handleIncomingPacket) — no hay estado
              // persistente que "arrancar" dos veces, así que no hay riesgo
              // de reinicios concurrentes del reproductor.
              if (wavFilePath != null && wavHeader != null) {
                await _sendStreamInfoPacket(
                  sampleRate: wavHeader.sampleRate,
                  numChannels: wavHeader.numChannels,
                  bitsPerSample: wavHeader.bitsPerSample,
                  codec: kCodecPcm16, // el .wav viaja lineal, sin companding
                );
                unawaited(_transmitWav(
                    wavFilePath: wavFilePath, wavHeader: wavHeader));
              } else {
                await setMicEnabled(micEnabled);
              }
            } catch (e, st) {
              _log.e('Error iniciando sesión: $e', error: e, stackTrace: st);
              _statusController.add('Error iniciando sesión: $e');
            }
            break;

          case SppServerEventType.data:
            if (event.bytes != null) _onIncomingBytes(event.bytes!);
            break;

          case SppServerEventType.disconnected:
            _serverTxActive = false;
            _statusController.add('Participante desconectado');
            await _capture.stopCapture();
            break;

          case SppServerEventType.error:
            _serverTxActive = false;
            _log.e('Error servidor SPP: ${event.message}');
            _statusController.add('Error BT: ${event.message}');
            break;
        }
      },
      onError: (Object e, StackTrace st) {
        // Defensivo: un error no manejado en este stream (p. ej. una
        // excepción nativa marshaled desde el EventChannel) no debe tumbar
        // la app entera — se registra y se refleja en el estado.
        _log.e('Error en eventos del servidor SPP: $e', error: e, stackTrace: st);
        _statusController.add('Error BT: $e');
        _serverTxActive = false;
      },
    );

    await _sppServer.start();
    _statusController.add('Servidor SPP iniciado. Esperando…');
  }

  // ──────────────────────────────────────────────────────────────────────────
  // SESIÓN — PARTICIPANTE (se une como cliente)
  // ──────────────────────────────────────────────────────────────────────────

  /// Se une a la sesión del anfitrión en [address]. Si [micEnabled], también
  /// captura y transmite su propio micrófono — con esto la conversación es
  /// bidireccional (ambos lados hablan y escuchan por el mismo socket).
  Future<void> joinAsClient({
    required String address,
    required String name,
    required void Function(int sampleRate, int numChannels, int bitsPerSample)
        onWavInfo,
    bool micEnabled = true,
  }) async {
    _onWavInfoCallback = onWavInfo;
    _log.i('Uniéndose a $name ($address)…');
    _statusController.add('Conectando a $name…');

    try {
      _connection = await BluetoothConnection.toAddress(address);
      _log.i('Conexión establecida');
      _statusController.add('Conectado. Sesión activa…');

      _resetRxState();
      _resetTxState();
      _startRssiPolling(address);
      _startPingTimer();
      // La reproducción arranca cuando llegue el meta-paquete del anfitrión
      // (ver comentario en startAsHost sobre por qué NO se arranca aquí con
      // un formato por defecto).

      _connection!.input!.listen(
        _onIncomingBytes,
        onDone: () {
          _log.i('Conexión cerrada por el anfitrión');
          _statusController.add('Sesión finalizada');
          _rssiTimer?.cancel();
        },
        onError: (Object error) {
          _log.e('Error en stream de entrada: $error');
          _statusController.add('Error de recepción: $error');
          _rssiTimer?.cancel();
        },
        cancelOnError: false,
      );

      await setMicEnabled(micEnabled);
    } catch (e, st) {
      _log.e('Error uniéndose a la sesión: $e', error: e, stackTrace: st);
      _statusController.add('Error: $e');
      rethrow;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // TX — CAPTURA Y ENVÍO DEL MICRÓFONO PROPIO (ambos lados)
  // ──────────────────────────────────────────────────────────────────────────

  /// Habilita/deshabilita el micrófono propio EN VIVO — antes de conectar o
  /// durante una sesión activa. Al deshabilitar se detiene la captura por
  /// completo (apaga el indicador de micrófono del sistema, no solo deja de
  /// enviar); al habilitar se arranca bajo demanda si aún no estaba corriendo.
  /// Cualquier fallo nativo al arrancar el micrófono queda contenido aquí:
  /// se registra y refleja en el estado en vez de propagarse sin control.
  Future<void> setMicEnabled(bool enabled) async {
    if (enabled) {
      if (_pcmSub != null) return; // ya está corriendo
      try {
        // Anunciar el formato ANTES de capturar: es la única señal que le
        // dice al otro lado que arranque SU reproducción (una sola vez, con
        // el formato correcto) — ver nota en startAsHost/joinAsClient.
        await _sendStreamInfoPacket(
          sampleRate: kMicSampleRate,
          numChannels: kMicNumChannels,
          bitsPerSample: kMicBitsPerSample,
          codec: kCodecMuLaw, // la voz viaja comprimida (G.711 μ-law)
        );
        final pcmStream = await _capture.startCapture(
          hardwareAec: signalSettings.aecEnabled,
        );
        _algorithmLogController.add(signalSettings.aecEnabled
            ? 'AEC: captura por el camino de comunicación — el cancelador '
                'de eco de HARDWARE del teléfono está activo'
            : 'AEC apagado: micrófono crudo — el eco acústico '
                'parlante→micrófono NO se cancela');
        _pcmSub = pcmStream.listen(
          _onPcmChunk,
          onError: (Object e, StackTrace st) {
            _log.w('Error en captura de audio: $e', error: e, stackTrace: st);
            _statusController.add('Error de micrófono: $e');
          },
        );
        _statusController.add('Capturando voz (transmisión continua)…');
      } catch (e, st) {
        _log.w('No se pudo iniciar el micrófono: $e', error: e, stackTrace: st);
        _statusController.add('No se pudo activar el micrófono: $e');
      }
    } else {
      await _pcmSub?.cancel();
      _pcmSub = null;
      // Descartar el residuo parcial acumulado: si quedara, al reactivar el
      // micrófono el primer frame arrancaría con audio viejo de antes del
      // silencio (confuso para quien escucha).
      _frameBuilder.clear();
      try {
        await _capture.stopCapture();
      } catch (e) {
        _log.w('Error deteniendo captura de audio: $e');
      }
    }
  }

  /// Acumula PCM del micrófono; cada FRAME completo (~128 ms) sale al aire
  /// de inmediato — transmisión continua tipo radio, sin esperar ráfagas.
  /// La cancelación de eco ya ocurrió (o no, según el toggle AEC) ANTES de
  /// llegar aquí: la decide la fuente de captura (ver setMicEnabled y
  /// AudioCaptureService) — full-dúplex sin gates por software.
  void _onPcmChunk(Uint8List chunk) {
    _frameBuilder.add(chunk);
    _flushReadyFrames();
  }

  /// Tope de frames de voz esperando turno en la cadena de envío. Un frame
  /// son ~128 ms: 8 pendientes ≈ 1 s de atraso máximo posible en el emisor.
  /// Al superarlo, el frame nuevo se DESCARTA — en tiempo real, fresco e
  /// incompleto vale más que completo y atrasado. (La versión por ráfagas
  /// de 2 s permitía hasta ~4 s aquí; con frames el tope es 4× más fino.)
  static const int _kMaxPacketsInFlight = 8;
  int _packetsInFlight = 0;
  int _txFramesDropped = 0;

  /// Extrae de [_frameBuilder] cada frame completo (2040 B de PCM) y lo
  /// envía DE INMEDIATO: VAD → backpressure → μ-law → paquete → aire.
  void _flushReadyFrames() {
    while (_frameBuilder.length >= kFramePcmBytes) {
      final all = _frameBuilder.takeBytes();
      final frame = Uint8List.sublistView(all, 0, kFramePcmBytes);
      if (all.length > kFramePcmBytes) {
        _frameBuilder.add(Uint8List.sublistView(all, kFramePcmBytes));
      }

      // ── VAD: el silencio no se transmite ─────────────────────────────
      // Ahorra el canal para quien SÍ está hablando y evita que el parlante
      // del otro lado reproduzca silencio sin parar (lo que mantenía su
      // micrófono bloqueado en semi-dúplex). Con hangover de ~0.5 s para no
      // amputar la cola suave de las frases.
      final double rms = DspProcessor.rmsEnergy(frame);
      final bool voiced = rms >= kVadRmsThreshold;
      if (voiced) {
        _vadHangoverRemaining = kVadHangoverFrames;
        if (_vadWasSilent) {
          _vadWasSilent = false;
          _algorithmLogController
              .add('VAD: voz detectada — transmitiendo de nuevo');
        }
      } else if (_vadHangoverRemaining > 0) {
        _vadHangoverRemaining--; // cola de la frase: se envía igual
      } else {
        _vadSkippedBursts++;
        if (!_vadWasSilent) {
          _vadWasSilent = true;
          _algorithmLogController.add(
              'VAD: silencio — se deja de transmitir hasta detectar voz');
        }
        continue;
      }

      // ── Backpressure por frame: jamás acumular atraso en el emisor ───
      if (_packetsInFlight >= _kMaxPacketsInFlight) {
        _txFramesDropped++;
        _recentLinkStress += 1.0; // saturación propia también es estrés
        if (_txFramesDropped == 1 || _txFramesDropped % 20 == 0) {
          _algorithmLogController.add(
              'Backpressure: canal saturado → frame descartado en el emisor '
              '($_txFramesDropped en total; no se acumula atraso)');
        }
        continue;
      }

      // μ-law: 2040 B de PCM → exactamente un payload de 1020 B al aire.
      final Uint8List wire = MuLawCodec.encode(frame);
      final packet = buildPacket(_txSeq & 0xFFFF, wire);
      _txSeq++;
      _packetsInFlight++;
      _sendChain =
          _sendChain.then((_) => _txWrite(packet)).catchError((Object e) {
        _log.w('Error enviando frame de voz: $e');
      }).whenComplete(() {
        if (_packetsInFlight > 0) _packetsInFlight--;
      });
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // PING PERIÓDICO (RTT — ver PING/PONG en app_models.dart)
  // ──────────────────────────────────────────────────────────────────────────

  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(
      const Duration(milliseconds: kPingIntervalMs),
      (_) {
        _pingId = (_pingId + 1) & 0xFFFF;
        unawaited(_txWrite(buildPingPacket(
          pingId: _pingId,
          epochMs: DateTime.now().millisecondsSinceEpoch,
        )).catchError((Object e) {
          _log.w('No se pudo enviar PING: $e');
        }));
      },
    );
  }

  /// Escritura unificada de TX: servidor nativo (anfitrión) o socket cliente.
  Future<void> _txWrite(Uint8List bytes) async {
    if (_serverTxActive) {
      await _sppServer.write(bytes);
    } else if (_connection != null && _connection!.isConnected) {
      _connection!.output.add(bytes);
      await _connection!.output.allSent;
    } else {
      throw StateError('Sin canal TX activo');
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // TRANSMISIÓN DE ARCHIVO WAV (modo laboratorio, solo anfitrión)
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _transmitWav({
    required String wavFilePath,
    required WavHeader wavHeader,
  }) async {
    _statusController.add('Leyendo archivo WAV…');

    final file = File(wavFilePath);
    final allBytes = await file.readAsBytes();
    final pcmStart = wavHeader.dataOffset;
    final pcmEnd = pcmStart + wavHeader.dataSize;

    if (pcmEnd > allBytes.length) {
      throw FormatException(
          'Archivo WAV corrupto: dataOffset($pcmStart) + dataSize(${wavHeader.dataSize}) > fileSize(${allBytes.length})');
    }

    final pcmBytes = allBytes.sublist(pcmStart, pcmEnd);
    _log.i('Transmitiendo ${wavHeader.toString()}, '
        '${pcmBytes.length} bytes de PCM…');

    int sequenceNumber = 0;
    int offset = 0;

    while (_serverTxActive && offset < pcmBytes.length) {
      final int end = (offset + kPayloadSize).clamp(0, pcmBytes.length);
      final payload = Uint8List.fromList(pcmBytes.sublist(offset, end));

      final Uint8List paddedPayload = payload.length < kPayloadSize
          ? (Uint8List(kPayloadSize)..setRange(0, payload.length, payload))
          : payload;

      final packet = buildPacket(sequenceNumber & 0xFFFF, paddedPayload);

      try {
        await _txWrite(packet);
      } catch (e) {
        _log.w('Error enviando paquete $sequenceNumber: $e');
        break;
      }

      sequenceNumber++;
      offset += kPayloadSize;
      await Future.delayed(const Duration(milliseconds: kPacketIntervalMs));
    }

    await _sendEndOfStreamPacket();
    _statusController
        .add('Transmisión completada. $sequenceNumber paquetes enviados.');
    _log.i('Transmisión finalizada: $sequenceNumber paquetes');
  }

  /// Envía un paquete especial con los parámetros del stream de audio.
  /// Estructura: [0xCC, 0xDD, numChannels, bitsPerSample, SR(u32 LE),
  /// codec(1B: kCodecPcm16 | kCodecMuLaw), ...]
  Future<void> _sendStreamInfoPacket({
    required int sampleRate,
    required int numChannels,
    required int bitsPerSample,
    required int codec,
  }) async {
    final meta = Uint8List(kPacketSize);
    meta[0] = 0xCC;
    meta[1] = 0xDD;
    meta[2] = numChannels & 0xFF;
    meta[3] = bitsPerSample & 0xFF;
    final view = ByteData.sublistView(meta);
    view.setUint32(4, sampleRate, Endian.little);
    meta[8] = codec & 0xFF;
    await _txWrite(meta);
    await Future.delayed(const Duration(milliseconds: 20));
  }

  Future<void> _sendEndOfStreamPacket() async {
    final eos = Uint8List(kPacketSize);
    eos[0] = 0xFF;
    eos[1] = 0xFF;
    eos[2] = 0xEE;
    eos[3] = 0xDD;
    try {
      await _txWrite(eos);
    } catch (e) {
      _log.w('No se pudo enviar fin de stream: $e');
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // RX — PIPELINE UNIFICADO (anfitrión y participante usan el mismo código)
  // ──────────────────────────────────────────────────────────────────────────

  /// Punto de entrada único para bytes entrantes, vengan del socket cliente
  /// (participante) o de los eventos del servidor nativo (anfitrión).
  void _onIncomingBytes(Uint8List chunk) {
    _receiveBuffer.addAll(chunk);
    _processReceiveBuffer();
  }

  /// Determina el tamaño esperado de paquete según sus magic bytes: el ACK
  /// es más corto (20 B) que el resto de tipos (kPacketSize, 1024 B).
  int _expectedPacketLength(int b0, int b1) {
    if (b0 == kPingMagic0 && (b1 == kPingMagic1 || b1 == kPongMagic1)) {
      return kPingPacketSize;
    }
    return kPacketSize;
  }

  /// Procesa el buffer de reensamblado buscando paquetes completos.
  /// El tamaño de cada paquete depende de su tipo (ver [_expectedPacketLength]),
  /// por eso no se puede asumir un framing de longitud fija para todo el stream.
  void _processReceiveBuffer() {
    while (_receiveBuffer.length >= 2) {
      final int syncIndex = _findSyncIndex();
      if (syncIndex == -1) {
        if (_receiveBuffer.length > 3) {
          _receiveBuffer.removeRange(0, _receiveBuffer.length - 3);
        }
        return;
      }

      if (syncIndex > 0) {
        _receiveBuffer.removeRange(0, syncIndex);
        _log.w('Resincronización: descartados $syncIndex bytes');
      }

      if (_receiveBuffer.length < 2) return;
      final int expectedLen =
          _expectedPacketLength(_receiveBuffer[0], _receiveBuffer[1]);
      if (_receiveBuffer.length < expectedLen) return; // esperar más bytes

      final packetBytes =
          Uint8List.fromList(_receiveBuffer.sublist(0, expectedLen));
      _receiveBuffer.removeRange(0, expectedLen);

      _handleIncomingPacket(packetBytes);
    }
  }

  /// Encuentra el índice del primer magic byte válido en [_receiveBuffer].
  int _findSyncIndex() {
    for (int i = 0; i < _receiveBuffer.length - 1; i++) {
      final b0 = _receiveBuffer[i];
      final b1 = _receiveBuffer[i + 1];
      if ((b0 == kMagicByte0 && b1 == kMagicByte1) || // paquete de datos
          (b0 == 0xCC && b1 == 0xDD) || // meta-paquete audio
          (b0 == kPingMagic0 &&
              (b1 == kPingMagic1 || b1 == kPongMagic1)) || // PING/PONG
          (b0 == 0xFF && b1 == 0xFF)) {
        // fin de stream
        return i;
      }
    }
    return -1;
  }

  /// Despacha el paquete según su tipo.
  void _handleIncomingPacket(Uint8List packet) {
    final b0 = packet[0];
    final b1 = packet[1];

    // ── Meta-paquete de formato de audio ────────────────────────────────
    if (b0 == 0xCC && b1 == 0xDD) {
      final nc = packet[2];
      final bps = packet[3];
      final view = ByteData.sublistView(packet);
      final sr = view.getUint32(4, Endian.little);
      _rxIsMuLaw = packet[8] == kCodecMuLaw;
      _log.i('Meta-paquete audio: ${sr}Hz, ${nc}ch, ${bps}bit, '
          'codec=${_rxIsMuLaw ? "μ-law" : "PCM16"}');
      _beginPlayback(sr, nc, bps);
      return;
    }

    // ── PING entrante → responder PONG con el MISMO timestamp ───────────
    if (b0 == kPingMagic0 && b1 == kPingMagic1) {
      final ping = PingPong.parse(packet);
      unawaited(_txWrite(
              buildPongPacket(pingId: ping.pingId, epochMs: ping.epochMs))
          .catchError((Object e) {
        _log.w('No se pudo responder PONG: $e');
      }));
      return;
    }

    // ── PONG: RTT medido enteramente con nuestro propio reloj ────────────
    if (b0 == kPingMagic0 && b1 == kPongMagic1) {
      final pong = PingPong.parse(packet);
      final double rttMs =
          (DateTime.now().millisecondsSinceEpoch - pong.epochMs).toDouble();
      _latencyController.add(LatencyMetric(
        pingId: pong.pingId,
        latencyMs: rttMs,
        timestamp: DateTime.now(),
      ));
      return;
    }

    // ── Fin de stream ────────────────────────────────────────────────────
    if (b0 == 0xFF && b1 == 0xFF && packet[2] == 0xEE && packet[3] == 0xDD) {
      _log.i('Paquete de fin de stream recibido');
      _statusController.add('Stream finalizado');
      return;
    }

    // ── Paquete de datos normal ──────────────────────────────────────────
    if (b0 != kMagicByte0 || b1 != kMagicByte1) {
      _log.w(
          'Magic bytes inválidos: 0x${b0.toRadixString(16)} 0x${b1.toRadixString(16)}');
      return;
    }

    final int seqNum = parseSequenceNumber(packet);
    if (seqNum == -1) return;

    // ── Detección de paquetes perdidos por saltos en secuencia ───────────
    int lostInGap = 0;
    if (_lastSequenceNumber != -1) {
      final int expected = (_lastSequenceNumber + 1) & 0xFFFF;
      if (seqNum != expected) {
        lostInGap = ((seqNum - expected) & 0xFFFF);
        if (lostInGap > kMaxConsecutiveLostPackets) {
          lostInGap = kMaxConsecutiveLostPackets;
        }
        _totalPacketsLost += lostInGap;
        _recentLinkStress += lostInGap.toDouble();
        _log.w('Pérdida detectada: seq esperada=$expected recibida=$seqNum '
            'perdidos=$lostInGap');
        _algorithmLogController.add(signalSettings.plcEnabled
            ? 'PLC: $lostInGap paquete(s) perdido(s) → repetición atenuada '
                '(-3 dB por repetición)'
            : 'Pérdida: $lostInGap paquete(s) — PLC apagado, queda un hueco '
                'de silencio');

        for (int i = 0; i < lostInGap; i++) {
          _dsp.processBlock(
            rawBlock: null,
            rssiDbm: _effectiveRssi,
            isLost: true,
            plcEnabled: signalSettings.plcEnabled,
            filterEnabled: signalSettings.filterEnabled,
            fecEnabled: signalSettings.fecEnabled,
            numChannels: _rxNumChannels,
            bitsPerSample: _rxBitsPerSample,
            lostBlockSize: _rxBlockSizeDecoded,
          );
        }
      }
    }

    _lastSequenceNumber = seqNum;
    _totalPacketsReceived++;

    // ── Extraer payload, expandir μ-law → PCM y procesar con DSP ─────────
    final wirePayload = Uint8List.sublistView(packet, 4, kPacketSize);
    final payload =
        _rxIsMuLaw ? MuLawCodec.decode(wirePayload) : wirePayload;
    _dsp.processBlock(
      rawBlock: payload,
      rssiDbm: _effectiveRssi,
      isLost: false,
      plcEnabled: signalSettings.plcEnabled,
      filterEnabled: signalSettings.filterEnabled,
      fecEnabled: signalSettings.fecEnabled,
      numChannels: _rxNumChannels,
      bitsPerSample: _rxBitsPerSample,
      lostBlockSize: _rxBlockSizeDecoded,
    );
    // FEC con log de cadencia acotada (a ~8 paquetes/s el log por paquete
    // saturaría la UI de notificaciones).
    _fecBitsAccum += _dsp.lastFecCorrectedBits;
    if (++_fecLogCounter >= 16) {
      if (_fecBitsAccum > 0) {
        _algorithmLogController.add(
            'FEC (Hamming 7,4): $_fecBitsAccum bit(s) corregidos en los '
            'últimos ~2 s');
      }
      _fecLogCounter = 0;
      _fecBitsAccum = 0;
    }

    // ── Emitir métricas actualizadas ─────────────────────────────────────
    final total = _totalPacketsReceived + _totalPacketsLost;
    final lossPercent =
        total > 0 ? (_totalPacketsLost / total * 100.0) : 0.0;

    _metricsController.add(ChannelMetrics(
      rssiDbm: _currentRssi,
      rssiIsReal: _rssiIsReal,
      packetLossPercent: lossPercent,
      bufferFillRatio: _dsp.jitterBuffer.fillRatio,
      packetsReceived: _totalPacketsReceived,
      packetsLost: _totalPacketsLost,
      timestamp: DateTime.now(),
    ));
  }

  // ──────────────────────────────────────────────────────────────────────────
  // REPRODUCCIÓN — DRENAJE CONTINUO HACIA EL REPRODUCTOR STREAMING NATIVO
  // ──────────────────────────────────────────────────────────────────────────

  /// Fija el formato de audio entrante y asegura que el temporizador de
  /// drenaje esté corriendo.
  void _beginPlayback(int sampleRate, int numChannels, int bitsPerSample) {
    _rxSampleRate = sampleRate;
    _rxNumChannels = numChannels;
    _rxBitsPerSample = bitsPerSample;
    _onWavInfoCallback?.call(sampleRate, numChannels, bitsPerSample);
    _startPlaybackBatching();
  }

  /// Arranca (si no estaba corriendo) el timer de drenaje.
  void _startPlaybackBatching() {
    if (_playbackBatchTimer != null) return;
    _playbackBatchTimer = Timer.periodic(
      const Duration(milliseconds: kPlaybackBatchTickMs),
      (_) => _drainToPlaybackQueue(),
    );
  }

  /// Vacía TODO lo disponible del Jitter Buffer hacia el reproductor
  /// streaming en cada tick — sin esperar acumulaciones: el AudioTrack
  /// nativo consume a tiempo real exacto y no cobra costo por chunk (a
  /// diferencia de la reproducción por clips que obligaba a agrupar 2 s).
  void _drainToPlaybackQueue() {
    if (_dsp.jitterBuffer.isEmpty) return;
    final builder = BytesBuilder(copy: false);
    Uint8List? block;
    while ((block = _dsp.jitterBuffer.pop()) != null) {
      builder.add(block!);
    }
    if (builder.isEmpty) return;
    final chunk = builder.toBytes();
    _audioChunkController.add(chunk);

    // Teoría de la Información (Cap. IV) con cadencia acotada: acumula ~1 s
    // de audio y recién entonces calcula/emite — entropía sobre muestras
    // suficientes para el histograma, y sin spamear el log 4 veces/segundo.
    _entropyAccum.add(chunk);
    if (_entropyAccum.length < 16000) return;
    final sample = _entropyAccum.takeBytes();

    final double capacityBps = InformationTheory.shannonCapacityBps(
      rssiDbm: _effectiveRssi,
      sampleRate: _rxSampleRate,
    );
    final double entropy =
        InformationTheory.sourceEntropyBitsPerSample(sample);
    final double maxEntropy = InformationTheory.maxEntropyBitsPerSample();
    _infoTheoryController.add(InfoTheoryMetrics(
      channelCapacityBps: capacityBps,
      sourceEntropyBitsPerSample: entropy,
      maxEntropyBitsPerSample: maxEntropy,
      timestamp: DateTime.now(),
    ));

    final bool degraded = _effectiveRssi < kRssiWeakThreshold;
    final String forcedTag = forceDegradedChannel ? ' (forzado para demo)' : '';
    final String degradedNote = !degraded
        ? ''
        : signalSettings.filterEnabled
            ? ' · canal degradado$forcedTag: AWGN inyectado + filtro IIR/FIR '
                'limpiando (RSSI efectivo ${_effectiveRssi.toStringAsFixed(0)} dBm)'
            : ' · canal degradado$forcedTag: AWGN inyectado SIN filtrar — filtro '
                'apagado (RSSI efectivo ${_effectiveRssi.toStringAsFixed(0)} dBm)';
    _algorithmLogController.add(
      'Audio reproducido (${(sample.length / 1024).toStringAsFixed(1)} KB): '
      'H(X)=${entropy.toStringAsFixed(2)}/${maxEntropy.toStringAsFixed(0)} bits/muestra, '
      'C≈${(capacityBps / 1000).toStringAsFixed(1)} kbps$degradedNote',
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // POLLING DE RSSI
  // ──────────────────────────────────────────────────────────────────────────

  /// Sondea el RSSI cada [kRssiPollIntervalMs] ms. Intenta primero una
  /// lectura real (GATT híbrido sobre el enlace clásico, ver rssi_channel.dart);
  /// si el dispositivo remoto no lo soporta (frecuente en BT Clásico) o no
  /// responde a tiempo, cae a una simulación de respaldo — pero una que
  /// realmente fluctúa arriba y abajo (paseo aleatorio acotado), no la
  /// versión anterior que solo restaba y por eso el RSSI SIEMPRE bajaba.
  void _startRssiPolling(String address) {
    _rssiTimer?.cancel();
    _rssiFailStreak = 0;
    _rssiTickCount = 0;
    _rssiTimer = Timer.periodic(
      const Duration(milliseconds: kRssiPollIntervalMs),
      (_) async {
        // Timer.periodic NO espera al cuerpo async: sin este guard, una
        // lectura GATT lenta (hasta 3 s de timeout) se solaparía con los
        // ticks siguientes, apilando conexiones GATT concurrentes al mismo
        // dispositivo — cada una consume un handle del sistema.
        if (_rssiPollBusy) return;
        _rssiPollBusy = true;
        _rssiTickCount++;

        // HIGIENE DE RADIO (mejora de la CONEXIÓN, no del mensaje): cada
        // intento de lectura real es una conexión GATT completa que compite
        // por la radio de 2.4 GHz con el propio enlace de voz. Si el
        // teléfono remoto claramente no la soporta (3 fallos seguidos),
        // insistir cada 5 s solo le roba airtime al audio — se baja a un
        // reintento cada ~15 s por si acaso, y se simula el resto.
        final bool tryRealRead =
            _rssiFailStreak < 3 || _rssiTickCount % 3 == 0;
        try {
          if (!tryRealRead) {
            throw StateError('backoff GATT: sin intento real este tick');
          }
          _currentRssi = await RssiChannel.getRssi(address);
          _rssiIsReal = true;
          _rssiFailStreak = 0;
        } catch (_) {
          if (tryRealRead) _rssiFailStreak++;
          _rssiIsReal = false;
          // Simulación guiada por la salud REAL del enlace: el valor
          // persigue un objetivo derivado de las pérdidas y la saturación
          // TX recientes (_recentLinkStress, con decaimiento), más un poco
          // de ruido. El paseo aleatorio ciego anterior mostraba una señal
          // "sana" paseándose por -60 dBm mientras el enlace agonizaba —
          // un indicador que no indica nada. Así, aunque el número siga
          // siendo simulado (y la UI lo marque como tal), al menos SE MUEVE
          // CON el canal: enlace limpio → ~-48 dBm; pérdidas/saturación →
          // cae proporcionalmente; se recupera cuando el canal se limpia.
          _recentLinkStress *= 0.6; // decae si no hay eventos nuevos
          final double target =
              (-48.0 - _recentLinkStress * 2.0).clamp(-92.0, -45.0);
          final double noise = (_rssiRng.nextDouble() * 2.0) - 1.0;
          _currentRssi = (_currentRssi + (target - _currentRssi) * 0.4 + noise)
              .clamp(-95.0, -40.0);
        } finally {
          _rssiPollBusy = false;
        }
      },
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // CONTROL DE CICLO DE VIDA
  // ──────────────────────────────────────────────────────────────────────────

  void _resetRxState() {
    _receiveBuffer.clear();
    _lastSequenceNumber = -1;
    _totalPacketsReceived = 0;
    _totalPacketsLost = 0;
    _rxIsMuLaw = false;
    _recentLinkStress = 0.0;
    _entropyAccum.clear();
    _fecLogCounter = 0;
    _fecBitsAccum = 0;
    _dsp.reset();
  }

  void _resetTxState() {
    _txSeq = 0;
    _pingId = 0;
    _frameBuilder.clear();
    _sendChain = Future.value();
    _packetsInFlight = 0;
    _txFramesDropped = 0;
    _vadWasSilent = false;
    _vadSkippedBursts = 0;
    _vadHangoverRemaining = 0;
  }

  /// Detiene la transmisión/recepción y cierra la conexión.
  Future<void> disconnect() async {
    _serverTxActive = false;
    _rssiTimer?.cancel();
    _rssiTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _playbackBatchTimer?.cancel();
    _playbackBatchTimer = null;
    _resetRxState();
    _resetTxState();

    await _pcmSub?.cancel();
    _pcmSub = null;
    await _capture.stopCapture();

    await _serverEventsSub?.cancel();
    _serverEventsSub = null;
    try {
      await _sppServer.stop();
    } catch (e) {
      _log.w('Error deteniendo servidor SPP: $e');
    }

    try {
      await _connection?.close();
    } catch (e) {
      _log.w('Error cerrando conexión: $e');
    }
    _connection = null;
    _statusController.add('Desconectado');
    _log.i('Conexión BT cerrada');
  }

  /// Libera todos los recursos (llamar en dispose del widget).
  void dispose() {
    disconnect();
    _capture.dispose();
    _metricsController.close();
    _audioChunkController.close();
    _statusController.close();
    _latencyController.close();
    _infoTheoryController.close();
    _algorithmLogController.close();
  }

  bool get isConnected =>
      _serverTxActive || (_connection?.isConnected ?? false);

  ChannelMetrics get currentMetrics {
    final total = _totalPacketsReceived + _totalPacketsLost;
    return ChannelMetrics(
      rssiDbm: _currentRssi,
      rssiIsReal: _rssiIsReal,
      packetLossPercent: total > 0 ? _totalPacketsLost / total * 100.0 : 0.0,
      bufferFillRatio: _dsp.jitterBuffer.fillRatio,
      packetsReceived: _totalPacketsReceived,
      packetsLost: _totalPacketsLost,
      timestamp: DateTime.now(),
    );
  }
}
