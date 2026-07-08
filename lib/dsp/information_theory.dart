// lib/dsp/information_theory.dart
//
// Utilidades de Teoría de la Información (Capítulo IV del curso) aplicadas
// al canal Bluetooth y a la señal de voz digitalizada. Complementa el
// análisis de sistemas de comunicación (Capítulos II-III) con las dos
// magnitudes centrales del capítulo de Teoría de la Información:
//   · Capacidad de canal (Shannon-Hartley): cuántos bits/s soporta el canal.
//   · Entropía de la fuente: cuánta información realmente contiene cada
//     muestra de audio (mide qué tan lejos está la fuente de ser "ruido
//     puro uniforme", que tendría entropía máxima).
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:math' as math;
import 'dart:typed_data';

class InformationTheory {
  /// Ancho de banda de Nyquist para una señal muestreada a [sampleRate] Hz:
  /// el ancho de banda mínimo que, según el teorema de muestreo (Cap. III
  /// 3.1), permite reconstruir la señal sin aliasing.
  static double nyquistBandwidthHz(int sampleRate) => sampleRate / 2.0;

  /// Piso de ruido asumido para un receptor Bluetooth 2.4 GHz típico
  /// (aprox. educativa: la app mide el RSSI —potencia de la señal
  /// recibida—, no la potencia de ruido real del canal, así que el SNR
  /// aquí es una ESTIMACIÓN relativa a este piso asumido, no una medida
  /// metrológicamente exacta).
  static const double kAssumedNoiseFloorDbm = -95.0;

  /// Capacidad de canal de Shannon-Hartley: C = B·log2(1 + SNR).
  ///
  /// [rssiDbm] hace de proxy de la potencia de señal recibida; el SNR se
  /// estima como la diferencia contra [kAssumedNoiseFloorDbm]. Devuelve la
  /// capacidad en bits por segundo.
  static double shannonCapacityBps({
    required double rssiDbm,
    required int sampleRate,
  }) {
    final double snrDb = rssiDbm - kAssumedNoiseFloorDbm;
    final double snrLinear = math.pow(10, snrDb / 10).toDouble();
    final double bandwidthHz = nyquistBandwidthHz(sampleRate);
    return bandwidthHz * _log2(1.0 + snrLinear);
  }

  /// Entropía de Shannon H(X) de un bloque de audio PCM Int16 LE, en
  /// bits/muestra, estimada por histograma de amplitudes:
  ///   H(X) = -Σ p(x)·log2(p(x))
  ///
  /// Se cuantiza a [bins] contenedores (en vez de los 65 536 valores
  /// posibles de Int16) para que el histograma sea estadísticamente
  /// significativo sobre un bloque de tamaño moderado (una ráfaga ≈ 32 000
  /// muestras). El máximo teórico con [bins] contenedores es log2(bins) —
  /// p. ej. 8 bits con 256 bins, alcanzado solo si la señal fuera ruido
  /// blanco uniforme; la voz real siempre da un valor menor, porque tiene
  /// silencios y una distribución de amplitud concentrada cerca de cero.
  static double sourceEntropyBitsPerSample(Uint8List pcmBytes, {int bins = 256}) {
    final int sampleCount = pcmBytes.length ~/ 2;
    if (sampleCount == 0) return 0.0;
    final view = ByteData.sublistView(pcmBytes);
    final counts = List<int>.filled(bins, 0);
    for (int i = 0; i < sampleCount; i++) {
      final int sample = view.getInt16(i * 2, Endian.little); // [-32768, 32767]
      final int bin = ((sample + 32768) * bins) ~/ 65536;
      counts[bin.clamp(0, bins - 1)]++;
    }
    double entropy = 0.0;
    for (final count in counts) {
      if (count == 0) continue;
      final double p = count / sampleCount;
      entropy -= p * _log2(p);
    }
    return entropy;
  }

  /// log2(bins): entropía máxima posible con esa cuantización (fuente
  /// equiprobable / ruido blanco uniforme) — útil como referencia en la UI.
  static double maxEntropyBitsPerSample({int bins = 256}) => _log2(bins.toDouble());

  static double _log2(double x) => math.log(x) / math.ln2;
}
