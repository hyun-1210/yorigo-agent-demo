import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/recipe_source_lookup.dart';

void main() {
  group('shouldConstrainSourceQueryToVisible', () {
    test('비네이버 공개 조회는 isHidden==false 제약을 넣는다', () {
      expect(
        shouldConstrainSourceQueryToVisible(includeHidden: false, userId: null),
        isTrue,
      );
      expect(
        shouldConstrainSourceQueryToVisible(includeHidden: false, userId: ''),
        isTrue,
      );
    });

    test('네이버 메타 조회는 숨김 문서를 포함하므로 제약을 넣지 않는다', () {
      expect(
        shouldConstrainSourceQueryToVisible(includeHidden: true, userId: null),
        isFalse,
      );
    });

    test('본인 userId 조회는 규칙상 숨김도 읽을 수 있어 쿼리 제약이 필요 없다', () {
      expect(
        shouldConstrainSourceQueryToVisible(
          includeHidden: false,
          userId: 'uid_me',
        ),
        isFalse,
      );
    });
  });

  group('isReusableSourceDocForDedup', () {
    test('공개 완료본은 재사용한다', () {
      expect(
        isReusableSourceDocForDedup({
          'status': 'completed',
          'isHidden': false,
        }),
        isTrue,
      );
    });

    test('공개 parsing 문서는 재사용한다 (동시 파싱 시 새 id 방지)', () {
      expect(
        isReusableSourceDocForDedup({
          'status': 'parsing',
          'isHidden': false,
        }),
        isTrue,
      );
    });

    test('숨김 껍데기·실패·취소는 재사용하지 않는다', () {
      expect(
        isReusableSourceDocForDedup({
          'status': 'completed',
          'isHidden': true,
          'hiddenReason': 'duplicate_of:abc',
        }),
        isFalse,
      );
      expect(
        isReusableSourceDocForDedup({'status': 'failed', 'isHidden': false}),
        isFalse,
      );
      expect(
        isReusableSourceDocForDedup({'status': 'error', 'isHidden': false}),
        isFalse,
      );
      expect(
        isReusableSourceDocForDedup({'status': 'cancelled', 'isHidden': false}),
        isFalse,
      );
    });
  });

  group('completed vs parsing', () {
    test('완료본은 attach 후 ExistingRecipeException', () {
      expect(isCompletedLikeSourceDoc({'status': 'completed'}), isTrue);
      expect(isCompletedLikeSourceDoc({'status': null}), isTrue);
      expect(isCompletedLikeSourceDoc({}), isTrue);
      expect(isInProgressSourceDoc({'status': 'completed', 'isHidden': false}),
          isFalse);
    });

    test('parsing 은 새 문서를 만들지 않고 기존 id 만 쓴다', () {
      expect(
        isInProgressSourceDoc({'status': 'parsing', 'isHidden': false}),
        isTrue,
      );
      expect(
        isCompletedLikeSourceDoc({'status': 'parsing'}),
        isFalse,
      );
    });
  });

  test('공개 목록 쿼리는 숨김 제외가 필요하다', () {
    expect(shouldConstrainPublicRecipeListToVisible(), isTrue);
  });

  group('isEligibleSavedRecipeForMealPlan', () {
    test('완료된 실레시피만 통과한다', () {
      expect(
        isEligibleSavedRecipeForMealPlan({
          'id': 'abc',
          'status': 'completed',
          'title': '두부찌개',
        }),
        isTrue,
      );
    });

    test('파싱 실패·취소·임시 더미는 식단에 넣지 않는다', () {
      expect(
        isEligibleSavedRecipeForMealPlan({
          'id': 'PUPKvv5Fr6HuOjYgqUob',
          'status': 'error',
          'title': '분석 중..',
          'isTemporary': true,
        }),
        isFalse,
      );
      expect(
        isEligibleSavedRecipeForMealPlan({
          'id': 'x',
          'status': 'parsing',
          'title': '분석 중..',
        }),
        isFalse,
      );
      expect(
        isEligibleSavedRecipeForMealPlan({
          'id': 'x',
          'status': 'cancelled',
          'title': '두부찌개',
        }),
        isFalse,
      );
    });
  });

  group('isReusableFailedRecipeData', () {
    test('본인 error 문서는 재시도 슬롯이다', () {
      expect(
        isReusableFailedRecipeData({
          'status': 'error',
          'userId': 'uid_me',
        }, userId: 'uid_me'),
        isTrue,
      );
    });

    test('타인 error·duplicate_of 사본은 재사용하지 않는다', () {
      expect(
        isReusableFailedRecipeData({
          'status': 'error',
          'userId': 'uid_other',
        }, userId: 'uid_me'),
        isFalse,
      );
      expect(
        isReusableFailedRecipeData({
          'status': 'error',
          'userId': 'uid_me',
          'hiddenReason': 'duplicate_of:canonical',
        }, userId: 'uid_me'),
        isFalse,
      );
      expect(
        isReusableFailedRecipeData({
          'status': 'completed',
          'userId': 'uid_me',
        }, userId: 'uid_me'),
        isFalse,
      );
    });
  });

  group('shouldCreateNewRecipeDocument', () {
    test('공개 원본이 있으면 새 문서를 만들지 않는다', () {
      expect(
        shouldCreateNewRecipeDocument({
          'id': 'canonical',
          'status': 'completed',
          'isHidden': false,
        }),
        isFalse,
      );
    });

    test('parsing 중이어도 새 문서를 만들지 않는다', () {
      expect(
        shouldCreateNewRecipeDocument({
          'id': 'in_flight',
          'status': 'parsing',
          'isHidden': false,
        }),
        isFalse,
      );
    });

    test('숨김 껍데기만 있거나 없으면 새 문서를 만든다', () {
      expect(shouldCreateNewRecipeDocument(null), isTrue);
      expect(
        shouldCreateNewRecipeDocument({
          'id': 'shell',
          'status': 'completed',
          'isHidden': true,
          'hiddenReason': 'duplicate_of:canonical',
        }),
        isTrue,
      );
    });

    test('숨김 사본이 섞여 있어도 쿼리가 공개만 보면 원본을 재사용한다', () {
      final matchedByUnconstrainedQuery = <Map<String, dynamic>>[
        {'id': 'canonical', 'status': 'completed', 'isHidden': false},
        {
          'id': 'shell',
          'status': 'completed',
          'isHidden': true,
          'hiddenReason': 'duplicate_of:canonical',
        },
      ];
      // 제약 없는 쿼리: 숨김이 섞여 통째로 실패 → existing=null → 새 문서 생성(버그)
      expect(shouldCreateNewRecipeDocument(null), isTrue);

      final matchedByVisibleQuery = matchedByUnconstrainedQuery
          .where((d) => d['isHidden'] != true)
          .toList();
      expect(matchedByVisibleQuery, hasLength(1));
      expect(shouldCreateNewRecipeDocument(matchedByVisibleQuery.first), isFalse);
    });
  });
}
