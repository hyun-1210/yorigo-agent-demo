import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/recipebook_sync.dart';

void main() {
  Map<String, dynamic> defaultCat() => {
        'id': 'default_often',
        'name': '자주 해먹는',
        'isDefault': true,
      };

  Map<String, dynamic> customCat() => {
        'id': 'custom_1',
        'name': '다이어트',
        'isDefault': false,
      };

  group('hasMeaningfulData', () {
    test('기본 카테고리만 있고 맵이 비면 false', () {
      expect(
        RecipebookSync.hasMeaningfulData(
          categories: [defaultCat()],
          recipeCategoryMap: const {},
        ),
        isFalse,
      );
    });

    test('커스텀 폴더가 있으면 true', () {
      expect(
        RecipebookSync.hasMeaningfulData(
          categories: [defaultCat(), customCat()],
          recipeCategoryMap: const {},
        ),
        isTrue,
      );
    });

    test('기본 폴더만 있어도 레시피 배정이 있으면 true', () {
      expect(
        RecipebookSync.hasMeaningfulData(
          categories: [defaultCat()],
          recipeCategoryMap: const {
            'r1': ['default_often'],
          },
        ),
        isTrue,
      );
    });
  });

  group('decide', () {
    test('새 기기 + 클라우드에 커스텀 폴더 → 클라우드 적용', () {
      expect(
        RecipebookSync.decide(
          remoteHasMeaningfulData: true,
          localHasMeaningfulData: false,
          localDirty: false,
        ),
        RecipebookSyncAction.applyRemote,
      );
    });

    test('새 기기 + 클라우드 비어 있음 → 기본값 시드', () {
      expect(
        RecipebookSync.decide(
          remoteHasMeaningfulData: false,
          localHasMeaningfulData: false,
          localDirty: false,
        ),
        RecipebookSyncAction.seedDefaults,
      );
    });

    test('옛 폰에만 커스텀이 있고 클라우드는 비어 있음 → 업로드 (마이그레이션)', () {
      expect(
        RecipebookSync.decide(
          remoteHasMeaningfulData: false,
          localHasMeaningfulData: true,
          localDirty: false,
        ),
        RecipebookSyncAction.persistLocal,
      );
    });

    test('태블릿이 기본값만 심은 클라우드 vs 폰의 커스텀 → 폰을 업로드', () {
      expect(
        RecipebookSync.decide(
          remoteHasMeaningfulData: false,
          localHasMeaningfulData: true,
          localDirty: false,
        ),
        RecipebookSyncAction.persistLocal,
      );
    });

    test('미전송 로컬이 더 최신 → 업로드', () {
      expect(
        RecipebookSync.decide(
          remoteHasMeaningfulData: true,
          localHasMeaningfulData: true,
          localDirty: true,
          localUpdatedAt: DateTime.utc(2026, 8, 29, 10),
          remoteUpdatedAt: DateTime.utc(2026, 8, 29, 9),
        ),
        RecipebookSyncAction.persistLocal,
      );
    });

    test('미전송 로컬이 더 오래됨 → 클라우드 적용', () {
      expect(
        RecipebookSync.decide(
          remoteHasMeaningfulData: true,
          localHasMeaningfulData: true,
          localDirty: true,
          localUpdatedAt: DateTime.utc(2026, 8, 29, 8),
          remoteUpdatedAt: DateTime.utc(2026, 8, 29, 9),
        ),
        RecipebookSyncAction.applyRemote,
      );
    });

    test('dirty 인데 클라우드가 의미 없으면 업로드', () {
      expect(
        RecipebookSync.decide(
          remoteHasMeaningfulData: false,
          localHasMeaningfulData: true,
          localDirty: true,
        ),
        RecipebookSyncAction.persistLocal,
      );
    });
  });

  group('remapRecipeId', () {
    test('임시 ID 분류를 정식 ID 로 합친다', () {
      final result = RecipebookSync.remapRecipeId(
        mapping: {
          'temp_a': ['default_often', 'custom_1'],
          'canonical_b': ['custom_1'],
        },
        fromId: 'temp_a',
        toId: 'canonical_b',
      );
      expect(result.containsKey('temp_a'), isFalse);
      expect(result['canonical_b'], ['custom_1', 'default_often']);
    });

    test('임시 ID 에 배정이 없으면 맵을 그대로 둔다', () {
      const original = {
        'canonical_b': ['custom_1'],
      };
      final result = RecipebookSync.remapRecipeId(
        mapping: original,
        fromId: 'temp_a',
        toId: 'canonical_b',
      );
      expect(result, original);
    });

    test('같은 ID 면 변경 없다', () {
      const original = {
        'r1': ['c1'],
      };
      expect(
        RecipebookSync.remapRecipeId(
          mapping: original,
          fromId: 'r1',
          toId: 'r1',
        ),
        original,
      );
    });
  });
}
