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
    // Si ya se está reproduciendo con EXACTAMENTE el mismo formato, no hay
    // nada que reconfigurar. Evitar el reinicio es importante: un stop()+
    // start() repetido en poco tiempo (p. ej. dos meta-paquetes seguidos con
    // el mismo formato) puede dejar el hilo escritor interno de flutter_sound
    // esperando para siempre una señal nativa "needSomeFood" que nunca llega
    // — silencio total el resto de la sesión, sin ningún error visible
    // (confirmado con logcat en hardware real: 0 frames entregados al
    // AudioTrack durante toda la llamada tras un reinicio).
    if (_isPlaying &&
        sampleRate == _sampleRate &&
        numChannels == _numChannels &&
        bitsPerSample == _bitsPerSample) {
      return;
    }

    if (!_isPlayerOpen) await init();
    if (_isPlaying) await stopStreaming();

    _sampleRate    = sampleRate;
    _numChannels   = numChannels;
    _bitsPerSample = bitsPerSample;

    // flutter_sound mapea numChannels via Codec.pcm16 (mono) o pcm16Stereo.
    // Para Int16 mono/stereo se usa t_CODEC.codec_pcm16.
    // El Codec correcto para PCM crudo de 16 bits es pcm16.
    //
    // bufferSize=8192 (≈256 ms a 16kHz mono, antes 2048≈64ms): un buffer
    // nativo tan chico se vacía (underrun) apenas el Timer de drenado se
    // atrasa un poco (el event loop de Dart no es tiempo-real duro; el BT/DSP
    // compitiendo por el hilo puede retrasar un tick). Confirmado con logcat
    // real: el HAL reporta "out_write: underrun" justo antes de un crash
    // nativo en AudioTrack — cuando el buffer se vacía del todo, la
    // recuperación automática de Android (restartIfDisabled) puede chocar
    // con nuestra siguiente escritura y corromper el conteo interno del
    // AudioTrack (mismo bug reportado en flutter_sound#508). Un buffer más
    // grande absorbe esa fluctuación sin llegar nunca a vaciarse del todo.
    await _player.startPlayerFromStream(
      codec: Codec.pcm16,
      numChannels: numChannels,
      sampleRate: sampleRate,
      bufferSize: 8192,
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
  ///
  /// Con `timeout`: si `feedFromStream()` internamente queda esperando para
  /// siempre una señal nativa que nunca llega (ver nota en [startStreaming]),
  /// esto evita que la cadena de escrituras serializada de AppState quede
  /// bloqueada de forma permanente — se sacrifica ese bloque puntual en vez
  /// de perder el audio del resto de la sesión.
  Future<void> feedChunk(Uint8List chunk) async {
    if (!_isPlaying) return;
    try {
      await _player.feedFromStream(chunk).timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          _log.w('feedFromStream() sin responder tras 2 s — se descarta este bloque');
        },
      );
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
