/// 제휴 경유 기록용 하루 문서. 클릭마다 문서를 늘리지 않는다.
const String kCoupangVisitsCollection = 'coupang_visits';

/// 하루 문서 하나 안에 넣을 최대 건수. 넘으면 오래된 것부터 버린다.
const int kCoupangVisitsMaxPerDay = 100;

const String kAffiliateVisitMarketplaceCoupang = 'coupang';
const String kAffiliateVisitMarketplaceKurly = 'kurly';
const String kAffiliateVisitMarketplaceNaver = 'naver';

/// 출석 키와 같은 KST(UTC+9) `yyyy-MM-dd`. 자정에 문서 id가 바뀐다.
String coupangVisitDayId(DateTime dateTime) {
  final kst = dateTime.toUtc().add(const Duration(hours: 9));
  final month = kst.month.toString().padLeft(2, '0');
  final day = kst.day.toString().padLeft(2, '0');
  return '${kst.year}-$month-$day';
}

/// 경유 기록에 넣는 마켓. oasis 등은 null (기록 안 함).
String? normalizeAffiliateVisitMarketplace(String? raw) {
  final value = (raw ?? '').trim().toLowerCase();
  if (value == 'coupang') return kAffiliateVisitMarketplaceCoupang;
  if (value == 'kurly' || value == 'marketkurly' || value == 'market_kurly') {
    return kAffiliateVisitMarketplaceKurly;
  }
  if (value == 'naver' ||
      value == 'brandconnect' ||
      value == 'naver_brandconnect') {
    return kAffiliateVisitMarketplaceNaver;
  }
  return null;
}

/// 오늘 문서에 한 건을 붙인다. [max]를 넘기면 앞에서 자른다.
List<Map<String, dynamic>> appendCoupangVisit({
  required List<Map<String, dynamic>> existing,
  required Map<String, dynamic> next,
  int max = kCoupangVisitsMaxPerDay,
}) {
  final cap = max < 1 ? 1 : max;
  final nextList = <Map<String, dynamic>>[...existing, next];
  if (nextList.length <= cap) return nextList;
  return nextList.sublist(nextList.length - cap);
}

/// 오늘이 아닌 날짜 문서는 삭제 대상.
List<String> coupangVisitDocIdsToDelete({
  required Iterable<String> docIds,
  required String todayId,
}) {
  final today = todayId.trim();
  return [
    for (final raw in docIds)
      if (raw.trim().isNotEmpty && raw.trim() != today) raw.trim(),
  ];
}
