import 'dart:math' as math;

/// 요리고 레벨는 EXP 기준. 기록 수 곡선은 레거시.
int yorigoReviewsRequiredForLevel(int level) {
  if (level <= 1) return 0;
  final n = level - 1;
  return math.max(n, math.pow(n, 1.32).round());
}

int yorigoLevelFromReviewCount(int count) {
  if (count <= 0) return 1;
  var lo = 1;
  var hi = 8;
  while (yorigoReviewsRequiredForLevel(hi) <= count) {
    hi *= 2;
    if (hi > 100000) break;
  }
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (yorigoReviewsRequiredForLevel(mid) <= count) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}

int yorigoReviewsToNextLevel(int count) {
  final level = yorigoLevelFromReviewCount(count);
  final next = yorigoReviewsRequiredForLevel(level + 1);
  return (next - count).clamp(0, next);
}

double yorigoProgressToNextLevel(int count) {
  final level = yorigoLevelFromReviewCount(count);
  final next = yorigoReviewsRequiredForLevel(level + 1);
  final prev = yorigoReviewsRequiredForLevel(level);
  if (next <= prev) return 1.0;
  return ((count - prev) / (next - prev)).clamp(0.0, 1.0);
}

/// 피드·프로필·랭킹 작성자 레벨. EXP만 본다.
int yorigoLevelFromUserData(Map<String, dynamic> userData) {
  if (userData.containsKey('expTotal')) {
    return yorigoLevelFromExp((userData['expTotal'] as num?)?.toInt() ?? 0);
  }
  final stored = (userData['level'] as num?)?.toInt();
  if (stored != null && stored > 0) return stored;
  return 1;
}

/// 요리고 레벨 수저 이름. 11부터는 마지막 이름을 유지한다.
const yorigoLevelSpoonNames = <String>[
  '흑수저',
  '종이수저',
  '플라스틱수저',
  '나무수저',
  '스테인리스수저',
  '은수저',
  '금수저',
  '다이아수저',
  '백수저',
  '요리고수저',
];

String yorigoLevelSpoonName(int level) {
  return yorigoLevelSpoonNames[
      (level - 1).clamp(0, yorigoLevelSpoonNames.length - 1)];
}

/// 레벨 N 도달에 필요한 누적 EXP.
/// Lv.2는 사진 기록 1번(50). 초반은 잘 오르고, 이후 통이 천천히 커진다.
/// functions/rewards.js · backend rewards_service.py 와 동일.
int yorigoExpRequiredForLevel(int level) {
  if (level <= 1) return 0;
  final n = level - 1;
  return (50 * math.pow(n, 1.38)).round();
}

int yorigoLevelFromExp(int totalExp) {
  if (totalExp <= 0) return 1;
  var lo = 1;
  var hi = 8;
  while (yorigoExpRequiredForLevel(hi) <= totalExp) {
    hi *= 2;
    if (hi > 100000) break;
  }
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (yorigoExpRequiredForLevel(mid) <= totalExp) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}
