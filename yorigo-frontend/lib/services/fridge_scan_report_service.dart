import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'api_service.dart';

/// 영수증/냉장고 스캔 인식 오류 신고.
///
/// `fridge_scan_reports` 컬렉션에 쌓이며, 관리자만 조회한다.
class FridgeScanReportService {
  FridgeScanReportService._();
  static final FridgeScanReportService instance = FridgeScanReportService._();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  static const String collection = 'fridge_scan_reports';

  /// [reason]
  /// - wrong_name: 이름이 틀려요
  /// - missing_item: 빠진 재료가 있어요
  /// - blocked_item: 담을 수 없음으로 잘못 나왔어요
  /// - junk_item: 이상한 게 재료로 나왔어요
  /// - other: 기타
  Future<void> report({
    required String reason,
    String? note,
    String photoType = 'receipt',
    List<FridgeScanItemResult> items = const [],
    String? focusItemName,
    String? focusRawLine,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw StateError('login_required');
    }

    final trimmedNote = (note ?? '').trim();
    final snapshot = items
        .take(40)
        .map(
          (e) => {
            'name': e.name,
            'rawLine': e.rawLine ?? '',
            'isFood': e.isFood,
            'inCatalog': e.inCatalog,
            'confidence': e.confidence,
            if (e.price != null) 'price': e.price,
          },
        )
        .toList();

    var itemsJson = jsonEncode(snapshot);
    if (itemsJson.length > 8000) {
      itemsJson = itemsJson.substring(0, 8000);
    }

    String clip(String? value, int max) {
      final t = (value ?? '').trim();
      if (t.length <= max) return t;
      return t.substring(0, max);
    }

    final data = <String, dynamic>{
      'reason': reason.trim(),
      'note': clip(trimmedNote, 1000),
      'photoType': photoType,
      'focusItemName': clip(focusItemName, 120),
      'focusRawLine': clip(focusRawLine, 300),
      'itemsJson': itemsJson,
      'itemCount': items.length,
      'userId': user.uid,
      'userEmail': user.email ?? '',
      'appPlatform': defaultTargetPlatform.name,
      'status': 'open',
      'createdAt': FieldValue.serverTimestamp(),
    };

    await _firestore.collection(collection).add(data);
  }
}
