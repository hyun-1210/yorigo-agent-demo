import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/recipe_agent_confirm.dart';

void main() {
  test('yes markers accept punctuation but not a new request', () {
    expect(isRecipeAgentConfirmYes('네'), isTrue);
    expect(isRecipeAgentConfirmYes('네!'), isTrue);
    expect(isRecipeAgentConfirmYes('진행할게요'), isTrue);
    expect(isRecipeAgentConfirmYes('OK'), isTrue);
    expect(isRecipeAgentConfirmYes('ㄱㄱ'), isTrue);
    expect(isRecipeAgentConfirmYes('고고'), isTrue);
    expect(isRecipeAgentConfirmYes('네', chipId: 'confirm'), isTrue);
    expect(isRecipeAgentConfirmYes('', chipId: 'confirm'), isTrue);
    expect(isRecipeAgentConfirmYes('네 굴소스 빼줘'), isFalse);
  });

  test('no markers accept spaced 안 해 but not a mixed request', () {
    expect(isRecipeAgentConfirmNo('아니오'), isTrue);
    expect(isRecipeAgentConfirmNo('안 해'), isTrue);
    expect(isRecipeAgentConfirmNo('취소'), isTrue);
    expect(isRecipeAgentConfirmNo('', chipId: 'decline'), isTrue);
    expect(isRecipeAgentConfirmNo('아니 굴소스는 남겨'), isFalse);
  });
}
