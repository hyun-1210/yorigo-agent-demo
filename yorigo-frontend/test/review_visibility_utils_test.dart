import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/review_visibility_utils.dart';

void main() {
  group('shouldIncludeHiddenUserReviews', () {
    test('내 프로필 플래그면 private 포함', () {
      expect(
        shouldIncludeHiddenUserReviews(
          includeHiddenFlag: true,
          currentUserId: 'uid_a',
          queriedUserIds: const ['uid_a'],
        ),
        isTrue,
      );
    });

    test('쿼리 ids에 로그인 uid가 있으면 포함 (getUserReviews와 동일)', () {
      expect(
        shouldIncludeHiddenUserReviews(
          includeHiddenFlag: false,
          currentUserId: 'uid_a',
          queriedUserIds: const ['uid_legacy', 'uid_a'],
        ),
        isTrue,
      );
    });

    test('타인 프로필은 isHidden 필터 유지', () {
      expect(
        shouldIncludeHiddenUserReviews(
          includeHiddenFlag: false,
          currentUserId: 'uid_me',
          queriedUserIds: const ['uid_other'],
        ),
        isFalse,
      );
    });

    test('비로그인 + 플래그 false면 미포함', () {
      expect(
        shouldIncludeHiddenUserReviews(
          includeHiddenFlag: false,
          currentUserId: null,
          queriedUserIds: const ['uid_a'],
        ),
        isFalse,
      );
    });
  });

  group('filterReviewsForDiaryViewer', () {
    final publicReview = <String, dynamic>{
      'id': 'r1',
      'isHidden': false,
      'visibility': 'public',
    };
    final privateByHidden = <String, dynamic>{
      'id': 'r2',
      'isHidden': true,
      'visibility': 'private',
    };
    final privateByVisibility = <String, dynamic>{
      'id': 'r3',
      'isHidden': false,
      'visibility': 'private',
    };

    test('본인 다이어리에는 나만 보기 포함', () {
      final filtered = filterReviewsForDiaryViewer(
        reviews: [publicReview, privateByHidden, privateByVisibility],
        isViewingOwnProfile: true,
      );
      expect(filtered.map((r) => r['id']), ['r1', 'r2', 'r3']);
    });

    test('타인 프로필에서는 나만 보기 제외', () {
      final filtered = filterReviewsForDiaryViewer(
        reviews: [publicReview, privateByHidden, privateByVisibility],
        isViewingOwnProfile: false,
      );
      expect(filtered.map((r) => r['id']), ['r1']);
    });
  });
}
