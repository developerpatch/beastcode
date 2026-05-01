import '../enhancement/audio_enhancement_profile.dart';
import '../model/audio_track.dart';

abstract class AudioEngine {
  Future<void> initialize();
  Future<void> setCrossfade(Duration duration);
  Future<void> setQueue(List<AudioTrack> queue, {int initialIndex = 0});
  Future<void> prepare(AudioTrack track);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seekToTrack(int index);
  Future<void> applyEnhancement(AudioEnhancementProfile profile);
  Stream<PlaybackSignal> get playbackSignals;
  Future<void> dispose();
}

enum PlaybackSignalType {
  buffering,
  ready,
  playing,
  completed,
  networkError,
  decodingError,
}

class PlaybackSignal {
  const PlaybackSignal(this.type, {this.details});

  final PlaybackSignalType type;
  final Object? details;
}
