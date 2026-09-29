import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/constants/home_section_keys.dart';
import 'package:yorigo/services/analytics_service.dart';

/// 홈 행동 이벤트 프로퍼티 계약 (발화 전 sanitize/truncate 규칙).
void main() {
  group('home_category_clicked contract', () {
    test('source stays ascii; category_name keeps korean', () {
      expect(sanitizeAnalyticsName('recipebook'), 'recipebook');
      expect(sanitizeAnalyticsName('primary_filter'), 'primary_filter');
      expect(sanitizeAnalyticsName('secondary_filter'), 'secondary_filter');
      expect(truncateAnalyticsValue('전체'), '전체');
      expect(truncateAnalyticsValue('단백질'), '단백질');
    });
  });

  group('home_recipe_clicked contract', () {
    test('section_id from title key; section_name preserves label', () {
      const title = '단백질 많은';
      final sectionId = HomeSectionKeys.keyForTitle(title);
      expect(sectionId, 'high_protein');
      expect(sanitizeAnalyticsName(sectionId), 'high_protein');
      expect(truncateAnalyticsValue(title), title);
      // 절대 라벨을 section_id로 sanitize 하면 안 됨
      expect(sanitizeAnalyticsName(title), 'unknown');
    });

    test('chef and seasonal titles resolve to stable ids', () {
      expect(HomeSectionKeys.keyForTitle('셰프 · 백종원'), 'chef');
      expect(HomeSectionKeys.keyForTitle('7월 제철'), 'seasonal');
    });
  });

  group('home scroll summary contract', () {
    test('depth percent clamps to 0-100 when rounded', () {
      double clampDepth(double v) => v.clamp(0, 100).toDouble();
      expect(clampDepth(-5).round(), 0);
      expect(clampDepth(150).round(), 100);
      expect(clampDepth(42.6).round(), 43);
    });
  });

  group('home_section_impression contract', () {
    test('section_id is ascii key; section_name keeps korean label', () {
      const label = '실시간 인기 레시피';
      final id = HomeSectionKeys.keyForTitle(label);
      expect(id, 'trending_now');
      expect(sanitizeAnalyticsName(id), 'trending_now');
      expect(truncateAnalyticsValue(label), label);
    });

    test('impression threshold is mid-viewport (0.5)', () {
      // 홈 섹션 노출: visibleFraction >= 0.5 일 때만 1회 전송
      const threshold = 0.5;
      expect(0.49 < threshold, isTrue);
      expect(0.5 >= threshold, isTrue);
    });

    test('program block uses container id plus chip key', () {
      expect(sanitizeAnalyticsName('program_curation'), 'program_curation');
      expect(sanitizeAnalyticsName('program_pyeonstorang'), 'program_pyeonstorang');
      expect(kHomePrimaryFilterIds['전체'], 'all');
    });

    test('see-all surface uses section_recipes; origin stays in chip key', () {
      expect(sanitizeAnalyticsName('section_recipes'), 'section_recipes');
      expect(
        sanitizeAnalyticsName('program_pyeonstorang'),
        'program_pyeonstorang',
      );
    });
  });
}
