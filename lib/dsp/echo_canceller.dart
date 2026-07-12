// lib/dsp/echo_canceller.dart
//
// Cancelador de eco acústico (AEC) simplificado, de un solo canal, con
// filtro adaptativo NLMS (Normalized Least Mean Squares).
//
// Cuando el parlante y el micrófono del MISMO teléfono están activos a la
// vez (conversación sin auriculares), el micrófono capta una versión
// atenuada y retardada de lo que el propio parlante está reproduciendo —
// ese acoplamiento acústico es lo que el interlocutor escucha como "eco de
// su propia voz". Este cancelador mantiene un buffer del audio RECIÉN
// REPRODUCIDO (la señal de referencia o "far-end") y con un filtro
// adaptativo NLMS estima la porción de esa señal que se filtró de vuelta
// al micrófono, restándola de lo que se va a transmitir:
//
//   y[n] = Σ w[k]·x[n-k]              (predicción del eco, k=0..N-1)
//   e[n] = d[n] - y[n]                (señal "limpia": near-end sin eco)
//   w[k] += (μ·e[n] / ||x||²) · x[n-k]  (actualización NLMS de los pesos)
//
// donde x = referencia (far-end, lo reproducido) y d = micrófono (near-end,
// con eco). Es el mismo tipo de ecuación en diferencias que los filtros
// IIR/FIR de dsp_processor.dart, pero con coeficientes que se ADAPTAN solos
// en vez de ser fijos — el mismo principio que covers Cap. II del curso,
// llevado a un filtro variable en el tiempo.
//
// SIMPLIFICACIÓN DELIBERADA (nivel de curso, no un AEC de grado
// profesional): no hay estimación explícita del retardo acústico ni
// detección de doble-habla (double-talk); el filtro cubre una ventana de
// referencia lo bastante ancha para "encontrar" la correlación dentro de
// ella. En esta app la mitigación PRINCIPAL y garantizada es semi-dúplex
// (ver BluetoothManager: no se envía mientras el parlante propio está
// reproduciendo); el NLMS aquí ataca el eco RESIDUAL que pueda quedar
// (colas de reverberación, transiciones), no se le pide hacer todo el
// trabajo solo.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:typed_data';

class EchoCanceller {
  final int filterLength;
  final double stepSize;

  final Float64List _weights;
  final Float64List _referenceRing;
  final int _refCapacity;
  int _refWriteIndex = 0;
  bool _hasReference = false;

  /// [filterLength] : orden del filtro adaptativo (número de coeficientes).
  ///   128 taps a 16 kHz ≈ 8 ms de cobertura — suficiente para el eco
  ///   "residual" que deja pasar el semi-dúplex, sin un costo computacional
  ///   alto (2·filterLength operaciones por muestra).
  /// [stepSize] : μ, la tasa de adaptación del NLMS. Valores típicos 0.1-1.0;
  ///   más alto converge más rápido pero con más ruido/inestabilidad.
  /// [referenceSeconds]/[sampleRate] : tamaño del buffer circular de
  ///   referencia (far-end reciente).
  EchoCanceller({
    this.filterLength = 128,
    this.stepSize = 0.5,
    int referenceSeconds = 1,
    int sampleRate = 16000,
  })  : _weights = Float64List(filterLength),
        _refCapacity = referenceSeconds * sampleRate,
        _referenceRing = Float64List(referenceSeconds * sampleRate);

  /// Alimenta el buffer de referencia (far-end) con audio que se ACABA de
  /// entregar para reproducirse por el parlante propio.
  void pushReference(Uint8List pcmBytes) {
    final view = ByteData.sublistView(pcmBytes);
    final int n = pcmBytes.length ~/ 2;
    for (int i = 0; i < n; i++) {
      final double sample = view.getInt16(i * 2, Endian.little) / 32768.0;
      _referenceRing[_refWriteIndex] = sample;
      _refWriteIndex = (_refWriteIndex + 1) % _refCapacity;
    }
    _hasReference = true;
  }

  /// Procesa un bloque del micrófono (near-end, con posible eco) y devuelve
  /// la versión con el eco estimado restado. Si todavía no hay nada en el
  /// buffer de referencia (nadie ha reproducido nada aún), devuelve el
  /// bloque intacto — no hay nada que cancelar.
  Uint8List process(Uint8List micPcmBytes) {
    if (!_hasReference) return micPcmBytes;

    final view = ByteData.sublistView(micPcmBytes);
    final int n = micPcmBytes.length ~/ 2;
    final result = Uint8List(micPcmBytes.length);
    final outView = ByteData.sublistView(result);

    for (int i = 0; i < n; i++) {
      final double d = view.getInt16(i * 2, Endian.little) / 32768.0;

      // La ventana de referencia DEBE deslizarse muestra a muestra junto con
      // la señal del micrófono (x[n-k] en la ecuación NLMS): se alinea la
      // última muestra del bloque del mic con la última referencia escrita y
      // cada muestra anterior mira una posición más atrás. (Bug original:
      // todas las muestras del bloque usaban la MISMA ventana fija — sin
      // deslizamiento no hay correlación temporal que estimar y el filtro
      // degeneraba en un passthrough.)
      final int refNewest = _refWriteIndex - 1 - (n - 1 - i);

      double y = 0.0;
      double energy = 1e-6; // evita división por cero al normalizar
      for (int k = 0; k < filterLength; k++) {
        int refIdx = (refNewest - k) % _refCapacity;
        if (refIdx < 0) refIdx += _refCapacity;
        final double x = _referenceRing[refIdx];
        y += _weights[k] * x;
        energy += x * x;
      }

      final double e = d - y;
      final double muOverEnergy = stepSize * e / energy;
      for (int k = 0; k < filterLength; k++) {
        int refIdx = (refNewest - k) % _refCapacity;
        if (refIdx < 0) refIdx += _refCapacity;
        _weights[k] += muOverEnergy * _referenceRing[refIdx];
      }

      final int outSample = (e * 32768.0).round().clamp(-32768, 32767);
      outView.setInt16(i * 2, outSample, Endian.little);
    }
    return result;
  }

  void reset() {
    _weights.fillRange(0, filterLength, 0.0);
    _referenceRing.fillRange(0, _refCapacity, 0.0);
    _refWriteIndex = 0;
    _hasReference = false;
  }
}
