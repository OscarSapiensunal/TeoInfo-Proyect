// lib/bluetooth/rssi_channel.dart
//
// Wrapper Dart del canal nativo de RSSI (MainActivity.kt), que lee la
// potencia de señal real vía un truco híbrido GATT (BluetoothGatt.readRemoteRssi)
// sobre el dispositivo Bluetooth Clásico ya conectado. No todos los chips
// soportan esto para un dispositivo puramente clásico — por eso el llamador
// debe tratar cualquier fallo/timeout como señal para usar un valor simulado.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/services.dart';

class RssiChannel {
  static const MethodChannel _method = MethodChannel('com.dsp_bt_analyzer/rssi');

  /// Intenta leer el RSSI real (dBm) del dispositivo remoto en [address].
  /// Lanza si el teléfono/dispositivo remoto no soporta el truco GATT, o si
  /// no responde dentro de [timeout] (evita que una conexión GATT colgada
  /// deje la llamada pendiente para siempre).
  static Future<double> getRssi(
    String address, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final result = await _method
        .invokeMethod<double>('getRssi', <String, dynamic>{'address': address})
        .timeout(timeout);
    if (result == null) {
      throw StateError('Canal RSSI nativo devolvió null');
    }
    return result;
  }
}
