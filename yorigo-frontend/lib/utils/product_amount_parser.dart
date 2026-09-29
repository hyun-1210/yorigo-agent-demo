/// Strips duplicate mass/volume tokens (e.g. "450g, 8개, 450g" → "450g, 8개") so
/// parsers don't treat the same weight twice.
String dedupeDuplicateMassTokensInProductName(String input) {
  if (input.isEmpty) return input;
  final re = RegExp(
    r'(\d+(?:\.\d+)?)\s*(g|그램|kg|킬로그램|ml|밀리리터|l|리터|L|ML)\b',
    caseSensitive: false,
  );
  final seen = <String>{};
  var s = input.replaceAllMapped(re, (Match m) {
    final key = '${m.group(1)}_${m.group(2)!.toLowerCase()}';
    if (seen.contains(key)) {
      return '';
    }
    seen.add(key);
    return m.group(0)!;
  });
  s = s.replaceAll(RegExp(r'\s*,\s*,+'), ', ');
  s = s.replaceAll(RegExp(r',\s*,'), ', ');
  s = s.replaceAll(RegExp(r'\s{2,}'), ' ');
  return s.trim();
}

bool _looksLikeEggProductTitle(String name) {
  final lower = name.toLowerCase();
  return lower.contains('계란') ||
      lower.contains('달걀') ||
      lower.contains('무항생') ||
      lower.contains('특란') ||
      lower.contains('왕란') ||
      lower.contains('에그') ||
      lower.contains('egg');
}

/// Parses package size and unit from product name (e.g. "500g 2개" → 1000g).
/// Used so Kurly products without backend package_size can show the same UI as Coupang.
({double? size, String? unit}) parsePackageSizeFromName(String productName) {
  if (productName.isEmpty) return (size: null, unit: null);

  var name = dedupeDuplicateMassTokensInProductName(productName.trim());

  // Eggs: "30알 2개" → total eggs = 30 × 2 (always 알 × 개 for egg listings).
  if (_looksLikeEggProductTitle(name)) {
    final alMatch = RegExp(r'(\d+(?:\.\d+)?)\s*알').firstMatch(name);
    final packMatch = RegExp(r'(\d+)\s*개(?!입)').firstMatch(name);
    if (alMatch != null && packMatch != null) {
      final alN = double.tryParse(alMatch.group(1)!);
      final packN = int.tryParse(packMatch.group(1)!);
      if (alN != null && alN > 0 && packN != null && packN > 0) {
        return (size: alN * packN, unit: '알');
      }
    }
  }

  final weightMatches = <_WeightMatch>[];
  double? countEa;

  // Pattern: "500g, 2개" or "500g 2개" — capture (num)(unit) and optional (num)개 (not 개입)
  final structured = RegExp(
    r'(\d+(?:\.\d+)?)\s*(g|그램|kg|킬로그램|ml|밀리리터|l|리터|L|ML)\s*[,]\s*(\d+)\s*개(?!입)',
    caseSensitive: false,
  ).firstMatch(name);
  if (structured != null) {
    final subQty = double.tryParse(structured.group(1)!) ?? 1;
    final subUnit = structured.group(2)!.toLowerCase();
    final packCount = int.tryParse(structured.group(3)!) ?? 1;
    if (subUnit == 'kg' || subUnit == '킬로그램') {
      return (size: subQty * 1000 * packCount, unit: 'g');
    }
    if (subUnit == 'g' || subUnit == '그램') {
      return (size: subQty * packCount, unit: 'g');
    }
    if (subUnit == 'l' || subUnit == '리터') {
      return (size: subQty * 1000 * packCount, unit: 'ml');
    }
    if (subUnit == 'ml' || subUnit == '밀리리터') {
      return (size: subQty * packCount, unit: 'ml');
    }
  }

  // Same without comma: "500g 2개" or tight "500g2개" / "500g8개"
  final structured2 = RegExp(
    r'(\d+(?:\.\d+)?)\s*(g|그램|kg|킬로그램|ml|밀리리터|l|리터|L|ML)\s*(\d+)\s*개(?!입)',
    caseSensitive: false,
  ).firstMatch(name);
  if (structured2 != null) {
    final subQty = double.tryParse(structured2.group(1)!) ?? 1;
    final subUnit = structured2.group(2)!.toLowerCase();
    final packCount = int.tryParse(structured2.group(3)!) ?? 1;
    if (subUnit == 'kg' || subUnit == '킬로그램') {
      return (size: subQty * 1000 * packCount, unit: 'g');
    }
    if (subUnit == 'g' || subUnit == '그램') {
      return (size: subQty * packCount, unit: 'g');
    }
    if (subUnit == 'l' || subUnit == '리터') {
      return (size: subQty * 1000 * packCount, unit: 'ml');
    }
    if (subUnit == 'ml' || subUnit == '밀리리터') {
      return (size: subQty * packCount, unit: 'ml');
    }
  }

  // "450g(무료냉장배송), 8개" — comma before pack count, arbitrary text between g and comma.
  final structured3 = RegExp(
    r'(\d+(?:\.\d+)?)\s*(g|그램|kg|킬로그램|ml|밀리리터|l|리터|L|ML)\b[\s\S]*?,\s*(\d+)\s*개(?!입)',
    caseSensitive: false,
  ).firstMatch(name);
  if (structured3 != null) {
    final subQty = double.tryParse(structured3.group(1)!) ?? 1;
    final subUnit = structured3.group(2)!.toLowerCase();
    final packCount = int.tryParse(structured3.group(3)!) ?? 1;
    if (subUnit == 'kg' || subUnit == '킬로그램') {
      return (size: subQty * 1000 * packCount, unit: 'g');
    }
    if (subUnit == 'g' || subUnit == '그램') {
      return (size: subQty * packCount, unit: 'g');
    }
    if (subUnit == 'l' || subUnit == '리터') {
      return (size: subQty * 1000 * packCount, unit: 'ml');
    }
    if (subUnit == 'ml' || subUnit == '밀리리터') {
      return (size: subQty * packCount, unit: 'ml');
    }
  }

  // Single unit patterns: 500g, 1kg, 300ml, 1L, 2개 (standalone)
  final weightPatterns = [
    RegExp(r'(\d+(?:\.\d+)?)\s*(kg|킬로그램)\b', caseSensitive: false),
    RegExp(r'(\d+(?:\.\d+)?)\s*(g|그램)\b', caseSensitive: false),
    RegExp(r'(\d+(?:\.\d+)?)\s*(l|리터|L)\b', caseSensitive: false),
    RegExp(r'(\d+(?:\.\d+)?)\s*(ml|밀리리터|ML)\b', caseSensitive: false),
    RegExp(r'(\d+(?:\.\d+)?)\s*(개입)\b', caseSensitive: false),
    RegExp(r'(\d+(?:\.\d+)?)\s*(봉지)\b', caseSensitive: false),
  ];

  final countPattern = RegExp(r'(\d+(?:\.\d+)?)\s*개(?!입)', caseSensitive: false);

  for (final re in weightPatterns) {
    for (final m in re.allMatches(name)) {
      final size = double.tryParse(m.group(1) ?? '') ?? 0;
      final unit = (m.group(2) ?? '').toLowerCase();
      if (unit == 'kg' || unit == '킬로그램') {
        weightMatches.add(_WeightMatch(size * 1000, 'g', m.start));
      } else if (unit == 'g' || unit == '그램') {
        weightMatches.add(_WeightMatch(size, 'g', m.start));
      } else if (unit == 'l' || unit == '리터') {
        weightMatches.add(_WeightMatch(size * 1000, 'ml', m.start));
      } else if (unit == 'ml' || unit == '밀리리터') {
        weightMatches.add(_WeightMatch(size, 'ml', m.start));
      } else if (unit == '개입') {
        weightMatches.add(_WeightMatch(size, '개', m.start));
      } else if (unit == '봉지') {
        weightMatches.add(_WeightMatch(size, '봉지', m.start));
      }
    }
  }

  final countMatch = countPattern.firstMatch(name);
  if (countMatch != null) {
    final n = double.tryParse(countMatch.group(1) ?? '');
    if (n != null && n == n.toInt()) countEa = n;
  }

  if (countEa != null && countEa > 0 && weightMatches.isNotEmpty) {
    final w = weightMatches.first;
    if (w.unit == 'g') return (size: w.size * countEa, unit: 'g');
    if (w.unit == 'ml') return (size: w.size * countEa, unit: 'ml');
  }

  if (weightMatches.isEmpty) return (size: null, unit: null);

  weightMatches.sort((a, b) => b.size.compareTo(a.size));
  final best = weightMatches.first;
  return (size: best.size, unit: best.unit);
}

class _WeightMatch {
  final double size;
  final String unit;
  final int start;
  _WeightMatch(this.size, this.unit, this.start);
}
