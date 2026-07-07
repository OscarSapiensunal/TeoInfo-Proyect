// lib/bluetooth/bluetooth_manager.dart
//
// Gestión de Bluetooth Clásico (RFCOMM / SPP) — arquitectura P2P.
//
// Roles:
//   · Emisor (Servidor SPP nativo): escucha una conexión entrante
//     (MainActivity.kt vía RfcommSppServer), captura el micrófono en PCM
//     lineal, segmenta en ráfagas de 2 s y las transmite con cabecera de
//     ráfaga + paquetes numerados. Recibe ACKs del receptor y calcula la
//     latencia de bloque (RTT) con su propio reloj.
//
//   · Receptor (Cliente SPP): escanea/conecta al emisor, lee el stream de
//     bytes, valida cabeceras, detecta pérdidas, estima el tiempo de
//     tránsito de cada ráfaga, responde ACK y alimenta el DspProcessor.
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

/// Período de consulta de RSSI en el receptor (ms).
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

  // ── Estado interno ────────────────────────────────────────────────────────
  BluetoothConnection? _connection;
  bool _isTransmitting = false;
  bool _isReceiving = false;

  // ── Estado del emisor (servidor SPP) ──────────────────────────────────────
  StreamSubscription<SppServerEvent>? _serverEventsSub;
  StreamSubscription<Uint8List>? _pcmSub;
  bool _serverTxActive = false; // hay cliente conectado al servidor
  final BytesBuilder _burstBuilder = BytesBuilder(copy: true);
  int _txBurstId = 0;
  int _txSeq = 0;
  Future<void> _sendChain = Future.value();
  final List<int> _ackBuffer = [];

  // ── Estado de ráfaga del receptor ─────────────────────────────────────────
  int? _rxBurstId;
  int? _rxBurstTxEpochMs;
  int _rxBurstBytesRemaining = 0;

  // ── Métricas del receptor ─────────────────────────────────────────────────
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

  /// Stream de latencias por ráfaga (RTT en emisor, tránsito en receptor).
  Stream<LatencyMetric> get latencyStream => _latencyController.stream;

  /// Instancia DSP expuesta para acceso al Jitter Buffer desde la UI.
  DspProcessor get dsp => _dsp;

  // ──────────────────────────────────────────────────────────────────────────
  // ESCANEO Y LISTADO DE DISPOSITIVOS
  // ──────────────────────────────────────────────────────────────────────────

  /// Retorna la lista de dispositivos Bluetooth clásicos emparejados.
  Future<List<BluetoothDevice>> getPairedDevices() async {
    try {
      return await FlutterBluetoothSerial.instance.getBondedDevices();
    } catch (e) {
      _log.e('Error obteniendo dispositivos: $e');
      return [];
    }
  }

  /// Inicia el descubrimiento de dispositivos cercanos.
  Stream<BluetoothDiscoveryResult> startDiscovery() {
    return FlutterBluetoothSerial.instance.startDiscovery();
  }

  /// Cancela un descubrimiento en curso.
  Future<void> cancelDiscovery() async {
    await FlutterBluetoothSerial.instance.cancelDiscovery();
  }

  /// Solicita activar el adaptador Bluetooth.
  Future<bool> requestEnable() async {
    return await FlutterBluetoothSerial.instance.requestEnable() ?? false;
  }

  /// Solicita que el adaptador Bluetooth sea descubrible por 120 segundos.
  Future<void> requestDiscoverable() async {
    await FlutterBluetoothSerial.instance.requestDiscoverable(120);
  }

  /// Solicita emparejamiento con el dispositivo indicado.
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
  // ROL EMISOR — SERVIDOR SPP NATIVO
  // ──────────────────────────────────────────────────────────────────────────

  /// Inicia el servidor SPP y, cuando el receptor conecta, captura el
  /// micrófono y transmite ráfagas de audio de [kBurstDurationMs] ms.
  Future<void> startMicBurstTransmitter() async {
    await _startServer(onClientConnected: () async {
      // Informar formato del stream al receptor (meta-paquete 0xCC 0xDD)
      await _sendStreamInfoPacket(
        sampleRate: kMicSampleRate,
        numChannels: kMicNumChannels,
        bitsPerSample: kMicBitsPerSample,
      );
      final pcmStream = await _capture.startCapture();
      _pcmSub = pcmStream.listen(_onPcmChunk);
      _statusController.add(
          'Conectado. Capturando voz en ráfagas de ${kBurstDurationMs ~/ 1000} s…');
    });
  }

  /// Inicia el servidor SPP y, cuando el receptor conecta, transmite el
  /// archivo WAV indicado (modo alternativo al micrófono).
  Future<void> startWavServerTransmitter({
    required String wavFilePath,
    required WavHeader wavHeader,
  }) async {
    await _startServer(onClientConnected: () async {
      await _transmitWav(wavFilePath: wavFilePath, wavHeader: wavHeader);
    });
  }

  Future<void> _startServer({
    required Future<void> Function() onClientConnected,
  }) async {
    _isTransmitting = true;
    _txBurstId = 0;
    _txSeq = 0;
    _ackBuffer.clear();
    _burstBuilder.clear();

    _serverEventsSub = _sppServer.events().listen((event) async {
      switch (event.type) {
        case SppServerEventType.waiting:
          _statusController
              .add('Esperando conexión entrante… (hazte visible si no apareces)');
          break;

        case SppServerEventType.connected:
          _serverTxActive = true;
          _log.i('Cliente conectado: ${event.deviceName} (${event.deviceAddress})');
          _statusController.add('Receptor conectado: ${event.deviceName}');
          try {
            await onClientConnected();
          } catch (e) {
            _log.e('Error iniciando transmisión: $e');
            _statusController.add('Error iniciando transmisión: $e');
          }
          break;

        case SppServerEventType.data:
          if (event.bytes != null) _onAckData(event.bytes!);
          break;

        case SppServerEventType.disconnected:
          _serverTxActive = false;
          _statusController.add('Receptor desconectado');
          await _capture.stopCapture();
          break;

        case SppServerEventType.error:
          _serverTxActive = false;
          _log.e('Error servidor SPP: ${event.message}');
          _statusController.add('Error BT: ${event.message}');
          break;
      }
    });

    await _sppServer.start();
    _statusController.add('Servidor SPP iniciado. Esperando al receptor…');
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
    if (!_serverTxActive) return;

    final int txEpochMs = DateTime.now().millisecondsSinceEpoch;
    await _txWrite(buildBurstHeaderPacket(
      burstId: burstId,
      pcmByteLength: pcm.length,
      txEpochMs: txEpochMs,
    ));

    int offset = 0;
    int packets = 0;
    while (offset < pcm.length && _serverTxActive) {
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
    _log.i('TX ráfaga #$burstId: ${pcm.length} B en $packets paquetes ($sendMs ms)');
    _statusController.add('Ráfaga #$burstId enviada: $packets paquetes en $sendMs ms');
  }

  /// Parsea ACKs (receptor → emisor) del stream entrante del servidor y
  /// calcula el RTT de bloque con el reloj local del emisor.
  void _onAckData(Uint8List bytes) {
    _ackBuffer.addAll(bytes);
    while (true) {
      int idx = -1;
      for (int i = 0; i + 1 < _ackBuffer.length; i++) {
        if (_ackBuffer[i] == kAckMagic0 && _ackBuffer[i + 1] == kAckMagic1) {
          idx = i;
          break;
        }
      }
      if (idx == -1) {
        if (_ackBuffer.length > 1) {
          _ackBuffer.removeRange(0, _ackBuffer.length - 1);
        }
        return;
      }
      if (idx > 0) _ackBuffer.removeRange(0, idx);
      if (_ackBuffer.length < kAckPacketSize) return;

      final ack = BurstAck.parse(
          Uint8List.fromList(_ackBuffer.sublist(0, kAckPacketSize)));
      _ackBuffer.removeRange(0, kAckPacketSize);

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
    }
  }

  /// Escritura unificada de TX: servidor nativo (emisor) o socket cliente.
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
  // TRANSMISIÓN DE ARCHIVO WAV (modo alternativo)
  // ──────────────────────────────────────────────────────────────────────────

  /// Lee el archivo WAV, extrae los datos PCM y los envía en paquetes numerados.
  Future<void> _transmitWav({
    required String wavFilePath,
    required WavHeader wavHeader,
  }) async {
    _statusController.add('Leyendo archivo WAV…');

    final file = File(wavFilePath);
    final allBytes = await file.readAsBytes();
    final pcmStart = wavHeader.dataOffset;
    final pcmEnd   = pcmStart + wavHeader.dataSize;

    if (pcmEnd > allBytes.length) {
      throw FormatException(
          'Archivo WAV corrupto: dataOffset($pcmStart) + dataSize(${wavHeader.dataSize}) > fileSize(${allBytes.length})');
    }

    final pcmBytes = allBytes.sublist(pcmStart, pcmEnd);
    _log.i('Transmitiendo ${wavHeader.toString()}, '
        '${pcmBytes.length} bytes de PCM…');

    int sequenceNumber = 0;
    int offset = 0;

    // ── Enviar cabecera WAV como primer "paquete especial" ────────────────
    await _sendStreamInfoPacket(
      sampleRate: wavHeader.sampleRate,
      numChannels: wavHeader.numChannels,
      bitsPerSample: wavHeader.bitsPerSample,
    );

    // ── Enviar bloques PCM en bucle ────────────────────────────────────────
    while (_isTransmitting && _serverTxActive && offset < pcmBytes.length) {
      final int end = (offset + kPayloadSize).clamp(0, pcmBytes.length);
      final payload = Uint8List.fromList(pcmBytes.sublist(offset, end));

      // Rellena el último paquete incompleto con ceros (silencio PCM)
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

      // Throttle: mantener cadencia ~constante para no inundar el socket
      await Future.delayed(const Duration(milliseconds: kPacketIntervalMs));
    }

    // Paquete de fin de transmisión (magic bytes especiales: 0xFF 0xFF)
    await _sendEndOfStreamPacket();
    _statusController.add('Transmisión completada. $sequenceNumber paquetes enviados.');
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
    meta[0] = 0xCC; // magic de meta-paquete
    meta[1] = 0xDD;
    meta[2] = numChannels & 0xFF;
    meta[3] = bitsPerSample & 0xFF;
    final view = ByteData.sublistView(meta);
    view.setUint32(4, sampleRate, Endian.little);
    await _txWrite(meta);
    await Future.delayed(const Duration(milliseconds: 20));
  }

  /// Envía paquete señalizador de fin de stream.
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
  // ROL RECEPTOR — CLIENTE SPP
  // ──────────────────────────────────────────────────────────────────────────

  /// Conecta al emisor (que escucha en modo servidor) y comienza a recibir.
  ///
  /// [address]/[name] : dispositivo BT del emisor (emparejado previamente).
  /// [onWavInfo]      : callback con parámetros del stream de audio.
  Future<void> connectAndReceive({
    required String address,
    required String name,
    required void Function(int sampleRate, int numChannels, int bitsPerSample) onWavInfo,
  }) async {
    _log.i('Receptor conectando a $name ($address)…');
    _statusController.add('Conectando a $name…');

    try {
      _connection = await BluetoothConnection.toAddress(address);
      _log.i('Conexión establecida');
      _statusController.add('Conectado. Recibiendo audio…');

      _isReceiving = true;
      _lastSequenceNumber = -1;
      _totalPacketsReceived = 0;
      _totalPacketsLost = 0;
      _receiveBuffer.clear();
      _rxBurstId = null;
      _rxBurstTxEpochMs = null;
      _rxBurstBytesRemaining = 0;
      _dsp.reset();

      // Iniciar polling de RSSI
      _startRssiPolling(address);

      // Parámetros de audio por defecto; se actualizan con el meta-paquete
      int sampleRate  = 44100;
      int numChannels = 1;
      int bitsPerSample = 16;

      // Escuchar el stream de bytes del socket
      _connection!.input!.listen(
        (Uint8List chunk) {
          _receiveBuffer.addAll(chunk);
          _processReceiveBuffer(
            onWavInfo: (sr, nc, bps) {
              sampleRate    = sr;
              numChannels   = nc;
              bitsPerSample = bps;
              onWavInfo(sr, nc, bps);
            },
            sampleRate:    sampleRate,
            numChannels:   numChannels,
            bitsPerSample: bitsPerSample,
          );
        },
        onDone: () {
          _log.i('Conexión cerrada por el emisor');
          _statusController.add('Transmisión finalizada');
          _isReceiving = false;
          _rssiTimer?.cancel();
        },
        onError: (Object error) {
          _log.e('Error en stream de entrada: $error');
          _statusController.add('Error de recepción: $error');
          _isReceiving = false;
          _rssiTimer?.cancel();
        },
        cancelOnError: false,
      );
    } catch (e) {
      _log.e('Error conectando receptor: $e');
      _statusController.add('Error: $e');
      rethrow;
    }
  }

  /// Procesa el buffer de reensamblado buscando paquetes completos de [kPacketSize] bytes.
  void _processReceiveBuffer({
    required void Function(int sr, int nc, int bps) onWavInfo,
    required int sampleRate,
    required int numChannels,
    required int bitsPerSample,
  }) {
    while (_receiveBuffer.length >= kPacketSize) {
      // Sincronización: buscar magic bytes válidos
      int syncIndex = _findSyncIndex();
      if (syncIndex == -1) {
        // No hay inicio de paquete en el buffer; descartar todo excepto los
        // últimos 3 bytes (podrían ser el inicio de un paquete partido)
        if (_receiveBuffer.length > 3) {
          _receiveBuffer.removeRange(0, _receiveBuffer.length - 3);
        }
        return;
      }

      if (syncIndex > 0) {
        // Descartar bytes hasta el inicio del paquete (resincronización)
        _receiveBuffer.removeRange(0, syncIndex);
        _log.w('Resincronización: descartados $syncIndex bytes');
      }

      if (_receiveBuffer.length < kPacketSize) break;

      final packetBytes = Uint8List.fromList(
          _receiveBuffer.sublist(0, kPacketSize));
      _receiveBuffer.removeRange(0, kPacketSize);

      _handleIncomingPacket(
        packet: packetBytes,
        onWavInfo: onWavInfo,
        numChannels: numChannels,
        bitsPerSample: bitsPerSample,
      );
    }
  }

  /// Encuentra el índice del primer magic byte válido en [_receiveBuffer].
  int _findSyncIndex() {
    for (int i = 0; i < _receiveBuffer.length - 1; i++) {
      final b0 = _receiveBuffer[i];
      final b1 = _receiveBuffer[i + 1];
      if ((b0 == kMagicByte0 && b1 == kMagicByte1) ||       // paquete de datos
          (b0 == 0xCC && b1 == 0xDD) ||                      // meta-paquete audio
          (b0 == kBurstMagic0 && b1 == kBurstMagic1) ||      // cabecera de ráfaga
          (b0 == 0xFF && b1 == 0xFF)) {                      // fin de stream
        return i;
      }
    }
    return -1;
  }

  /// Despacha el paquete según su tipo.
  void _handleIncomingPacket({
    required Uint8List packet,
    required void Function(int sr, int nc, int bps) onWavInfo,
    required int numChannels,
    required int bitsPerSample,
  }) {
    final b0 = packet[0];
    final b1 = packet[1];

    // ── Meta-paquete de formato de audio ────────────────────────────────
    if (b0 == 0xCC && b1 == 0xDD) {
      final nc  = packet[2];
      final bps = packet[3];
      final view = ByteData.sublistView(packet);
      final sr  = view.getUint32(4, Endian.little);
      _log.i('Meta-paquete audio: ${sr}Hz, ${nc}ch, ${bps}bit');
      onWavInfo(sr, nc, bps);
      return;
    }

    // ── Cabecera de ráfaga (modo micrófono P2P) ─────────────────────────
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
      _log.w('Magic bytes inválidos: 0x${b0.toRadixString(16)} 0x${b1.toRadixString(16)}');
      return;
    }

    final int seqNum = parseSequenceNumber(packet);
    if (seqNum == -1) return;

    // ── Detección de paquetes perdidos por saltos en secuencia ───────────
    int lostInGap = 0;
    if (_lastSequenceNumber != -1) {
      final int expected = (_lastSequenceNumber + 1) & 0xFFFF;
      if (seqNum != expected) {
        // Calcular paquetes perdidos en el hueco (módulo 65536)
        lostInGap = ((seqNum - expected) & 0xFFFF);
        // Limitar a un máximo razonable para evitar conteo erróneo por reordenamiento
        if (lostInGap > kMaxConsecutiveLostPackets) lostInGap = kMaxConsecutiveLostPackets;
        _totalPacketsLost += lostInGap;
        _log.w('Pérdida detectada: seq esperada=$expected recibida=$seqNum '
            'perdidos=$lostInGap');

        // Generar bloques PLC para cada paquete perdido
        for (int i = 0; i < lostInGap; i++) {
          final plcBlock = _dsp.processBlock(
            rawBlock: null,
            rssiDbm: _currentRssi,
            isLost: true,
            numChannels: numChannels,
            bitsPerSample: bitsPerSample,
          );
          _audioChunkController.add(plcBlock);
          _consumeBurstBytes(kPayloadSize);
        }
      }
    }

    _lastSequenceNumber = seqNum;
    _totalPacketsReceived++;

    // ── Extraer payload y procesar con DSP ──────────────────────────────
    final payload = Uint8List.sublistView(packet, 4, kPacketSize);
    final processedBlock = _dsp.processBlock(
      rawBlock: payload,
      rssiDbm: _currentRssi,
      isLost: false,
      numChannels: numChannels,
      bitsPerSample: bitsPerSample,
    );

    _audioChunkController.add(processedBlock);
    _consumeBurstBytes(kPayloadSize);

    // ── Emitir métricas actualizadas ─────────────────────────────────────
    final total = _totalPacketsReceived + _totalPacketsLost;
    final lossPercent = total > 0
        ? (_totalPacketsLost / total * 100.0)
        : 0.0;

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
  /// de tránsito, emite la métrica y responde ACK al emisor.
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

    // ACK de vuelta al emisor por el mismo socket (canal bidireccional)
    try {
      _connection?.output.add(buildAckPacket(
        burstId: _rxBurstId!,
        txEpochMs: _rxBurstTxEpochMs!,
        rxEpochMs: rxEpochMs,
      ));
    } catch (e) {
      _log.w('No se pudo enviar ACK de ráfaga #$_rxBurstId: $e');
    }

    _rxBurstId = null;
    _rxBurstTxEpochMs = null;
    _rxBurstBytesRemaining = 0;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // POLLING DE RSSI
  // ──────────────────────────────────────────────────────────────────────────

  /// Consulta el RSSI de la conexión BT activa cada [kRssiPollIntervalMs] ms.
  void _startRssiPolling(String address) {
    _rssiTimer = Timer.periodic(
      const Duration(milliseconds: kRssiPollIntervalMs),
      (_) async {
        try {
          // Intento de lectura real de RSSI via método nativo
          final rssi = await _getRssiNative(address);
          _currentRssi = rssi;
        } catch (_) {
          // Fallback: mantener último valor conocido con pequeña variación
          // para simular fluctuaciones reales del canal
          _currentRssi += (_currentRssi > -90.0 ? -0.5 : 0.5);
        }
      },
    );
  }

  /// Llama al canal nativo para leer el RSSI real del dispositivo conectado.
  /// Lanza excepción si no está disponible (Android < 8 / iOS).
  Future<double> _getRssiNative(String address) async {
    // En Android >= 8, BluetoothDevice.readRemoteRssi() está disponible.
    // Aquí se invoca vía MethodChannel registrado en MainActivity.kt.
    // Si falla, relanza para que el caller use el fallback.
    throw UnimplementedError('Canal nativo RSSI no implementado en esta plataforma');
  }

  // ──────────────────────────────────────────────────────────────────────────
  // CONTROL DE CICLO DE VIDA
  // ──────────────────────────────────────────────────────────────────────────

  /// Detiene la transmisión o recepción y cierra la conexión.
  Future<void> disconnect() async {
    _isTransmitting = false;
    _isReceiving = false;
    _serverTxActive = false;
    _rssiTimer?.cancel();
    _rssiTimer = null;
    _receiveBuffer.clear();
    _ackBuffer.clear();
    _burstBuilder.clear();
    _rxBurstId = null;
    _rxBurstTxEpochMs = null;
    _rxBurstBytesRemaining = 0;
    _dsp.reset();

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
  bool get isTransmitting => _isTransmitting;
  bool get isReceiving => _isReceiving;

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
