/// 영수증 스캔 품명 **기계적 정리** + 비식품 휴리스틱.
///
/// 의미 정규화(브랜드 상품 → 식재료 일반명)는 비전 AI 프롬프트에 맡긴다.
/// 클라이언트/서버 후처리는 매칭을 방해하는 잡음만 제거한다.
///
/// 백엔드(`fridge_vision_service.py`)와 동일 계약을 유지한다.
class ReceiptScanItemNormalizer {
  ReceiptScanItemNormalizer._();

  /// 앞쪽에 붙는 브랜드/PB 접두. 의미 변환 없이 제거만 한다.
  static const List<String> _brandPrefixes = [
    '풀무원',
    '서울우유',
    '매일유업',
    '매일',
    '남양유업',
    '남양',
    '빙그레',
    '동원',
    '오뚜기',
    '청정원',
    '샘표',
    '대상',
    'CJ',
    'cj',
    '비비고',
    '햇반',
    '농심',
    '삼양',
    '팔도',
    '하림',
    '목우촌',
    '롯데',
    '오리온',
    '해태',
    '크라운',
    '사조',
    '사조대림',
    '대림',
    '한성',
    '종가집',
    '이마트',
    '노브랜드',
    '피코크',
    '트레이더스',
    '홈플러스',
    '쿠팡',
    '곰표',
    '굿모닝',
    '하선정',
  ];

  /// 생활용품 등 — 품명/원문에 있으면 비식품.
  static const List<String> _nonFoodProductKeywords = [
    '세제',
    '세탁',
    '섬유유연',
    '표백',
    '락스',
    '클리너',
    '세정제',
    '주방세제',
    '설거지',
    '휴지',
    '화장지',
    '물티슈',
    '키친타올',
    '키친타월',
    '키친타워',
    '비닐봉투',
    '쓰레기봉투',
    '종량제',
    '쿠킹랩',
    '위생랩',
    '식품랩',
    '호일',
    '호일지',
    '알루미늄호일',
    '건전지',
    '배터리',
    '샴푸',
    '린스',
    '컨디셔너',
    '바디워시',
    '바디로션',
    '치약',
    '칫솔',
    '비누',
    '방향제',
    '탈취제',
    '살충제',
    '담배',
    '라이터',
    '잡지',
    '신문',
    '문구',
    '볼펜',
    '테이프',
    '고무장갑',
    '수세미',
    '행주',
    '스펀지',
    '생리대',
    '기저귀',
    '반창고',
    '밴드에이드',
    '마스크팩',
    '화장품',
    '로션',
    '크림팩',
  ];

  /// 영수증 메타 줄. 품명 자체에만 적용 (할인삼겹살 오탐 방지).
  static const List<String> _receiptMetaMarkers = [
    '합계',
    '총액',
    '부가세',
    '거스름돈',
    '거스름',
    '카드승인',
    '할부',
    '봉사료',
    '배달팁',
    '배송비',
    '과세물품',
    '면세물품',
    '받을금액',
    '받은금액',
    '포인트사용',
    '포인트적립',
    '할인금액',
  ];

  static final RegExp _sizeSuffix = RegExp(
    r'[\d.,]+\s*(kg|g|ml|l|L|입|개입|팩|봉|매|장|병|캔|포|구)?$',
    caseSensitive: false,
  );

  /// `001 P 양파 .` / `P굿모닝우유` 같은 영수증 잡음.
  static final RegExp _leadingLineNoise = RegExp(
    r'^(?:\d{1,3}\s*)?P\s*',
    caseSensitive: false,
  );

  static String _compact(String text) => text.replaceAll(RegExp(r'\s+'), '');

  static String _stripReceiptNoise(String name) {
    var s = name.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (s.isEmpty) return s;
    s = s.replaceFirst(_leadingLineNoise, '');
    s = s.replaceAll(RegExp(r'[.]+$'), '').trim();
    s = s.replaceAll(RegExp(r'^[ \-_/·]+|[ \-_/·]+$'), '');
    return s;
  }

  static String _stripBrandAndSize(String name) {
    var s = _stripReceiptNoise(name);
    if (s.isEmpty) return s;
    var changed = true;
    while (changed) {
      changed = false;
      for (final brand in _brandPrefixes) {
        if (s.startsWith(brand)) {
          s = s.substring(brand.length).replaceFirst(RegExp(r'^[ \-_/·]+'), '');
          changed = true;
          break;
        }
      }
    }
    s = s
        .replaceFirst(_sizeSuffix, '')
        .replaceAll(RegExp(r'^[ \-_/·]+|[ \-_/·]+$'), '');
    for (final fluff in ['통통', '신선한', '무항생제', '유기농', '친환경', '프리미엄']) {
      s = s.replaceAll(fluff, '');
    }
    s = s
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^[ \-_/·]+|[ \-_/·]+$'), '');
    return s.isEmpty ? _stripReceiptNoise(name) : s;
  }

  /// AI가 준 이름을 기계적으로만 정리. 의미 변환은 하지 않는다.
  ///
  /// 예: `P굿모닝우유 900ML` → `우유` (브랜드·용량 제거 후 카탈로그 매칭용)
  static String normalizeName(String name, {String? rawLine}) {
    final original = name.trim();
    if (original.isEmpty) return original;

    // raw_line만 있고 name이 잡음인 경우는 거의 없으므로 name 기준으로 정리.
    // raw는 카탈로그 매처가 별도로 참고한다.
    final stripped = _stripBrandAndSize(original);
    final out = stripped.isEmpty ? _stripReceiptNoise(original) : stripped;
    final cleaned = out.isEmpty ? original : out;
    return cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned;
  }

  static bool _looksLikeReceiptMetaLine(String compactName) {
    if (compactName.isEmpty) return false;
    for (final kw in _receiptMetaMarkers) {
      if (compactName == kw) return true;
      // "합계금액", "부가세액"처럼 짧은 접미만 허용
      if (compactName.startsWith(kw) && compactName.length <= kw.length + 4) {
        return true;
      }
    }
    return false;
  }

  static bool isLikelyFood(String name, {String? rawLine}) {
    final nameCompact = _compact(name);
    if (nameCompact.isEmpty) return false;

    if (_looksLikeReceiptMetaLine(nameCompact)) return false;

    var hay = nameCompact;
    final raw = rawLine?.trim();
    if (raw != null && raw.isNotEmpty) {
      hay += _compact(raw);
    }
    for (final kw in _nonFoodProductKeywords) {
      if (hay.contains(kw)) return false;
    }
    return true;
  }

  static String categoryForNormalizedName(String name, String fallback) {
    if (name == '계란' || name == '달걀' || name == '메추리알') {
      return 'dairy';
    }
    return fallback;
  }
}
