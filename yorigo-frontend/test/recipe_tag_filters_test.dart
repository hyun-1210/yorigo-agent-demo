import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/recipe_tag_filters.dart';

void main() {
  group('recipeTaglineForDisplay', () {
    test('reads chips_v2 tagline and skips notes-like description', () {
      expect(
        recipeTaglineForDisplay(
          source: {
            'tagline': '육수와 액젓으로 깊은 맛을 낸 잔치국수',
            'description': '구독과 좋아요 부탁드립니다 긴 영상 설명',
          },
        ),
        '육수와 액젓으로 깊은 맛을 낸 잔치국수',
      );
    });

    test('prefers recipeDoc tagline over source hook', () {
      expect(
        recipeTaglineForDisplay(
          recipeDoc: {'tagline': '청하와 꿀로 졸여 부드러운 삼겹살 장조림'},
          source: {'hook': '오래된 훅 문장입니다'},
        ),
        '청하와 꿀로 졸여 부드러운 삼겹살 장조림',
      );
    });

    test('hides short or missing copy', () {
      expect(recipeTaglineForDisplay(source: {'tagline': '짧음'}), isEmpty);
      expect(recipeTaglineForDisplay(source: {}), isEmpty);
    });

    test('does not fall back to notes', () {
      expect(
        recipeTaglineForDisplay(
          source: {},
          recipeDoc: {
            'notes': ['간장 조금 더 넣어도 좋아요'],
          },
        ),
        isEmpty,
      );
    });
  });

  group('hydrateRecipeDisplayMeta', () {
    test('copies tagline and occasionTags without extra fields', () {
      final source = <String, dynamic>{
        'tags': ['매콤한'],
        'platform': 'youtube',
      };
      hydrateRecipeDisplayMeta(source, {
        'tagline': '마늘 듬뿍 넣어 매콤하게 조린 매콤마늘삼겹',
        'occasionTags': ['혼밥', '저녁'],
        'tags': ['매콤한', '고소한'],
      });
      expect(source['tagline'], '마늘 듬뿍 넣어 매콤하게 조린 매콤마늘삼겹');
      expect(source['occasionTags'], ['혼밥', '저녁']);
      expect(source['platform'], 'youtube');
    });
  });

  group('recipeIdentityDisplayTags', () {
    test('appends unique occasion tags after taste tags', () {
      expect(
        recipeIdentityDisplayTags(
          tags: ['매콤한', '고소한'],
          occasionTags: ['저녁', '혼밥', '매콤한'],
        ),
        ['매콤한', '고소한', '저녁', '혼밥'],
      );
    });

    test('drops blocked tokens', () {
      expect(
        recipeIdentityDisplayTags(tags: ['회사', '매콤한']),
        ['매콤한'],
      );
    });
  });

  group('recipeMatchesAnyTag', () {
    test('matches occasionTags after chips_v2 split', () {
      final recipe = {
        'tags': ['매콤한', '고소한'],
        'occasionTags': ['혼밥', '저녁'],
      };
      expect(recipeMatchesAnyTag(recipe, ['혼밥용', '혼밥']), isTrue);
      expect(recipeMatchesAnyTag(recipe, ['집밥용', '집밥']), isFalse);
    });

    test('also reads nested source.occasionTags', () {
      final recipe = {
        'tags': ['단짠단짠'],
        'source': {
          'occasionTags': ['야식'],
        },
      };
      expect(recipeMatchesAnyTag(recipe, ['야식각', '야식']), isTrue);
    });
  });

  group('recipeTagOrTaglineContains', () {
    test('finds query in tagline', () {
      expect(
        recipeTagOrTaglineContains({
          'tags': ['매콤한'],
          'tagline': '육수와 액젓으로 깊은 맛을 낸 잔치국수',
        }, '액젓'),
        isTrue,
      );
    });
  });

  group('recipeDisplayMetaWriteFields', () {
    test('omits empty values so reparse cannot wipe a backfill', () {
      expect(recipeDisplayMetaWriteFields({}), isEmpty);
      expect(
        recipeDisplayMetaWriteFields({
          'tagline': '배와 무로 시원한 맛을 낸 물김치',
          'occasionTags': ['더운날'],
        }),
        {
          'tagline': '배와 무로 시원한 맛을 낸 물김치',
          'occasionTags': ['더운날'],
        },
      );
    });
  });
}
