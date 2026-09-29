import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/constants/home_poster_curations.dart';
import 'package:yorigo/constants/home_section_keys.dart';
import 'package:yorigo/utils/recipe_signal_snapshot.dart';
import 'package:yorigo/widgets/home_poster_carousel.dart';

void main() {
  test('RecipeSignalSnapshot reads flattened and nested recipe maps', () {
    final listItem = RecipeSignalSnapshot.fromRecipeMap({
      'id': 'r1',
      'tags': ['한식', '간단'],
      'categories': {
        'cuisine_type': ['한식'],
        'time_category': ['10분 이내'],
        'menu_type': ['반찬'],
        'main_ingredient': ['계란'],
      },
      'source': {'platform': 'instagram'},
      'recipe': {
        'servings': 2,
        'ingredients': [
          {'name': '계란', 'category': '축산'},
        ],
      },
    });
    expect(listItem.cuisineType, ['한식']);
    expect(listItem.timeCategory, ['10분 이내']);
    expect(listItem.sourcePlatform, 'instagram');
    expect(listItem.servings, 2);
    expect(listItem.ingredientCategories, ['축산']);

    final detail = RecipeSignalSnapshot.fromRecipeMap({
      'id': 'r2',
      'source': {
        'platform': 'youtube',
        'categories': {
          'cuisine_type': ['양식'],
        },
        'tags': ['파스타'],
      },
      'recipe': {'servings': '3'},
    });
    expect(detail.cuisineType, ['양식']);
    expect(detail.tags, ['파스타']);
    expect(detail.sourcePlatform, 'youtube');
    expect(detail.servings, 3);
  });

  test('poster carousel items carry curation ids for signal attribution', () {
    expect(HomePosterCurations.all, isNotEmpty);
    for (final curation in HomePosterCurations.all) {
      expect(curation.id, isNotEmpty);
    }
    const item = HomePosterItem(
      id: 'first_main_for_two',
      assetPath: 'assets/images/home_poster_1.png',
    );
    expect(item.id, 'first_main_for_two');
  });

  test('HomeSectionKeys keeps seasonal/chef join keys when labels change', () {
    expect(HomeSectionKeys.keyForTitle('8월 제철'), HomeSectionKeys.seasonal);
    expect(HomeSectionKeys.keyForTitle('셰프 · 백종원'), HomeSectionKeys.chef);
    expect(
      HomeSectionKeys.keyForTitle('실시간 인기 레시피'),
      HomeSectionKeys.trendingNow,
    );
  });

  test('poster chips expose stable sectionKeys for CMS recipe pools', () {
    var keyedChips = 0;
    for (final curation in HomePosterCurations.all) {
      expect(curation.id, matches(RegExp(r'^[a-z][a-z0-9_]*$')));
      for (final chip in curation.chips) {
        final key = chip.sectionKey?.trim();
        if (key == null || key.isEmpty) continue;
        keyedChips += 1;
        expect(key, matches(RegExp(r'^[a-z][a-z0-9_]*$')));
      }
    }
    expect(keyedChips, greaterThan(0));
  });
}
