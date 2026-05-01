import 'package:beastclient/beastclient.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('IntelligentCache', () {
    test('evicts least recently used entries when capacity is exceeded', () {
      final clock = _FakeClock(DateTime(2026, 1, 1));
      final cache = IntelligentCache(
        maxEntries: 2,
        maxBytes: 100,
        ttl: const Duration(minutes: 5),
        now: clock.now,
      );

      cache.put('a', 40);
      cache.put('b', 40);
      expect(cache.contains('a'), isTrue); // refresh recency for a

      cache.put('c', 40);

      expect(cache.contains('a'), isTrue);
      expect(cache.contains('b'), isFalse);
      expect(cache.contains('c'), isTrue);
      expect(cache.count, 2);
    });

    test('expires entries after ttl', () {
      final clock = _FakeClock(DateTime(2026, 1, 1));
      final cache = IntelligentCache(
        maxEntries: 4,
        maxBytes: 1000,
        ttl: const Duration(seconds: 30),
        now: clock.now,
      );

      cache.put('x', 100);
      expect(cache.contains('x'), isTrue);
      clock.advance(const Duration(seconds: 31));
      expect(cache.contains('x'), isFalse);
    });
  });
}

class _FakeClock {
  _FakeClock(this._now);

  DateTime _now;

  DateTime now() => _now;

  void advance(Duration delta) {
    _now = _now.add(delta);
  }
}