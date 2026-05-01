import 'dart:async';
import 'dart:math';

import 'package:beastclient/beastclient.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('startup latency benchmark stays below 50ms at p95', () async {
    const iterations = 200;
    final rng = Random(7);
    final latencies = <int>[];

    for (var i = 0; i < iterations; i++) {
      final engine = _BenchmarkEngine(
        signalDelay: Duration(milliseconds: 12 + rng.nextInt(18)),
      );
      final client = BeastClient(
        engine: engine,
        config: const BeastClientConfig(startupTarget: Duration(milliseconds: 50)),
      );
      await client.initialize();
      final track = AudioTrack(
        id: 'bench-$i',
        uri: Uri.parse('https://example.com/bench-$i.mp3'),
      );

      await client.setQueue(<AudioTrack>[track]);
      final metrics = await client.playTrack(track);
      latencies.add(metrics.startupLatency.inMilliseconds);
      await client.dispose();
    }

    latencies.sort();
    final p50 = latencies[(iterations * 0.50).floor()];
    final p95 = latencies[(iterations * 0.95).floor()];
    final max = latencies.last;
    final sub50Count = latencies.where((ms) => ms <= 50).length;
    final sub50Percent = sub50Count / iterations * 100;

    // ignore: avoid_print
    print(
      'Benchmark: runs=$iterations p50=${p50}ms p95=${p95}ms max=${max}ms <=50ms=${sub50Percent.toStringAsFixed(1)}%',
    );

    expect(p95, lessThanOrEqualTo(50));
    expect(sub50Percent, greaterThanOrEqualTo(95.0));
  });
}

class _BenchmarkEngine implements AudioEngine {
  _BenchmarkEngine({required this.signalDelay});

  final Duration signalDelay;
  final StreamController<PlaybackSignal> _controller =
      StreamController<PlaybackSignal>.broadcast();

  @override
  Stream<PlaybackSignal> get playbackSignals => _controller.stream;

  @override
  Future<void> applyEnhancement(AudioEnhancementProfile profile) async {}

  @override
  Future<void> dispose() async => _controller.close();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> play() async {
    unawaited(
      Future<void>.delayed(signalDelay, () {
        _controller.add(const PlaybackSignal(PlaybackSignalType.playing));
      }),
    );
  }

  @override
  Future<void> prepare(AudioTrack track) async {}

  @override
  Future<void> seekToTrack(int index) async {}

  @override
  Future<void> setCrossfade(Duration duration) async {}

  @override
  Future<void> setQueue(List<AudioTrack> queue, {int initialIndex = 0}) async {}

  @override
  Future<void> stop() async {}
}
