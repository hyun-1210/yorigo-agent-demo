import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/lru_bounded_map.dart';

void main() {
  group('LruBoundedMap', () {
    test('evicts oldest when over maxEntries', () {
      final map = LruBoundedMap<String, int>(maxEntries: 3);
      map.put('a', 1);
      map.put('b', 2);
      map.put('c', 3);
      map.put('d', 4);
      expect(map.length, 3);
      expect(map.get('a'), isNull);
      expect(map.get('b'), 2);
      expect(map.get('c'), 3);
      expect(map.get('d'), 4);
    });

    test('get bumps entry to most recently used', () {
      final map = LruBoundedMap<String, int>(maxEntries: 3);
      map.put('a', 1);
      map.put('b', 2);
      map.put('c', 3);
      expect(map.get('a'), 1);
      map.put('d', 4);
      expect(map.get('b'), isNull);
      expect(map.get('a'), 1);
      expect(map.get('c'), 3);
      expect(map.get('d'), 4);
    });

    test('put updates existing key without evicting others', () {
      final map = LruBoundedMap<String, int>(maxEntries: 2);
      map.put('a', 1);
      map.put('b', 2);
      map.put('a', 10);
      expect(map.length, 2);
      expect(map.get('a'), 10);
      expect(map.get('b'), 2);
    });
  });
}
