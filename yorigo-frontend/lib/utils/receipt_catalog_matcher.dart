import '../data/ingredient_shelf_life_seed.dart';
import '../services/ingredient_shelf_life_service.dart';
import 'receipt_scan_item_normalizer.dart';

/// 영수증 스캔 품명 → 냉장고 재료 시드/DB 카탈로그 매칭.
///
/// 수동 추가 UI와 동일하게 [ingredientShelfLifeSeedData] /
/// [IngredientShelfLifeService] 를 기준으로 한다.
class ReceiptCatalogMatcher {
  ReceiptCatalogMatcher._();

  static final Map<String, String> _compactToCanonical = {
    for (final key in ingredientShelfLifeSeedData.keys)
      _compact(key): key,
  };

  static String _compact(String s) =>
      s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');

  /// 정규화 후 카탈로그 정식 이름을 반환. 없으면 null.
  static String? resolveCatalogName(
    String name, {
    String? rawLine,
  }) {
    final normalized = ReceiptScanItemNormalizer.normalizeName(
      name,
      rawLine: rawLine,
    );
    if (normalized.isEmpty) return null;

    // 1) 공백 무시 exact
    final compact = _compact(normalized);
    final exact = _compactToCanonical[compact];
    if (exact != null) return exact;

    // raw_line에서도 한 번 더 (모델이 이름을 이상하게 줘도 OCR 원문 보정)
    if (rawLine != null && rawLine.trim().isNotEmpty) {
      final rawNorm = ReceiptScanItemNormalizer.normalizeName(
        rawLine,
        rawLine: rawLine,
      );
      final rawCompact = _compact(rawNorm);
      final rawExact = _compactToCanonical[rawCompact];
      if (rawExact != null) return rawExact;
    }

    // 2) 서비스 lookup (Firestore overlay 포함). 약한 부분일치 거름.
    final shelf = IngredientShelfLifeService.instance.lookup(normalized);
    if (shelf != null && _isAcceptableMatch(normalized, shelf.ingredientName)) {
      return shelf.ingredientName;
    }

    // 3) compact 부분일치 — 쿼리가 카탈로그명을 포함(긴 쪽 우선).
    //    같은 길이의 서로 다른 후보가 동률이면 추측하지 않고 실패(null).
    String? best;
    var bestLen = 0;
    var tie = false;
    for (final entry in _compactToCanonical.entries) {
      final key = entry.key;
      if (key.length < 2) continue;
      if (!compact.contains(key)) continue;
      if (key.length > bestLen) {
        bestLen = key.length;
        best = entry.value;
        tie = false;
      } else if (key.length == bestLen &&
          best != null &&
          entry.value != best) {
        tie = true;
      }
    }
    if (!tie && best != null && _isAcceptableMatch(normalized, best)) {
      return best;
    }

    // 4) 카탈로그가 쿼리를 포함하는 경우 — 쿼리가 충분히 길 때만
    //    ("파" → "양파" 같은 오매칭 방지). 동률이면 실패.
    if (compact.length >= 3) {
      best = null;
      tie = false;
      for (final entry in _compactToCanonical.entries) {
        final key = entry.key;
        if (key.length < compact.length) continue;
        if (!key.contains(compact)) continue;
        // 매칭 점수는 쿼리 길이로 고정이므로, 서로 다른 캐노니컬이면 곧 동률.
        if (best == null) {
          best = entry.value;
        } else if (entry.value != best) {
          tie = true;
          break;
        }
      }
      if (!tie && best != null) return best;
    }

    // 5) OCR 오타용 퍼지 매칭 (브로커리 → 브로콜리)
    final fuzzy = _fuzzyMatch(compact);
    if (fuzzy != null) return fuzzy;
    if (rawLine != null && rawLine.trim().isNotEmpty) {
      final rawCompact = _compact(
        ReceiptScanItemNormalizer.normalizeName(rawLine),
      );
      if (rawCompact.isNotEmpty && rawCompact != compact) {
        final fuzzyRaw = _fuzzyMatch(rawCompact);
        if (fuzzyRaw != null) return fuzzyRaw;
      }
    }

    // 6) 최후 수단: 오검수 위험이 없는 확정 별칭만.
    //    (브랜드 고유명사 1:1 매핑, 계란 등급명 접미사 — 다른 단계가
    //    모두 실패했을 때만 적용해서 "신선란/특란" 같은 등급명이
    //    카탈로그에 없어도 계란으로 들어갈 수 있게 한다.)
    final alias = _resolveSafeAlias(compact, rawLine: rawLine);
    if (alias != null) return alias;

    return null;
  }

  /// 브랜드 고유명사는 다른 단어의 부분문자열로 등장할 위험이 없어
  /// (예: "자연실록"은 다른 식재료명에 섞여 나올 일이 없음) contains 매칭이
  /// 안전하다. 일반 한글 단어(고추/배추 등)에는 절대 이런 표를 쓰지 않는다.
  static const List<(List<String>, String)> _safeBrandAlias = [
    (['자연실록'], '닭고기'),
  ];

  static String? _resolveSafeAlias(String compact, {String? rawLine}) {
    final haystacks = <String>[compact];
    if (rawLine != null && rawLine.trim().isNotEmpty) {
      final rawCompact = _compact(rawLine);
      if (rawCompact.isNotEmpty && !haystacks.contains(rawCompact)) {
        haystacks.add(rawCompact);
      }
    }
    for (final rule in _safeBrandAlias) {
      for (final hay in haystacks) {
        for (final p in rule.$1) {
          if (hay.contains(p)) return rule.$2;
        }
      }
    }
    // 계란 등급명 접미사 (신선란/특란/유정란/무항생제란 등) — 짧은 이름이
    // "란"으로 끝나면 거의 항상 계란 등급 표기다. 카탈로그에 '계란'이
    // 있을 때만 적용한다.
    if (compact.length <= 6 &&
        compact.endsWith('란') &&
        !compact.endsWith('고란') &&
        _compactToCanonical.containsKey(_compact('계란'))) {
      return '계란';
    }
    return null;
  }

  static bool isInCatalog(String name, {String? rawLine}) =>
      resolveCatalogName(name, rawLine: rawLine) != null;

  static bool _isAcceptableMatch(String query, String catalog) {
    final q = _compact(query);
    final c = _compact(catalog);
    if (q.isEmpty || c.isEmpty) return false;
    if (q == c) return true;
    if (c.length < 2) return false;
    // 쿼리가 카탈로그를 포함 (예: 돼지고기삼겹살 → 삼겹살)
    if (q.contains(c)) return true;
    // 카탈로그가 쿼리를 포함 — 쿼리 길이 3자 이상만
    if (q.length >= 3 && c.contains(q)) return true;
    return false;
  }

  /// 비슷한 길이의 카탈로그명 중 편집 거리가 가까운 유일 후보.
  static String? _fuzzyMatch(String compact) {
    if (compact.length < 3) return null;
    final maxDist = compact.length <= 4 ? 1 : 2;

    String? best;
    var bestDist = 999;
    var tie = false;

    for (final entry in _compactToCanonical.entries) {
      final key = entry.key;
      if (key.length < 3) continue;
      if ((key.length - compact.length).abs() > maxDist) continue;
      final d = _levenshtein(compact, key);
      if (d <= 0 || d > maxDist) continue;
      if (d < bestDist) {
        bestDist = d;
        best = entry.value;
        tie = false;
      } else if (d == bestDist && best != null && entry.value != best) {
        tie = true;
      }
    }
    if (tie) return null;
    return best;
  }

  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    final prev = List<int>.generate(b.length + 1, (i) => i);
    final curr = List<int>.filled(b.length + 1, 0);

    for (var i = 1; i <= a.length; i++) {
      curr[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        curr[j] = [
          prev[j] + 1,
          curr[j - 1] + 1,
          prev[j - 1] + cost,
        ].reduce((x, y) => x < y ? x : y);
      }
      for (var j = 0; j <= b.length; j++) {
        prev[j] = curr[j];
      }
    }
    return prev[b.length];
  }
}
