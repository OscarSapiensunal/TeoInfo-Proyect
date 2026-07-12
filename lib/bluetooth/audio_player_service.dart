// lib/bluetooth/audio_player_service.dart
//
// Reproducción de audio PCM por clips discretos encolados (NO streaming en
// tiempo real).
//
// Se abandonó `startPlayerFromStream()` + `feedFromStream()` tras confirmar
// con logcat en tres teléfonos distintos (dos chipsets, dos versiones de
// Android) un crash nativo reproducible: SIGSEGV/SIGABRT dentro de
// `AudioTrack::write`/`releaseBuffer`, exactamente el mismo patrón reportado
// sin resolver en flutter_sound#508 (github.com/Canardoux/flutter_sound).
// Ajustar el tamaño del buffer o la cadencia de escritura no lo eliminó —
// es un bug de concurrencia interno del plugin en su API de streaming.
//
// En su lugar, cada bloque de PCM recibido se agrupa en clips de ~500 ms
// (ver BluetoothManager) y se reproduce con `startPlayer(fromDataBuffer:)`,
// la API "de archivo" mucho más madura y usada de flutter_sound — evita por
// completo el código de streaming en tiempo real donde vive el bug. Los
// clips se encolan y se reproducen uno tras otro (dispara el siguiente en
// `whenFinished`), a costa de ~0.5-1 s de latencia adicional frente al
// streaming puro, aceptable dado que la arquitectura ya tiene ~2 s de
// latencia inherente por el diseño de ráfagas de 2 s.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_sound/flutter_sound.dart';
import 'package:logger/logger.dart';

class AudioPlayerService {
  final Logger _log = Logger();
  final FlutterSoundPlayer _player = FlutterSoundPlayer();

  bool _isPlayerOpen = false;
  bool _isPlayingClip = false;

  int _sampleRate  = 44100;
  int _numChannels = 1;

  final Queue<Uint8List> _queue = Queue<Uint8List>();

  /// Tope de la cola de clips pendientes. Cada startPlayer() añade una
  /// pequeña pausa entre clips (~0.2 s), así que reproducir 2 s de audio
  /// tarda ~2.2 s: la reproducción es estructuralmente más lenta que la
  /// llegada y sin tope la cola crece sin límite (latencia siempre en
  /// aumento). Con drop-oldest y tope 2, la latencia embalsada queda
  /// acotada a ~2 clips (~5 s peor caso): se prefiere perder el fragmento
  /// más viejo a que toda la conversación quede en diferido.
  static const int kMaxQueuedClips = 2;

  // ─────────────────────────────────────────────────────────────────────────
  // INICIALIZACIÓN
  // ─────────────────────────────────────────────────────────────────────────

  /// Abre el motor de audio. Debe llamarse antes de encolar clips.
  Future<void> init() async {
    if (_isPlayerOpen) return;
    await _player.openPlayer();
    _isPlayerOpen = true;
    _log.i('FlutterSoundPlayer abierto');
  }

  /// Fija el formato (sampleRate/canales) con el que se reproducirán los
  /// próximos clips encolados. Operación puramente local — no toca el
  /// reproductor nativo, así que no hay riesgo de reinicios concurrentes.
  void configure({required int sampleRate, required int numChannels}) {
    _sampleRate  = sampleRate;
    _numChannels = numChannels;
  }

  /// Encola un bloque de PCM Int16 LE para reproducirse como clip discreto,
  /// en el orden en que llega. Si no hay nada reproduciéndose, arranca de
  /// inmediato; si no, queda en cola y se reproduce cuando le toque.
  void enqueueChunk(Uint8List chunk) {
    if (chunk.isEmpty) return;
    _queue.add(chunk);
    while (_queue.length > kMaxQueuedClips) {
      _queue.removeFirst();
      _log.w('Cola de reproducción llena: se descarta el clip más antiguo '
          'para mantener la conversación cerca del presente');
    }
    if (!_isPlayingClip) {
      unawaited(_playNext());
    }
  }

  Future<void> _playNext() async {
    if (_queue.isEmpty) {
      _isPlayingClip = false;
      return;
    }
    _isPlayingClip = true;
    final chunk = _queue.removeFirst();

    try {
      if (!_isPlayerOpen) await init();
      await _player.startPlayer(
        codec: Codec.pcm16,
        fromDataBuffer: chunk,
        sampleRate: _sampleRate,
        numChannels: _numChannels,
        whenFinished: () {
          unawaited(_playNext());
        },
      );
    } catch (e) {
      _log.w('Error reproduciendo clip de audio: $e');
      // Seguir con el siguiente clip aunque este falle — un bloque perdido
      // no debe silenciar el resto de la sesión.
      unawaited(_playNext());
    }
  }

  /// Vacía la cola y detiene la reproducción en curso.
  Future<void> stopStreaming() async {
    _queue.clear();
    _isPlayingClip = false;
    try {
      await _player.stopPlayer();
    } catch (e) {
      _log.w('Error deteniendo el reproductor: $e');
    }
    _log.i('Reproducción detenida');
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

  bool get isPlaying => _isPlayingClip;
  int  get sampleRate => _sampleRate;
}
