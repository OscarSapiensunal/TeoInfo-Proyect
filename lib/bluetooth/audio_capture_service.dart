// lib/bluetooth/audio_capture_service.dart
//
// Captura de micrófono en PCM lineal Int16 LE (sin compresión) usando
// flutter_sound. Emite los bytes crudos por un Stream; la segmentación en
// frames de ~128 ms la hace BluetoothManager acumulando kFramePcmBytes.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_sound/flutter_sound.dart';
import 'package:logger/logger.dart';

import '../models/app_models.dart';

class AudioCaptureService {
  final Logger _log = Logger();
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();

  StreamController<Uint8List>? _pcmController;
  bool _isOpen = false;
  bool _isCapturing = false;

  bool get isCapturing => _isCapturing;

  /// Abre el motor de grabación. Debe llamarse antes de startCapture().
  Future<void> init() async {
    if (_isOpen) return;
    await _recorder.openRecorder();
    _isOpen = true;
    _log.i('FlutterSoundRecorder abierto');
  }

  /// Inicia la captura del micrófono y devuelve el stream de bytes PCM
  /// Int16 LE intercalados a [sampleRate] Hz / [numChannels] canales.
  Future<Stream<Uint8List>> startCapture({
    int sampleRate = kMicSampleRate,
    int numChannels = kMicNumChannels,
  }) async {
    if (!_isOpen) await init();
    if (_isCapturing) await stopCapture();

    _pcmController = StreamController<Uint8List>();
    try {
      await _recorder.startRecorder(
        codec: Codec.pcm16,
        toStream: _pcmController!.sink,
        sampleRate: sampleRate,
        numChannels: numChannels,
        // LA CLAVE DEL ANTI-ECO: capturar por el camino de audio de
        // COMUNICACIÓN (el de las llamadas), no por el de medios. Con esta
        // fuente, Android pasa el micrófono por el cancelador de eco
        // acústico DE HARDWARE del teléfono — que dentro del HAL tiene
        // acceso alineado a lo que el parlante reproduce y a lo que el
        // micrófono capta (justo la alineación que nuestro NLMS en Dart no
        // podía lograr, ver README dif. 14/15). Es el mismo mecanismo que
        // usan WhatsApp y las apps de VoIP. Trae además supresión de ruido
        // y control de ganancia orientados a voz.
        audioSource: AudioSource.voice_communication,
      );
    } catch (e) {
      _log.e('Error arrancando la grabadora: $e');
      await _pcmController?.close();
      _pcmController = null;
      // Un fallo aquí puede dejar el recorder nativo en un estado inconsistente;
      // forzamos reabrirlo desde cero en el próximo intento en lugar de
      // reutilizar una instancia potencialmente corrupta (evita que reintentos
      // sucesivos fallen en silencio o de forma cada vez más impredecible).
      try {
        await _recorder.closeRecorder();
      } catch (_) {
        // Ignorado: ya estamos en manejo de error, closeRecorder es best-effort.
      }
      _isOpen = false;
      rethrow;
    }
    _isCapturing = true;
    _log.i('Captura de micrófono iniciada: ${sampleRate}Hz ${numChannels}ch PCM16');
    return _pcmController!.stream;
  }

  /// Detiene la captura y cierra el stream de PCM.
  Future<void> stopCapture() async {
    if (!_isCapturing) return;
    _isCapturing = false;
    try {
      await _recorder.stopRecorder();
    } catch (e) {
      _log.w('Error deteniendo grabadora: $e');
    }
    await _pcmController?.close();
    _pcmController = null;
    _log.i('Captura de micrófono detenida');
  }

  /// Libera todos los recursos del motor de grabación.
  Future<void> dispose() async {
    await stopCapture();
    if (_isOpen) {
      await _recorder.closeRecorder();
      _isOpen = false;
    }
    _log.i('AudioCaptureService liberado');
  }
}
