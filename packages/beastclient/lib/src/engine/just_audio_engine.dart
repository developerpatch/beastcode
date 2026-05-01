import 'dart:async';

import 'package:just_audio/just_audio.dart';

import '../core/audio_engine.dart';
import '../enhancement/audio_enhancement_profile.dart';
import '../model/audio_track.dart';

class JustAudioEngine implements AudioEngine {
  JustAudioEngine({
    AudioPlayer? player,
    AudioPlayer? warmupPlayer,
  })  : _player = player ?? AudioPlayer(),
        _warmupPlayer = warmupPlayer ?? AudioPlayer();

  final AudioPlayer _player;
  final AudioPlayer _warmupPlayer;
  final StreamController<PlaybackSignal> _signalsController =
      StreamController<PlaybackSignal>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];

  @override
  Future<void> initialize() async {
    _subscriptions.add(
      _player.playerStateStream.listen((state) {
        final signal = switch (state.processingState) {
          ProcessingState.loading || ProcessingState.buffering =>
            PlaybackSignalType.buffering,
          ProcessingState.ready when state.playing => PlaybackSignalType.playing,
          ProcessingState.ready => PlaybackSignalType.ready,
          ProcessingState.completed => PlaybackSignalType.completed,
          ProcessingState.idle => PlaybackSignalType.buffering,
        };
        _signalsController.add(PlaybackSignal(signal));
      }),
    );
    _subscriptions.add(
      _player.playbackEventStream.listen(
        (_) {},
        onError: (Object error, StackTrace _) {
          final text = error.toString().toLowerCase();
          final signalType =
              text.contains('network') ||
                      text.contains('socket') ||
                      text.contains('http') ||
                      text.contains('response code')
                  ? PlaybackSignalType.networkError
                  : PlaybackSignalType.decodingError;
          _signalsController.add(PlaybackSignal(signalType, details: error));
        },
      ),
    );
  }

  @override
  Future<void> setCrossfade(Duration duration) async {
    // `just_audio` 0.9.x does not expose a stable crossfade API here.
    // Keep the abstraction so a backend with native DSP/crossfade can implement it.
  }

  @override
  Future<void> setQueue(List<AudioTrack> queue, {int initialIndex = 0}) async {
    final source = ConcatenatingAudioSource(
      // Lazy preparation avoids waiting for full queue hydration before
      // current-track playback can start.
      useLazyPreparation: true,
      children: queue
          .map(
            (track) => AudioSource.uri(
              track.uri,
              headers: track.headers,
              tag: track.id,
            ),
          )
          .toList(growable: false),
    );
    await _player.setAudioSource(
      source,
      initialIndex: initialIndex,
      // Ensure current track is loaded immediately while keeping rest lazy.
      preload: true,
    );
  }

  @override
  Future<void> prepare(AudioTrack track) async {
    await _warmupPlayer.setAudioSource(
      AudioSource.uri(
        track.uri,
        headers: track.headers,
        tag: track.id,
      ),
      preload: true,
    );
  }

  @override
  Future<void> play() async {
    // Start playback without waiting for completion of the whole track.
    unawaited(
      _player.play().catchError((Object error) {
        final text = error.toString().toLowerCase();
        final signalType =
            text.contains('network') || text.contains('socket') || text.contains('http')
                ? PlaybackSignalType.networkError
                : PlaybackSignalType.decodingError;
        _signalsController.add(PlaybackSignal(signalType, details: error));
      }),
    );
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seekToTrack(int index) async {
    await _player.seek(Duration.zero, index: index);
  }

  @override
  Future<void> applyEnhancement(AudioEnhancementProfile profile) async {
    if (!profile.enableEnhancement) return;
    // Placeholder hook: platform DSP integration can be injected here.
  }

  @override
  Stream<PlaybackSignal> get playbackSignals => _signalsController.stream;

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _signalsController.close();
    await _warmupPlayer.dispose();
    await _player.dispose();
  }
}
