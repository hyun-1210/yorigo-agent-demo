import '../models/recipe_models.dart';

class RecipeWaitTimer {
  RecipeWaitTimer._();

  static const int maxSeconds = 24 * 60 * 60;

  /// 시간 문구 근처에서만 본다. 단계 전체에서 `우리`/`휴지`/`절이`를 찾으면
  /// `우리는`, `휴지로`, `겉절이` 같은 글에도 타이머가 붙는다.
  static final _waitNear = RegExp(
    r'기다리|기다려|기다린|'
    r'끓이|끓인|끓여|'
    r'삶아|삶은|삶고|'
    r'찌고|쪄서|쪄주|찐 뒤|찜기|'
    r'우리고|우려내|우려낸|'
    r'재우|재워|재운|'
    r'숙성|'
    r'식히|식힌|식혀|'
    r'뜸|'
    r'그대로 두|두고|두세|두었|둡니|둬요|'
    r'뚜껑|'
    r'졸이|졸여|졸인|'
    r'오븐|'
    r'타이머|'
    r'절여|절인|소금에 절|'
    r'불려|불린|'
    r'익히|익혀|'
    r'중탕|'
    r'중불|약불|'
    r'구워|구운|'
    r'휴지시키',
  );

  static final _waitCue = RegExp(r'^\s*(동안|이상|가량|간(?:\s|[.!?,]|$))');

  static final _hourRange = RegExp(r'(\d+)\s*[~\-–]\s*(\d+)\s*시간');
  static final _hours = RegExp(r'(\d+)\s*시간');
  static final _combo = RegExp(r'(\d+)\s*분\s*(\d+)\s*초');
  static final _minRange = RegExp(r'(\d+)\s*[~\-–]\s*(\d+)\s*분');
  static final _mins = RegExp(r'(\d+)\s*분');
  static final _secs = RegExp(r'(\d+)\s*초');

  static ({int seconds, String phrase})? suggestionFor(Step step) {
    return suggestionForText('${step.instruction} ${step.tip ?? ''}');
  }

  static ({int seconds, String phrase})? suggestionForText(String text) {
    for (final candidate in _candidates(text)) {
      if (candidate.seconds < 20 || candidate.seconds > maxSeconds) continue;
      if (_isFalseTime(text, candidate)) continue;
      if (!_isWait(text, candidate)) continue;
      return (seconds: candidate.seconds, phrase: candidate.phrase);
    }
    return null;
  }

  static ({int seconds, String phrase})? extractWaitPhrase(String text) {
    return suggestionForText(text);
  }

  static String formatClock(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  static String formatLabel(int seconds) {
    if (seconds <= 0) return '0초';
    if (seconds % 3600 == 0) return '${seconds ~/ 3600}시간';
    if (seconds % 60 == 0) return '${seconds ~/ 60}분';
    if (seconds < 60) return '$seconds초';
    if (seconds >= 3600) {
      final h = seconds ~/ 3600;
      final m = (seconds % 3600) ~/ 60;
      return m == 0 ? '$h시간' : '$h시간 $m분';
    }
    return '${seconds ~/ 60}분 ${seconds % 60}초';
  }

  static List<({int seconds, String phrase, int index})> _candidates(
    String text,
  ) {
    final found = <({int seconds, String phrase, int index})>[];

    void addAll(RegExp pattern, int Function(RegExpMatch) secondsOf) {
      for (final match in pattern.allMatches(text)) {
        found.add((
          seconds: secondsOf(match),
          phrase: match.group(0)!,
          index: match.start,
        ));
      }
    }

    addAll(_hourRange, (m) => int.parse(m.group(2)!) * 3600);
    addAll(_hours, (m) => int.parse(m.group(1)!) * 3600);
    addAll(
      _combo,
      (m) => int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!),
    );
    addAll(_minRange, (m) => int.parse(m.group(2)!) * 60);
    addAll(_mins, (m) => int.parse(m.group(1)!) * 60);
    addAll(_secs, (m) => int.parse(m.group(1)!));

    found.sort((a, b) {
      final byIndex = a.index.compareTo(b.index);
      if (byIndex != 0) return byIndex;
      return b.phrase.length.compareTo(a.phrase.length);
    });

    final picked = <({int seconds, String phrase, int index})>[];
    for (final item in found) {
      final covered = picked.any(
        (prev) =>
            item.index >= prev.index &&
            item.index < prev.index + prev.phrase.length,
      );
      if (!covered) picked.add(item);
    }
    return picked;
  }

  static bool _isFalseTime(
    String text,
    ({int seconds, String phrase, int index}) candidate,
  ) {
    final after = text.substring(candidate.index + candidate.phrase.length);
    if (RegExp(r'^(량|씩)').hasMatch(after)) return true;
    if (RegExp(r'^\s*(전|간격|마다)').hasMatch(after)) return true;
    return false;
  }

  static bool _isWait(
    String text,
    ({int seconds, String phrase, int index}) candidate,
  ) {
    final from = (candidate.index - 18).clamp(0, text.length);
    final to =
        (candidate.index + candidate.phrase.length + 22).clamp(0, text.length);
    final window = text.substring(from, to);
    if (_waitNear.hasMatch(window)) return true;

    final after = text.substring(candidate.index + candidate.phrase.length, to);
    return _waitCue.hasMatch(after);
  }
}
