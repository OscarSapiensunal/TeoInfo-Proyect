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
import '../dsp/echo_canceller.dart';
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

/// Hangover del VAD: cuántas ráfagas EXTRA se transmiten después de la
/// última con voz. Sin esto el VAD cortaba "por fragmentos": una ráfaga de
/// 2 s con la cola suave de una frase caía bajo el umbral y la frase
/// llegaba amputada. Con hangover, al detectar voz se transmite hasta que
/// el fragmento termine de verdad (una ráfaga silenciosa completa después
/// de la última voz) — el mismo diseño de los VAD de telefonía.
const int kVadHangoverBursts = 1;

/// Cola del semi-dúplex (ms): el micrófono se mantiene silenciado un
/// momento DESPUÉS de que el parlante termina, para no captar la
/// reverberación de la sala ni el desinfle del control automático de
/// ganancia — las colas de eco que se escapaban justo al liberar el gate.
const int kAecGateHangoverMs = 300;

/// Intervalo mínimo entre solicitudes de retransmisión (NACK). En un canal
/// ya estresado, pedir reenvío por CADA hueco crea una espiral: reenvíos →
/// más carga → más huecos → más reenvíos (colapso por congestión, el mismo
/// fenómeno que motivó el control de congestión de TCP).
const int kMinNackIntervalMs = 2000;

/// Número máximo de paquetes perdidos consecutivos antes de limitar el conteo.
/// DEBE cubrir al menos 2 ráfagas completas: una ráfaga entera puede
/// perderse de golpe, y con un tope menor que eso el conteo además rompe la
/// ventana del ARQ (ver kArqRecoveryWindowPackets). Con μ-law una ráfaga
/// son 16 paquetes de aire, así que 126 cubre con margen de sobra.
const int kMaxConsecutiveLostPackets = 126;

/// Ventana hacia atrás (en números de secuencia) dentro de la cual un
/// paquete "atrasado" se interpreta como retransmisión ARQ y no como un
/// salto gigante hacia adelante. Debe ser MAYOR que el máximo de pérdidas
/// contabilizables de una vez: si fuera menor (bug original: 50 < 63
/// paquetes por ráfaga), la retransmisión de una ráfaga completa caería al
/// detector de pérdidas y se contaría como un falso salto adelante de
/// decenas de miles de paquetes.
const int kArqRecoveryWindowPackets = 128;

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
  final BytesBuilder _burstBuilder = BytesBuilder(copy: true);
  int _txBurstId = 0;
  int _txSeq = 0;
  Future<void> _sendChain = Future.value();

  /// Cancelador de eco (ver echo_canceller.dart) aplicado a lo que SÍ se
  /// captura tras el filtro de semi-dúplex.
  final EchoCanceller _aec = EchoCanceller();

  /// Debe devolver true mientras el parlante propio esté reproduciendo algo
  /// (lo fija AppState apuntando a `audioPlayer.isPlaying`) — es la señal
  /// que activa el semi-dúplex del cancelador de eco.
  bool Function()? isSpeakerActive;
  bool _wasGatingMic = false;

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

  // ── Estado de ARQ (retransmisión de ráfagas a pedido) ─────────────────────
  Uint8List? _lastSentBurstPcm;
  int? _lastSentBurstId;
  int? _lastSentBurstStartSeq;

  /// SEQs marcados como perdidos recientemente, a la espera de una posible
  /// retransmisión. NO se limpia al llegar la siguiente cabecera de ráfaga:
  /// el reenvío viaja encolado detrás de la ráfaga en curso del emisor y es
  /// normal que llegue DESPUÉS de que la siguiente ráfaga ya empezó — solo
  /// la ventana de secuencia ([kArqRecoveryWindowPackets]) decide si un SEQ
  /// atrasado sigue siendo recuperable. Con tope para no crecer sin límite
  /// en sesiones largas con muchas pérdidas nunca recuperadas.
  final Set<int> _recentlyLostSeqs = {};
  static const int _kMaxTrackedLostSeqs = 256;
  int _totalPacketsRecovered = 0;
  int _lastNackEpochMs = 0;

  // ── VAD (no transmitir silencio) ──────────────────────────────────────────
  bool _vadWasSilent = false;
  int _vadSkippedBursts = 0;
  int _vadHangoverRemaining = 0;

  /// Último instante (epoch ms) en que el parlante propio estuvo activo —
  /// sostiene el gate del semi-dúplex durante [kAecGateHangoverMs] extra.
  int _speakerActiveLastMs = 0;

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

  /// Agrupa el Jitter Buffer en clips discretos para reproducción (ver
  /// README/AudioPlayerService: se abandonó el streaming en tiempo real por
  /// un bug nativo confirmado de flutter_sound). El timer es solo la cadencia
  /// de CHEQUEO — el tamaño del clip lo decide _drainToPlaybackQueue:
  /// espera a acumular una ráfaga completa (~2 s) antes de emitir, para que
  /// la pausa de arranque entre clips ocurra solo en el límite natural entre
  /// ráfagas y no cada medio segundo (probado en campo: clips de 500 ms
  /// suenan entrecortados porque cada startPlayer() añade ~100-300 ms de
  /// silencio entre clips).
  Timer? _playbackBatchTimer;
  static const int kPlaybackBatchTickMs = 250;

  /// Tamaño del último tick del Jitter Buffer, para detectar que dejó de
  /// crecer (fin de la ráfaga en tránsito) y vaciar la cola restante.
  int _lastJitterSize = 0;

  // ── Estado de ráfaga entrante en curso ────────────────────────────────────
  int? _rxBurstId;
  int? _rxBurstTxEpochMs;
  int _rxBurstBytesRemaining = 0;

  // ── Métricas de recepción ──────────────────────────────────────────────────
  int _lastSequenceNumber = -1;
  int _totalPacketsReceived = 0;
  int _totalPacketsLost = 0;
  double _currentRssi = -60.0;
  bool _rssiIsReal = false;
  Timer? _rssiTimer;
  bool _rssiPollBusy = false;
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
        final pcmStream = await _capture.startCapture();
        _pcmSub = pcmStream.listen(
          _onPcmChunk,
          onError: (Object e, StackTrace st) {
            _log.w('Error en captura de audio: $e', error: e, stackTrace: st);
            _statusController.add('Error de micrófono: $e');
          },
        );
        _statusController.add(
            'Capturando voz en ráfagas de ${kBurstDurationMs ~/ 1000} s…');
      } catch (e, st) {
        _log.w('No se pudo iniciar el micrófono: $e', error: e, stackTrace: st);
        _statusController.add('No se pudo activar el micrófono: $e');
      }
    } else {
      await _pcmSub?.cancel();
      _pcmSub = null;
      // Descartar el residuo parcial acumulado: si quedara, al reactivar el
      // micrófono la primera ráfaga arrancaría con audio viejo de antes del
      // silencio (confuso para quien escucha).
      _burstBuilder.clear();
      try {
        await _capture.stopCapture();
      } catch (e) {
        _log.w('Error deteniendo captura de audio: $e');
      }
    }
  }

  /// Acumula PCM del micrófono; al completar una ráfaga de 2 s la encola
  /// para envío secuencial (la captura continúa mientras se envía).
  ///
  /// Cancelación de eco en dos capas:
  ///  1. Semi-dúplex (garantizado): mientras el parlante PROPIO está
  ///     reproduciendo algo, se descarta el audio capturado — así nunca se
  ///     envía de vuelta lo que el propio parlante acaba de emitir. Es la
  ///     mitigación principal contra el eco fuerte.
  ///  2. Filtro adaptativo NLMS (ver echo_canceller.dart): sobre lo que SÍ
  ///     se captura, resta el eco residual estimado usando como referencia
  ///     lo que se reprodujo recientemente (colas de reverberación,
  ///     transiciones justo al dejar de estar en semi-dúplex).
  void _onPcmChunk(Uint8List chunk) {
    if (!signalSettings.aecEnabled) {
      // AEC apagado: full-dúplex sin gating ni NLMS — el eco acústico propio
      // (si no hay auriculares) se escucha tal cual, sin ninguna mitigación.
      _wasGatingMic = false;
      _burstBuilder.add(chunk);
      _flushReadyBursts();
      return;
    }

    final bool speakerActive = isSpeakerActive?.call() ?? false;
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    if (speakerActive) _speakerActiveLastMs = nowMs;
    // El gate se sostiene kAecGateHangoverMs después de que el parlante
    // calla: la reverberación de la sala y el AGC del micrófono siguen
    // "escupiendo" eco un momento más allá del fin del clip.
    final bool gated = speakerActive ||
        (nowMs - _speakerActiveLastMs) < kAecGateHangoverMs;
    if (gated) {
      if (!_wasGatingMic) {
        _algorithmLogController.add(
            'AEC: micrófono en semi-dúplex (silenciado mientras reproduce '
            'el parlante propio)');
      }
      _wasGatingMic = true;
      return; // no se acumula ni se envía nada mientras se reproduce
    }
    if (_wasGatingMic) {
      _algorithmLogController.add('AEC: micrófono reactivado');
      _wasGatingMic = false;
    }

    final Uint8List cleaned = _aec.process(chunk);
    _burstBuilder.add(cleaned);
    _flushReadyBursts();
  }

  /// Extrae y envía cada ráfaga completa acumulada en [_burstBuilder].
  ///
  /// BACKPRESSURE (control de saturación): el micrófono produce a ritmo
  /// fijo (1 ráfaga cada 2 s), pero el canal RFCOMM entrega a un ritmo que
  /// depende del entorno — y con AMBOS teléfonos transmitiendo a la vez
  /// (full-dúplex, modo sin optimizar) la demanda combinada puede superar lo
  /// que el enlace físico realmente da. Sin este límite, la cadena de envío
  /// acumulaba ráfagas sin tope: cada una salía más tarde que la anterior,
  /// la latencia SOLO podía crecer, y al final el enlace se ahogaba hasta el
  /// silencio total (confirmado en campo). Con el límite, si ya hay 2
  /// ráfagas esperando turno la nueva se DESCARTA: se pierde ese fragmento
  /// de voz (2 s), pero la conversación se mantiene cerca del presente —
  /// en tiempo real, fresco-e-incompleto vale más que completo-y-atrasado.
  static const int _kMaxBurstsInFlight = 2;
  int _burstsInFlight = 0;
  int _txBurstsDropped = 0;

  void _flushReadyBursts() {
    while (_burstBuilder.length >= kBurstPcmBytes) {
      final all = _burstBuilder.takeBytes();
      final burst = Uint8List.sublistView(all, 0, kBurstPcmBytes);
      if (all.length > kBurstPcmBytes) {
        _burstBuilder.add(Uint8List.sublistView(all, kBurstPcmBytes));
      }

      // ── VAD: el silencio no se transmite ─────────────────────────────
      // Ahorra el canal para quien SÍ está hablando y, de paso, evita que
      // el parlante del otro lado reproduzca silencio sin parar (lo que
      // mantenía su micrófono bloqueado en semi-dúplex — ver kVadRmsThreshold).
      // Con HANGOVER: tras la última ráfaga con voz se transmite
      // [kVadHangoverBursts] ráfaga(s) extra, para que el fragmento hablado
      // termine completo en vez de amputarse cuando la cola de la frase cae
      // bajo el umbral (reportado en campo como "detecta por fragmentos").
      final double rms = DspProcessor.rmsEnergy(burst);
      final bool voiced = rms >= kVadRmsThreshold;
      if (voiced) {
        _vadHangoverRemaining = kVadHangoverBursts;
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
              'VAD: silencio — se deja de transmitir hasta detectar voz '
              '(RMS ${rms.toStringAsFixed(4)})');
        }
        continue;
      }

      if (_burstsInFlight >= _kMaxBurstsInFlight) {
        _txBurstsDropped++;
        _recentLinkStress += 4.0; // saturación propia también es estrés
        _log.w('TX saturado: ráfaga descartada '
            '($_txBurstsDropped descartadas en total)');
        // Solo la 1ª y luego cada 5ª: bajo saturación sostenida este evento
        // se dispara seguido y el spam de log (con su notifyListeners por
        // línea) le quitaría CPU justo al teléfono que ya va ahogado.
        if (_txBurstsDropped == 1 || _txBurstsDropped % 5 == 0) {
          _algorithmLogController.add(
              'Backpressure: canal saturado → ráfaga descartada en el emisor '
              '($_txBurstsDropped en total; no se acumula atraso)');
        }
        continue;
      }

      final id = _txBurstId;
      _txBurstId = (_txBurstId + 1) & 0xFFFF;
      _burstsInFlight++;
      _sendChain = _sendChain
          .then((_) => _sendBurst(id, burst))
          .catchError((Object e) {
        _log.w('Error enviando ráfaga #$id: $e');
      }).whenComplete(() {
        if (_burstsInFlight > 0) _burstsInFlight--;
      });
    }
  }

  /// Envía una ráfaga completa: cabecera con timestamp + paquetes de datos.
  ///
  /// El PCM lineal se comprime a μ-law ANTES de salir al aire (adaptación
  /// de la tasa de la fuente a la capacidad del canal — ver companding.dart):
  /// una ráfaga de 2 s pasa de 32000 B a 16000 B (16 paquetes).
  Future<void> _sendBurst(int burstId, Uint8List pcm) async {
    final Uint8List wire = MuLawCodec.encode(pcm);

    final int txEpochMs = DateTime.now().millisecondsSinceEpoch;
    await _txWrite(buildBurstHeaderPacket(
      burstId: burstId,
      pcmByteLength: wire.length,
      txEpochMs: txEpochMs,
    ));

    // ARQ: se cachea la ráfaga YA CODIFICADA (bytes de aire + SEQ inicial)
    // por si el receptor pide reenvío — el emisor solo guarda la ÚLTIMA,
    // es best-effort (si ya empezó la siguiente, la solicitud llega tarde).
    _lastSentBurstId = burstId;
    _lastSentBurstPcm = wire;
    _lastSentBurstStartSeq = _txSeq;

    int offset = 0;
    int packets = 0;
    while (offset < wire.length) {
      final int end = (offset + kPayloadSize).clamp(0, wire.length);
      Uint8List payload = Uint8List.sublistView(wire, offset, end);
      if (payload.length < kPayloadSize) {
        // Relleno con SILENCIO μ-law (0xFF), no con ceros binarios: 0x00 en
        // μ-law decodifica a casi fondo de escala y sonaría como un clic.
        payload = Uint8List(kPayloadSize)
          ..fillRange(0, kPayloadSize, MuLawCodec.kSilenceByte)
          ..setRange(0, end - offset, payload);
      }
      await _txWrite(buildPacket(_txSeq & 0xFFFF, payload));
      _txSeq++;
      offset += kPayloadSize;
      packets++;
    }

    final int sendMs = DateTime.now().millisecondsSinceEpoch - txEpochMs;
    _log.i(
        'TX ráfaga #$burstId: ${wire.length} B μ-law en $packets paquetes ($sendMs ms)');
  }

  /// ARQ: reenvía todos los paquetes de datos de una ráfaga previamente
  /// cacheada (sin repetir su cabecera — el receptor ya la tiene), usando
  /// los MISMOS números de secuencia originales para que el receptor pueda
  /// reconciliarlos con los que marcó como perdidos.
  Future<void> _resendBurstPackets(int burstId, Uint8List wire, int startSeq) async {
    int seq = startSeq;
    int offset = 0;
    while (offset < wire.length) {
      final int end = (offset + kPayloadSize).clamp(0, wire.length);
      Uint8List payload = Uint8List.sublistView(wire, offset, end);
      if (payload.length < kPayloadSize) {
        payload = Uint8List(kPayloadSize)
          ..fillRange(0, kPayloadSize, MuLawCodec.kSilenceByte)
          ..setRange(0, end - offset, payload);
      }
      await _txWrite(buildPacket(seq & 0xFFFF, payload));
      seq++;
      offset += kPayloadSize;
    }
    _log.i('ARQ: reenviada ráfaga #$burstId completa a pedido del receptor');
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
    if (b0 == kAckMagic0 && b1 == kAckMagic1) return kAckPacketSize;
    if (b0 == kNackMagic0 && b1 == kNackMagic1) return kNackPacketSize;
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
          (b0 == kBurstMagic0 && b1 == kBurstMagic1) || // cabecera de ráfaga
          (b0 == kAckMagic0 && b1 == kAckMagic1) || // ACK de ráfaga
          (b0 == kNackMagic0 && b1 == kNackMagic1) || // NACK (solicitud ARQ)
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

    // ── ACK de ráfaga propia (RTT medido con el reloj local) ────────────
    if (b0 == kAckMagic0 && b1 == kAckMagic1) {
      final ack = BurstAck.parse(packet);
      final double rttMs =
          (DateTime.now().millisecondsSinceEpoch - ack.txEpochMs).toDouble();
      _log.i('ACK ráfaga #${ack.burstId}: latencia de bloque (RTT) '
          '${rttMs.toStringAsFixed(0)} ms');
      _latencyController.add(LatencyMetric(
        burstId: ack.burstId,
        latencyMs: rttMs,
        isRoundTrip: true,
        timestamp: DateTime.now(),
      ));
      return;
    }

    // ── Cabecera de ráfaga entrante ──────────────────────────────────────
    if (b0 == kBurstMagic0 && b1 == kBurstMagic1) {
      final header = BurstHeader.parse(packet);
      _rxBurstId = header.burstId;
      _rxBurstTxEpochMs = header.txEpochMs;
      _rxBurstBytesRemaining = header.pcmByteLength;
      _log.i('RX cabecera ráfaga #${header.burstId}: '
          '${header.pcmByteLength} B esperados');
      return;
    }

    // ── NACK: el otro lado pide reenvío de una ráfaga que él transmitió ──
    if (b0 == kNackMagic0 && b1 == kNackMagic1) {
      final req = NackRequest.parse(packet);
      if (_lastSentBurstId == req.burstId &&
          _lastSentBurstPcm != null &&
          _lastSentBurstStartSeq != null) {
        // El reenvío también respeta el backpressure: retransmitir sobre un
        // canal ya saturado solo profundiza la congestión que causó la
        // pérdida original — mejor dejar que el PLC del receptor cubra ese
        // hueco y conservar el canal para el audio fresco.
        if (_burstsInFlight >= _kMaxBurstsInFlight) {
          _algorithmLogController.add(
              'ARQ: reenvío de ráfaga #${req.burstId} IGNORADO — canal '
              'saturado (retransmitir empeoraría la congestión)');
          return;
        }
        _algorithmLogController.add(
            'ARQ: solicitud de reenvío para ráfaga #${req.burstId} → reenviando');
        final pcm = _lastSentBurstPcm!;
        final startSeq = _lastSentBurstStartSeq!;
        _burstsInFlight++;
        _sendChain = _sendChain
            .then((_) => _resendBurstPackets(req.burstId, pcm, startSeq))
            .catchError((Object e) {
          _log.w('ARQ: error reenviando ráfaga #${req.burstId}: $e');
        }).whenComplete(() {
          if (_burstsInFlight > 0) _burstsInFlight--;
        });
      } else {
        _log.d('ARQ: ráfaga #${req.burstId} ya no está en caché, se ignora');
      }
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

    // ── ARQ: ¿es la retransmisión tardía de un paquete ya marcado perdido? ──
    // Un SEQ "atrasado" respecto al último aceptado, dentro de la ventana de
    // recuperación, no es un paquete nuevo — es la respuesta a un NACK. El
    // payload recuperado se encola al final del Jitter Buffer (sale con el
    // siguiente clip, junto al resto del audio): reproducirlo como clip
    // aparte producía un "clic" de 32 ms con ~200 ms de arranque, y además
    // competía por los 4 cupos de la cola de reproducción con los clips
    // reales. RFCOMM es un transporte ordenado, así que el ÚNICO origen
    // posible de un SEQ atrasado son nuestras propias retransmisiones.
    if (_lastSequenceNumber != -1) {
      final int backDistance = (_lastSequenceNumber - seqNum) & 0xFFFF;
      if (backDistance > 0 && backDistance <= kArqRecoveryWindowPackets) {
        if (_recentlyLostSeqs.remove(seqNum)) {
          _totalPacketsRecovered++;
          _totalPacketsLost = (_totalPacketsLost - 1).clamp(0, 1 << 30);
          final recoveredWire = Uint8List.sublistView(packet, 4, kPacketSize);
          _dsp.processBlock(
            rawBlock:
                _rxIsMuLaw ? MuLawCodec.decode(recoveredWire) : recoveredWire,
            rssiDbm: _effectiveRssi,
            isLost: false,
            plcEnabled: signalSettings.plcEnabled,
            filterEnabled: signalSettings.filterEnabled,
            fecEnabled: signalSettings.fecEnabled,
            numChannels: _rxNumChannels,
            bitsPerSample: _rxBitsPerSample,
            lostBlockSize: _rxBlockSizeDecoded,
          );
          _algorithmLogController.add(
              'ARQ: paquete SEQ=$seqNum recuperado por retransmisión '
              '(añadido al final del buffer)');
          _metricsController.add(currentMetrics);
        } else {
          _log.d('Paquete SEQ=$seqNum ignorado (duplicado o fuera de '
              'ventana ARQ)');
        }
        return;
      }
    }

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

        if (signalSettings.arqEnabled && _rxBurstId != null) {
          for (int i = 0; i < lostInGap; i++) {
            _recentlyLostSeqs.add((expected + i) & 0xFFFF);
          }
          while (_recentlyLostSeqs.length > _kMaxTrackedLostSeqs) {
            _recentlyLostSeqs.remove(_recentlyLostSeqs.first);
          }
          // Disciplina anti-congestión: como mucho un NACK cada
          // kMinNackIntervalMs — pedir reenvío por CADA hueco en un canal
          // ya estresado realimenta la congestión (reenvíos → más carga →
          // más huecos → más reenvíos) en vez de corregirla.
          final int nowMs = DateTime.now().millisecondsSinceEpoch;
          if (nowMs - _lastNackEpochMs >= kMinNackIntervalMs) {
            _lastNackEpochMs = nowMs;
            _algorithmLogController
                .add('ARQ: solicitando reenvío de la ráfaga #$_rxBurstId');
            unawaited(_txWrite(buildNackPacket(burstId: _rxBurstId!))
                .catchError((Object e) {
              _log.w('No se pudo enviar NACK: $e');
            }));
          }
        }

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
          _consumeBurstBytes(kPayloadSize);
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
    if (_dsp.lastFecCorrectedBits > 0) {
      _algorithmLogController.add(
          'FEC (Hamming 7,4): ${_dsp.lastFecCorrectedBits} bit(s) '
          'corregidos automáticamente');
    }
    _consumeBurstBytes(kPayloadSize);

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
      packetsRecovered: _totalPacketsRecovered,
      timestamp: DateTime.now(),
    ));
  }

  /// Descuenta bytes de la ráfaga en curso; al completarla estima el tiempo
  /// de tránsito, emite la métrica y responde ACK (fire-and-forget: no debe
  /// bloquear el pipeline de recepción si la escritura tarda).
  void _consumeBurstBytes(int bytes) {
    if (_rxBurstId == null) return;
    _rxBurstBytesRemaining -= bytes;
    if (_rxBurstBytesRemaining > 0) return;

    final int rxEpochMs = DateTime.now().millisecondsSinceEpoch;
    final double transitMs = (rxEpochMs - _rxBurstTxEpochMs!).toDouble();
    _log.i('RX ráfaga #$_rxBurstId completa: tránsito '
        '${transitMs.toStringAsFixed(0)} ms (relojes no sincronizados)');

    _latencyController.add(LatencyMetric(
      burstId: _rxBurstId!,
      latencyMs: transitMs,
      isRoundTrip: false,
      timestamp: DateTime.now(),
    ));

    unawaited(_txWrite(buildAckPacket(
      burstId: _rxBurstId!,
      txEpochMs: _rxBurstTxEpochMs!,
      rxEpochMs: rxEpochMs,
    )).catchError((Object e) {
      _log.w('No se pudo enviar ACK de ráfaga #$_rxBurstId: $e');
    }));

    _rxBurstId = null;
    _rxBurstTxEpochMs = null;
    _rxBurstBytesRemaining = 0;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // REPRODUCCIÓN — AGRUPAR EL JITTER BUFFER EN CLIPS DISCRETOS
  // ──────────────────────────────────────────────────────────────────────────

  /// Fija el formato de audio entrante y asegura que el temporizador de
  /// agrupado esté corriendo. Operación puramente local y síncrona — no hay
  /// ningún estado de reproductor nativo persistente que reiniciar, así que
  /// no existe el riesgo de arranques concurrentes que teníamos con el
  /// streaming en tiempo real (ver AudioPlayerService).
  void _beginPlayback(int sampleRate, int numChannels, int bitsPerSample) {
    _rxSampleRate = sampleRate;
    _rxNumChannels = numChannels;
    _rxBitsPerSample = bitsPerSample;
    _onWavInfoCallback?.call(sampleRate, numChannels, bitsPerSample);
    _startPlaybackBatching();
  }

  /// Arranca (si no estaba corriendo) el timer de chequeo del agrupado.
  void _startPlaybackBatching() {
    if (_playbackBatchTimer != null) return;
    _lastJitterSize = 0;
    _playbackBatchTimer = Timer.periodic(
      const Duration(milliseconds: kPlaybackBatchTickMs),
      (_) => _drainToPlaybackQueue(),
    );
  }

  /// Bloques que debe acumular el Jitter Buffer antes de emitir un clip:
  /// una ráfaga completa de audio DECODIFICADO. Con μ-law cada bloque de
  /// 1020 B de aire se expande a 2040 B de PCM, así que 2 s de voz a 8 kHz
  /// (32000 B) son ~15 bloques; en modo .wav (PCM lineal) el bloque queda
  /// de 1020 B. Depende del códec anunciado, por eso no puede ser estático.
  int get _minClipBlocks => kBurstPcmBytes ~/ _rxBlockSizeDecoded;

  /// Emite un clip solo cuando hay una ráfaga completa acumulada, O cuando
  /// el buffer dejó de crecer entre ticks (llegó el final de la transmisión
  /// o una ráfaga incompleta por pérdidas) — así el clip típico dura ~2 s y
  /// la pausa de arranque entre clips cae en el límite natural entre
  /// ráfagas, en vez de trocear la voz cada 500 ms.
  void _drainToPlaybackQueue() {
    final int size = _dsp.jitterBuffer.size;
    if (size == 0) {
      _lastJitterSize = 0;
      return;
    }
    final bool fullClip = size >= _minClipBlocks;
    final bool stalled = size == _lastJitterSize;
    _lastJitterSize = size;
    if (!fullClip && !stalled) return; // seguir acumulando

    final builder = BytesBuilder(copy: false);
    Uint8List? block;
    while ((block = _dsp.jitterBuffer.pop()) != null) {
      builder.add(block!);
    }
    _lastJitterSize = 0;
    if (builder.isEmpty) return;
    final clip = builder.toBytes();
    _audioChunkController.add(clip);
    _aec.pushReference(clip); // referencia far-end para el cancelador de eco

    // Teoría de la Información (Cap. IV): capacidad de Shannon del canal
    // (con el RSSI efectivo como proxy de SNR — si el canal degradado está
    // forzado para la demo, la capacidad reportada baja coherentemente) y
    // entropía de la fuente medida sobre el clip que se acaba de completar.
    final double capacityBps = InformationTheory.shannonCapacityBps(
      rssiDbm: _effectiveRssi,
      sampleRate: _rxSampleRate,
    );
    final double entropy = InformationTheory.sourceEntropyBitsPerSample(clip);
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
      'Clip reproducido (${(clip.length / 1024).toStringAsFixed(1)} KB): '
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
    _rssiTimer = Timer.periodic(
      const Duration(milliseconds: kRssiPollIntervalMs),
      (_) async {
        // Timer.periodic NO espera al cuerpo async: sin este guard, una
        // lectura GATT lenta (hasta 3 s de timeout) se solaparía con los
        // ticks siguientes, apilando conexiones GATT concurrentes al mismo
        // dispositivo — cada una consume un handle del sistema.
        if (_rssiPollBusy) return;
        _rssiPollBusy = true;
        try {
          _currentRssi = await RssiChannel.getRssi(address);
          _rssiIsReal = true;
        } catch (_) {
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
    _totalPacketsRecovered = 0;
    _recentlyLostSeqs.clear();
    _rxIsMuLaw = false;
    _lastNackEpochMs = 0;
    _recentLinkStress = 0.0;
    _rxBurstId = null;
    _rxBurstTxEpochMs = null;
    _rxBurstBytesRemaining = 0;
    _dsp.reset();
  }

  void _resetTxState() {
    _txBurstId = 0;
    _txSeq = 0;
    _burstBuilder.clear();
    _sendChain = Future.value();
    _burstsInFlight = 0;
    _txBurstsDropped = 0;
    _vadWasSilent = false;
    _vadSkippedBursts = 0;
    _vadHangoverRemaining = 0;
    _speakerActiveLastMs = 0;
    _aec.reset();
    _wasGatingMic = false;
    _lastSentBurstPcm = null;
    _lastSentBurstId = null;
    _lastSentBurstStartSeq = null;
  }

  /// Detiene la transmisión/recepción y cierra la conexión.
  Future<void> disconnect() async {
    _serverTxActive = false;
    _rssiTimer?.cancel();
    _rssiTimer = null;
    _playbackBatchTimer?.cancel();
    _playbackBatchTimer = null;
    _lastJitterSize = 0;
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
      packetsRecovered: _totalPacketsRecovered,
      timestamp: DateTime.now(),
    );
  }
}
