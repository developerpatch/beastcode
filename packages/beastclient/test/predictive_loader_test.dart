import 'package:beastclient/beastclient.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PredictiveLoader', () {
    test('returns highest-probability transitions first', () {
      final predictor = PredictiveLoader();
      predictor.recordTransition(fromTrackId: 'a', toTrackId: 'c');
      predictor.recordTransition(fromTrackId: 'a', toTrackId: 'b');
      predictor.recordTransition(fromTrackId: 'a', toTrackId: 'b');

      final tracks = <AudioTrack>[
        AudioTrack(id: 'b', uri: Uri.parse('https://example.com/b.mp3')),
        AudioTrack(id: 'c', uri: Uri.parse('https://example.com/c.mp3')),
        AudioTrack(id: 'd', uri: Uri.parse('https://example.com/d.mp3')),
      ];

      final predicted = predictor.predictNext(
        currentTrack: AudioTrack(id: 'a', uri: Uri.parse('https://example.com/a.mp3')),
        availableTracks: tracks,
        limit: 2,
      );

      expect(predicted.map((track) => track.id).toList(), <String>['b', 'c']);
    });
  });
}