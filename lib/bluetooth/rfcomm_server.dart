// lib/bluetooth/rfcomm_server.dart
//
// Wrapper Dart del servidor RFCOMM/SPP nativo implementado en MainActivity.kt.
//
// flutter_bluetooth_serial solo permite conexiones salientes (cliente). Para
// que dos teléfonos con el mismo APK se comuniquen P2P, el emisor escucha
// conexiones entrantes con este servidor nativo mientras el receptor conecta
// como cliente con BluetoothConnection.toAddress().
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';

import 'package:flutter/services.dart';

enum SppServerEventType { waiting, connected, data, disconnected, error }

class SppServerEvent {
  final SppServerEventType type;
  final String? deviceName;
  final String? deviceAddress;
  final Uint8List? bytes;
  final String? message;

  const SppServerEvent({
    required this.type,
    this.deviceName,
    this.deviceAddress,
    this.bytes,
    this.message,
  });
}

class RfcommSppServer {
  static const MethodChannel _method =
      MethodChannel('com.dsp_bt_analyzer/spp_server');
  static const EventChannel _events =
      EventChannel('com.dsp_bt_analyzer/spp_server_events');

  /// Stream de eventos del servidor. Suscribirse ANTES de llamar a [start]
  /// para no perder el evento 'waiting'.
  Stream<SppServerEvent> events() {
    return _events.receiveBroadcastStream().map((dynamic raw) {
      final map = Map<Object?, Object?>.from(raw as Map);
      switch (map['event'] as String?) {
        case 'waiting':
          return const SppServerEvent(type: SppServerEventType.waiting);
        case 'connected':
          return SppServerEvent(
            type: SppServerEventType.connected,
            deviceName: map['name'] as String?,
            deviceAddress: map['address'] as String?,
          );
        case 'data':
          return SppServerEvent(
            type: SppServerEventType.data,
            bytes: map['bytes'] as Uint8List?,
          );
        case 'disconnected':
          return const SppServerEvent(type: SppServerEventType.disconnected);
        default:
          return SppServerEvent(
            type: SppServerEventType.error,
            message: map['message'] as String?,
          );
      }
    });
  }

  /// Inicia el servidor: listen + accept() de una conexión entrante.
  Future<void> start() => _method.invokeMethod<void>('start');

  /// Escribe bytes al cliente conectado. Completa cuando la escritura
  /// termina en el socket (backpressure natural para el emisor).
  Future<void> write(Uint8List bytes) =>
      _method.invokeMethod<void>('write', <String, dynamic>{'bytes': bytes});

  /// Cierra sockets de servidor y cliente.
  Future<void> stop() => _method.invokeMethod<void>('stop');

  Future<bool> isConnected() async =>
      await _method.invokeMethod<bool>('isConnected') ?? false;
}
