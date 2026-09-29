import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/models/community_challenge.dart';
import 'package:yorigo/models/meetup.dart';

void main() {
  group('normalizeInviteCode', () {
    test('uppercases and keeps charset characters only', () {
      expect(normalizeInviteCode('ab3k7p'), 'AB3K7P');
      expect(normalizeInviteCode('  ab-3k  '), 'AB3K');
      expect(normalizeInviteCode('ABIO01'), 'AB');
    });
  });

  group('generateInviteCode', () {
    test('emits 6 characters from the invite charset', () {
      final code = generateInviteCode();
      expect(code.length, 6);
      expect(
        code.split('').every(kChallengeInviteCharset.contains),
        isTrue,
      );
    });
  });

  group('Meetup derived flags', () {
    test('isFull when memberCount reaches capacity', () {
      final meetup = Meetup.fromMap('id', {
        'capacity': 4,
        'memberCount': 4,
        'startsAt': DateTime.now().add(const Duration(days: 1)),
      });
      expect(meetup.isFull, isTrue);
      expect(meetup.isPast, isFalse);
    });

    test('isPast when startsAt is before now', () {
      final meetup = Meetup.fromMap('id', {
        'capacity': 8,
        'memberCount': 1,
        'startsAt': DateTime.now().subtract(const Duration(hours: 1)),
      });
      expect(meetup.isPast, isTrue);
    });

    test('paid open class is not free-joinable', () {
      final meetup = Meetup.fromMap('id', {
        'kind': 'open_class',
        'priceKrw': 25000,
        'capacity': 10,
        'memberCount': 1,
        'startsAt': DateTime.now().add(const Duration(days: 1)),
      });
      expect(meetup.isPaid, isTrue);
      expect(meetup.isJoinable, isFalse);
    });
  });

  group('CommunityChallenge derived flags', () {
    test('progress clamps and isActive uses the window', () {
      final challenge = CommunityChallenge.fromMap('id', {
        'kind': 'official',
        'goalParticipantCount': 100,
        'participantCount': 150,
        'startsAt': DateTime.now().subtract(const Duration(days: 1)),
        'endsAt': DateTime.now().add(const Duration(days: 1)),
      });
      expect(challenge.progress, 1);
      expect(challenge.isOfficial, isTrue);
      expect(challenge.isActive, isTrue);
    });

    test('ended challenge is not active', () {
      final challenge = CommunityChallenge.fromMap('id', {
        'kind': 'friend',
        'startsAt': DateTime.now().subtract(const Duration(days: 3)),
        'endsAt': DateTime.now().subtract(const Duration(days: 1)),
      });
      expect(challenge.isFriend, isTrue);
      expect(challenge.isActive, isFalse);
    });
  });
}
