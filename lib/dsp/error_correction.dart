// lib/dsp/error_correction.dart
//
// Corrección de errores hacia adelante (FEC) — código de Hamming (7,4)
// (Capítulo V del curso).
//
// Bluetooth Clásico (RFCOMM sobre L2CAP) ya protege el enlace contra
// corrupción de bits a nivel físico, así que en la práctica casi nunca llega
// un bit volteado hasta esta capa. Para poder enseñar y MEDIR el efecto de
// un código corrector, este archivo también simula una tasa de bit-error
// propia (proporcional a la degradación del RSSI, igual que el AWGN de
// dsp_processor.dart) — así se puede comparar, con el mismo bloque de audio,
// "qué se oiría si el canal corrompiera bits y no tuviéramos FEC" contra
// "qué se oye si Hamming los corrige".
//
// Hamming (7,4): cada nibble (4 bits de datos) se codifica en 1 byte de
// 7 bits útiles (bit 7 sin usar) con 3 bits de paridad, en el orden estándar
// p1 p2 d1 p3 d2 d3 d4 (posiciones 1..7):
//   p1 = d1 ⊕ d2 ⊕ d4      p2 = d1 ⊕ d3 ⊕ d4      p3 = d2 ⊕ d3 ⊕ d4
// En el receptor se recalculan 3 chequeos de paridad; su combinación binaria
// (el "síndrome") apunta directamente a la POSICIÓN del bit que se volteó
// (0 = sin error), permitiendo corregirlo sin pedir reenvío — a diferencia
// de una simple paridad, que solo detecta.
//
// SIMPLIFICACIÓN: se usa 1 byte transmitido por nibble de datos (en vez de
// empaquetar los 7 bits útiles de forma compacta) — más caro en bytes, pero
// mucho más simple de leer/depurar, apropiado para un proyecto de curso.
// Solo corrige errores AISLADOS (1 bit por cada grupo de 7); si la tasa de
// corrupción simulada es alta, puede haber grupos con 2+ bits volteados que
// Hamming no puede corregir (y a veces "corrige" mal) — eso también es
// honesto: ningún código corrector es perfecto.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:math' as math;
import 'dart:typed_data';

/// Resultado de decodificar un bloque Hamming: los datos recuperados y
/// cuántos bits tuvo que corregir (para mostrarlo en el log de algoritmos).
class HammingDecodeResult {
  final Uint8List data;
  final int correctedBits;
  const HammingDecodeResult({required this.data, required this.correctedBits});
}

class HammingCodec {
  static int _encodeNibble(int nibble) {
    final int d1 = (nibble >> 3) & 1;
    final int d2 = (nibble >> 2) & 1;
    final int d3 = (nibble >> 1) & 1;
    final int d4 = nibble & 1;
    final int p1 = d1 ^ d2 ^ d4;
    final int p2 = d1 ^ d3 ^ d4;
    final int p3 = d2 ^ d3 ^ d4;
    // Posiciones 1..7 empaquetadas en los 7 bits bajos del byte: p1 p2 d1 p3 d2 d3 d4
    return (p1 << 6) | (p2 << 5) | (d1 << 4) | (p3 << 3) | (d2 << 2) | (d3 << 1) | d4;
  }

  /// Decodifica un byte codificado (7 bits útiles) corrigiendo 1 bit si el
  /// síndrome de paridad detecta un error.
  static (int nibble, bool corrected) _decodeByte(int code) {
    final List<int> bits = List<int>.generate(7, (i) => (code >> (6 - i)) & 1);
    // bits[0..6] = p1 p2 d1 p3 d2 d3 d4 (posiciones 1..7)
    final int c1 = bits[0] ^ bits[2] ^ bits[4] ^ bits[6];
    final int c2 = bits[1] ^ bits[2] ^ bits[5] ^ bits[6];
    final int c3 = bits[3] ^ bits[4] ^ bits[5] ^ bits[6];
    final int syndrome = c1 | (c2 << 1) | (c3 << 2);

    bool corrected = false;
    if (syndrome != 0) {
      bits[syndrome - 1] ^= 1;
      corrected = true;
    }
    final int nibble = (bits[2] << 3) | (bits[4] << 2) | (bits[5] << 1) | bits[6];
    return (nibble, corrected);
  }

  /// Codifica [data] (N bytes) a 2N bytes (un byte-Hamming por nibble).
  static Uint8List encode(Uint8List data) {
    final result = Uint8List(data.length * 2);
    for (int i = 0; i < data.length; i++) {
      result[i * 2] = _encodeNibble((data[i] >> 4) & 0xF);
      result[i * 2 + 1] = _encodeNibble(data[i] & 0xF);
    }
    return result;
  }

  /// Decodifica un bloque codificado (2N bytes) de vuelta a N bytes,
  /// corrigiendo bits aislados y contando cuántos corrigió.
  static HammingDecodeResult decode(Uint8List encoded) {
    final int n = encoded.length ~/ 2;
    final result = Uint8List(n);
    int corrections = 0;
    for (int i = 0; i < n; i++) {
      final (hi, c1) = _decodeByte(encoded[i * 2]);
      final (lo, c2) = _decodeByte(encoded[i * 2 + 1]);
      if (c1) corrections++;
      if (c2) corrections++;
      result[i] = (hi << 4) | lo;
    }
    return HammingDecodeResult(data: result, correctedBits: corrections);
  }

  /// Simula corrupción del canal: voltea cada bit de [data] de forma
  /// independiente con probabilidad [flipProbability].
  static Uint8List simulateBitErrors(
    Uint8List data,
    double flipProbability,
    math.Random rng,
  ) {
    if (flipProbability <= 0) return data;
    final result = Uint8List.fromList(data);
    for (int i = 0; i < result.length; i++) {
      int byte = result[i];
      for (int b = 0; b < 8; b++) {
        if (rng.nextDouble() < flipProbability) {
          byte ^= (1 << b);
        }
      }
      result[i] = byte;
    }
    return result;
  }
}
