import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/constants/home_poster_curations.dart';
import 'package:yorigo/utils/naver_brandconnect_link.dart';

void main() {
  group('isNaverBrandConnectAffiliateUrl', () {
    test('accepts naver.me and brandconnect landing', () {
      expect(
        isNaverBrandConnectAffiliateUrl('https://naver.me/xG0ejV3u'),
        isTrue,
      );
      expect(
        isNaverBrandConnectAffiliateUrl(
          'https://brandconnect.naver.com/affiliates/982169764941664?channelProductNo=12144877070',
        ),
        isTrue,
      );
    });

    test('rejects coupang and kurly so they do not skip marketplace open', () {
      expect(
        isNaverBrandConnectAffiliateUrl(
          'https://link.coupang.com/a/gbQ29L6CUm',
        ),
        isFalse,
      );
      expect(
        isNaverBrandConnectAffiliateUrl(
          'https://lounge.kurly.com/link/rSjY-rFsb',
        ),
        isFalse,
      );
    });
  });

  group('resolveBrandConnectLaunchUri', () {
    test('passthrough brandconnect landing without resolver', () async {
      final uri = Uri.parse(
        'https://brandconnect.naver.com/affiliates/982169764941664?channelProductNo=12144877070',
      );
      expect(await resolveBrandConnectLaunchUri(uri), uri);
    });

    test('expands naver.me via injected resolver', () async {
      final short = Uri.parse('https://naver.me/xG0ejV3u');
      final landing = Uri.parse(
        'https://brandconnect.naver.com/affiliates/982169764941664?channelProductNo=12144877070',
      );
      final resolved = await resolveBrandConnectLaunchUri(
        short,
        resolveShort: (_) async => landing,
      );
      expect(resolved, landing);
    });

    test('keeps short link if resolver throws or returns non-affiliate', () async {
      final short = Uri.parse('https://naver.me/xG0ejV3u');
      expect(
        await resolveBrandConnectLaunchUri(
          short,
          resolveShort: (_) async => throw Exception('network'),
        ),
        short,
      );
      expect(
        await resolveBrandConnectLaunchUri(
          short,
          resolveShort: (_) async => Uri.parse('https://example.com/x'),
        ),
        short,
      );
    });
  });

  group('home poster fallback products', () {
    test('mynormal products use BrandConnect affiliate landing URLs', () {
      final curation = HomePosterCurations.byId('mynormal_low_sugar');
      expect(curation, isNotNull);
      expect(curation!.products, isNotEmpty);
      for (final product in curation.products) {
        final url = product.productUrl ?? '';
        expect(isNaverBrandConnectAffiliateUrl(url), isTrue, reason: product.id);
        expect(url, contains('brandconnect.naver.com/affiliates/'));
        expect(url, contains('channelProductNo='));
      }
    });
  });
}
