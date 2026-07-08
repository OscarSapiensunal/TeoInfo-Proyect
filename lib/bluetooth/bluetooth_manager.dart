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
import 'dart:typed_data';

import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:logger/logger.dart';

import '../models/app_models.dart';
import '../dsp/dsp_processor.dart';
import 'audio_capture_service.dart';
import 'rfcomm_server.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTES DE PROTOCOLO
// ─────────────────────────────────────────────────────────────────────────────

/// Intervalo entre paquetes en modo archivo WAV (ms).
const int kPacketIntervalMs = 11;

/// Período de consulta de RSSI (ms).
const int kRssiPollIntervalMs = 1000;

/// Número máximo de paquetes perdidos consecutivos antes de limitar el conteo.
const int kMaxConsecutiveLostPackets = 50;

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

  // ── Estado de RX (formato de audio entrante y reproducción) ──────────────
  int _rxNumChannels = kMicNumChannels;
  int _rxBitsPerSample = kMicBitsPerSample;
  void Function(int sr, int nc, int bps)? _onWavInfoCallback;

  /// Agrupa el Jitter Buffer en clips de ~500 ms para reproducirse como
  /// archivos discretos (ver README/AudioPlayerService: se abandonó el
  /// streaming en tiempo real por un bug nativo confirmado de flutter_sound).
  Timer? _playbackBatchTimer;
  static const int kPlaybackBatchMs = 500;

  // ── Estado de ráfaga entrante en curso ────────────────────────────────────
  int? _rxBurstId;
  int? _rxBurstTxEpochMs;
  int _rxBurstBytesRemaining = 0;

  // ── Métricas de recepción ──────────────────────────────────────────────────
  int _lastSequenceNumber = -1;
  int _totalPacketsReceived = 0;
  int _totalPacketsLost = 0;
  double _currentRssi = -60.0;
  Timer? _rssiTimer;

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

  /// Stream de métricas en tiempo real (RSSI, packet loss, buffer fill).
  Stream<ChannelMetrics> get metricsStream => _metricsController.stream;

  /// Stream de bloques de audio PCM procesados para el motor de reproducción.
  Stream<Uint8List> get audioChunkStream => _audioChunkController.stream;

  /// Stream de mensajes de estado para la UI.
  Stream<String> get statusStream => _statusController.stream;

  /// Stream de latencias por ráfaga (RTT de los paquetes propios enviados).
  Stream<LatencyMetric> get latencyStream => _latencyController.stream;

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
      try {
        await _capture.stopCapture();
      } catch (e) {
        _log.w('Error deteniendo captura de audio: $e');
      }
    }
  }

  /// Acumula PCM del micrófono; al completar una ráfaga de 2 s la encola
  /// para envío secuencial (la captura continúa mientras se envía).
  void _onPcmChunk(Uint8List chunk) {
    _burstBuilder.add(chunk);
    while (_burstBuilder.length >= kBurstPcmBytes) {
      final all = _burstBuilder.takeBytes();
      final burst = Uint8List.sublistView(all, 0, kBurstPcmBytes);
      if (all.length > kBurstPcmBytes) {
        _burstBuilder.add(Uint8List.sublistView(all, kBurstPcmBytes));
      }

      final id = _txBurstId;
      _txBurstId = (_txBurstId + 1) & 0xFFFF;
      _sendChain = _sendChain
          .then((_) => _sendBurst(id, burst))
          .catchError((Object e) {
        _log.w('Error enviando ráfaga #$id: $e');
      });
    }
  }

  /// Envía una ráfaga completa: cabecera con timestamp + paquetes de datos.
  Future<void> _sendBurst(int burstId, Uint8List pcm) async {
    final int txEpochMs = DateTime.now().millisecondsSinceEpoch;
    await _txWrite(buildBurstHeaderPacket(
      burstId: burstId,
      pcmByteLength: pcm.length,
      txEpochMs: txEpochMs,
    ));

    int offset = 0;
    int packets = 0;
    while (offset < pcm.length) {
      final int end = (offset + kPayloadSize).clamp(0, pcm.length);
      Uint8List payload = Uint8List.sublistView(pcm, offset, end);
      if (payload.length < kPayloadSize) {
        payload = Uint8List(kPayloadSize)..setRange(0, end - offset, payload);
      }
      await _txWrite(buildPacket(_txSeq & 0xFFFF, payload));
      _txSeq++;
      offset += kPayloadSize;
      packets++;
    }

    final int sendMs = DateTime.now().millisecondsSinceEpoch - txEpochMs;
    _log.i(
        'TX ráfaga #$burstId: ${pcm.length} B en $packets paquetes ($sendMs ms)');
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
  /// Estructura: [0xCC, 0xDD, numChannels, bitsPerSample, SR_B0..SR_B3, ...]
  Future<void> _sendStreamInfoPacket({
    required int sampleRate,
    required int numChannels,
    required int bitsPerSample,
  }) async {
    final meta = Uint8List(kPacketSize);
    meta[0] = 0xCC;
    meta[1] = 0xDD;
    meta[2] = numChannels & 0xFF;
    meta[3] = bitsPerSample & 0xFF;
    final view = ByteData.sublistView(meta);
    view.setUint32(4, sampleRate, Endian.little);
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
      _log.i('Meta-paquete audio: ${sr}Hz, ${nc}ch, ${bps}bit');
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
        _log.w('Pérdida detectada: seq esperada=$expected recibida=$seqNum '
            'perdidos=$lostInGap');

        for (int i = 0; i < lostInGap; i++) {
          _dsp.processBlock(
            rawBlock: null,
            rssiDbm: _currentRssi,
            isLost: true,
            numChannels: _rxNumChannels,
            bitsPerSample: _rxBitsPerSample,
          );
          _consumeBurstBytes(kPayloadSize);
        }
      }
    }

    _lastSequenceNumber = seqNum;
    _totalPacketsReceived++;

    // ── Extraer payload y procesar con DSP (encola en el Jitter Buffer) ──
    final payload = Uint8List.sublistView(packet, 4, kPacketSize);
    _dsp.processBlock(
      rawBlock: payload,
      rssiDbm: _currentRssi,
      isLost: false,
      numChannels: _rxNumChannels,
      bitsPerSample: _rxBitsPerSample,
    );
    _consumeBurstBytes(kPayloadSize);

    // ── Emitir métricas actualizadas ─────────────────────────────────────
    final total = _totalPacketsReceived + _totalPacketsLost;
    final lossPercent =
        total > 0 ? (_totalPacketsLost / total * 100.0) : 0.0;

    _metricsController.add(ChannelMetrics(
      rssiDbm: _currentRssi,
      packetLossPercent: lossPercent,
      bufferFillRatio: _dsp.jitterBuffer.fillRatio,
      packetsReceived: _totalPacketsReceived,
      packetsLost: _totalPacketsLost,
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
    _rxNumChannels = numChannels;
    _rxBitsPerSample = bitsPerSample;
    _onWavInfoCallback?.call(sampleRate, numChannels, bitsPerSample);
    _startPlaybackBatching();
  }

  /// Arranca (si no estaba corriendo) el timer que cada [kPlaybackBatchMs]
  /// ms extrae TODO lo acumulado en el Jitter Buffer y lo emite como un solo
  /// clip para reproducirse con `AudioPlayerService.enqueueChunk()`. El
  /// Jitter Buffer sigue absorbiendo la llegada a ráfagas de los paquetes
  /// BT; este timer solo decide cada cuánto se corta esa cola en clips
  /// reproducibles.
  void _startPlaybackBatching() {
    if (_playbackBatchTimer != null) return;
    _playbackBatchTimer = Timer.periodic(
      const Duration(milliseconds: kPlaybackBatchMs),
      (_) => _drainToPlaybackQueue(),
    );
  }

  void _drainToPlaybackQueue() {
    if (_dsp.jitterBuffer.isEmpty) return;
    final builder = BytesBuilder(copy: false);
    Uint8List? block;
    while ((block = _dsp.jitterBuffer.pop()) != null) {
      builder.add(block!);
    }
    if (builder.isEmpty) return;
    _audioChunkController.add(builder.toBytes());
  }

  // ──────────────────────────────────────────────────────────────────────────
  // POLLING DE RSSI
  // ──────────────────────────────────────────────────────────────────────────

  void _startRssiPolling(String address) {
    _rssiTimer = Timer.periodic(
      const Duration(milliseconds: kRssiPollIntervalMs),
      (_) async {
        try {
          final rssi = await _getRssiNative(address);
          _currentRssi = rssi;
        } catch (_) {
          _currentRssi += (_currentRssi > -90.0 ? -0.5 : 0.5);
        }
      },
    );
  }

  Future<double> _getRssiNative(String address) async {
    throw UnimplementedError('Canal nativo RSSI no implementado en esta plataforma');
  }

  // ──────────────────────────────────────────────────────────────────────────
  // CONTROL DE CICLO DE VIDA
  // ──────────────────────────────────────────────────────────────────────────

  void _resetRxState() {
    _receiveBuffer.clear();
    _lastSequenceNumber = -1;
    _totalPacketsReceived = 0;
    _totalPacketsLost = 0;
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
  }

  /// Detiene la transmisión/recepción y cierra la conexión.
  Future<void> disconnect() async {
    _serverTxActive = false;
    _rssiTimer?.cancel();
    _rssiTimer = null;
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
  }

  bool get isConnected =>
      _serverTxActive || (_connection?.isConnected ?? false);

  ChannelMetrics get currentMetrics {
    final total = _totalPacketsReceived + _totalPacketsLost;
    return ChannelMetrics(
      rssiDbm: _currentRssi,
      packetLossPercent: total > 0 ? _totalPacketsLost / total * 100.0 : 0.0,
      bufferFillRatio: _dsp.jitterBuffer.fillRatio,
      packetsReceived: _totalPacketsReceived,
      packetsLost: _totalPacketsLost,
      timestamp: DateTime.now(),
    );
  }
}
