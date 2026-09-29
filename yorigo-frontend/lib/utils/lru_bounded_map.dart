/// 삽입 순서 기반 LRU. [maxEntries] 초과 시 가장 오래된 항목부터 제거.
class LruBoundedMap<K, V> {
  LruBoundedMap({required this.maxEntries}) : assert(maxEntries > 0);

  final int maxEntries;
  final Map<K, V> _entries = {};

  int get length => _entries.length;
  Iterable<K> get keys => _entries.keys;

  V? get(K key) {
    final value = _entries.remove(key);
    if (value == null) return null;
    _entries[key] = value;
    return value;
  }

  void put(K key, V value) {
    _entries.remove(key);
    while (_entries.length >= maxEntries) {
      final oldest = _entries.keys.firstOrNull;
      if (oldest == null) break;
      _entries.remove(oldest);
    }
    _entries[key] = value;
  }

  void remove(K key) => _entries.remove(key);

  void clear() => _entries.clear();
}
