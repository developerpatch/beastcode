import '../model/audio_track.dart';

class PredictiveLoader {
  final Map<String, Map<String, int>> _transitions =
      <String, Map<String, int>>{};

  void recordTransition({
    required String fromTrackId,
    required String toTrackId,
  }) {
    final map = _transitions.putIfAbsent(fromTrackId, () => <String, int>{});
    map.update(toTrackId, (value) => value + 1, ifAbsent: () => 1);
  }

  List<AudioTrack> predictNext({
    required AudioTrack currentTrack,
    required List<AudioTrack> availableTracks,
    required int limit,
  }) {
    if (limit <= 0 || availableTracks.isEmpty) return const <AudioTrack>[];
    final map = _transitions[currentTrack.id];
    if (map == null || map.isEmpty) {
      return availableTracks.take(limit).toList(growable: false);
    }

    final byId = <String, AudioTrack>{
      for (final track in availableTracks) track.id: track,
    };
    final sorted = map.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final predicted = <AudioTrack>[];
    for (final entry in sorted) {
      final track = byId[entry.key];
      if (track != null) predicted.add(track);
      if (predicted.length >= limit) break;
    }
    if (predicted.length >= limit) return predicted;

    for (final track in availableTracks) {
      if (predicted.any((item) => item.id == track.id)) continue;
      predicted.add(track);
      if (predicted.length >= limit) break;
    }
    return predicted;
  }
}
