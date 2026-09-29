import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/meetup.dart';
import 'analytics_service.dart';

class MeetupService {
  MeetupService._();
  static final MeetupService instance = MeetupService._();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  List<Meetup>? _upcomingCache;
  final ValueNotifier<int> listRevision = ValueNotifier<int>(0);

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('meetups');

  void invalidateCache() {
    _upcomingCache = null;
    listRevision.value++;
  }

  Future<String> _currentName() async {
    final user = _auth.currentUser;
    if (user == null) return '';
    final fromAuth = user.displayName?.trim() ?? '';
    if (fromAuth.isNotEmpty) return fromAuth;
    try {
      final snap = await _firestore.collection('users').doc(user.uid).get();
      final data = snap.data();
      final name = (data?['name'] as String?)?.trim() ?? '';
      if (name.isNotEmpty) return name;
      return (data?['handle'] as String?)?.trim() ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<List<Meetup>> fetchUpcoming({bool forceRefresh = false}) async {
    if (_auth.currentUser == null) return const <Meetup>[];
    if (!forceRefresh && _upcomingCache != null) return _upcomingCache!;
    final snap = await _col
        .where('isHidden', isEqualTo: false)
        .where('startsAt', isGreaterThanOrEqualTo: Timestamp.now())
        .orderBy('startsAt')
        .limit(40)
        .get();
    final list = snap.docs
        .map(Meetup.fromDoc)
        .where((m) => !m.cancelled)
        .toList();
    _upcomingCache = list;
    return list;
  }

  Future<Meetup?> getMeetup(String id) async {
    final snap = await _col.doc(id).get();
    if (!snap.exists) return null;
    return Meetup.fromDoc(snap);
  }

  Future<List<MeetupAttendee>> fetchAttendees(String meetupId) async {
    final snap = await _col.doc(meetupId).collection('attendees').get();
    return snap.docs.map(MeetupAttendee.fromDoc).toList();
  }

  Future<MeetupAttendee?> getMyAttendee(String meetupId) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return null;
    final snap = await _col
        .doc(meetupId)
        .collection('attendees')
        .doc(uid)
        .get();
    if (!snap.exists) return null;
    return MeetupAttendee.fromDoc(snap);
  }

  Future<String> createMeetup({
    required MeetupKind kind,
    required String title,
    required String subtitle,
    required String description,
    required String tag,
    required String placeText,
    required DateTime startsAt,
    required int capacity,
    String meetingFormat = 'offline',
    int priceKrw = 0,
    String iconKey = 'restaurant_menu',
    String? recurrenceNote,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw StateError('로그인이 필요합니다');
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty) throw ArgumentError('제목을 입력해주세요');
    if (startsAt.isBefore(DateTime.now())) {
      throw ArgumentError('시작 시간은 미래여야 해요');
    }
    if (capacity < 2 || capacity > 30) {
      throw ArgumentError('정원은 2~30명이에요');
    }
    final name = await _currentName();
    final ref = _col.doc();
    final batch = _firestore.batch();
    batch.set(ref, {
      'hostId': user.uid,
      'hostName': name,
      'kind': kind == MeetupKind.openClass ? 'open_class' : 'small_group',
      'title': trimmedTitle,
      'subtitle': subtitle.trim(),
      'description': description.trim(),
      'tag': tag.trim(),
      'placeText': placeText.trim(),
      'meetingFormat': meetingFormat,
      'startsAt': Timestamp.fromDate(startsAt),
      if (recurrenceNote != null && recurrenceNote.trim().isNotEmpty)
        'recurrenceNote': recurrenceNote.trim(),
      'capacity': capacity,
      'memberCount': 1,
      'priceKrw': kind == MeetupKind.openClass ? priceKrw : 0,
      'iconKey': iconKey,
      'cancelled': false,
      'isHidden': false,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    batch.set(ref.collection('attendees').doc(user.uid), {
      'uid': user.uid,
      'name': name,
      'role': 'host',
      'status': 'joined',
      'joinedAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
    invalidateCache();
    unawaited(
      AnalyticsService().trackContentCreated(
        contentType: 'meetup',
        contentId: ref.id,
        categoryId: kind == MeetupKind.openClass ? 'open_class' : 'small_group',
      ),
    );
    return ref.id;
  }

  Future<void> updateMeetup(
    String id, {
    required String title,
    required String subtitle,
    required String description,
    required String tag,
    required String placeText,
    required DateTime startsAt,
    required int capacity,
    String? meetingFormat,
    String? iconKey,
    String? recurrenceNote,
  }) async {
    await _col.doc(id).update({
      'title': title.trim(),
      'subtitle': subtitle.trim(),
      'description': description.trim(),
      'tag': tag.trim(),
      'placeText': placeText.trim(),
      'startsAt': Timestamp.fromDate(startsAt),
      'capacity': capacity,
      if (meetingFormat != null) 'meetingFormat': meetingFormat,
      if (iconKey != null) 'iconKey': iconKey,
      if (recurrenceNote != null) 'recurrenceNote': recurrenceNote.trim(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    invalidateCache();
  }

  Future<void> cancelMeetup(String id) async {
    await _col.doc(id).update({
      'cancelled': true,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    invalidateCache();
  }

  Future<void> applyOpenClass(String meetupId) async {
    final user = _auth.currentUser;
    if (user == null) throw StateError('로그인이 필요합니다');
    final name = await _currentName();
    await _col.doc(meetupId).collection('attendees').doc(user.uid).set({
      'uid': user.uid,
      'name': name,
      'role': 'member',
      'status': 'applied',
      'joinedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> withdrawApplication(String meetupId) async {
    final user = _auth.currentUser;
    if (user == null) throw StateError('로그인이 필요합니다');
    await _col.doc(meetupId).collection('attendees').doc(user.uid).delete();
  }

  Future<void> rejectApplication({
    required String meetupId,
    required String targetUid,
  }) async {
    await _col.doc(meetupId).collection('attendees').doc(targetUid).delete();
  }

  Future<void> joinMeetup(String meetupId) async {
    await _call('joinMeetup', {'meetupId': meetupId});
    invalidateCache();
    unawaited(
      AnalyticsService().trackCommunitySocialAction(
        action: 'join',
        contentType: 'meetup',
        contentId: meetupId,
      ),
    );
  }

  Future<void> leaveMeetup(String meetupId) async {
    await _call('leaveMeetup', {'meetupId': meetupId});
    invalidateCache();
  }

  Future<void> confirmOpenClass({
    required String meetupId,
    required String targetUid,
  }) async {
    await _call('confirmOpenClass', {
      'meetupId': meetupId,
      'targetUid': targetUid,
    });
    invalidateCache();
  }

  Future<void> _call(String name, Map<String, dynamic> data) async {
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(name);
      await callable.call(data);
    } on FirebaseFunctionsException catch (e) {
      throw StateError(e.message ?? '요청에 실패했어요');
    }
  }
}
