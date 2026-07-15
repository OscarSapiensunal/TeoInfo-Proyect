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
// PROTOCOLO DE VOZ P2P CONTINUO (micrófono → BT → parlante)
//
// v2 — "radio": la voz fluye en FRAMES pequeños (~128 ms) enviados apenas
// se completan, no en ráfagas de 2 s. El diseño original de ráfagas exigía
// acumular 2 s antes de enviar nada y reproducir por clips discretos con
// ~0.2 s de arranque cada uno — el consumo era estructuralmente más lento
// que la llegada y la latencia solo podía crecer. Con frames continuos +
// reproducción streaming nativa (AudioTrack), la latencia extremo a extremo
// queda acotada en ~0.5-1 s de forma permanente.
// ─────────────────────────────────────────────────────────────────────────────

/// Formato de captura del micrófono: PCM lineal Int16 LE mono a 8 kHz.
///
/// 8 kHz (no 16): la voz telefónica ocupa 300-3400 Hz, así que por el
/// teorema de muestreo 8 kHz bastan para reconstruirla — y a la vez reduce
/// a la MITAD la carga sobre el canal RFCOMM, cuyo throughput real no
/// soportaba PCM de 16 kHz en ambas direcciones a la vez (la fuente
/// producía más de lo que el canal entregaba → latencia siempre creciente
/// hasta ahogar el enlace, confirmado en campo). Antes de salir al aire,
/// además, cada muestra se comprime de 16 a 8 bits con μ-law (ver
/// companding.dart) — reducción total de la fuente: 4×.
const int kMicSampleRate = 8000;
const int kMicNumChannels = 1;
const int kMicBitsPerSample = 16;

/// Bytes de PCM lineal por FRAME de voz: 2040 B = exactamente un payload de
/// paquete tras el companding μ-law (1020 B al aire). A 8 kHz mono Int16 son
/// 127.5 ms de audio — la unidad de transmisión continua: cada frame sale al
/// aire apenas el micrófono lo completa (~8 paquetes/s hablando).
const int kFramePcmBytes = kPayloadSize * 2;

/// Identificadores de códec para el meta-paquete (byte 8):
/// el modo laboratorio (.wav) transmite PCM lineal tal cual; el modo voz
/// transmite μ-law para caber en el canal.
const int kCodecPcm16 = 0;
const int kCodecMuLaw = 1;

// ─────────────────────────────────────────────────────────────────────────────
// PING/PONG — MEDICIÓN DE LATENCIA (RTT) DESACOPLADA DEL AUDIO
// ─────────────────────────────────────────────────────────────────────────────
//
// Un PING minúsculo (12 B) viaja cada ~2 s con el reloj del emisor; el otro
// lado lo devuelve como PONG con el mismo timestamp, y el emisor mide el RTT
// con SU PROPIO reloj (inmune al desfase entre teléfonos). Reemplaza al ACK
// por ráfaga del diseño v1: al no depender del audio, mide el estado del
// canal aunque nadie hable, y no se infla con el tiempo de transmisión de
// una ráfaga grande.
//
// NOTA HISTÓRICA (v1, retirado): existió un ARQ por ráfaga (NACK 0xCD,0xF0 +
// reenvío desde caché). Se retiró tras confirmar en campo que sobre un canal
// saturado la retransmisión REALIMENTA la congestión (reenvíos → más carga →
// más pérdidas → más reenvíos) — el mismo fenómeno que motivó el control de
// congestión de TCP. Queda documentado en README §9 como experimento.

/// Magic bytes del PING (quien mide → quien responde) y del PONG (respuesta).
const int kPingMagic0 = 0xCE;
const int kPingMagic1 = 0xF1;
const int kPongMagic1 = 0xF2;

/// Tamaño fijo de PING/PONG: [0xCE, 0xF1|0xF2, ID_HI, ID_LO, t0(u64 LE)] = 12 B.
const int kPingPacketSize = 12;

Uint8List _buildPingLike(int magic1, int pingId, int epochMs) {
  final packet = Uint8List(kPingPacketSize);
  packet[0] = kPingMagic0;
  packet[1] = magic1;
  packet[2] = (pingId >> 8) & 0xFF;
  packet[3] = pingId & 0xFF;
  ByteData.sublistView(packet).setUint64(4, epochMs, Endian.little);
  return packet;
}

Uint8List buildPingPacket({required int pingId, required int epochMs}) =>
    _buildPingLike(kPingMagic1, pingId, epochMs);

/// El PONG devuelve el MISMO timestamp del PING (el reloj del receptor no
/// participa — por eso el RTT resultante no sufre el desfase entre relojes).
Uint8List buildPongPacket({required int pingId, required int epochMs}) =>
    _buildPingLike(kPongMagic1, pingId, epochMs);

/// PING o PONG parseado.
class PingPong {
  final int pingId;
  final int epochMs;
  const PingPong({required this.pingId, required this.epochMs});

  static PingPong parse(Uint8List packet) => PingPong(
        pingId: (packet[2] << 8) | packet[3],
        epochMs: ByteData.sublistView(packet).getUint64(4, Endian.little),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// CONFIGURACIÓN DE OPTIMIZACIÓN DE SEÑAL — "crudo" vs "optimizado"
// ─────────────────────────────────────────────────────────────────────────────

/// Controla, en vivo y por teléfono, qué mitigaciones de canal están activas.
/// Por defecto la sesión arranca en [raw] (todo apagado) para que se pueda
/// escuchar primero la señal "cruda" tal como llega, y luego activar cada
/// técnica y sentir la diferencia — ver panel "Optimizar señal" en la UI.
class SignalOptimizationSettings {
  /// PLC: repone paquetes perdidos con repetición atenuada en vez de dejar
  /// silencio/gap crudo.
  final bool plcEnabled;

  /// Filtro paso-bajos IIR+FIR: limpia el ruido (AWGN) que el receptor
  /// inyecta cuando el RSSI es débil. El ruido en sí SIEMPRE se inyecta
  /// (representa el canal, no una optimización) — este toggle solo decide
  /// si se limpia o se deja audible.
  final bool filterEnabled;

  /// AEC: semi-dúplex (silencia el mic propio mientras el parlante propio
  /// reproduce) + NLMS residual. Desactivado = full-dúplex sin cancelar,
  /// eco muy audible sin auriculares.
  final bool aecEnabled;

  /// FEC (Hamming 7,4): igual que con el filtro, el receptor SIEMPRE simula
  /// una tasa de bit-errores proporcional a la degradación del RSSI (BT
  /// Clásico real ya protege contra esto a nivel de enlace, así que se
  /// simula para poder enseñar el Cap. V). Este toggle decide si se
  /// corrigen esos bits con Hamming o si se dejan corrompidos (clics/pops).
  final bool fecEnabled;

  const SignalOptimizationSettings({
    this.plcEnabled = false,
    this.filterEnabled = false,
    this.aecEnabled = false,
    this.fecEnabled = false,
  });

  /// Señal "cruda": todas las mitigaciones apagadas (estado inicial de cada sesión).
  static const raw = SignalOptimizationSettings();

  /// Señal "optimizada": todas las mitigaciones activas.
  static const optimized = SignalOptimizationSettings(
    plcEnabled: true,
    filterEnabled: true,
    aecEnabled: true,
    fecEnabled: true,
  );

  bool get allEnabled =>
      plcEnabled && filterEnabled && aecEnabled && fecEnabled;
  bool get allDisabled =>
      !plcEnabled && !filterEnabled && !aecEnabled && !fecEnabled;

  SignalOptimizationSettings copyWith({
    bool? plcEnabled,
    bool? filterEnabled,
    bool? aecEnabled,
    bool? fecEnabled,
  }) {
    return SignalOptimizationSettings(
      plcEnabled: plcEnabled ?? this.plcEnabled,
      filterEnabled: filterEnabled ?? this.filterEnabled,
      aecEnabled: aecEnabled ?? this.aecEnabled,
      fecEnabled: fecEnabled ?? this.fecEnabled,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MÉTRICA DE LATENCIA (RTT medido por PING/PONG)
// ─────────────────────────────────────────────────────────────────────────────

class LatencyMetric {
  final int pingId;

  /// RTT en milisegundos, medido enteramente con el reloj del emisor del
  /// PING (inmune al desfase de reloj entre los dos teléfonos).
  final double latencyMs;

  final DateTime timestamp;

  const LatencyMetric({
    required this.pingId,
    required this.latencyMs,
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
