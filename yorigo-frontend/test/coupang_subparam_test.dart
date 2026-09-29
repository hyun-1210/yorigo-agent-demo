import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/services/coupang_service.dart';
import 'package:yorigo/utils/coupang_subparam.dart';

void main() {
  group('generateCoupangSubparam', () {
    test('yr_ prefix plus 10-16 alphanumeric, never a raw uid', () {
      final uid = 'firebaseUidAbcdefghijklmnop';
      final first = generateCoupangSubparam(Random(1));
      final second = generateCoupangSubparam(Random(2));

      expect(isValidCoupangSubparam(first), isTrue);
      expect(isValidCoupangSubparam(second), isTrue);
      expect(first, isNot(second));
      expect(first, isNot(uid));
      expect(first.contains(uid), isFalse);
      expect(first.startsWith('yr_'), isTrue);
      expect(first.length, 3 + kCoupangSubparamTokenLen);
    });
  });

  group('isCoupangAffsdpLandingUrl', () {
    test('accepts AFFSDP on link.coupang.com', () {
      expect(
        isCoupangAffsdpLandingUrl(
          'https://link.coupang.com/re/AFFSDP?lptag=123&itemId=1',
        ),
        isTrue,
      );
      expect(
        isCoupangAffsdpLandingUrl('link.coupang.com/re/AFFSDP'),
        isTrue,
      );
    });

    test('rejects short links and www product pages', () {
      expect(
        isCoupangAffsdpLandingUrl('https://link.coupang.com/a/abc12'),
        isFalse,
      );
      expect(
        isCoupangAffsdpLandingUrl(
          'https://www.coupang.com/vp/products/123?itemId=1',
        ),
        isFalse,
      );
      expect(isCoupangAffsdpLandingUrl(''), isFalse);
      expect(isCoupangAffsdpLandingUrl(null), isFalse);
    });
  });

  group('attachCoupangSubparamIfAffsdp', () {
    test('appends subparam only on AFFSDP', () {
      final attached = attachCoupangSubparamIfAffsdp(
        landingUrl: 'https://link.coupang.com/re/AFFSDP?lptag=abc',
        subparam: 'yr_abc123XYZ0',
      );
      final uri = Uri.parse(attached!);
      expect(uri.host, 'link.coupang.com');
      expect(uri.path.toUpperCase(), contains('/RE/AFFSDP'));
      expect(uri.queryParameters['subparam'], 'yr_abc123XYZ0');
      expect(uri.queryParameters['lptag'], 'abc');
    });

    test('does not overwrite an existing subparam', () {
      final attached = attachCoupangSubparamIfAffsdp(
        landingUrl:
            'https://link.coupang.com/re/AFFSDP?subparam=yr_alreadyHere1',
        subparam: 'yr_shouldNotWin1',
      );
      expect(
        Uri.parse(attached!).queryParameters['subparam'],
        'yr_alreadyHere1',
      );
    });

    test('returns null for short, www, missing landing, or missing token', () {
      expect(
        attachCoupangSubparamIfAffsdp(
          landingUrl: 'https://link.coupang.com/a/short',
          subparam: 'yr_abc123XYZ0',
        ),
        isNull,
      );
      expect(
        attachCoupangSubparamIfAffsdp(
          landingUrl: 'https://www.coupang.com/vp/products/1',
          subparam: 'yr_abc123XYZ0',
        ),
        isNull,
      );
      expect(
        attachCoupangSubparamIfAffsdp(
          landingUrl: 'https://link.coupang.com/re/AFFSDP',
          subparam: null,
        ),
        isNull,
      );
      expect(
        attachCoupangSubparamIfAffsdp(
          landingUrl: null,
          subparam: 'yr_abc123XYZ0',
        ),
        isNull,
      );
    });
  });

  group('coupangOpenUrlCandidates', () {
    test('priority is landing+subparam then deeplink then product then original', () {
      final candidates = coupangOpenUrlCandidates(
        landingUrl: 'https://link.coupang.com/re/AFFSDP?lptag=x',
        deeplinkUrl: 'https://link.coupang.com/a/short',
        productUrl: 'https://www.coupang.com/vp/products/1',
        originalUrl: 'https://www.coupang.com/vp/products/1?orig=1',
        subparam: 'yr_trackToken12',
      );

      expect(candidates.length, 4);
      expect(
        Uri.parse(candidates.first).queryParameters['subparam'],
        'yr_trackToken12',
      );
      expect(candidates[1], 'https://link.coupang.com/a/short');
      expect(candidates[2], 'https://www.coupang.com/vp/products/1');
      expect(candidates[3], 'https://www.coupang.com/vp/products/1?orig=1');
    });

    test('keeps short-first order when landing or subparam is missing', () {
      expect(
        coupangOpenUrlCandidates(
          landingUrl: null,
          deeplinkUrl: 'https://link.coupang.com/a/short',
          productUrl: 'https://www.coupang.com/vp/products/1',
          originalUrl: 'https://www.coupang.com/vp/products/1?orig=1',
          subparam: 'yr_trackToken12',
        ),
        <String>[
          'https://link.coupang.com/a/short',
          'https://www.coupang.com/vp/products/1',
          'https://www.coupang.com/vp/products/1?orig=1',
        ],
      );
      expect(
        coupangOpenUrlCandidates(
          landingUrl: 'https://link.coupang.com/re/AFFSDP',
          deeplinkUrl: 'https://link.coupang.com/a/short',
          productUrl: 'https://www.coupang.com/vp/products/1',
          subparam: null,
        ),
        <String>[
          'https://link.coupang.com/a/short',
          'https://www.coupang.com/vp/products/1',
        ],
      );
    });
  });

  group('coupangMarketplaceLinkArgs', () {
    test('kurly/oasis keep deeplink + product without subparam', () {
      final args = coupangMarketplaceLinkArgs(
        landingUrl: 'https://link.coupang.com/re/AFFSDP',
        deeplinkUrl: 'https://www.kurly.com/goods/1',
        productUrl: 'https://www.kurly.com/goods/1',
        originalUrl: null,
        subparam: 'yr_trackToken12',
        attachTracking: false,
      );
      expect(args.deepLinkUrl, 'https://www.kurly.com/goods/1');
      expect(args.httpsUrl, 'https://www.kurly.com/goods/1');
    });
  });

  group('CoupangProduct landingUrl', () {
    test('parses landing_url and landingUrl', () {
      final snake = CoupangProduct.fromJson(<String, dynamic>{
        'product_id': '1',
        'product_name': 'n',
        'product_price': 1000,
        'product_image': '',
        'product_url': 'https://www.coupang.com/vp/products/1',
        'landing_url': 'https://link.coupang.com/re/AFFSDP?lptag=snake',
      });
      final camel = CoupangProduct.fromJson(<String, dynamic>{
        'product_id': '2',
        'product_name': 'n',
        'product_price': 1000,
        'product_image': '',
        'product_url': 'https://www.coupang.com/vp/products/2',
        'landingUrl': 'https://link.coupang.com/re/AFFSDP?lptag=camel',
      });
      expect(snake.landingUrl, 'https://link.coupang.com/re/AFFSDP?lptag=snake');
      expect(camel.landingUrl, 'https://link.coupang.com/re/AFFSDP?lptag=camel');
    });
  });

  group('homePosterCoupangLinkArgs', () {
    test('opens AFFSDP+subparam before short url', () {
      final args = homePosterCoupangLinkArgs(
        productUrl: 'https://link.coupang.com/a/short',
        landingUrl: 'https://link.coupang.com/re/AFFSDP?lptag=x',
        deeplinkUrl: 'https://link.coupang.com/a/short',
        subparam: 'yr_trackToken12',
      );
      expect(
        Uri.parse(args.deepLinkUrl!).queryParameters['subparam'],
        'yr_trackToken12',
      );
      expect(args.httpsUrl, 'https://link.coupang.com/a/short');
    });

    test('promotes productUrl AFFSDP to landing when landingUrl is empty', () {
      final args = homePosterCoupangLinkArgs(
        productUrl: 'https://link.coupang.com/re/AFFSDP?lptag=x',
        landingUrl: null,
        deeplinkUrl: 'https://link.coupang.com/a/short',
        subparam: 'yr_trackToken12',
      );
      expect(
        Uri.parse(args.deepLinkUrl!).path.toUpperCase(),
        contains('/RE/AFFSDP'),
      );
      expect(
        Uri.parse(args.deepLinkUrl!).queryParameters['subparam'],
        'yr_trackToken12',
      );
    });
  });

  group('coupangUrlHasTrackingSubparam', () {
    test('accepts only valid yr_ tokens', () {
      expect(
        coupangUrlHasTrackingSubparam(
          'https://link.coupang.com/re/AFFSDP?subparam=yr_trackToken12',
        ),
        isTrue,
      );
      expect(
        coupangUrlHasTrackingSubparam(
          'https://link.coupang.com/re/AFFSDP?subparam=not-ours',
        ),
        isFalse,
      );
      expect(
        coupangUrlHasTrackingSubparam('https://link.coupang.com/a/short'),
        isFalse,
      );
    });
  });
}
