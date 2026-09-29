import 'dart:math';

/// 쿠팡 파트너스 주문 API `subParam`에 실리는 유저 추적 토큰.
const String kCoupangSubparamPrefix = 'yr_';
const int kCoupangSubparamTokenMin = 10;
const int kCoupangSubparamTokenMax = 16;

/// 신규 발급 시 쓰는 토큰 길이. 허용 범위(10~16) 안.
const int kCoupangSubparamTokenLen = 12;

const String _alnum =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

final RegExp _httpScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://');

/// `yr_` + 영문숫자 10~16자. Firebase uid는 절대 쓰지 않는다.
String generateCoupangSubparam([Random? random]) {
  final r = random ?? Random.secure();
  final buf = StringBuffer(kCoupangSubparamPrefix);
  for (var i = 0; i < kCoupangSubparamTokenLen; i++) {
    buf.write(_alnum[r.nextInt(_alnum.length)]);
  }
  return buf.toString();
}

/// 저장된 값이 우리 발급 규칙과 맞는지. 기존 값은 재발급하지 않으므로 조회용.
bool isValidCoupangSubparam(String? value) {
  final token = (value ?? '').trim();
  if (!token.startsWith(kCoupangSubparamPrefix)) return false;
  final body = token.substring(kCoupangSubparamPrefix.length);
  if (body.length < kCoupangSubparamTokenMin ||
      body.length > kCoupangSubparamTokenMax) {
    return false;
  }
  return RegExp(r'^[a-zA-Z0-9]+$').hasMatch(body);
}

/// `link.coupang.com/re/AFFSDP` 랜딩만 추적에 쓴다. 단축·www는 제외.
bool isCoupangAffsdpLandingUrl(String? url) {
  final raw = (url ?? '').trim();
  if (raw.isEmpty) return false;
  final parsed = Uri.tryParse(_ensureHttpScheme(raw));
  if (parsed == null || parsed.host.isEmpty) return false;
  if (parsed.host.toLowerCase() != 'link.coupang.com') return false;
  return parsed.path.toUpperCase().contains('/RE/AFFSDP');
}

/// AFFSDP 랜딩에 `subparam`을 붙인다. 이미 있으면 덮어쓰지 않는다.
/// 조건이 안 맞으면 null (호출부는 단축/원본으로 폴백).
String? attachCoupangSubparamIfAffsdp({
  required String? landingUrl,
  required String? subparam,
}) {
  final landing = (landingUrl ?? '').trim();
  final token = (subparam ?? '').trim();
  if (landing.isEmpty || token.isEmpty) return null;
  if (!isCoupangAffsdpLandingUrl(landing)) return null;

  final uri = Uri.tryParse(_ensureHttpScheme(landing));
  if (uri == null) return null;
  if (uri.queryParameters.keys.any((k) => k.toLowerCase() == 'subparam')) {
    return uri.toString();
  }

  final params = Map<String, String>.from(uri.queryParameters);
  params['subparam'] = token;
  return uri.replace(queryParameters: params).toString();
}

/// 쿠팡 상품 열기 후보.
/// 우선순위: AFFSDP+subparam → 단축(deeplink) → productUrl → originalUrl.
/// 단축·www에는 subparam을 붙이지 않는다.
List<String> coupangOpenUrlCandidates({
  String? landingUrl,
  String? deeplinkUrl,
  String? productUrl,
  String? originalUrl,
  String? subparam,
}) {
  final tracked = attachCoupangSubparamIfAffsdp(
    landingUrl: landingUrl,
    subparam: subparam,
  );
  final seen = <String>{};
  final out = <String>[];

  void add(String? raw) {
    final value = (raw ?? '').trim();
    if (value.isEmpty) return;
    if (seen.add(value)) out.add(value);
  }

  add(tracked);
  add(deeplinkUrl);
  add(productUrl);
  add(originalUrl);
  return out;
}

/// 연  URL에 우리 subparam이 실렸는지.
bool coupangUrlHasTrackingSubparam(String? url) {
  final raw = (url ?? '').trim();
  if (raw.isEmpty) return false;
  final uri = Uri.tryParse(_ensureHttpScheme(raw));
  if (uri == null) return false;
  for (final entry in uri.queryParameters.entries) {
    if (entry.key.toLowerCase() != 'subparam') continue;
    return isValidCoupangSubparam(entry.value);
  }
  return false;
}

/// 홈 포스터 상품. landingUrl이 있으면 그걸 먼저 열고, 없으면 productUrl이
/// AFFSDP일 때 랜딩으로 승격한다. 단축 URL은 그 다음이다.
({String? deepLinkUrl, String? httpsUrl}) homePosterCoupangLinkArgs({
  String? productUrl,
  String? landingUrl,
  String? deeplinkUrl,
  String? searchQuery,
  String? fallbackName,
  String? subparam,
}) {
  final direct = (productUrl ?? '').trim();
  final explicitLanding = (landingUrl ?? '').trim();
  final resolvedLanding = explicitLanding.isNotEmpty
      ? explicitLanding
      : (isCoupangAffsdpLandingUrl(direct) ? direct : null);
  final query = (searchQuery ?? fallbackName ?? '').trim();
  final searchUrl = query.isEmpty
      ? null
      : Uri.https('www.coupang.com', '/np/search', <String, String>{'q': query})
          .toString();
  final productOrSearch = direct.isNotEmpty ? direct : searchUrl;
  return coupangMarketplaceLinkArgs(
    landingUrl: resolvedLanding,
    deeplinkUrl: deeplinkUrl,
    productUrl: productOrSearch,
    originalUrl: searchUrl,
    subparam: subparam,
  );
}

/// [openMarketplaceLink]에 넘길 deep/https. 쿠팡만 추적 URL을 맨 앞에 둔다.
({String? deepLinkUrl, String? httpsUrl}) coupangMarketplaceLinkArgs({
  required String? landingUrl,
  required String? deeplinkUrl,
  required String? productUrl,
  required String? originalUrl,
  required String? subparam,
  bool attachTracking = true,
}) {
  final fallbackHttps =
      (productUrl ?? '').trim().isNotEmpty ? productUrl : originalUrl;
  if (!attachTracking) {
    return (deepLinkUrl: deeplinkUrl, httpsUrl: fallbackHttps);
  }

  final candidates = coupangOpenUrlCandidates(
    landingUrl: landingUrl,
    deeplinkUrl: deeplinkUrl,
    productUrl: productUrl,
    originalUrl: originalUrl,
    subparam: subparam,
  );
  if (candidates.isEmpty) {
    return (deepLinkUrl: deeplinkUrl, httpsUrl: fallbackHttps);
  }
  return (
    deepLinkUrl: candidates.first,
    httpsUrl: candidates.length > 1 ? candidates[1] : fallbackHttps,
  );
}

String _ensureHttpScheme(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty || _httpScheme.hasMatch(trimmed)) return trimmed;
  return 'https://$trimmed';
}
