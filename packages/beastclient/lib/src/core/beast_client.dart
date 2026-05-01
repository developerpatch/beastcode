import 'dart:async';

import '../cache/intelligent_cache.dart';
import '../enhancement/audio_enhancement_profile.dart';
import '../model/audio_format.dart';
import '../model/audio_track.dart';
import '../model/beast_client_config.dart';
import '../predictive/predictive_loader.dart';
import 'audio_engine.dart';
import 'beast_client_exception.dart';

class PlaybackMetrics {
  const PlaybackMetrics({
    required this.startupLatency,
    required this.metStartupTarget,
  });

  final Duration startupLatency;
  final bool metStartupTarget;
}

class BeastClient {
  BeastClient({
    required AudioEngine engine,
    BeastClientConfig config = const BeastClientConfig(),
    IntelligentCache? cache,
    PredictiveLoader? predictiveLoader,
  })  : _engine = engine,
        _config = config,
        _cache = cache ??
            IntelligentCache(
              maxEntries: config.maxCacheEntries,
              maxBytes: config.maxCacheBytes,
              ttl: config.cacheTtl,
            ),
        _predictiveLoader = predictiveLoader ?? PredictiveLoader();

  final AudioEngine _engine;
  final BeastClientConfig _config;
  final IntelligentCache _cache;
  final PredictiveLoader _predictiveLoader;

  final List<AudioTrack> _queue = <AudioTrack>[];
  Future<void> _operation = Future<void>.value();
  StreamSubscription<PlaybackSignal>? _signalSubscription;

  AudioTrack? _currentTrack;
  AudioTrack? _previousTrack;
  PlaybackMetrics? _lastPlaybackMetrics;
  Object? _lastEngineError;
  PlaybackSignalType? _lastSignalType;
  bool _initialized = false;

  bool get isInitialized => _initialized;
  PlaybackMetrics? get lastPlaybackMetrics => _lastPlaybackMetrics;

  Future<void> initialize() async {
    if (_initialized) return;
    await _engine.initialize();
    await _engine.setCrossfade(_config.crossfadeDuration);
    _signalSubscription = _engine.playbackSignals.listen(_onSignal);
    _initialized = true;
  }

  Future<void> setQueue(List<AudioTrack> tracks) {
    return _serialize(() async {
      _queue
        ..clear()
        ..addAll(tracks.map((track) => track.withInferredFormat()));
    });
  }

  Future<PlaybackMetrics> playTrack(
    AudioTrack track, {
    List<AudioTrack>? queueOverride,
    AudioEnhancementProfile enhancementProfile =
        const AudioEnhancementProfile(),
  }) {
    return _serialize(() async {
      _assertInitialized();

      if (queueOverride != null) {
        _queue
          ..clear()
          ..addAll(queueOverride.map((item) => item.withInferredFormat()));
      }

      if (_queue.isEmpty) _queue.add(track.withInferredFormat());
      final requestedTrack = track.withInferredFormat();
      _ensureFormatSupported(requestedTrack);

      final index = _queue.indexWhere((item) => item.id == requestedTrack.id);
      final trackIndex = index >= 0 ? index : 0;

      await _engine.applyEnhancement(enhancementProfile);
      unawaited(_aggressivePrebuffer(requestedTrack));

      final stopwatch = Stopwatch()..start();
      await _retry(() async {
        await _engine.setQueue(_queue, initialIndex: trackIndex);
        await _engine.play();
        await _awaitAudibleSignal();
      });
      stopwatch.stop();

      _currentTrack = requestedTrack;
      if (_previousTrack != null && _previousTrack!.id != requestedTrack.id) {
        _predictiveLoader.recordTransition(
          fromTrackId: _previousTrack!.id,
          toTrackId: requestedTrack.id,
        );
      }
      _previousTrack = requestedTrack;

      _lastPlaybackMetrics = PlaybackMetrics(
        startupLatency: stopwatch.elapsed,
        metStartupTarget: stopwatch.elapsed <= _config.startupTarget,
      );
      return _lastPlaybackMetrics!;
    });
  }

  Future<void> pause() => _serialize(_engine.pause);
  Future<void> stop() => _serialize(_engine.stop);

  Future<void> dispose() async {
    await _signalSubscription?.cancel();
    await _engine.dispose();
    _initialized = false;
  }

  void _onSignal(PlaybackSignal signal) {
    _lastSignalType = signal.type;
    switch (signal.type) {
      case PlaybackSignalType.networkError:
      case PlaybackSignalType.decodingError:
        _lastEngineError = signal.details;
        break;
      case PlaybackSignalType.buffering:
      case PlaybackSignalType.ready:
      case PlaybackSignalType.playing:
      case PlaybackSignalType.completed:
        break;
    }
  }

  Future<void> _aggressivePrebuffer(AudioTrack currentTrack) async {
    final queueRemainder = _queue.where((track) => track.id != currentTrack.id).toList();
    final candidates = _config.enablePredictiveLoading
        ? _predictiveLoader.predictNext(
            currentTrack: currentTrack,
            availableTracks: queueRemainder,
            limit: _config.prebufferTrackCount,
          )
        : queueRemainder.take(_config.prebufferTrackCount).toList(growable: false);

    if (candidates.isEmpty) return;
    final concurrency = _config.prebufferConcurrency.clamp(1, candidates.length);
    var cursor = 0;

    Future<void> worker() async {
      while (true) {
        if (cursor >= candidates.length) return;
        final candidate = candidates[cursor++];
        if (_cache.contains(candidate.id)) continue;
        try {
          await _engine.prepare(candidate);
          _cache.put(candidate.id, _estimateBytes(candidate));
        } catch (_) {
          // Prebuffer failures must not block primary playback startup.
        }
      }
    }

    await Future.wait(
      List<Future<void>>.generate(concurrency, (_) => worker()),
    );
  }

  int _estimateBytes(AudioTrack track) {
    final duration = track.durationHint;
    if (duration == null) return 2 * 1024 * 1024;
    const bitsPerSecond = 192000;
    final bytes = (duration.inMilliseconds / 1000 * bitsPerSecond / 8).round();
    return bytes.clamp(64 * 1024, 50 * 1024 * 1024);
  }

  Future<void> _retry(Future<void> Function() action) async {
    BeastClientException? lastFailure;
    for (var attempt = 0; attempt <= _config.maxRetries; attempt++) {
      try {
        _lastEngineError = null;
        _lastSignalType = null;
        await action();
        return;
      } catch (error) {
        lastFailure = _classifyError(error);
        if (attempt == _config.maxRetries) break;
        await Future<void>.delayed(_config.retryBackoff * (attempt + 1));
      }
    }
    throw lastFailure ??
        const BeastClientException(
          BeastClientErrorCode.unknown,
          'Playback failed with unknown error',
        );
  }

  BeastClientException _classifyError(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('socket') ||
        text.contains('network') ||
        text.contains('timeout') ||
        text.contains('http')) {
      return BeastClientException(
        BeastClientErrorCode.networkInterruption,
        'Network interruption detected while starting playback.',
        cause: error,
      );
    }
    if (text.contains('decoder') ||
        text.contains('format') ||
        text.contains('corrupt')) {
      return BeastClientException(
        BeastClientErrorCode.corruptedAudio,
        'Audio file is corrupted or cannot be decoded.',
        cause: error,
      );
    }
    if (_lastEngineError != null) {
      return BeastClientException(
        BeastClientErrorCode.playbackFailure,
        'Playback engine reported an unrecoverable error.',
        cause: _lastEngineError,
      );
    }
    return BeastClientException(
      BeastClientErrorCode.unknown,
      'Unknown playback failure.',
      cause: error,
    );
  }

  Future<void> _awaitAudibleSignal() async {
    if (_lastSignalType == PlaybackSignalType.playing) {
      return;
    }
    if (_lastSignalType == PlaybackSignalType.networkError ||
        _lastSignalType == PlaybackSignalType.decodingError) {
      throw _lastEngineError ?? 'Playback failed before audible output.';
    }

    final signal = await _engine.playbackSignals
        .firstWhere(
          (event) =>
              event.type == PlaybackSignalType.playing ||
              event.type == PlaybackSignalType.networkError ||
              event.type == PlaybackSignalType.decodingError,
        )
        .timeout(_config.startupTarget * 4);

    if (signal.type == PlaybackSignalType.networkError ||
        signal.type == PlaybackSignalType.decodingError) {
      throw signal.details ?? 'Playback failed before audible output.';
    }
  }

  void _assertInitialized() {
    if (!_initialized) {
      throw const BeastClientException(
        BeastClientErrorCode.playbackFailure,
        'BeastClient must be initialized before playback.',
      );
    }
  }

  void _ensureFormatSupported(AudioTrack track) {
    if (track.format == AudioFormat.unknown) return;
    const supported = <AudioFormat>{
      AudioFormat.mp3,
      AudioFormat.flac,
      AudioFormat.aac,
      AudioFormat.wav,
      AudioFormat.ogg,
    };
    if (!supported.contains(track.format)) {
      throw const BeastClientException(
        BeastClientErrorCode.unsupportedFormat,
        'Unsupported audio format.',
      );
    }
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _operation = _operation.then((_) async {
      try {
        final result = await operation();
        completer.complete(result);
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
