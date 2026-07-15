// lib/bluetooth/native_audio_player.dart
//
// Reproducción de audio PCM en STREAMING REAL vía AudioTrack nativo
// (MainActivity.kt, canal "com.dsp_bt_analyzer/player").
//
// Historia de por qué existe (ver README §9): la API de streaming de
// flutter_sound crashea nativamente (SIGSEGV en AudioTrack::write, issue
// #508) y su API de clips discretos añade ~0.2 s de arranque POR CLIP —
// reproducir 2 s de audio tardaba ~2.2 s, el consumo era estructuralmente
// más lento que la llegada y la latencia solo podía crecer hasta ahogar la
// sesión. Con AudioTrack propio en MODE_STREAM el consumo es exactamente
// tiempo real, sin costo por chunk, y el hilo escritor único del lado
// nativo elimina la concurrencia que causaba el crash del plugin.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:logger/logger.dart';

import '../models/app_models.dart';

class NativeAudioPlayer {
  final Logger _log = Logger();
  static const MethodChannel _method =
      MethodChannel('com.dsp_bt_analyzer/player');

  int _sampleRate = kMicSampleRate;
  int _numChannels = kMicNumChannels;
  bool _started = false;

  /// Estimación (epoch ms) de cuándo terminará de sonar todo lo encolado:
  /// cada chunk empuja este horizonte hacia adelante según su duración.
  /// [isPlaying] compara contra el reloj — sin viajes por el MethodChannel
  /// (se consulta en cada chunk del micrófono para el gate del AEC).
  double _playbackEndEpochMs = 0;

  Future<void> init() async {} // el track nativo arranca perezosamente

  /// Fija el formato de los próximos chunks. Si cambia, el track nativo se
  /// recrea en el siguiente [enqueueChunk].
  void configure({required int sampleRate, required int numChannels}) {
    if (sampleRate != _sampleRate || numChannels != _numChannels) {
      _sampleRate = sampleRate;
      _numChannels = numChannels;
      _started = false;
    }
  }

  /// Encola PCM Int16 LE para reproducción streaming. El lado nativo
  /// mantiene una cola acotada con drop-oldest: esto NUNCA acumula atraso.
  Future<void> enqueueChunk(Uint8List pcm) async {
    if (pcm.isEmpty) return;
    try {
      if (!_started) {
        await _method.invokeMethod<void>('ptStart', <String, dynamic>{
          'sampleRate': _sampleRate,
          'channels': _numChannels,
        });
        _started = true;
      }
      await _method.invokeMethod<void>('ptWrite', <String, dynamic>{
        'bytes': pcm,
      });
      final double nowMs =
          DateTime.now().millisecondsSinceEpoch.toDouble();
      final double durMs =
          pcm.length / (_sampleRate * _numChannels * 2) * 1000.0;
      _playbackEndEpochMs =
          (nowMs > _playbackEndEpochMs ? nowMs : _playbackEndEpochMs) + durMs;
    } catch (e) {
      _log.w('Error escribiendo al reproductor nativo: $e');
    }
  }

  /// true mientras (según la estimación) quede audio encolado sonando —
  /// es la señal del semi-dúplex del AEC.
  bool get isPlaying =>
      DateTime.now().millisecondsSinceEpoch < _playbackEndEpochMs;

  int get sampleRate => _sampleRate;

  Future<void> stopStreaming() async {
    _playbackEndEpochMs = 0;
    _started = false;
    try {
      await _method.invokeMethod<void>('ptStop');
    } catch (e) {
      _log.w('Error deteniendo el reproductor nativo: $e');
    }
  }

  Future<void> dispose() => stopStreaming();
}
