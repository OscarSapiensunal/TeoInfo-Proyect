// lib/main.dart
//
// Punto de entrada de la aplicación.
// Configura el árbol de Provider y arranca el Dashboard.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';

import 'utils/app_state.dart';
import 'ui/ui_dashboard.dart';

final Logger _crashLog = Logger();

void main() {
  // Red de seguridad global: cualquier excepción no capturada (Flutter
  // framework o asíncrona fuera de un try/catch) se registra en vez de
  // cerrar la app silenciosamente — crítico durante las pruebas de campo
  // con Bluetooth/audio, donde un fallo nativo puntual no debe tumbar la
  // sesión completa.
  FlutterError.onError = (FlutterErrorDetails details) {
    _crashLog.e('FlutterError no capturado', error: details.exception, stackTrace: details.stack);
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    _crashLog.e('Error no capturado en PlatformDispatcher', error: error, stackTrace: stack);
    return true; // manejado: no relanzar
  };

  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();

    // Forzar orientación vertical para mejor legibilidad del dashboard
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    // Estilo de barra de estado oscuro (fondo de app oscuro)
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
    );

    runApp(
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: const DspBtApp(),
      ),
    );
  }, (Object error, StackTrace stack) {
    _crashLog.e('Error no capturado en la zona raíz', error: error, stackTrace: stack);
  });
}

class DspBtApp extends StatelessWidget {
  const DspBtApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DSP · BT Analyzer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF58A6FF),
          brightness: Brightness.dark,
          surface: const Color(0xFF0D1117),
        ),
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        fontFamily: 'sans-serif',
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: Color(0xFFE6EDF3)),
        ),
      ),
      home: const UiDashboard(),
    );
  }
}
