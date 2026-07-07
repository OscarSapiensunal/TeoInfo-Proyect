// lib/bluetooth/audio_player_service.dart
//
// Servicio de reproducción de audio PCM crudo en tiempo real.
//
// Usa flutter_sound con FlutterSoundPlayer.startPlayerFromStream() para
// escribir bloques de bytes PCM directamente a los parlantes sin crear
// archivos intermedios. Esto es esencial para la reproducción en tiempo
// real del stream BT procesado por el DspProcessor.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_sound/flutter_sound.dart';
import 'package:logger/logger.dart';

class AudioPlayerService {
  final Logger _log = Logger();
  final FlutterSoundPlayer _player = FlutterSoundPlayer();

  bool _isPlayerOpen = false;
  bool _isPlaying   = false;

  /// Parámetros del stream de audio activo.
  int _sampleRate    = 44100;
  int _numChannels   = 1;
  int _bitsPerSample = 16;

  // ─────────────────────────────────────────────────────────────────────────
  // INICIALIZACIÓN
  // ─────────────────────────────────────────────────────────────────────────

  /// Abre el motor de audio. Debe llamarse antes de startStreaming().
  Future<void> init() async {
    if (_isPlayerOpen) return;
    await _player.openPlayer();
    _isPlayerOpen = true;
    _log.i('FlutterSoundPlayer abierto');
  }

  /// Configura e inicia el stream PCM crudo hacia los parlantes.
  ///
  /// [sampleRate]    : frecuencia de muestreo en Hz (ej. 44100, 16000).
  /// [numChannels]   : 1 = mono, 2 = estéreo.
  /// [bitsPerSample] : 16 (Int16 PCM LE) es el único soportado actualmente.
  Future<void> startStreaming({
    int sampleRate    = 44100,
    int numChannels   = 1,
    int bitsPerSample = 16,
  }) async {
    if (!_isPlayerOpen) await init();
    if (_isPlaying) await stopStreaming();

    _sampleRate    = sampleRate;
    _numChannels   = numChannels;
    _bitsPerSample = bitsPerSample;

    // flutter_sound mapea numChannels via Codec.pcm16 (mono) o pcm16Stereo.
    // Para Int16 mono/stereo se usa t_CODEC.codec_pcm16.
    // El Codec correcto para PCM crudo de 16 bits es pcm16.
    await _player.startPlayerFromStream(
      codec: Codec.pcm16,
      numChannels: numChannels,
      sampleRate: sampleRate,
      bufferSize: 2048,
      interleaved: true,
    );

    _isPlaying = true;
    _log.i('Streaming de audio iniciado: ${sampleRate}Hz ${numChannels}ch ${bitsPerSample}bit');
  }

  /// Escribe un bloque de bytes PCM al buffer del motor de audio.
  ///
  /// Debe llamarse desde un hilo de aislamiento o con precaución para no
  /// bloquear el hilo UI. La escritura es no-bloqueante gracias al FoodSink
  /// interno de flutter_sound.
  ///
  /// [chunk] : bytes PCM Int16 LE, longitud variable.
  Future<void> feedChunk(Uint8List chunk) async {
    if (!_isPlaying) return;
    try {
      await _player.feedFromStream(chunk);
    } catch (e) {
      _log.w('Error alimentando chunk de audio: $e');
    }
  }

  /// Detiene la reproducción y libera el stream.
  Future<void> stopStreaming() async {
    if (!_isPlaying) return;
    await _player.stopPlayer();
    _isPlaying = false;
    _log.i('Streaming de audio detenido');
  }

  /// Libera todos los recursos del motor de audio.
  Future<void> dispose() async {
    await stopStreaming();
    if (_isPlayerOpen) {
      await _player.closePlayer();
      _isPlayerOpen = false;
    }
    _log.i('AudioPlayerService liberado');
  }

  bool get isPlaying => _isPlaying;
  int  get sampleRate => _sampleRate;
}
