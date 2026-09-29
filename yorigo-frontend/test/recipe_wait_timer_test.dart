import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/models/recipe_models.dart';
import 'package:yorigo/utils/recipe_wait_timer.dart';

void main() {
  ({int seconds, String phrase})? suggest(
    String instruction, {
    String? tip,
    int? estMinutes,
  }) {
    return RecipeWaitTimer.suggestionFor(
      Step(
        order: 1,
        instruction: instruction,
        tip: tip,
        estMinutes: estMinutes,
      ),
    );
  }

  group('false positives', () {
    test('겉절이 + 예상 5분은 타이머가 아니다', () {
      expect(
        suggest(
          '물기를 짠 배추에 고춧가루 3큰술, 멸치액젓 2큰술, 가루알룰로스 1.5큰술, '
          '다진 마늘 1큰술, 통깨를 넣고 버무려 배추겉절이를 완성해주세요.',
          estMinutes: 5,
        ),
        isNull,
      );
    });

    test('우리는 / 휴지로 / 중불만 있는 손작업은 빼다', () {
      expect(suggest('우리는 이제 양념을 버무려주세요.', estMinutes: 5), isNull);
      expect(suggest('휴지로 물기를 닦아주세요.', estMinutes: 5), isNull);
      expect(suggest('중불에서 빠르게 볶아주세요.', estMinutes: 4), isNull);
    });

    test('분량, 분 전, 간격은 대기 시간이 아니다', () {
      expect(suggest('3분량의 양념을 넣고 버무려주세요.'), isNull);
      expect(suggest('2시간 전에 불려둔 콩을 씻어주세요.'), isNull);
      expect(suggest('10분 간격으로 저어주세요.'), isNull);
      expect(suggest('1분씩 앞뒤로 뒤집어주세요.'), isNull);
    });
  });

  group('real wait times', () {
    test('본문에 있는 대기 시간만 고른다', () {
      expect(suggest('10분 정도 끓여주세요.')?.phrase, '10분');
      expect(suggest('4시간 재워주세요.')?.seconds, 4 * 3600);
      expect(suggest('3~5분 익혀주세요.')?.phrase, '3~5분');
      expect(suggest('중불에서 15분간 졸여주세요.')?.phrase, '15분');
      expect(suggest('오븐에서 20분 구워주세요.')?.phrase, '20분');
      expect(suggest('그대로 10분간 두세요.')?.phrase, '10분');
      expect(suggest('5분간 삶아주세요.')?.phrase, '5분');
    });

    test('앞에 가짜 시간이 있어도 진짜 대기를 고른다', () {
      final found = suggest('3분량의 양념을 넣고 10분 끓여주세요.');
      expect(found?.phrase, '10분');
      expect(found?.seconds, 10 * 60);
    });
  });
}
