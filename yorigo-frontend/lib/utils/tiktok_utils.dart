import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// URL이 TikTok URL인지 확인합니다.
bool isTikTokUrl(String url) {
  if (url.isEmpty) return false;
  final lower = url.toLowerCase();
  return lower.contains('tiktok.com') || lower.contains('vt.tiktok.com');
}

/// 파싱 시점에 저장된 TikTok CDN 썸네일(서명 만료되면 403)인지 여부.
bool isTikTokCdnThumbnailUrl(String url) {
  if (url.isEmpty) return false;
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  if (host.isEmpty) return false;
  return host.contains('tiktokcdn') ||
      host.contains('tiktokv.com') ||
      host.contains('ibyteimg') ||
      host.contains('muscdn') ||
      host.contains('byteoversea');
}

/// TikTok oEmbed API 응답에서 추출한 임베드 정보.
class TikTokOEmbedResult {
  /// `<blockquote class="tiktok-embed">...</blockquote><script src="...embed.js">`
  /// 형태의 임베드 HTML.
  final String html;
  final String? title;
  final String? authorName;
  final String? thumbnailUrl;

  const TikTokOEmbedResult({
    required this.html,
    this.title,
    this.authorName,
    this.thumbnailUrl,
  });
}

/// TikTok oEmbed 결과 메모리 캐시.
///
/// 같은 URL을 같은 세션 안에서 다시 호출할 때 네트워크 호출을 생략한다.
/// 영상별 캐시 키이고, 영상마다 한 번씩만 호출되므로 LRU 크기 제한은 보수적으로 둔다.
final _Map<String, TikTokOEmbedResult> _cache = _Map<String, TikTokOEmbedResult>(
  maxEntries: 64,
);

class _Map<K, V> {
  final int maxEntries;
  final _entries = <K, V>{};
  _Map({required this.maxEntries});

  V? operator [](K key) {
    final value = _entries.remove(key);
    if (value != null) {
      _entries[key] = value;
    }
    return value;
  }

  void operator []=(K key, V value) {
    _entries.remove(key);
    _entries[key] = value;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }
}

/// TikTok 공식 oEmbed API를 호출해 임베드 HTML을 가져옵니다.
///
/// - 인증 토큰 불필요·공개 API.
/// - 동일 URL은 메모리에 캐시.
/// - 실패 시 null 반환 → 호출부는 외부 링크 폴백 처리.
Future<TikTokOEmbedResult?> fetchTikTokOEmbed(String videoUrl) async {
  final trimmed = videoUrl.trim();
  if (trimmed.isEmpty || !isTikTokUrl(trimmed)) return null;

  final cached = _cache[trimmed];
  if (cached != null) return cached;

  final oembedUri = Uri.parse(
    'https://www.tiktok.com/oembed?url=${Uri.encodeQueryComponent(trimmed)}',
  );

  try {
    final response = await http
        .get(oembedUri, headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 8));

    if (response.statusCode != 200) {
      debugPrint(
        '[tiktok_utils] oEmbed non-200: ${response.statusCode} for $trimmed',
      );
      return null;
    }

    final data = jsonDecode(response.body);
    if (data is! Map) return null;

    final html = data['html'];
    if (html is! String || html.isEmpty) return null;

    final result = TikTokOEmbedResult(
      html: html,
      title: data['title'] is String ? data['title'] as String : null,
      authorName:
          data['author_name'] is String ? data['author_name'] as String : null,
      thumbnailUrl: data['thumbnail_url'] is String
          ? data['thumbnail_url'] as String
          : null,
    );
    _cache[trimmed] = result;
    return result;
  } catch (e) {
    debugPrint('[tiktok_utils] oEmbed fetch failed: $e');
    return null;
  }
}

/// oEmbed `html` 조각을 WebView가 바로 로드할 수 있는 완전한 HTML 도큐먼트로 감쌉니다.
///
/// - 마진/스크롤 제거
/// - viewport meta로 모바일 폭에 맞춤
/// - 배경 검정으로 레터박싱 자연스럽게
/// - [scale]로 임베드 전체를 CSS `transform: scale`로 확대해 1:1 박스에서도
///   영상 영역이 박스를 거의 꽉 채우도록 함. 1.0이면 기본, 1.3~1.5 정도가
///   영상이 자연스럽게 커 보이는 값. 너무 키우면 박스 밖으로 컨텐츠가 넘쳐
///   잘려 나간다 (`overflow: hidden`으로 잘림 처리).
/// - [containInBox]이면 임베드를 네이티브 크기(~325px)로 그린 뒤 래퍼만
///   `transform: scale`로 줄인다. iframe 크기/zoom을 건드리면 재생이 깨진다.
///   iOS는 맞춘 뒤 영상만 212px 키우고, 위가 잘리지 않게 56px 내린다.
String wrapTikTokEmbedHtml(
  String embedHtml, {
  double scale = 1.0,
  bool containInBox = false,
}) {
  if (containInBox) {
    return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
<style>
  html, body {
    margin: 0; padding: 0; background: #000;
    overflow: hidden; width: 100%; height: 100%;
  }
  .tiktok-slot {
    width: 100%; height: 100%;
    display: flex; align-items: center; justify-content: center;
    overflow: hidden; background: #000;
  }
  .tiktok-scale-wrap {
    display: flex; align-items: center; justify-content: center;
    transform-origin: center center;
    flex: 0 0 auto;
  }
  .tiktok-embed { margin: 0 !important; }
</style>
</head>
<body>
<div class="tiktok-slot">
  <div class="tiktok-scale-wrap">
$embedHtml
  </div>
</div>
<script>
(function(){
  var timer = 0;
  var readySent = false;
  var iframeSeenAt = 0;
  function nativeSize(wrap, embed){
    var w = Math.max(embed.offsetWidth || 0, wrap.scrollWidth || 0, 325);
    var h = Math.max(embed.offsetHeight || 0, wrap.scrollHeight || 0, 1);
    if (w < 200) w = 325;
    if (h < 480) h = 700;
    return {w:w, h:h};
  }
  function iframeReady(){
    var iframe = document.querySelector('iframe');
    if (!iframe) return false;
    var r = iframe.getBoundingClientRect();
    var w = Math.max(iframe.offsetWidth || 0, r.width || 0);
    var h = Math.max(iframe.offsetHeight || 0, r.height || 0);
    return w >= 240 && h >= 400;
  }
  function notifyReady(){
    if (readySent) return;
    if (!iframeReady()) return;
    if (!iframeSeenAt) return;
    var wait = 600 - (Date.now() - iframeSeenAt);
    if (wait > 0) {
      setTimeout(fit, wait + 20);
      return;
    }
    readySent = true;
    try { YorigoTtFit.postMessage('ready'); } catch (e) {}
  }
  function fit(){
    if (readySent) return;
    var wrap = document.querySelector('.tiktok-scale-wrap');
    var embed = document.querySelector('.tiktok-embed') || document.querySelector('iframe');
    if (!wrap || !embed) return;
    if (iframeReady() && !iframeSeenAt) iframeSeenAt = Date.now();
    var size = nativeSize(wrap, embed);
    var w = size.w, h = size.h;
    var vw = window.__yorigoTtFitW || window.innerWidth;
    var vh = window.__yorigoTtFitH || window.innerHeight;
    if (vw < 8 || vh < 8) return;
    var pad = Math.min(vw, vh) * 0.16;
    var s = Math.min((vw - pad * 2) / w, (vh - pad * 2) / h);
    if (!(s > 0) || !isFinite(s)) s = 0.4;
    // 박스는 그대로 두고 영상만 212px 키운 뒤, 위가 잘리지 않게 56px 내린다.
    s = s + 212 / h;
    var my = (s - 1) * h / 2;
    var mx = (s - 1) * w / 2;
    wrap.style.width = w + 'px';
    wrap.style.height = h + 'px';
    wrap.style.transformOrigin = 'center center';
    wrap.style.webkitTransform = 'translateY(56px) scale(' + s + ')';
    wrap.style.transform = 'translateY(56px) scale(' + s + ')';
    wrap.style.margin = my + 'px ' + mx + 'px';
    notifyReady();
  }
  function scheduleFit(){
    if (readySent) return;
    if (timer) return;
    timer = setTimeout(function(){ timer = 0; fit(); }, 80);
  }
  window.__yorigoTtFit = fit;
  window.addEventListener('load', fit);
  window.addEventListener('resize', scheduleFit);
  setTimeout(fit, 200);
  setTimeout(fit, 700);
  setTimeout(fit, 1600);
  try {
    new MutationObserver(scheduleFit).observe(document.body, {childList:true, subtree:true});
  } catch (e) {}
})();
</script>
</body>
</html>
''';
  }

  final scaleStr = scale.toStringAsFixed(2);
  return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
<style>
  html, body { margin: 0; padding: 0; background: #000; overflow: hidden; height: 100%; }
  body { display: flex; align-items: center; justify-content: center; min-height: 100vh; }
  .tiktok-scale-wrap {
    transform: scale($scaleStr);
    transform-origin: center center;
    display: flex;
    align-items: center;
    justify-content: center;
  }
  .tiktok-embed { margin: 0 !important; max-width: 100% !important; min-width: 0 !important; }
</style>
</head>
<body>
<div class="tiktok-scale-wrap">
$embedHtml
</div>
</body>
</html>
''';
}
