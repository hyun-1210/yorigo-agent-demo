import 'package:http/http.dart' as http;

/// 네이버 BrandConnect / 쇼핑 제휴 링크로 보고 쿠팡 WebView를 타면 안 되는 URL인지.
bool isNaverBrandConnectAffiliateUrl(String url) {
  final lower = url.trim().toLowerCase();
  if (lower.isEmpty) return false;
  return lower.contains('naver.me') ||
      lower.contains('brandconnect.naver.com') ||
      lower.contains('smartstore.naver.com') ||
      lower.contains('brand.naver.com') ||
      lower.contains('shopping.naver.com');
}

bool isNaverMeHost(String? host) {
  final h = (host ?? '').toLowerCase();
  return h == 'naver.me' || h.endsWith('.naver.me');
}

/// `naver.me` 단축링크를 BrandConnect 랜딩으로 풀어 네이버 앱 App Link 가로채기를 피한다.
///
/// 실패하면 원본 URI를 그대로 반환한다. Custom Tabs에서 단축링크를 열어도
/// 외부 앱 실행보다는 제휴 JS가 돌 가능성이 높다.
Future<Uri> resolveBrandConnectLaunchUri(
  Uri uri, {
  Future<Uri?> Function(Uri shortUri)? resolveShort,
  Duration timeout = const Duration(seconds: 4),
}) async {
  if (!isNaverMeHost(uri.host)) return uri;
  try {
    final resolved = resolveShort != null
        ? await resolveShort(uri)
        : await followNaverMeRedirect(uri, timeout: timeout);
    if (resolved == null) return uri;
    if (!isNaverBrandConnectAffiliateUrl(resolved.toString())) return uri;
    return resolved;
  } catch (_) {
    return uri;
  }
}

/// HTTP redirect를 따라가 최종 URL을 반환한다. 호출 측에서 클라이언트 주입 가능.
Future<Uri?> followNaverMeRedirect(
  Uri shortUri, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 4),
}) async {
  if (!isNaverMeHost(shortUri.host)) return shortUri;
  final owned = client ?? http.Client();
  try {
    final request = http.Request('GET', shortUri)
      ..followRedirects = true
      ..maxRedirects = 5
      ..headers['User-Agent'] =
          'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36'
      ..headers['Accept'] = 'text/html';
    final streamed = await owned.send(request).timeout(timeout);
    final finalUrl = streamed.request?.url;
    try {
      await streamed.stream.drain<void>().timeout(
        const Duration(milliseconds: 800),
        onTimeout: () {},
      );
    } catch (_) {}
    return finalUrl;
  } finally {
    if (client == null) {
      owned.close();
    }
  }
}
