import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/community_challenge.dart';
import 'analytics_service.dart';

class ChallengeService {
  ChallengeService._();
  static final ChallengeService instance = ChallengeService._();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  List<CommunityChallenge>? _officialCache;
  List<CommunityChallenge>? _mineCache;
  final ValueNotifier<int> listRevision = ValueNotifier<int>(0);

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('challenges');

  void invalidateCache() {
    _officialCache = null;
    _mineCache = null;
    listRevision.value++;
  }

  Future<List<CommunityChallenge>> fetchOfficialActive({
    bool forceRefresh = false,
  }) async {
    if (_auth.currentUser == null) return const <CommunityChallenge>[];
    if (!forceRefresh && _officialCache != null) return _officialCache!;
    final snap = await _col
        .where('isHidden', isEqualTo: false)
        .where('kind', isEqualTo: 'official')
        .where('endsAt', isGreaterThanOrEqualTo: Timestamp.now())
        .orderBy('endsAt')
        .limit(10)
        .get();
    final now = DateTime.now();
    final list = snap.docs
        .map(CommunityChallenge.fromDoc)
        .where((c) => !c.cancelled && !c.startsAt.isAfter(now))
        .toList();
    _officialCache = list;
    return list;
  }

  Future<List<CommunityChallenge>> fetchMyChallenges({
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _mineCache != null) return _mineCache!;
    final uid = _auth.currentUser?.uid;
    if (uid == null) return const <CommunityChallenge>[];
    final memberSnap = await _firestore
        .collection('users')
        .doc(uid)
        .collection('challengeMemberships')
        .get();
    final ids = memberSnap.docs.map((d) => d.id).toList();
    if (ids.isEmpty) {
      _mineCache = const <CommunityChallenge>[];
      return _mineCache!;
    }
    final refs = ids.map(_col.doc).toList();
    final snaps = await Future.wait(refs.map((ref) => ref.get()));
    final list = snaps
        .where((s) => s.exists)
        .map((s) => CommunityChallenge.fromDoc(s))
        .where((c) => !c.cancelled && !c.isHidden)
        .toList();
    _mineCache = list;
    return list;
  }

  Future<CommunityChallenge?> getChallenge(String id) async {
    final snap = await _col.doc(id).get();
    if (!snap.exists) return null;
    return CommunityChallenge.fromDoc(snap);
  }

  Future<ChallengeParticipant?> getMyParticipant(String challengeId) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return null;
    final snap = await _col
        .doc(challengeId)
        .collection('participants')
        .doc(uid)
        .get();
    if (!snap.exists) return null;
    return ChallengeParticipant.fromDoc(snap);
  }

  Future<List<ChallengeParticipant>> fetchFriendParticipants(
    String challengeId,
  ) async {
    final snap = await _col.doc(challengeId).collection('participants').get();
    return snap.docs.map(ChallengeParticipant.fromDoc).toList();
  }

  Future<String> createFriendChallenge({
    required String title,
    required String subtitle,
    required String description,
    required String tag,
    required DateTime startsAt,
    required DateTime endsAt,
    required int requiredProofCount,
    required ChallengeProofMode proofMode,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw StateError('로그인이 필요합니다');
    final trimmed = title.trim();
    if (trimmed.isEmpty) throw ArgumentError('제목을 입력해주세요');
    if (!endsAt.isAfter(startsAt)) {
      throw ArgumentError('종료 시간은 시작 이후여야 해요');
    }

    Object? lastError;
    for (var attempt = 0; attempt < 6; attempt++) {
      final code = generateInviteCode();
      final ref = _col.doc();
      final batch = _firestore.batch();
      batch.set(ref, {
        'kind': 'friend',
        'createdBy': user.uid,
        'title': trimmed,
        'subtitle': subtitle.trim(),
        'description': description.trim(),
        'tag': tag.trim(),
        'inviteCode': code,
        'startsAt': Timestamp.fromDate(startsAt),
        'endsAt': Timestamp.fromDate(endsAt),
        'goalParticipantCount': 0,
        'participantCount': 1,
        'requiredProofCount': requiredProofCount,
        'proofMode': proofMode == ChallengeProofMode.consecutiveDays
            ? 'consecutive_days'
            : 'count',
        'cancelled': false,
        'isHidden': false,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      batch.set(_firestore.collection('challenge_invite_codes').doc(code), {
        'challengeId': ref.id,
        'createdBy': user.uid,
      });
      batch.set(ref.collection('participants').doc(user.uid), {
        'uid': user.uid,
        'status': 'joined',
        'proofCount': 0,
        'proofDayKeys': <String>[],
        'joinedAt': FieldValue.serverTimestamp(),
      });
      batch.set(
        _firestore
            .collection('users')
            .doc(user.uid)
            .collection('challengeMemberships')
            .doc(ref.id),
        {
          'kind': 'friend',
          'status': 'joined',
          'endsAt': Timestamp.fromDate(endsAt),
        },
      );
      try {
        await batch.commit();
        invalidateCache();
        unawaited(
          AnalyticsService().trackContentCreated(
            contentType: 'challenge',
            contentId: ref.id,
            categoryId: 'friend',
          ),
        );
        return ref.id;
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError('초대코드 생성에 실패했어요: $lastError');
  }

  Future<String> createOfficialChallenge({
    required String title,
    required String subtitle,
    required String description,
    required String tag,
    required DateTime startsAt,
    required DateTime endsAt,
    required int requiredProofCount,
    required ChallengeProofMode proofMode,
    required int goalParticipantCount,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw StateError('로그인이 필요합니다');
    final ref = _col.doc();
    await ref.set({
      'kind': 'official',
      'createdBy': user.uid,
      'title': title.trim(),
      'subtitle': subtitle.trim(),
      'description': description.trim(),
      'tag': tag.trim(),
      'startsAt': Timestamp.fromDate(startsAt),
      'endsAt': Timestamp.fromDate(endsAt),
      'goalParticipantCount': goalParticipantCount,
      'participantCount': 0,
      'requiredProofCount': requiredProofCount,
      'proofMode': proofMode == ChallengeProofMode.consecutiveDays
          ? 'consecutive_days'
          : 'count',
      'cancelled': false,
      'isHidden': false,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    invalidateCache();
    unawaited(
      AnalyticsService().trackContentCreated(
        contentType: 'challenge',
        contentId: ref.id,
        categoryId: 'official',
      ),
    );
    return ref.id;
  }

  Future<void> cancelChallenge(String id) async {
    await _col.doc(id).update({
      'cancelled': true,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    invalidateCache();
  }

  Future<void> hideChallenge(String id, {required bool hidden}) async {
    await _col.doc(id).update({
      'isHidden': hidden,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    invalidateCache();
  }

  Future<String> joinChallenge({String? challengeId, String? inviteCode}) async {
    final result = await _call('joinChallenge', {
      if (challengeId != null) 'challengeId': challengeId,
      if (inviteCode != null) 'inviteCode': normalizeInviteCode(inviteCode),
    });
    invalidateCache();
    final id = result['challengeId']?.toString() ?? challengeId ?? '';
    unawaited(
      AnalyticsService().trackCommunitySocialAction(
        action: 'join',
        contentType: 'challenge',
        contentId: id,
      ),
    );
    return id;
  }

  Future<void> leaveChallenge(String challengeId) async {
    await _call('leaveChallenge', {'challengeId': challengeId});
    invalidateCache();
  }

  Future<bool> submitProof({
    required String challengeId,
    required String reviewId,
  }) async {
    final result = await _call('submitChallengeProof', {
      'challengeId': challengeId,
      'reviewId': reviewId,
    });
    invalidateCache();
    unawaited(
      AnalyticsService().trackCommunitySocialAction(
        action: 'proof',
        contentType: 'challenge',
        contentId: challengeId,
      ),
    );
    return result['completed'] == true;
  }

  Future<Map<String, dynamic>> _call(
    String name,
    Map<String, dynamic> data,
  ) async {
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(name);
      final raw = await callable.call(data);
      final payload = raw.data;
      if (payload is Map) {
        return payload.map((key, value) => MapEntry(key.toString(), value));
      }
      return const <String, dynamic>{};
    } on FirebaseFunctionsException catch (e) {
      throw StateError(e.message ?? '요청에 실패했어요');
    }
  }
}
