// test/widget_test.dart
//
// Pruebas unitarias del protocolo de paquetes BT (voz continua + PING/PONG),
// del Jitter Buffer del DspProcessor y de los códecs (Hamming, μ-law).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsp_bt_analyzer/models/app_models.dart';
import 'package:dsp_bt_analyzer/dsp/companding.dart';
import 'package:dsp_bt_analyzer/dsp/dsp_processor.dart';
import 'package:dsp_bt_analyzer/dsp/error_correction.dart';

void main() {
  test('Paquete de datos: build + parse de secuencia', () {
    final payload = Uint8List.fromList(List.filled(kPayloadSize, 0x7F));
    final packet = buildPacket(0x1234, payload);

    expect(packet.length, kPacketSize);
    expect(packet[0], kMagicByte0);
    expect(packet[1], kMagicByte1);
    expect(parseSequenceNumber(packet), 0x1234);
  });

  test('PING/PONG: build + parse con el mismo timestamp', () {
    final t0 = DateTime.now().millisecondsSinceEpoch;

    final ping = buildPingPacket(pingId: 42, epochMs: t0);
    expect(ping.length, kPingPacketSize);
    expect(ping[0], kPingMagic0);
    expect(ping[1], kPingMagic1);
    final parsedPing = PingPong.parse(ping);
    expect(parsedPing.pingId, 42);
    expect(parsedPing.epochMs, t0);

    // El PONG debe devolver el MISMO timestamp (el reloj del receptor no
    // participa — de ahí que el RTT no sufra el desfase entre relojes).
    final pong =
        buildPongPacket(pingId: parsedPing.pingId, epochMs: parsedPing.epochMs);
    expect(pong.length, kPingPacketSize);
    expect(pong[0], kPingMagic0);
    expect(pong[1], kPongMagic1);
    final parsedPong = PingPong.parse(pong);
    expect(parsedPong.pingId, 42);
    expect(parsedPong.epochMs, t0);
  });

  test('Frame de voz: 2040 B de PCM = 1020 B μ-law = un payload exacto', () {
    expect(kFramePcmBytes, kPayloadSize * 2);
    expect(kFramePcmBytes, 2040);
  });

  test('Jitter Buffer: processBlock encola sin auto-extraer (fillRatio real)', () {
    // Regresión: antes processBlock() empujaba y extraía en la misma llamada,
    // dejando el buffer en count=0 siempre y el indicador de UI "muerto".
    final dsp = DspProcessor();
    expect(dsp.jitterBuffer.size, 0);

    final block = Uint8List.fromList(List.filled(kPayloadSize, 0x11));
    for (int i = 0; i < 5; i++) {
      dsp.processBlock(
        rawBlock: block,
        rssiDbm: -60.0,
        isLost: false,
        plcEnabled: false,
        filterEnabled: false,
        fecEnabled: false,
      );
    }

    // El buffer debe reflejar los 5 bloques encolados, no drenarse solo.
    expect(dsp.jitterBuffer.size, 5);
    expect(dsp.jitterBuffer.fillRatio, closeTo(5 / kJitterBufferCapacity, 1e-9));

    // pop() externo (el consumidor periódico) sí debe drenarlo.
    for (int i = 0; i < 5; i++) {
      expect(dsp.jitterBuffer.pop(), isNotNull);
    }
    expect(dsp.jitterBuffer.size, 0);
    expect(dsp.jitterBuffer.pop(), isNull);
  });

  test('Jitter Buffer: descarta el más antiguo cuando se llena (drop-oldest)', () {
    final dsp = DspProcessor();
    for (int i = 0; i < kJitterBufferCapacity + 3; i++) {
      final block = Uint8List(kPayloadSize)..[0] = i & 0xFF;
      dsp.processBlock(
        rawBlock: block,
        rssiDbm: -60.0,
        isLost: false,
        plcEnabled: false,
        filterEnabled: false,
        fecEnabled: false,
      );
    }
    expect(dsp.jitterBuffer.size, kJitterBufferCapacity);
    expect(dsp.jitterBuffer.isFull, isTrue);
    // Los 3 primeros bloques (índices 0,1,2) fueron descartados por overflow.
    expect(dsp.jitterBuffer.pop()!.first, 3);
  });

  test('Hamming (7,4): codifica y decodifica sin corrupción', () {
    final data = Uint8List.fromList([0x00, 0xFF, 0xA5, 0x3C, 0x91]);
    final encoded = HammingCodec.encode(data);
    expect(encoded.length, data.length * 2);

    final decoded = HammingCodec.decode(encoded);
    expect(decoded.data, equals(data));
    expect(decoded.correctedBits, 0);
  });

  test('Hamming (7,4): corrige un bit volteado por cada byte codificado', () {
    final data = Uint8List.fromList([0x5A]);
    final encoded = HammingCodec.encode(data);

    // Voltea el bit 3 (posición arbitraria dentro de los 7 útiles) de cada
    // uno de los 2 bytes codificados (uno por nibble).
    final corrupted = Uint8List.fromList(encoded);
    corrupted[0] ^= (1 << 3);
    corrupted[1] ^= (1 << 5);

    final decoded = HammingCodec.decode(corrupted);
    expect(decoded.data, equals(data));
    expect(decoded.correctedBits, 2);
  });

  test('μ-law: silencio digital codifica a 0xFF y decodifica a 0', () {
    expect(MuLawCodec.encodeSample(0), MuLawCodec.kSilenceByte);
    expect(MuLawCodec.decodeSample(MuLawCodec.kSilenceByte), 0);
  });

  test('μ-law: error de cuantización acotado y signo preservado', () {
    // La cuantización μ-law es logarítmica: el paso crece con la amplitud
    // (fino cerca de 0, grueso en fondo de escala) pero el error relativo
    // se mantiene acotado. Verificamos sobre una rampa de amplitudes que
    // el round-trip conserva el signo y el error no supera el paso del
    // segmento correspondiente (~ amplitud/16 + sesgo).
    for (int s = -30000; s <= 30000; s += 977) {
      final decoded = MuLawCodec.decodeSample(MuLawCodec.encodeSample(s));
      if (s != 0) {
        expect(decoded.sign, s.sign, reason: 'signo en s=$s');
      }
      final tolerance = (s.abs() / 16) + 132;
      expect((decoded - s).abs() <= tolerance, isTrue,
          reason: 'error de cuantización excesivo en s=$s → $decoded');
    }
  });

  test('μ-law: encode reduce a la mitad y decode restaura el tamaño', () {
    final pcm = Uint8List.fromList(List.generate(64, (i) => i * 3));
    final encoded = MuLawCodec.encode(pcm);
    expect(encoded.length, pcm.length ~/ 2);
    final decoded = MuLawCodec.decode(encoded);
    expect(decoded.length, pcm.length);
  });
}
