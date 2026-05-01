import 'dart:async';

import 'package:beastclient/beastclient.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BeastClient', () {
    test('measures startup latency and prebuffers predicted tracks', () async {
      final engine = _FakeAudioEngine(playDelay: const Duration(milliseconds: 8));
      final client = BeastClient(
        engine: engine,
        config: const BeastClientConfig(
          startupTarget: Duration(milliseconds: 50),
          prebufferTrackCount: 2,
        ),
      );

      await client.initialize();
      final queue = <AudioTrack>[
        AudioTrack(id: 'a', uri: Uri.parse('https://example.com/a.mp3')),
        AudioTrack(id: 'b', uri: Uri.parse('https://example.com/b.flac')),
        AudioTrack(id: 'c', uri: Uri.parse('https://example.com/c.ogg')),
      ];
      await client.setQueue(queue);
      final metrics = await client.playTrack(queue.first);

      expect(metrics.metStartupTarget, isTrue);
      expect(metrics.startupLatency.inMilliseconds, lessThan(50));
      expect(engine.preparedTrackIds, containsAll(<String>['b', 'c']));
    });

    test('retries transient network failures', () async {
      final engine = _FakeAudioEngine(
        playDelay: const Duration(milliseconds: 1),
        failuresBeforeSuccess: 2,
        failureMessage: 'SocketException: network disconnected',
      );
      final client = BeastClient(
        engine: engine,
        config: const BeastClientConfig(maxRetries: 2),
      );
      await client.initialize();
      final track =
          AudioTrack(id: 'x', uri: Uri.parse('https://example.com/x.mp3'));
      await client.setQueue(<AudioTrack>[track]);

      final metrics = await client.playTrack(track);

      expect(metrics.startupLatency, isA<Duration>());
      expect(engine.playAttempts, 3);
    });

    test('throws corruptedAudio for decoder-like failures', () async {
      final engine = _FakeAudioEngine(
        failuresBeforeSuccess: 1,
        failureMessage: 'DecoderError: corrupt frame',
      );
      final client = BeastClient(
        engine: engine,
        config: const BeastClientConfig(maxRetries: 0),
      );
      await client.initialize();
      final track =
          AudioTrack(id: 'bad', uri: Uri.parse('https://example.com/bad.flac'));
      await client.setQueue(<AudioTrack>[track]);

      expect(
        () => client.playTrack(track),
        throwsA(
          isA<BeastClientException>()
              .having((error) => error.code, 'code', BeastClientErrorCode.corruptedAudio),
        ),
      );
    });

    test('serializes concurrent play requests', () async {
      final engine = _FakeAudioEngine(playDelay: const Duration(milliseconds: 20));
      final client = BeastClient(engine: engine);
      await client.initialize();
      final first =
          AudioTrack(id: '1', uri: Uri.parse('https://example.com/1.mp3'));
      final second =
          AudioTrack(id: '2', uri: Uri.parse('https://example.com/2.mp3'));
      await client.setQueue(<AudioTrack>[first, second]);

      final f1 = client.playTrack(first);
      final f2 = client.playTrack(second);
      await Future.wait(<Future<PlaybackMetrics>>[f1, f2]);

      expect(engine.maxConcurrentPlayCalls, 1);
      expect(engine.playAttempts, 2);
    });

    test('handles immediate playing signal without timing out', () async {
      final engine = _FakeAudioEngine(
        playDelay: Duration.zero,
        emitImmediately: true,
      );
      final client = BeastClient(
        engine: engine,
        config: const BeastClientConfig(
          startupTarget: Duration(milliseconds: 20),
        ),
      );

      await client.initialize();
      final track =
          AudioTrack(id: 'fast', uri: Uri.parse('https://example.com/fast.mp3'));
      await client.setQueue(<AudioTrack>[track]);
      final metrics = await client.playTrack(track);

      expect(metrics.startupLatency.inMilliseconds, lessThan(100));
      expect(metrics.metStartupTarget, isTrue);
    });

    test('does not reuse stale playing signal across play attempts', () async {
      final engine = _OneShotSignalAudioEngine();
      final client = BeastClient(
        engine: engine,
        config: const BeastClientConfig(
          startupTarget: Duration(milliseconds: 20),
          maxRetries: 0,
        ),
      );
      await client.initialize();

      final first =
          AudioTrack(id: 'first', uri: Uri.parse('https://example.com/first.mp3'));
      await client.setQueue(<AudioTrack>[first]);
      await client.playTrack(first);

      final second =
          AudioTrack(id: 'second', uri: Uri.parse('https://example.com/second.mp3'));
      await client.setQueue(<AudioTrack>[second]);
      await expectLater(
        client.playTrack(second),
        throwsA(isA<BeastClientException>()),
      );
      expect(engine.playAttempts, 2);
    });
  });
}

class _FakeAudioEngine implements AudioEngine {
  _FakeAudioEngine({
    this.playDelay = Duration.zero,
    this.failuresBeforeSuccess = 0,
    this.failureMessage = 'network failure',
    this.emitImmediately = false,
  });

  final Duration playDelay;
  final int failuresBeforeSuccess;
  final String failureMessage;
  final bool emitImmediately;
  final StreamController<PlaybackSignal> _signals =
      StreamController<PlaybackSignal>.broadcast();

  final List<String> preparedTrackIds = <String>[];
  int _failureCount = 0;
  int _activePlayCalls = 0;
  int maxConcurrentPlayCalls = 0;
  int playAttempts = 0;

  @override
  Stream<PlaybackSignal> get playbackSignals => _signals.stream;

  @override
  Future<void> applyEnhancement(AudioEnhancementProfile profile) async {}

  @override
  Future<void> dispose() async {
    await _signals.close();
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> play() async {
    playAttempts++;
    _activePlayCalls++;
    if (_activePlayCalls > maxConcurrentPlayCalls) {
      maxConcurrentPlayCalls = _activePlayCalls;
    }
    try {
      if (_failureCount < failuresBeforeSuccess) {
        _failureCount++;
        throw Exception(failureMessage);
      }
      if (emitImmediately) {
        _signals.add(const PlaybackSignal(PlaybackSignalType.playing));
        return;
      }
      unawaited(
        Future<void>.delayed(playDelay, () {
          _signals.add(const PlaybackSignal(PlaybackSignalType.playing));
        }),
      );
    } finally {
      _activePlayCalls--;
    }
  }

  @override
  Future<void> prepare(AudioTrack track) async {
    preparedTrackIds.add(track.id);
  }

  @override
  Future<void> seekToTrack(int index) async {}

  @override
  Future<void> setCrossfade(Duration duration) async {}

  @override
  Future<void> setQueue(List<AudioTrack> queue, {int initialIndex = 0}) async {}

  @override
  Future<void> stop() async {}
}

class _OneShotSignalAudioEngine implements AudioEngine {
  final StreamController<PlaybackSignal> _signals =
      StreamController<PlaybackSignal>.broadcast();
  int playAttempts = 0;

  @override
  Stream<PlaybackSignal> get playbackSignals => _signals.stream;

  @override
  Future<void> applyEnhancement(AudioEnhancementProfile profile) async {}

  @override
  Future<void> dispose() async {
    await _signals.close();
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> play() async {
    playAttempts++;
    if (playAttempts == 1) {
      _signals.add(const PlaybackSignal(PlaybackSignalType.playing));
    }
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
