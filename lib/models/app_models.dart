// lib/models/app_models.dart
//
// Modelos de datos centrales de la aplicación.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:typed_data';

// ─────────────────────────────────────────────────────────────────────────────
// MODELO DE PAQUETE BLUETOOTH
// ─────────────────────────────────────────────────────────────────────────────

/// Tamaño del payload de audio por paquete (bytes).
const int kPayloadSize = 1020;

/// Tamaño total del paquete: 4 bytes de cabecera + kPayloadSize bytes de payload.
/// Cabecera: [0xAA, 0xBB, SEQ_HI, SEQ_LO]
const int kPacketSize = kPayloadSize + 4;

/// Byte de inicio de trama (magic bytes para sincronización).
const int kMagicByte0 = 0xAA;
const int kMagicByte1 = 0xBB;

/// Construye un paquete listo para enviar por el socket RFCOMM.
///
/// Estructura:
/// ┌──────────┬──────────┬─────────────┬─────────────┬──────────────────────┐
/// │ 0xAA (1B)│ 0xBB (1B)│ SEQ_HI (1B) │ SEQ_LO (1B) │ PAYLOAD (1020 bytes) │
/// └──────────┴──────────┴─────────────┴─────────────┴──────────────────────┘
Uint8List buildPacket(int sequenceNumber, Uint8List payload) {
  assert(payload.length <= kPayloadSize,
      'Payload excede kPayloadSize: ${payload.length}');

  final packet = Uint8List(kPacketSize);
  packet[0] = kMagicByte0;
  packet[1] = kMagicByte1;
  packet[2] = (sequenceNumber >> 8) & 0xFF; // byte alto
  packet[3] = sequenceNumber & 0xFF;         // byte bajo

  // Copia payload; si es menor que kPayloadSize rellena con ceros (silencio PCM)
  packet.setRange(4, 4 + payload.length, payload);
  return packet;
}

/// Parsea los primeros 4 bytes de un paquete y devuelve el número de secuencia.
/// Retorna -1 si los magic bytes no coinciden.
int parseSequenceNumber(Uint8List packet) {
  if (packet.length < 4) return -1;
  if (packet[0] != kMagicByte0 || packet[1] != kMagicByte1) return -1;
  return (packet[2] << 8) | packet[3];
}

// ─────────────────────────────────────────────────────────────────────────────
// PROTOCOLO DE RÁFAGAS DE VOZ P2P (micrófono → BT → parlante)
// ─────────────────────────────────────────────────────────────────────────────

/// Duración de cada ráfaga de audio capturada del micrófono (ms).
const int kBurstDurationMs = 2000;

/// Formato de captura del micrófono: PCM lineal Int16 LE mono a 16 kHz.
const int kMicSampleRate = 16000;
const int kMicNumChannels = 1;
const int kMicBitsPerSample = 16;

/// Bytes de PCM por ráfaga: 16000 Hz × 1 ch × 2 B × 2 s = 64000 bytes.
const int kBurstPcmBytes =
    kMicSampleRate * kMicNumChannels * (kMicBitsPerSample ~/ 8) * kBurstDurationMs ~/ 1000;

/// Magic bytes de la cabecera de ráfaga (emisor → receptor).
const int kBurstMagic0 = 0xCC;
const int kBurstMagic1 = 0xEE;

/// Magic bytes del ACK de ráfaga (receptor → emisor).
const int kAckMagic0 = 0xCD;
const int kAckMagic1 = 0xEF;

/// Tamaño fijo del paquete ACK:
/// [0xCD, 0xEF, ID_HI, ID_LO, txEpochMs(u64 LE), rxEpochMs(u64 LE)] = 20 bytes.
const int kAckPacketSize = 20;

/// Construye la cabecera de ráfaga (ocupa un paquete completo, con relleno).
/// Estructura: [0xCC, 0xEE, ID_HI, ID_LO, byteLen(u32 LE), txEpochMs(u64 LE), 0…]
Uint8List buildBurstHeaderPacket({
  required int burstId,
  required int pcmByteLength,
  required int txEpochMs,
}) {
  final packet = Uint8List(kPacketSize);
  packet[0] = kBurstMagic0;
  packet[1] = kBurstMagic1;
  packet[2] = (burstId >> 8) & 0xFF;
  packet[3] = burstId & 0xFF;
  final view = ByteData.sublistView(packet);
  view.setUint32(4, pcmByteLength, Endian.little);
  view.setUint64(8, txEpochMs, Endian.little);
  return packet;
}

/// Cabecera de ráfaga parseada.
class BurstHeader {
  final int burstId;
  final int pcmByteLength;
  final int txEpochMs;

  const BurstHeader({
    required this.burstId,
    required this.pcmByteLength,
    required this.txEpochMs,
  });

  static BurstHeader parse(Uint8List packet) {
    final view = ByteData.sublistView(packet);
    return BurstHeader(
      burstId: (packet[2] << 8) | packet[3],
      pcmByteLength: view.getUint32(4, Endian.little),
      txEpochMs: view.getUint64(8, Endian.little),
    );
  }
}

/// Construye el paquete ACK que el receptor devuelve al completar una ráfaga.
Uint8List buildAckPacket({
  required int burstId,
  required int txEpochMs,
  required int rxEpochMs,
}) {
  final ack = Uint8List(kAckPacketSize);
  ack[0] = kAckMagic0;
  ack[1] = kAckMagic1;
  ack[2] = (burstId >> 8) & 0xFF;
  ack[3] = burstId & 0xFF;
  final view = ByteData.sublistView(ack);
  view.setUint64(4, txEpochMs, Endian.little);
  view.setUint64(12, rxEpochMs, Endian.little);
  return ack;
}

/// ACK de ráfaga parseado.
class BurstAck {
  final int burstId;
  final int txEpochMs;
  final int rxEpochMs;

  const BurstAck({
    required this.burstId,
    required this.txEpochMs,
    required this.rxEpochMs,
  });

  static BurstAck parse(Uint8List bytes) {
    final view = ByteData.sublistView(bytes);
    return BurstAck(
      burstId: (bytes[2] << 8) | bytes[3],
      txEpochMs: view.getUint64(4, Endian.little),
      rxEpochMs: view.getUint64(12, Endian.little),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MÉTRICA DE LATENCIA POR RÁFAGA
// ─────────────────────────────────────────────────────────────────────────────

class LatencyMetric {
  final int burstId;

  /// Latencia medida en milisegundos.
  final double latencyMs;

  /// true  → RTT medido por el emisor con su propio reloj (header → ACK).
  /// false → tránsito estimado por el receptor (epoch TX vs epoch RX;
  ///         sujeto al desfase de reloj entre teléfonos).
  final bool isRoundTrip;

  final DateTime timestamp;

  const LatencyMetric({
    required this.burstId,
    required this.latencyMs,
    required this.isRoundTrip,
    required this.timestamp,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// DISPOSITIVO BLUETOOTH (unifica emparejados y descubiertos)
// ─────────────────────────────────────────────────────────────────────────────

class BtDeviceInfo {
  final String name;
  final String address;
  final bool bonded;

  /// RSSI reportado durante el descubrimiento (null para emparejados).
  final int? rssi;

  const BtDeviceInfo({
    required this.name,
    required this.address,
    required this.bonded,
    this.rssi,
  });

  BtDeviceInfo copyWith({bool? bonded, int? rssi}) => BtDeviceInfo(
        name: name,
        address: address,
        bonded: bonded ?? this.bonded,
        rssi: rssi ?? this.rssi,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// MODELO DE MÉTRICAS EN TIEMPO REAL
// ─────────────────────────────────────────────────────────────────────────────

class ChannelMetrics {
  /// Intensidad de señal recibida en dBm (Bluetooth RSSI).
  /// Rango típico: -100 dBm (muy débil) a -40 dBm (muy fuerte).
  final double rssiDbm;

  /// true si [rssiDbm] viene de una lectura real del hardware (GATT sobre
  /// el enlace clásico); false si es una simulación de respaldo porque el
  /// dispositivo remoto no soportó la lectura real (frecuente en BT
  /// Clásico — no todos los chips exponen RSSI así). Se muestra en la UI
  /// para no hacer pasar un valor simulado por uno medido.
  final bool rssiIsReal;

  /// Tasa de pérdida de paquetes en porcentaje [0.0 – 100.0].
  final double packetLossPercent;

  /// Nivel de ocupación del Jitter Buffer [0.0 – 1.0].
  final double bufferFillRatio;

  /// Número de paquetes recibidos correctamente.
  final int packetsReceived;

  /// Número de paquetes perdidos (saltos en secuencia detectados).
  final int packetsLost;

  /// Marca de tiempo de la muestra.
  final DateTime timestamp;

  const ChannelMetrics({
    required this.rssiDbm,
    this.rssiIsReal = false,
    required this.packetLossPercent,
    required this.bufferFillRatio,
    required this.packetsReceived,
    required this.packetsLost,
    required this.timestamp,
  });

  ChannelMetrics copyWith({
    double? rssiDbm,
    bool? rssiIsReal,
    double? packetLossPercent,
    double? bufferFillRatio,
    int? packetsReceived,
    int? packetsLost,
    DateTime? timestamp,
  }) {
    return ChannelMetrics(
      rssiDbm: rssiDbm ?? this.rssiDbm,
      rssiIsReal: rssiIsReal ?? this.rssiIsReal,
      packetLossPercent: packetLossPercent ?? this.packetLossPercent,
      bufferFillRatio: bufferFillRatio ?? this.bufferFillRatio,
      packetsReceived: packetsReceived ?? this.packetsReceived,
      packetsLost: packetsLost ?? this.packetsLost,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  /// Punto de datos para la gráfica fl_chart: (tiempo relativo en segundos, valor).
  static ChannelMetrics zero() => ChannelMetrics(
        rssiDbm: -60.0,
        packetLossPercent: 0.0,
        bufferFillRatio: 0.0,
        packetsReceived: 0,
        packetsLost: 0,
        timestamp: DateTime.now(),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// MÉTRICAS DE TEORÍA DE LA INFORMACIÓN (Capítulo IV)
// ─────────────────────────────────────────────────────────────────────────────

class InfoTheoryMetrics {
  /// Capacidad de canal de Shannon-Hartley estimada (bits/s), a partir del
  /// RSSI actual como proxy de SNR (ver InformationTheory.shannonCapacityBps).
  final double channelCapacityBps;

  /// Entropía de Shannon H(X) del último clip de audio recibido, en
  /// bits/muestra (ver InformationTheory.sourceEntropyBitsPerSample).
  final double sourceEntropyBitsPerSample;

  /// Entropía máxima posible con la misma cuantización (fuente
  /// equiprobable) — referencia para comparar contra [sourceEntropyBitsPerSample].
  final double maxEntropyBitsPerSample;

  final DateTime timestamp;

  const InfoTheoryMetrics({
    required this.channelCapacityBps,
    required this.sourceEntropyBitsPerSample,
    required this.maxEntropyBitsPerSample,
    required this.timestamp,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// ENCABEZADO WAV (RIFF/PCM)
// ─────────────────────────────────────────────────────────────────────────────

/// Parsea los primeros 44 bytes de un archivo WAV estándar (PCM sin compresión).
/// Si el archivo no es WAV estándar, lanza [FormatException].
class WavHeader {
  final int audioFormat;   // 1 = PCM, 3 = IEEE float
  final int numChannels;   // 1 = mono, 2 = estéreo
  final int sampleRate;    // Hz (ej. 44100, 22050, 16000)
  final int bitsPerSample; // 8, 16, 24 o 32
  final int byteRate;      // sampleRate * numChannels * bitsPerSample / 8
  final int dataOffset;    // posición en bytes donde comienza el chunk "data"
  final int dataSize;      // tamaño en bytes del chunk de datos de audio

  const WavHeader({
    required this.audioFormat,
    required this.numChannels,
    required this.sampleRate,
    required this.bitsPerSample,
    required this.byteRate,
    required this.dataOffset,
    required this.dataSize,
  });

  /// Duración total en segundos.
  double get durationSeconds => dataSize / byteRate.toDouble();

  /// Número total de muestras (frames) por canal.
  int get totalFrames =>
      dataSize ~/ (numChannels * (bitsPerSample ~/ 8));

  static WavHeader parse(Uint8List bytes) {
    if (bytes.length < 44) {
      throw const FormatException('Archivo demasiado pequeño para ser WAV');
    }

    final view = ByteData.sublistView(bytes);

    // Verificar "RIFF"
    if (bytes[0] != 0x52 || bytes[1] != 0x49 ||
        bytes[2] != 0x46 || bytes[3] != 0x46) {
      throw const FormatException('No es un archivo RIFF válido');
    }
    // Verificar "WAVE"
    if (bytes[8] != 0x57 || bytes[9] != 0x41 ||
        bytes[10] != 0x56 || bytes[11] != 0x45) {
      throw const FormatException('No es un archivo WAVE válido');
    }

    // Buscar chunk "fmt " y "data" dinámicamente
    int offset = 12;
    int fmtOffset = -1;
    int dataOffset = -1;
    int dataSize = 0;

    while (offset + 8 <= bytes.length) {
      final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final chunkSize = view.getUint32(offset + 4, Endian.little);

      if (chunkId == 'fmt ') {
        fmtOffset = offset + 8;
      } else if (chunkId == 'data') {
        dataOffset = offset + 8;
        dataSize = chunkSize;
        break;
      }
      offset += 8 + chunkSize;
    }

    if (fmtOffset == -1) throw const FormatException('Chunk "fmt " no encontrado');
    if (dataOffset == -1) throw const FormatException('Chunk "data" no encontrado');

    return WavHeader(
      audioFormat:   view.getUint16(fmtOffset,      Endian.little),
      numChannels:   view.getUint16(fmtOffset + 2,  Endian.little),
      sampleRate:    view.getUint32(fmtOffset + 4,  Endian.little),
      byteRate:      view.getUint32(fmtOffset + 8,  Endian.little),
      bitsPerSample: view.getUint16(fmtOffset + 14, Endian.little),
      dataOffset:    dataOffset,
      dataSize:      dataSize,
    );
  }

  @override
  String toString() =>
      'WavHeader(${sampleRate}Hz, ${numChannels}ch, ${bitsPerSample}bit, '
      '${durationSeconds.toStringAsFixed(2)}s)';
}

// ─────────────────────────────────────────────────────────────────────────────
// PUNTO DE DATOS PARA GRÁFICA
// ─────────────────────────────────────────────────────────────────────────────

class ChartDataPoint {
  /// Tiempo relativo desde el inicio del experimento (segundos).
  final double timeSeconds;
  final double rssiDbm;
  final double packetLossPercent;

  const ChartDataPoint({
    required this.timeSeconds,
    required this.rssiDbm,
    required this.packetLossPercent,
  });
}
