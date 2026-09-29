import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/home_agent_intent.dart';

void main() {
  test('dish names are not treated as home-agent intent', () {
    expect(looksLikeHomeAgentIntent('김치찌개'), isFalse);
    expect(looksLikeHomeAgentIntent('된장찌개'), isFalse);
  });

  test('intent markers trip the home-agent path', () {
    expect(looksLikeHomeAgentIntent('단백질 많은 거'), isTrue);
    expect(looksLikeHomeAgentIntent('뭐 해먹지'), isTrue);
    expect(looksLikeHomeAgentIntent('김치찌개 덜 맵게'), isTrue);
    expect(looksLikeHomeAgentIntent('야식'), isTrue);
    expect(looksLikeHomeAgentIntent('달달한 거'), isTrue);
    expect(looksLikeHomeAgentIntent('채식'), isTrue);
    expect(looksLikeHomeAgentIntent('전자레인지로 만들 수 있는 거'), isTrue);
    expect(looksLikeHomeAgentIntent('에어프라이어 요리'), isTrue);
  });

  test('spice-low drops cheongyang and spicy tags but keeps gochujang stew', () {
    final spicy = <String, dynamic>{
      'tags': <String>['매콤'],
      'recipe': {
        'ingredients': [
          {'item': '청양고추'},
        ],
      },
    };
    final stew = <String, dynamic>{
      'tags': <String>['집밥'],
      'recipe': {
        'ingredients': [
          {'item': '고추장'},
          {'item': '고춧가루'},
        ],
      },
    };
    expect(recipeFailsSpiceLow(spicy), isTrue);
    expect(recipeFailsSpiceLow(stew), isFalse);
    expect(applySpiceLowFilter([spicy, stew]).length, 1);
  });
}
