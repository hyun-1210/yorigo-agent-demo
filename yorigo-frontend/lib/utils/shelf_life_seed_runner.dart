import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../data/ingredient_shelf_life_seed.dart';

/// One-time seed of `ingredient_shelf_life` Firestore collection from
/// the hard-coded [ingredientShelfLifeSeedData] map.
///
/// Only writes documents that do not already exist (never overwrites
/// manual edits or LLM-researched data). Safe to call multiple times.
class ShelfLifeSeedRunner {
  ShelfLifeSeedRunner._();

  static const String _collection = 'ingredient_shelf_life';
  // Firestore는 앞뒤로 이중 밑줄(`__..__`)이 붙은 문서 ID를 예약어로 취급해
  // invalid-argument 예외를 던진다. 예약 패턴을 피한 ID를 사용한다.
  static const String _metaDoc = 'seed_meta';

  /// Returns `true` if seeding was performed, `false` if it was already done.
  static Future<bool> seedIfNeeded() async {
    final db = FirebaseFirestore.instance;

    final metaSnap = await db.collection(_collection).doc(_metaDoc).get();
    if (metaSnap.exists) {
      if (kDebugMode) {
        debugPrint('[ShelfLifeSeed] Already seeded, skipping');
      }
      return false;
    }

    int written = 0;
    final entries = ingredientShelfLifeSeedData.entries.toList();

    // Firestore batch limit is 500; split into chunks.
    for (var start = 0; start < entries.length; start += 450) {
      final chunk = entries.skip(start).take(450);
      final batch = db.batch();
      for (final e in chunk) {
        final docRef = db.collection(_collection).doc(e.key);
        batch.set(docRef, {
          'ingredientName': e.key,
          ...e.value,
          'source': 'seed',
        }, SetOptions(merge: false));
        written++;
      }
      await batch.commit();
    }

    await db.collection(_collection).doc(_metaDoc).set({
      'seededAt': FieldValue.serverTimestamp(),
      'count': written,
    });

    if (kDebugMode) {
      debugPrint('[ShelfLifeSeed] Seeded $written ingredient shelf-life entries');
    }
    return true;
  }
}
