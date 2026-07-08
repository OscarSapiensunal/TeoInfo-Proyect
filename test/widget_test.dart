// test/widget_test.dart
//
// Pruebas unitarias del protocolo de paquetes BT (ráfagas P2P y ACK) y del
// Jitter Buffer del DspProcessor.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsp_bt_analyzer/models/app_models.dart';
import 'package:dsp_bt_analyzer/dsp/dsp_processor.dart';

void main() {
  test('Paquete de datos: build + parse de secuencia', () {
    final payload = Uint8List.fromList(List.filled(kPayloadSize, 0x7F));
    final packet = buildPacket(0x1234, payload);

    expect(packet.length, kPacketSize);
    expect(packet[0], kMagicByte0);
    expect(packet[1], kMagicByte1);
    expect(parseSequenceNumber(packet), 0x1234);
  });

  test('Cabecera de ráfaga: build + parse', () {
    final txEpoch = DateTime.now().millisecondsSinceEpoch;
    final packet = buildBurstHeaderPacket(
      burstId: 42,
      pcmByteLength: kBurstPcmBytes,
      txEpochMs: txEpoch,
    );

    expect(packet.length, kPacketSize);
    expect(packet[0], kBurstMagic0);
    expect(packet[1], kBurstMagic1);

    final header = BurstHeader.parse(packet);
    expect(header.burstId, 42);
    expect(header.pcmByteLength, kBurstPcmBytes);
    expect(header.txEpochMs, txEpoch);
  });

  test('ACK de ráfaga: build + parse', () {
    final tx = DateTime.now().millisecondsSinceEpoch;
    final rx = tx + 137;
    final ack = buildAckPacket(burstId: 7, txEpochMs: tx, rxEpochMs: rx);

    expect(ack.length, kAckPacketSize);
    expect(ack[0], kAckMagic0);
    expect(ack[1], kAckMagic1);

    final parsed = BurstAck.parse(ack);
    expect(parsed.burstId, 7);
    expect(parsed.txEpochMs, tx);
    expect(parsed.rxEpochMs, rx);
  });

  test('Tamaño de ráfaga: 2 s de PCM 16 kHz mono Int16 = 64000 bytes', () {
    expect(kBurstPcmBytes, 64000);
  });

  test('Jitter Buffer: processBlock encola sin auto-extraer (fillRatio real)', () {
    // Regresión: antes processBlock() empujaba y extraía en la misma llamada,
    // dejando el buffer en count=0 siempre y el indicador de UI "muerto".
    final dsp = DspProcessor();
    expect(dsp.jitterBuffer.size, 0);

    final block = Uint8List.fromList(List.filled(kPayloadSize, 0x11));
    for (int i = 0; i < 5; i++) {
      dsp.processBlock(rawBlock: block, rssiDbm: -60.0, isLost: false);
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
      dsp.processBlock(rawBlock: block, rssiDbm: -60.0, isLost: false);
    }
    expect(dsp.jitterBuffer.size, kJitterBufferCapacity);
    expect(dsp.jitterBuffer.isFull, isTrue);
    // Los 3 primeros bloques (índices 0,1,2) fueron descartados por overflow.
    expect(dsp.jitterBuffer.pop()!.first, 3);
  });
}
