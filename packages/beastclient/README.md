# BeastClient

`beastclient` is a standalone, modular music client component designed for ultra-fast playback startup and resilient streaming.

## Core Goals

- Sub-50ms startup target for warm playback paths.
- Aggressive pre-buffering and predictive next-track loading.
- Intelligent in-memory cache with TTL and LRU eviction.
- Gapless queue playback and configurable crossfade controls via API.
- Real-time enhancement API surface for EQ/compressor integration.
- Robust error handling for network interruptions and decode/corruption issues.

## Supported Formats

The default `JustAudioEngine` supports the major formats requested by the client API:

- MP3
- FLAC
- AAC/M4A
- WAV
- OGG/OGA

## Architecture

- `BeastClient`: orchestration layer with serialized operations, retries, metrics, and predictive preloading.
- `AudioEngine`: abstract playback contract for pluggable backends.
- `JustAudioEngine`: `just_audio` implementation (gapless queue + warmup buffering).
- `IntelligentCache`: memory-efficient LRU + TTL cache metadata.
- `PredictiveLoader`: transition-aware next-track ranking.
- `AudioEnhancementProfile`: enhancement controls for DSP pipeline integration.

## Public API

```dart
final client = BeastClient(
  engine: JustAudioEngine(),
  config: const BeastClientConfig(
    startupTarget: Duration(milliseconds: 50),
    prebufferTrackCount: 3,
    crossfadeDuration: Duration(milliseconds: 250),
  ),
);

await client.initialize();
await client.setQueue(tracks);
final metrics = await client.playTrack(tracks.first);
print(metrics.startupLatency);
```

## Benchmarks

Run the startup benchmark test:

```bash
flutter pub get
flutter test test/startup_benchmark_test.dart -r expanded
```

The benchmark reports `P50`, `P95`, and `% <=50ms` startup metrics. Real-world latency depends on device, decoder stack, storage/network speed, and cache hit ratio.

## Testing

```bash
flutter test
```

Coverage includes:

- Network interruption retry behavior.
- Corrupted/decode error classification.
- Concurrent playback request serialization.
- Cache LRU/TTL edge cases.
- Predictive loader ranking.

## Integration Notes

- This package is self-contained and can be integrated into any Flutter app as a local path dependency or published package.
- For production DSP (EQ/compressor/limiter), inject platform audio processing in `JustAudioEngine.applyEnhancement`.
