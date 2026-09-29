/// 레시피 도우미 수정 제안의 네/아니오 확인.
library;

const String kRecipeAgentConfirmAsk = '이렇게 수정할 수 있습니다. 진행할까요?';
const String kRecipeAgentConfirmedReply = '이 카드에 반영할게요.';
const String kRecipeAgentDeclinedReply = '반영하지 않았어요.';

const Set<String> kRecipeAgentConfirmYes = <String>{
  '네',
  '예',
  '응',
  'ㅇㅇ',
  '진행',
  '진행할게요',
  '진행해줘',
  '진행할께',
  '좋아요',
  '그래',
  '해줘',
  '반영',
  '반영해줘',
  'ok',
  'okay',
  'yes',
  'ㅇㅋ',
  'ㄱㄱ',
  '고고',
  'go',
};

const Set<String> kRecipeAgentConfirmNo = <String>{
  '아니',
  '아니오',
  '아니요',
  '아냐',
  '싫어',
  '취소',
  '됐어',
  '됐음',
  '안해',
  '안돼',
  '안됨',
  'no',
};

String normalizeRecipeAgentConfirmText(String? raw) {
  final folded = (raw ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
  return folded.replaceAll(RegExp(r'[.!?~…,]+$'), '');
}

bool isRecipeAgentConfirmYes(String? text, {String? chipId}) {
  if (chipId == 'confirm') return true;
  return kRecipeAgentConfirmYes.contains(normalizeRecipeAgentConfirmText(text));
}

bool isRecipeAgentConfirmNo(String? text, {String? chipId}) {
  if (chipId == 'decline') return true;
  return kRecipeAgentConfirmNo.contains(normalizeRecipeAgentConfirmText(text));
}
