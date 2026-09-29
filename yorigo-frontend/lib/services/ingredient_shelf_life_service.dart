import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../data/ingredient_shelf_life_seed.dart';

enum StorageType {
  frozen,
  refrigerated,
  roomTemp;

  String get label {
    switch (this) {
      case StorageType.frozen:
        return '냉동';
      case StorageType.refrigerated:
        return '냉장';
      case StorageType.roomTemp:
        return '실온';
    }
  }

  String get firestoreValue {
    switch (this) {
      case StorageType.frozen:
        return 'frozen';
      case StorageType.refrigerated:
        return 'refrigerated';
      case StorageType.roomTemp:
        return 'room_temp';
    }
  }

  static StorageType fromString(String? value) {
    switch (value) {
      case 'frozen':
        return StorageType.frozen;
      case 'room_temp':
        return StorageType.roomTemp;
      default:
        return StorageType.refrigerated;
    }
  }
}

@immutable
class IngredientShelfLife {
  const IngredientShelfLife({
    required this.ingredientName,
    required this.storageType,
    required this.shelfLifeDays,
    this.notes,
  });

  final String ingredientName;
  final StorageType storageType;
  final int shelfLifeDays;
  final String? notes;

  factory IngredientShelfLife.fromFirestore(
    String docId,
    Map<String, dynamic> data,
  ) {
    return IngredientShelfLife(
      ingredientName: data['ingredientName']?.toString() ?? docId,
      storageType: StorageType.fromString(data['storageType']?.toString()),
      shelfLifeDays: (data['shelfLifeDays'] as num?)?.toInt() ?? 7,
      notes: data['notes']?.toString(),
    );
  }

  factory IngredientShelfLife.fromSeedEntry(
    String name,
    Map<String, dynamic> data,
  ) {
    return IngredientShelfLife(
      ingredientName: name,
      storageType: StorageType.fromString(data['storageType']?.toString()),
      shelfLifeDays: (data['shelfLifeDays'] as num?)?.toInt() ?? 7,
      notes: data['notes']?.toString(),
    );
  }

  Map<String, dynamic> toFirestore() => {
        'ingredientName': ingredientName,
        'storageType': storageType.firestoreValue,
        'shelfLifeDays': shelfLifeDays,
        if (notes != null) 'notes': notes,
      };
}

class IngredientShelfLifeService {
  IngredientShelfLifeService._() {
    _loadSeedData();
  }

  static final IngredientShelfLifeService instance =
      IngredientShelfLifeService._();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static const String _collection = 'ingredient_shelf_life';

  final Map<String, IngredientShelfLife> _cache = {};
  bool _firestoreLoaded = false;

  /// Pre-populate cache from the hardcoded seed map so lookups work
  /// instantly, even before Firestore is reachable.
  void _loadSeedData() {
    for (final entry in ingredientShelfLifeSeedData.entries) {
      _cache[entry.key] =
          IngredientShelfLife.fromSeedEntry(entry.key, entry.value);
    }
    if (kDebugMode) {
      debugPrint(
        '[ShelfLife] Loaded ${_cache.length} entries from hardcoded seed',
      );
    }
  }

  /// Overlay Firestore data on top of the seed cache (called once on app start).
  /// Firestore entries win over seed entries for the same key.
  Future<void> ensureLoaded() async {
    if (_firestoreLoaded) return;
    try {
      final snap = await _firestore.collection(_collection).get();
      int overrideCount = 0;
      for (final doc in snap.docs) {
        if (doc.id.startsWith('__')) continue;
        final data = doc.data();
        _cache[doc.id] = IngredientShelfLife.fromFirestore(doc.id, data);
        overrideCount++;
      }
      _firestoreLoaded = true;
      if (kDebugMode) {
        debugPrint(
          '[ShelfLife] Firestore overlay: $overrideCount docs, '
          'total cache: ${_cache.length} entries',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[ShelfLife] Firestore load failed (seed data still active): $e');
      }
    }
  }

  /// Look up shelf life for an ingredient name.
  /// Tries exact match first, then substring matching for compound names.
  IngredientShelfLife? lookup(String ingredientName) {
    final normalized = ingredientName.trim();
    if (normalized.isEmpty) return null;

    if (_cache.containsKey(normalized)) return _cache[normalized];

    // Try substring matching: "돼지고기 삼겹살" matches "삼겹살",
    // "다진 마늘" matches "마늘", etc.
    IngredientShelfLife? bestMatch;
    int bestLen = 0;
    for (final entry in _cache.entries) {
      if (normalized.contains(entry.key) || entry.key.contains(normalized)) {
        if (entry.key.length > bestLen) {
          bestLen = entry.key.length;
          bestMatch = entry.value;
        }
      }
    }
    return bestMatch;
  }

  /// Compute the expiry date ISO string, or null if no shelf-life data exists.
  ///
  /// [alreadyOwned] true면 배송 대기 없이 [orderTime] 당일부터 유통기한을 센다
  /// (수동 추가·영수증 스캔). false면 쿠팡 등 배송 도착 예정일부터 센다.
  String? computeExpiryDate(
    String ingredientName,
    DateTime orderTime, {
    bool alreadyOwned = false,
  }) {
    final info = lookup(ingredientName);
    if (info == null) return null;
    final start =
        alreadyOwned ? orderTime : estimateDeliveryArrival(orderTime);
    final expiry = start.add(Duration(days: info.shelfLifeDays));
    return '${expiry.year}-${expiry.month.toString().padLeft(2, '0')}-${expiry.day.toString().padLeft(2, '0')}';
  }

  /// Estimate when a grocery delivery will arrive based on order time.
  /// Conservative model based on Coupang/Kurly/SSG overnight delivery:
  ///   - Order before 23:00 -> next day 07:00
  ///   - Order at/after 23:00 -> day-after-tomorrow 07:00
  static DateTime estimateDeliveryArrival(DateTime orderTime) {
    final orderDate = DateTime(orderTime.year, orderTime.month, orderTime.day);
    if (orderTime.hour < 23) {
      return orderDate.add(const Duration(days: 1, hours: 7));
    } else {
      return orderDate.add(const Duration(days: 2, hours: 7));
    }
  }

  /// Get storage type for an ingredient, or null if unknown.
  StorageType? getStorageType(String ingredientName) {
    return lookup(ingredientName)?.storageType;
  }

  /// Return all ingredient names that don't have shelf-life data yet.
  List<String> findMissingIngredients(List<String> ingredientNames) {
    final missing = <String>[];
    for (final name in ingredientNames) {
      if (lookup(name) == null) missing.add(name);
    }
    return missing;
  }

  /// Insert or update shelf-life data (from LLM research or manual).
  Future<void> upsert(IngredientShelfLife data) async {
    await _firestore
        .collection(_collection)
        .doc(data.ingredientName)
        .set(data.toFirestore(), SetOptions(merge: true));
    _cache[data.ingredientName] = data;
  }

  /// Batch insert/update (for LLM bulk research results).
  Future<void> upsertBatch(List<IngredientShelfLife> items) async {
    final batch = _firestore.batch();
    for (final item in items) {
      batch.set(
        _firestore.collection(_collection).doc(item.ingredientName),
        item.toFirestore(),
        SetOptions(merge: true),
      );
      _cache[item.ingredientName] = item;
    }
    await batch.commit();
    if (kDebugMode) {
      debugPrint('[ShelfLife] Batch upserted ${items.length} entries');
    }
  }

  @visibleForTesting
  void clearCache() {
    _cache.clear();
    _firestoreLoaded = false;
  }
}
