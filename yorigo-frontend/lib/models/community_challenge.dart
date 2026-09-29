import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';

const String kChallengeInviteCharset = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

enum ChallengeKind { official, friend }

enum ChallengeProofMode { count, consecutiveDays }

class CommunityChallenge {
  const CommunityChallenge({
    required this.id,
    required this.kind,
    required this.createdBy,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.tag,
    this.inviteCode,
    required this.startsAt,
    required this.endsAt,
    required this.goalParticipantCount,
    required this.participantCount,
    required this.requiredProofCount,
    required this.proofMode,
    required this.cancelled,
    required this.isHidden,
  });

  final String id;
  final ChallengeKind kind;
  final String createdBy;
  final String title;
  final String subtitle;
  final String description;
  final String tag;
  final String? inviteCode;
  final DateTime startsAt;
  final DateTime endsAt;
  final int goalParticipantCount;
  final int participantCount;
  final int requiredProofCount;
  final ChallengeProofMode proofMode;
  final bool cancelled;
  final bool isHidden;

  bool get isOfficial => kind == ChallengeKind.official;
  bool get isFriend => kind == ChallengeKind.friend;
  bool get isActive {
    final now = DateTime.now();
    return !cancelled &&
        !isHidden &&
        !now.isBefore(startsAt) &&
        !now.isAfter(endsAt);
  }

  double get progress {
    if (goalParticipantCount <= 0) return 0;
    return (participantCount / goalParticipantCount).clamp(0, 1);
  }

  factory CommunityChallenge.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    return CommunityChallenge.fromMap(
      doc.id,
      doc.data() ?? const <String, dynamic>{},
    );
  }

  factory CommunityChallenge.fromMap(String id, Map<String, dynamic> data) {
    return CommunityChallenge(
      id: id,
      kind: (data['kind'] as String?) == 'friend'
          ? ChallengeKind.friend
          : ChallengeKind.official,
      createdBy: (data['createdBy'] as String?) ?? '',
      title: (data['title'] as String?) ?? '',
      subtitle: (data['subtitle'] as String?) ?? '',
      description: (data['description'] as String?) ?? '',
      tag: (data['tag'] as String?) ?? '',
      inviteCode: (data['inviteCode'] as String?)?.trim(),
      startsAt: _readDate(data['startsAt']) ?? DateTime.now(),
      endsAt: _readDate(data['endsAt']) ?? DateTime.now(),
      goalParticipantCount: (data['goalParticipantCount'] as num?)?.toInt() ?? 0,
      participantCount: (data['participantCount'] as num?)?.toInt() ?? 0,
      requiredProofCount: (data['requiredProofCount'] as num?)?.toInt() ?? 1,
      proofMode: (data['proofMode'] as String?) == 'consecutive_days'
          ? ChallengeProofMode.consecutiveDays
          : ChallengeProofMode.count,
      cancelled: data['cancelled'] == true,
      isHidden: data['isHidden'] == true,
    );
  }

  static DateTime? _readDate(dynamic raw) {
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    return null;
  }
}

class ChallengeParticipant {
  const ChallengeParticipant({
    required this.uid,
    required this.status,
    required this.proofCount,
    required this.proofDayKeys,
  });

  final String uid;
  final String status;
  final int proofCount;
  final List<String> proofDayKeys;

  bool get isCompleted => status == 'completed';

  factory ChallengeParticipant.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? const <String, dynamic>{};
    return ChallengeParticipant(
      uid: (data['uid'] as String?) ?? doc.id,
      status: (data['status'] as String?) ?? 'joined',
      proofCount: (data['proofCount'] as num?)?.toInt() ?? 0,
      proofDayKeys: ((data['proofDayKeys'] as List?) ?? const <dynamic>[])
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList(),
    );
  }
}

class ChallengeMembership {
  const ChallengeMembership({
    required this.challengeId,
    required this.kind,
    required this.status,
    this.endsAt,
  });

  final String challengeId;
  final ChallengeKind kind;
  final String status;
  final DateTime? endsAt;

  factory ChallengeMembership.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? const <String, dynamic>{};
    return ChallengeMembership(
      challengeId: doc.id,
      kind: (data['kind'] as String?) == 'friend'
          ? ChallengeKind.friend
          : ChallengeKind.official,
      status: (data['status'] as String?) ?? 'joined',
      endsAt: CommunityChallenge._readDate(data['endsAt']),
    );
  }
}

String normalizeInviteCode(String raw) {
  final upper = raw.trim().toUpperCase();
  final buf = StringBuffer();
  for (final rune in upper.runes) {
    final ch = String.fromCharCode(rune);
    if (kChallengeInviteCharset.contains(ch)) buf.write(ch);
  }
  return buf.toString();
}

String generateInviteCode([Random? random]) {
  final rng = random ?? Random.secure();
  return List<String>.generate(
    6,
    (_) => kChallengeInviteCharset[rng.nextInt(kChallengeInviteCharset.length)],
  ).join();
}
