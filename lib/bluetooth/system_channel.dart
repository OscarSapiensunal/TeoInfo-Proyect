// lib/bluetooth/system_channel.dart
//
// Canal hacia utilidades del sistema Android (MainActivity.kt).
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/services.dart';

class SystemChannel {
  static const MethodChannel _method = MethodChannel('com.dsp_bt_analyzer/system');

  /// Mantiene (o deja de mantener) la pantalla encendida.
  ///
  /// Durante una sesión activa la pantalla NO debe apagarse: al bloquearse,
  /// Android manda la app a segundo plano y estrangula sus timers y CPU
  /// (Doze/App Standby) — el audio y los paquetes BT siguen llegando pero se
  /// procesan a trompicones, la cola de reproducción acumula atraso y al
  /// desbloquear hay varios segundos de "latencia" embalsada. Best-effort:
  /// si el canal falla no debe tumbar la sesión (solo se pierde la comodidad).
  static Future<void> keepScreenOn(bool on) async {
    try {
      await _method.invokeMethod<void>('keepScreenOn', <String, dynamic>{'on': on});
    } catch (_) {
      // Ignorado: función de comodidad, nunca crítica.
    }
  }
}
