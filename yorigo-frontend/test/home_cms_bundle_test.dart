import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/constants/home_poster_curations.dart';
import 'package:yorigo/models/home_cms_models.dart';

void main() {
  test('HomeCmsBundle parses posters and sections', () {
    final bundle = HomeCmsBundle.fromJson({
      'schemaVersion': 1,
      'updatedAt': '2026-08-15T00:00:00Z',
      'posters': [
        {
          'id': 'first_main_for_two',
          'order': 0,
          'enabled': true,
          'posterTitle': '더위야',
          'subtitle': '시원',
          'pageTitle': '더위야',
          'body': '본문',
          'chips': [
            {'label': '전체', 'sectionKey': 'poster_summer_all'},
          ],
        },
      ],
      'sections': [
        {
          'sectionKey': 'dessert',
          'label': '달콤한 디저트 한 입',
          'kind': 'trend',
          'order': 11,
          'enabled': true,
        },
        {
          'sectionKey': 'sauce',
          'label': '소스',
          'kind': 'trend',
          'order': 10,
          'enabled': false,
        },
      ],
    });
    expect(bundle.enabledPosters, hasLength(1));
    expect(bundle.enabledSections.map((s) => s.sectionKey), ['dessert']);
    final curation = HomePosterCuration.fromCms(bundle.posters.first.data);
    expect(curation.id, 'first_main_for_two');
    expect(curation.chips.first.sectionKey, 'poster_summer_all');
  });

  test('fromCms keeps coupang landingUrl and deeplinkUrl', () {
    final curation = HomePosterCuration.fromCms({
      'id': 'first_main_for_two',
      'chips': [
        {'label': '전체', 'sectionKey': 'poster_summer_all'},
      ],
      'products': [
        {
          'id': 'egg',
          'name': '계란',
          'subtitle': '',
          'badge': '추천',
          'productUrl': 'https://link.coupang.com/a/short',
          'landingUrl': 'https://link.coupang.com/re/AFFSDP?lptag=x',
          'deeplinkUrl': 'https://link.coupang.com/a/short',
        },
      ],
    });
    expect(curation.products, hasLength(1));
    expect(
      curation.products.first.landingUrl,
      'https://link.coupang.com/re/AFFSDP?lptag=x',
    );
    expect(
      curation.products.first.deeplinkUrl,
      'https://link.coupang.com/a/short',
    );
  });

  test('fromCms skips empty chips and requires id', () {
    expect(
      () => HomePosterCuration.fromCms({'id': '', 'chips': []}),
      throwsA(isA<FormatException>()),
    );
  });
}
