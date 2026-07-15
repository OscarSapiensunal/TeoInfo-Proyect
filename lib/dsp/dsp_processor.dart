// lib/dsp/dsp_processor.dart
//
// Núcleo de Procesamiento Digital de Señales (DSP).
//
// Implementa:
//   1. Jitter Buffer circular para mitigar fluctuaciones del canal BT.
//   2. Packet Loss Concealment (PLC) cuando RSSI < umbral.
//   3. Inyección de ruido AWGN proporcional a la degradación de señal.
//   4. Filtro digital paso-bajos (promedio móvil / IIR) para suavizar ruido.
//   5. Conversión bytes ↔ muestras PCM (Int16 / Float32).
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:math' as math;
import 'dart:typed_data';
import 'package:logger/logger.dart';

import '../models/app_models.dart';
import 'error_correction.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTES DSP
// ─────────────────────────────────────────────────────────────────────────────

/// Capacidad del Jitter Buffer en número de bloques de audio.
///
/// DEBE ser al menos tantos bloques como una ráfaga completa de voz
/// (con frames de voz continuos de ~128 ms, 80 bloques ≈ 10 s de margen).
/// Bluetooth entrega los 63 paquetes de una ráfaga casi de golpe (no
/// espaciados en el tiempo); con una capacidad menor (16, el valor
/// original), el buffer se llena y descarta con política drop-oldest la
/// mayoría de esos paquetes ANTES de que el temporizador de reproducción
/// alcance a drenarlos — el resultado audible es silencio la mayor parte
/// de cada ráfaga, aunque las métricas de pérdida (que se miden al llegar
/// el paquete, no al reproducirlo) sigan reportando datos correctos.
const int kJitterBufferCapacity = 80;

/// Umbral de RSSI (dBm) bajo el cual se activa PLC + ruido.
/// -75 dBm es típico del límite interior/exterior de una casa.
const double kRssiWeakThreshold = -75.0;

/// Umbral de RSSI (dBm) bajo el cual la señal se considera crítica.
const double kRssiCriticalThreshold = -88.0;

/// Factor de atenuación para PLC por repetición de bloque.
/// Cada bloque repetido se atenúa en 3 dB (factor ~0.707).
const double kPlcAttenuationFactor = 0.707;

/// Coeficiente del filtro IIR paso-bajos.
/// y[n] = α·x[n] + (1-α)·y[n-1]  →  fc ≈ −fs·ln(1−α)/(2π)
///
/// RECALIBRADO PARA 8 kHz: α = 0.85 → fc ≈ 2.4 kHz — conserva la banda de
/// la voz (300-3400 Hz) y atenúa el silbido del AWGN por encima. El valor
/// original (0.15) venía de la época de 44.1 kHz; al bajar el muestreo a
/// 8 kHz ese mismo α pasó a cortar desde ~190 Hz, EN PLENA banda de voz —
/// el "filtro" no limpiaba el ruido: amputaba la voz (reportado en campo
/// como "los filtros empeoran la señal"). Lección de DSP: los coeficientes
/// de un filtro digital solo tienen sentido RELATIVOS a la frecuencia de
/// muestreo — cambiar fs sin recalcularlos cambia el filtro por completo.
const double kIirAlpha = 0.85;

/// Orden del filtro de promedio móvil (FIR) para segunda pasada.
/// Orden 2 a 8 kHz: caída suave hacia Nyquist (nulo en 4 kHz), fuera de la
/// banda útil. El orden 5 original ponía su primer nulo en fs/5 = 1.6 kHz —
/// dentro de la voz (misma lección que kIirAlpha).
const int kMovingAvgOrder = 2;

/// Tasa MÁXIMA de bit-error simulada (por bit) para el demo de FEC, alcanzada
/// en el peor caso de degradación de RSSI. Bluetooth Clásico ya protege el
/// enlace contra esto a nivel físico; se simula aquí para poder enseñar y
/// medir Hamming (7,4) — ver error_correction.dart.
const double kFecMaxBitErrorRate = 0.03;

// ─────────────────────────────────────────────────────────────────────────────
// JITTER BUFFER CIRCULAR
// ─────────────────────────────────────────────────────────────────────────────

/// Buffer circular de longitud fija que almacena bloques de bytes de audio.
/// 
/// El transmisor produce bloques; el receptor los deposita aquí antes de
/// enviarlos al motor de audio, desacoplando la variabilidad del canal BT
/// (jitter) del reloj de reproducción constante.
class JitterBuffer {
  final int capacity;
  final List<Uint8List?> _slots;
  int _head = 0; // índice de escritura
  int _tail = 0; // índice de lectura
  int _count = 0;

  JitterBuffer({this.capacity = kJitterBufferCapacity})
      : _slots = List.filled(kJitterBufferCapacity, null);

  /// Número de bloques actualmente en el buffer.
  int get size => _count;

  /// Ratio de llenado [0.0 – 1.0].
  double get fillRatio => _count / capacity;

  /// ¿Está lleno?
  bool get isFull => _count >= capacity;

  /// ¿Está vacío?
  bool get isEmpty => _count == 0;

  /// Inserta un bloque. Si el buffer está lleno, descarta el bloque más antiguo
  /// (política de descarte por desbordamiento: drop-oldest).
  void push(Uint8List block) {
    if (isFull) {
      // Descarta el bloque más antiguo avanzando la cola
      _tail = (_tail + 1) % capacity;
      _count--;
    }
    _slots[_head] = block;
    _head = (_head + 1) % capacity;
    _count++;
  }

  /// Extrae el bloque más antiguo. Retorna null si el buffer está vacío.
  Uint8List? pop() {
    if (isEmpty) return null;
    final block = _slots[_tail];
    _slots[_tail] = null;
    _tail = (_tail + 1) % capacity;
    _count--;
    return block;
  }

  /// Inspecciona el bloque más antiguo sin extraerlo.
  Uint8List? peek() => isEmpty ? null : _slots[_tail];

  /// Vacía el buffer.
  void clear() {
    for (int i = 0; i < capacity; i++) _slots[i] = null;
    _head = 0;
    _tail = 0;
    _count = 0;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PROCESADOR DSP PRINCIPAL
// ─────────────────────────────────────────────────────────────────────────────

class DspProcessor {
  final Logger _log = Logger();
  final math.Random _rng = math.Random();

  // ── Estado del filtro IIR (un estado por canal) ──────────────────────────
  double _iirStateLeft = 0.0;
  double _iirStateRight = 0.0;

  // ── Buffer de cola para filtro FIR de promedio móvil ────────────────────
  final List<double> _firBufferLeft  = List.filled(kMovingAvgOrder, 0.0);
  final List<double> _firBufferRight = List.filled(kMovingAvgOrder, 0.0);
  int _firIndex = 0;

  // ── Último bloque de audio válido para PLC ───────────────────────────────
  Uint8List? _lastValidBlock;

  // ── Contador de bloques PLC consecutivos aplicados ──────────────────────
  int _plcRepeatCount = 0;

  // ── Jitter Buffer ────────────────────────────────────────────────────────
  final JitterBuffer jitterBuffer = JitterBuffer();

  /// Cuántos bits corrigió Hamming en el último bloque procesado (0 si FEC no
  /// se activó para ese bloque). `BluetoothManager` lo lee justo después de
  /// llamar a [processBlock] para decidir si emite una línea al log de
  /// algoritmos — evita tener que cambiar `processBlock` a un tipo de retorno
  /// más complejo por un solo dato informativo.
  int lastFecCorrectedBits = 0;

  // ─────────────────────────────────────────────────────────────────────────
  // API PÚBLICA
  // ─────────────────────────────────────────────────────────────────────────

  /// Procesa un bloque de bytes de audio recibido del canal BT y lo encola
  /// en el Jitter Buffer.
  ///
  /// Parámetros:
  /// - [rawBlock]  : bytes crudos del payload del paquete (PCM Int16 LE).
  /// - [rssiDbm]   : RSSI actual en dBm.
  /// - [isLost]    : true si este bloque fue inferido como perdido (PLC trigger).
  /// - [plcEnabled]/[filterEnabled]/[fecEnabled]: toggles en vivo del panel
  ///   "Optimizar señal" (ver SignalOptimizationSettings). El ruido AWGN NO
  ///   se gatea por ningún toggle: representa el canal degradado en sí, no
  ///   una mitigación — lo que se activa/desactiva es si se LIMPIA (filtro)
  ///   o se CORRIGE (FEC).
  /// - [numChannels] y [bitsPerSample]: parámetros del stream de audio en curso.
  ///
  /// No retorna el bloque directamente: la extracción del Jitter Buffer la
  /// hace un consumidor periódico externo (ver `BluetoothManager._startPlaybackDrain`),
  /// a ritmo constante e independiente de la llegada a ráfagas de los paquetes BT.
  void processBlock({
    required Uint8List? rawBlock,
    required double rssiDbm,
    required bool isLost,
    required bool plcEnabled,
    required bool filterEnabled,
    required bool fecEnabled,
    int numChannels = 1,
    int bitsPerSample = 16,
    int lostBlockSize = kPayloadSize,
  }) {
    Uint8List workBlock;
    lastFecCorrectedBits = 0;

    // ── 1. Packet Loss Concealment (si está apagado: silencio crudo) ────────
    if (isLost || rawBlock == null) {
      workBlock = _applyPlc(
        enabled: plcEnabled,
        numChannels: numChannels,
        bitsPerSample: bitsPerSample,
        blockSize: lostBlockSize,
      );
    } else {
      workBlock = Uint8List.fromList(rawBlock); // copia defensiva

      // ── 1b. FEC (Hamming 7,4) sobre bit-errores simulados ────────────────
      if (rssiDbm < kRssiWeakThreshold && bitsPerSample == 16) {
        workBlock = _applyFec(
          block: workBlock,
          rssiDbm: rssiDbm,
          fecEnabled: fecEnabled,
        );
      }

      _lastValidBlock = Uint8List.fromList(workBlock);
      _plcRepeatCount = 0;
    }

    // ── 2. Inyección de ruido AWGN (señal débil) — siempre activa ───────────
    if (rssiDbm < kRssiWeakThreshold && bitsPerSample == 16) {
      workBlock = _injectAwgnNoise(
        block: workBlock,
        rssiDbm: rssiDbm,
        numChannels: numChannels,
      );
    }

    // ── 3. Filtro digital paso-bajos (solo si está activado) ────────────────
    if (filterEnabled && rssiDbm < kRssiWeakThreshold && bitsPerSample == 16) {
      workBlock = _applyLowPassFilter(
        block: workBlock,
        numChannels: numChannels,
      );
    }

    // ── 4. Empujar al Jitter Buffer; el consumidor periódico externo lo drena ─
    jitterBuffer.push(workBlock);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // FEC — HAMMING (7,4) SOBRE BIT-ERRORES SIMULADOS
  // ─────────────────────────────────────────────────────────────────────────

  /// Simula una tasa de bit-error proporcional a la degradación del RSSI y,
  /// según [fecEnabled], corrige esos bits con Hamming (7,4) o los deja
  /// corrompidos — ver error_correction.dart para el porqué de simular en
  /// vez de depender de corrupción real (rara sobre RFCOMM).
  Uint8List _applyFec({
    required Uint8List block,
    required double rssiDbm,
    required bool fecEnabled,
  }) {
    final double degradation = (kRssiWeakThreshold - rssiDbm).clamp(0.0, 30.0);
    final double bitErrorRate = kFecMaxBitErrorRate * (degradation / 30.0);
    if (bitErrorRate <= 0) return block;

    if (!fecEnabled) {
      return HammingCodec.simulateBitErrors(block, bitErrorRate, _rng);
    }

    final encoded = HammingCodec.encode(block);
    final corrupted = HammingCodec.simulateBitErrors(encoded, bitErrorRate, _rng);
    final decoded = HammingCodec.decode(corrupted);
    lastFecCorrectedBits = decoded.correctedBits;
    if (decoded.correctedBits > 0) {
      _log.d('FEC: ${decoded.correctedBits} bit(s) corregidos (Hamming 7,4)');
    }
    return decoded.data;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PACKET LOSS CONCEALMENT (PLC)
  // ─────────────────────────────────────────────────────────────────────────

  /// Genera un bloque de sustitución cuando se detecta pérdida de paquete.
  ///
  /// Algoritmo:
  ///   - Si [enabled] es false: silencio crudo, sin concealment — el hueco
  ///     de pérdida se escucha tal cual (gap/clic), que es justo el punto de
  ///     comparación del panel "Optimizar señal".
  ///   - Si hay bloque previo: repite con atenuación exponencial de 3 dB/repetición.
  ///   - Si no hay bloque previo: genera silencio (relleno con ceros).
  ///
  /// La atenuación previene artefactos perceptuales al cortar abruptamente.
  Uint8List _applyPlc({
    required bool enabled,
    required int numChannels,
    required int bitsPerSample,
    int blockSize = kPayloadSize,
  }) {
    if (!enabled) {
      return Uint8List(blockSize);
    }

    _plcRepeatCount++;

    if (_lastValidBlock == null) {
      _log.d('PLC: sin bloque previo → silencio');
      return Uint8List(blockSize);
    }

    if (bitsPerSample != 16) {
      // Para formatos distintos a Int16, simplemente repetimos sin atenuar
      _log.d('PLC: repetición sin atenuación (bps=$bitsPerSample)');
      return Uint8List.fromList(_lastValidBlock!);
    }

    // Atenuación acumulada: cada repetición reduce 3 dB más
    // factor = kPlcAttenuationFactor ^ _plcRepeatCount
    final double attenuation =
        math.pow(kPlcAttenuationFactor, _plcRepeatCount).toDouble();

    final source = _lastValidBlock!;
    final result = Uint8List(source.length);
    final srcView = ByteData.sublistView(source);
    final dstView = ByteData.sublistView(result);

    final int sampleCount = source.length ~/ 2; // 2 bytes por muestra Int16
    for (int i = 0; i < sampleCount; i++) {
      final int rawSample = srcView.getInt16(i * 2, Endian.little);
      // Clamp para evitar overflow de Int16
      final int attenuated = (rawSample * attenuation).round().clamp(-32768, 32767);
      dstView.setInt16(i * 2, attenuated, Endian.little);
    }

    _log.d('PLC rep=$_plcRepeatCount atten=${attenuation.toStringAsFixed(3)}');

    // Si la atenuación es < 1% de la amplitud original, guardar silencio
    if (attenuation < 0.01) {
      _lastValidBlock = null;
    }

    return result;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // INYECCIÓN DE RUIDO AWGN
  // ─────────────────────────────────────────────────────────────────────────

  /// Añade ruido blanco gaussiano aditivo (AWGN) proporcional a la degradación.
  ///
  /// Modelo de SNR simplificado:
  ///   SNR_lineal = 10^((RSSI_dBm - RSSI_referencia) / 10)
  ///
  /// La amplitud del ruido escala inversamente con SNR.
  /// Se usa el método Box-Muller para generar muestras gaussianas.
  Uint8List _injectAwgnNoise({
    required Uint8List block,
    required double rssiDbm,
    required int numChannels,
  }) {
    // Potencia del ruido (normalizada a rango Int16 máx = 32767)
    // Cuando RSSI = kRssiWeakThreshold → noiseAmp ≈ 300 (ruido leve, ~1% de FS)
    // Cuando RSSI = kRssiCriticalThreshold → noiseAmp ≈ 3000 (ruido audible, ~10% de FS)
    final double degradation = (kRssiWeakThreshold - rssiDbm).clamp(0.0, 30.0);
    final double noiseAmp = 300.0 * (degradation / 13.0); // escala lineal

    final result = Uint8List.fromList(block);
    final view = ByteData.sublistView(result);
    final int sampleCount = result.length ~/ 2;

    for (int i = 0; i < sampleCount; i++) {
      // Box-Muller transform: genera muestra gaussiana N(0,1)
      final double u1 = _rng.nextDouble() + 1e-10; // evitar log(0)
      final double u2 = _rng.nextDouble();
      final double gaussian =
          math.sqrt(-2.0 * math.log(u1)) * math.cos(2.0 * math.pi * u2);

      final int originalSample = view.getInt16(i * 2, Endian.little);
      final int noisySample =
          (originalSample + gaussian * noiseAmp).round().clamp(-32768, 32767);
      view.setInt16(i * 2, noisySample, Endian.little);
    }

    return result;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // FILTRO DIGITAL PASO-BAJOS
  // ─────────────────────────────────────────────────────────────────────────

  /// Aplica un filtro paso-bajos de dos etapas al bloque de audio:
  ///
  /// Etapa 1 — Filtro IIR de primer orden (Butterworth):
  ///   y[n] = α·x[n] + (1-α)·y[n-1]     (ver kIirAlpha)
  ///
  /// Etapa 2 — Filtro FIR de promedio móvil (ventana rectangular):
  ///   y[n] = (1/M) · Σ x[n-k], k=0..M-1   (ver kMovingAvgOrder)
  ///
  /// La combinación ofrece una pendiente de caída de ~40 dB/octava,
  /// suficiente para atenuar el ruido de alta frecuencia añadido por AWGN.
  Uint8List _applyLowPassFilter({
    required Uint8List block,
    required int numChannels,
  }) {
    final result = Uint8List.fromList(block);
    final view = ByteData.sublistView(result);
    final int sampleCount = result.length ~/ 2;

    for (int i = 0; i < sampleCount; i++) {
      double sample = view.getInt16(i * 2, Endian.little).toDouble();

      // ── Etapa 1: IIR ────────────────────────────────────────────────────
      final bool isRightChannel = (numChannels == 2) && (i % 2 == 1);
      if (isRightChannel) {
        _iirStateRight = kIirAlpha * sample + (1.0 - kIirAlpha) * _iirStateRight;
        sample = _iirStateRight;
      } else {
        _iirStateLeft = kIirAlpha * sample + (1.0 - kIirAlpha) * _iirStateLeft;
        sample = _iirStateLeft;
      }

      // ── Etapa 2: FIR promedio móvil ────────────────────────────────────
      final List<double> buf = isRightChannel ? _firBufferRight : _firBufferLeft;
      buf[_firIndex % kMovingAvgOrder] = sample;
      double sum = 0.0;
      for (int k = 0; k < kMovingAvgOrder; k++) sum += buf[k];
      sample = sum / kMovingAvgOrder;

      view.setInt16(i * 2, sample.round().clamp(-32768, 32767), Endian.little);
    }
    _firIndex = (_firIndex + 1) % kMovingAvgOrder;

    return result;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // UTILIDADES DE CONVERSIÓN PCM
  // ─────────────────────────────────────────────────────────────────────────

  /// Convierte un bloque de bytes PCM Int16 LE a lista de muestras [−1.0, 1.0].
  static List<double> int16BytesToNormalized(Uint8List bytes) {
    final int sampleCount = bytes.length ~/ 2;
    final samples = List<double>.filled(sampleCount, 0.0);
    final view = ByteData.sublistView(bytes);
    for (int i = 0; i < sampleCount; i++) {
      samples[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return samples;
  }

  /// Convierte lista de muestras normalizadas [−1.0, 1.0] a bytes PCM Int16 LE.
  static Uint8List normalizedToInt16Bytes(List<double> samples) {
    final result = Uint8List(samples.length * 2);
    final view = ByteData.sublistView(result);
    for (int i = 0; i < samples.length; i++) {
      final int s = (samples[i] * 32767.0).round().clamp(-32768, 32767);
      view.setInt16(i * 2, s, Endian.little);
    }
    return result;
  }

  /// Calcula la energía RMS de un bloque PCM Int16.
  static double rmsEnergy(Uint8List block) {
    if (block.isEmpty) return 0.0;
    final view = ByteData.sublistView(block);
    final int sampleCount = block.length ~/ 2;
    double sumSq = 0.0;
    for (int i = 0; i < sampleCount; i++) {
      final double s = view.getInt16(i * 2, Endian.little) / 32768.0;
      sumSq += s * s;
    }
    return math.sqrt(sumSq / sampleCount);
  }

  /// Resetea los estados internos del filtro y PLC.
  void reset() {
    _iirStateLeft = 0.0;
    _iirStateRight = 0.0;
    for (int i = 0; i < kMovingAvgOrder; i++) {
      _firBufferLeft[i] = 0.0;
      _firBufferRight[i] = 0.0;
    }
    _firIndex = 0;
    _lastValidBlock = null;
    _plcRepeatCount = 0;
    jitterBuffer.clear();
  }
}
