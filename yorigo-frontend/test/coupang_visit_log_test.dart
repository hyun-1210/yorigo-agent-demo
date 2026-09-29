import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/coupang_visit_log.dart';

void main() {
  group('coupangVisitDayId', () {
    test('uses KST so 00:30 KST is the new calendar day', () {
      // 2026-09-10 15:30 UTC = 2026-09-11 00:30 KST
      final justAfterMidnightKst =
          DateTime.utc(2026, 9, 10, 15, 30);
      expect(coupangVisitDayId(justAfterMidnightKst), '2026-09-11');
    });

    test('keeps previous KST day before midnight', () {
      // 2026-09-10 14:59 UTC = 2026-09-10 23:59 KST
      final beforeMidnightKst = DateTime.utc(2026, 9, 10, 14, 59);
      expect(coupangVisitDayId(beforeMidnightKst), '2026-09-10');
    });
  });

  group('appendCoupangVisit', () {
    test('appends and drops oldest when over max', () {
      final existing = <Map<String, dynamic>>[
        {'at': '1'},
        {'at': '2'},
      ];
      final next = <String, dynamic>{'at': '3'};
      final visits = appendCoupangVisit(
        existing: existing,
        next: next,
        max: 2,
      );
      expect(visits, [
        {'at': '2'},
        {'at': '3'},
      ]);
    });
  });

  group('normalizeAffiliateVisitMarketplace', () {
    test('keeps coupang kurly naver and drops oasis', () {
      expect(normalizeAffiliateVisitMarketplace('coupang'), 'coupang');
      expect(normalizeAffiliateVisitMarketplace('kurly'), 'kurly');
      expect(normalizeAffiliateVisitMarketplace('market_kurly'), 'kurly');
      expect(normalizeAffiliateVisitMarketplace('naver'), 'naver');
      expect(normalizeAffiliateVisitMarketplace('naver_brandconnect'), 'naver');
      expect(normalizeAffiliateVisitMarketplace('oasis'), isNull);
    });
  });

  group('coupangVisitDocIdsToDelete', () {
    test('keeps today and drops other day ids', () {
      expect(
        coupangVisitDocIdsToDelete(
          docIds: ['2026-09-10', '2026-09-11', 'legacy'],
          todayId: '2026-09-11',
        ),
        ['2026-09-10', 'legacy'],
      );
    });
  });
}
