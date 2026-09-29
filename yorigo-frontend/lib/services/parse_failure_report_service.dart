import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// 사용자가 "분석이 안 돼요"를 **한 번의 탭**으로 관리자에게 바로 알릴 수 있게 하는 서비스.
///
/// 기록은 `parsing_failures` 컬렉션에 쌓이며, 관리자 계정만 조회할 수 있다.
/// (Firestore 규칙: create=anyone(검증), read/list=admin only.)
/// 분석 실패의 상당수가 일시적인 서버 문제이므로, 이 신호를 모아두면
/// 어떤 링크/플랫폼/에러 유형이 자주 실패하는지 빠르게 파악할 수 있다.
class ParseFailureReportService {
  ParseFailureReportService._();
  static final ParseFailureReportService instance =
      ParseFailureReportService._();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// 분석 실패/지연을 관리자에게 보고한다.
  ///
  /// [reason] 은 'failed'(분석 실패) | 'stuck'(오래 걸림) | 'wrong_result'(결과 이상).
  Future<void> report({
    required String reason,
    String? recipeId,
    String? sourceUrl,
    String kind = 'link', // 'link' | 'text' | 'image'
    String? errorType,
    String? errorMessage,
    String? platform,
    String? note,
  }) async {
    final user = _auth.currentUser;
    final data = <String, dynamic>{
      'reason': reason,
      'recipeId': (recipeId ?? '').trim(),
      'sourceUrl': (sourceUrl ?? '').trim(),
      'kind': kind,
      'errorType': (errorType ?? '').trim(),
      'errorMessage': (errorMessage ?? '').trim(),
      'platform': (platform ?? '').trim(),
      'note': (note ?? '').trim(),
      'userId': user?.uid ?? '',
      'userEmail': user?.email ?? '',
      'appPlatform': defaultTargetPlatform.name,
      'status': 'open',
      'createdAt': FieldValue.serverTimestamp(),
    };
    // 메시지 길이 가드 (규칙 검증과 일치).
    if ((data['errorMessage'] as String).length > 1000) {
      data['errorMessage'] =
          (data['errorMessage'] as String).substring(0, 1000);
    }
    if ((data['note'] as String).length > 1000) {
      data['note'] = (data['note'] as String).substring(0, 1000);
    }
    await _firestore.collection('parsing_failures').add(data);
  }
}
