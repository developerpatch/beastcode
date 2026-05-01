import 'dart:async';
import 'dart:math';

import 'package:beastclient/beastclient.dart';

Future<void> main() async {
  final iterations = 200;
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
      id: 'track-$i',
      uri: Uri.parse('https://example.com/track-$i.mp3'),
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

  print('BeastClient Startup Benchmark');
  print('Runs: $iterations');
  print('P50: ${p50}ms');
  print('P95: ${p95}ms');
  print('Max: ${max}ms');
  print('<=50ms: ${(sub50Count / iterations * 100).toStringAsFixed(1)}%');
}

class _BenchmarkEngine implements AudioEngine {
  _BenchmarkEngine({required this.signalDelay});

  final Duration signalDelay;
  final _controller = StreamController<PlaybackSignal>.broadcast();

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
