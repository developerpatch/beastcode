class BeastClientConfig {
  const BeastClientConfig({
    this.startupTarget = const Duration(milliseconds: 50),
    this.prebufferTrackCount = 3,
    this.prebufferConcurrency = 2,
    this.maxCacheEntries = 256,
    this.maxCacheBytes = 200 * 1024 * 1024,
    this.cacheTtl = const Duration(hours: 12),
    this.crossfadeDuration = Duration.zero,
    this.maxRetries = 2,
    this.retryBackoff = const Duration(milliseconds: 120),
    this.enablePredictiveLoading = true,
  });

  final Duration startupTarget;
  final int prebufferTrackCount;
  final int prebufferConcurrency;
  final int maxCacheEntries;
  final int maxCacheBytes;
  final Duration cacheTtl;
  final Duration crossfadeDuration;
  final int maxRetries;
  final Duration retryBackoff;
  final bool enablePredictiveLoading;
}
