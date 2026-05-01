import 'dart:collection';

class CacheEntry {
  CacheEntry({
    required this.trackId,
    required this.sizeBytes,
    required this.createdAt,
    required this.expiresAt,
  });

  final String trackId;
  final int sizeBytes;
  final DateTime createdAt;
  final DateTime expiresAt;
}

class IntelligentCache {
  IntelligentCache({
    required this.maxEntries,
    required this.maxBytes,
    required this.ttl,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int maxEntries;
  final int maxBytes;
  final Duration ttl;
  final DateTime Function() _now;
  final LinkedHashMap<String, CacheEntry> _entries =
      LinkedHashMap<String, CacheEntry>();
  int _usedBytes = 0;

  int get usedBytes => _usedBytes;
  int get count => _entries.length;

  bool contains(String trackId) {
    _pruneExpired();
    final entry = _entries.remove(trackId);
    if (entry == null) return false;
    _entries[trackId] = entry;
    return true;
  }

  void put(String trackId, int sizeBytes) {
    _pruneExpired();
    final existing = _entries.remove(trackId);
    if (existing != null) {
      _usedBytes -= existing.sizeBytes;
    }
    final now = _now();
    _entries[trackId] = CacheEntry(
      trackId: trackId,
      sizeBytes: sizeBytes,
      createdAt: now,
      expiresAt: now.add(ttl),
    );
    _usedBytes += sizeBytes;
    _evictIfNeeded();
  }

  void _pruneExpired() {
    if (_entries.isEmpty) return;
    final now = _now();
    final expired = _entries.entries
        .where((entry) => entry.value.expiresAt.isBefore(now))
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final key in expired) {
      final removed = _entries.remove(key);
      if (removed != null) _usedBytes -= removed.sizeBytes;
    }
  }

  void _evictIfNeeded() {
    while (_entries.length > maxEntries || _usedBytes > maxBytes) {
      final key = _entries.keys.first;
      final removed = _entries.remove(key);
      if (removed != null) _usedBytes -= removed.sizeBytes;
    }
  }
}
