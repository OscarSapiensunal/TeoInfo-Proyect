// lib/dsp/companding.dart
//
// Companding μ-law (PCM logarítmico no uniforme, estándar ITU-T G.711) —
// Capítulo III del curso (PCM / cuantización no uniforme).
//
// PROBLEMA QUE RESUELVE: el enlace RFCOMM real no transporta los 32 KB/s
// por dirección que produce PCM lineal de 16 bits a 16 kHz — con ambos
// teléfonos hablando a la vez la fuente produce MÁS de lo que el canal
// entrega, y la latencia solo puede crecer (confirmado en campo: subía
// hasta ~11 s y el enlace moría). La respuesta clásica de sistemas de
// comunicación es adaptar la TASA DE LA FUENTE a la capacidad del canal:
// muestrear a 8 kHz (la voz telefónica ocupa 300-3400 Hz → Nyquist lo
// permite) y comprimir cada muestra de 16 a 8 bits con μ-law. Juntos
// reducen la carga 4× (32 → 8 KB/s por dirección).
//
// POR QUÉ FUNCIONA PERCEPTUALMENTE: el oído responde de forma logarítmica —
// distingue bien entre susurro y voz baja, pero apenas entre fuerte y muy
// fuerte. μ-law asigna sus 8 bits con paso fino cerca de cero (donde vive
// casi toda la señal de voz) y paso grueso en amplitudes altas: cuantiza
// donde el oído nota y ahorra donde no. Es exactamente la "cuantización no
// uniforme" del Cap. III, y el códec G.711 de la telefonía fija mundial.
//
// Formato del byte codificado: ~(signo | exponente(3b) | mantisa(4b)) —
// una representación tipo punto flotante en miniatura, invertida por
// convención histórica (evita largas cadenas de ceros en línea).
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:typed_data';

class MuLawCodec {
  /// Sesgo estándar de G.711: desplaza la señal para que el tramo
  /// logarítmico arranque suave cerca de cero.
  static const int _kBias = 0x84; // 132

  /// Amplitud máxima representable antes de saturar (32767 - _kBias).
  static const int _kClip = 32635;

  /// Byte μ-law que representa silencio digital (encodeSample(0) == 0xFF).
  /// Se usa como relleno del último paquete de cada ráfaga: rellenar con
  /// ceros binarios sería un error — 0x00 en μ-law decodifica a -32124
  /// (¡casi fondo de escala!) y sonaría como un clic fortísimo.
  static const int kSilenceByte = 0xFF;

  /// Codifica UNA muestra PCM lineal Int16 → byte μ-law.
  static int encodeSample(int sample) {
    int sign = (sample >> 8) & 0x80;
    if (sign != 0) sample = -sample;
    if (sample > _kClip) sample = _kClip;
    sample += _kBias;

    // Posición del bit más significativo → "exponente" (segmento logarítmico)
    int exponent = 7;
    for (int mask = 0x4000; (sample & mask) == 0 && exponent > 0; exponent--) {
      mask >>= 1;
    }
    final int mantissa = (sample >> (exponent + 3)) & 0x0F;
    return ~(sign | (exponent << 4) | mantissa) & 0xFF;
  }

  /// Decodifica UN byte μ-law → muestra PCM lineal Int16.
  static int decodeSample(int ulawByte) {
    final int u = ~ulawByte & 0xFF;
    final int sign = u & 0x80;
    final int exponent = (u >> 4) & 0x07;
    final int mantissa = u & 0x0F;
    int sample = (((mantissa << 3) + _kBias) << exponent) - _kBias;
    return sign != 0 ? -sample : sample;
  }

  /// PCM Int16 LE → μ-law (mitad de bytes).
  static Uint8List encode(Uint8List pcm16Bytes) {
    final int n = pcm16Bytes.length ~/ 2;
    final view = ByteData.sublistView(pcm16Bytes);
    final out = Uint8List(n);
    for (int i = 0; i < n; i++) {
      out[i] = encodeSample(view.getInt16(i * 2, Endian.little));
    }
    return out;
  }

  /// μ-law → PCM Int16 LE (el doble de bytes).
  static Uint8List decode(Uint8List ulawBytes) {
    final out = Uint8List(ulawBytes.length * 2);
    final view = ByteData.sublistView(out);
    for (int i = 0; i < ulawBytes.length; i++) {
      view.setInt16(i * 2, decodeSample(ulawBytes[i]), Endian.little);
    }
    return out;
  }
}
