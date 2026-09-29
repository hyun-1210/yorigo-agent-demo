import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

enum MeetupKind { smallGroup, openClass }

enum MeetupMeetingFormat { offline, live }

enum MeetupAttendeeStatus { joined, applied }

class Meetup {
  const Meetup({
    required this.id,
    required this.hostId,
    required this.hostName,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.tag,
    required this.placeText,
    required this.meetingFormat,
    required this.startsAt,
    this.recurrenceNote,
    required this.capacity,
    required this.memberCount,
    required this.priceKrw,
    required this.iconKey,
    required this.cancelled,
    required this.isHidden,
    this.createdAt,
  });

  final String id;
  final String hostId;
  final String hostName;
  final MeetupKind kind;
  final String title;
  final String subtitle;
  final String description;
  final String tag;
  final String placeText;
  final MeetupMeetingFormat meetingFormat;
  final DateTime startsAt;
  final String? recurrenceNote;
  final int capacity;
  final int memberCount;
  final int priceKrw;
  final String iconKey;
  final bool cancelled;
  final bool isHidden;
  final DateTime? createdAt;

  bool get isPaid => kind == MeetupKind.openClass && priceKrw > 0;
  bool get isFull => memberCount >= capacity;
  bool get isPast => startsAt.isBefore(DateTime.now());
  bool get isJoinable => !cancelled && !isHidden && !isPast && !isFull && !isPaid;

  factory Meetup.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    return Meetup.fromMap(doc.id, doc.data() ?? const <String, dynamic>{});
  }

  factory Meetup.fromMap(String id, Map<String, dynamic> data) {
    return Meetup(
      id: id,
      hostId: (data['hostId'] as String?) ?? '',
      hostName: (data['hostName'] as String?) ?? '',
      kind: (data['kind'] as String?) == 'open_class'
          ? MeetupKind.openClass
          : MeetupKind.smallGroup,
      title: (data['title'] as String?) ?? '',
      subtitle: (data['subtitle'] as String?) ?? '',
      description: (data['description'] as String?) ?? '',
      tag: (data['tag'] as String?) ?? '',
      placeText: (data['placeText'] as String?) ?? '',
      meetingFormat: (data['meetingFormat'] as String?) == 'live'
          ? MeetupMeetingFormat.live
          : MeetupMeetingFormat.offline,
      startsAt: _readDate(data['startsAt']) ?? DateTime.now(),
      recurrenceNote: (data['recurrenceNote'] as String?)?.trim(),
      capacity: (data['capacity'] as num?)?.toInt() ?? 0,
      memberCount: (data['memberCount'] as num?)?.toInt() ?? 0,
      priceKrw: (data['priceKrw'] as num?)?.toInt() ?? 0,
      iconKey: (data['iconKey'] as String?) ?? 'restaurant_menu',
      cancelled: data['cancelled'] == true,
      isHidden: data['isHidden'] == true,
      createdAt: _readDate(data['createdAt']),
    );
  }

  static DateTime? _readDate(dynamic raw) {
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    return null;
  }
}

class MeetupAttendee {
  const MeetupAttendee({
    required this.uid,
    required this.name,
    required this.role,
    required this.status,
  });

  final String uid;
  final String name;
  final String role;
  final MeetupAttendeeStatus status;

  bool get isHost => role == 'host';
  bool get isJoined => status == MeetupAttendeeStatus.joined;
  bool get isApplied => status == MeetupAttendeeStatus.applied;

  factory MeetupAttendee.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    return MeetupAttendee(
      uid: (data['uid'] as String?) ?? doc.id,
      name: (data['name'] as String?) ?? '',
      role: (data['role'] as String?) ?? 'member',
      status: (data['status'] as String?) == 'applied'
          ? MeetupAttendeeStatus.applied
          : MeetupAttendeeStatus.joined,
    );
  }
}

IconData meetupIconFromKey(String key) {
  switch (key) {
    case 'eco':
      return Icons.eco_rounded;
    case 'videocam':
      return Icons.videocam_rounded;
    case 'cake':
      return Icons.cake_rounded;
    default:
      return Icons.restaurant_menu_rounded;
  }
}
