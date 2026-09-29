// 네이버 블로그 URL에서 (blogId, logNo)를 추출하고 dedup 키를 만드는 유틸.
//
// 지원하는 URL 형식:
// - https://blog.naver.com/{blogId}/{logNo}
// - https://m.blog.naver.com/{blogId}/{logNo}
// - https://blog.naver.com/PostView.naver?blogId={blogId}&logNo={logNo}
// - https://m.blog.naver.com/PostView.naver|nhn?blogId=...&logNo=...
// - https://naver.me/{shortcode} → 단축. 클라에서는 redirect 추적 불가.
// - https://link.naver.com/bridge?url=... → 네이버 앱 공유 래퍼 (unwrap 지원)
//
// 백엔드 `backend/services/naver_blog_url.py`와 같은 platform_key를 만들어야
// dedup이 어긋나지 않으므로 형식을 정확히 일치시킬 것.

/// URL이 네이버 블로그(또는 단축/래퍼) 도메인을 가리키는지.
bool isNaverBlogUrl(String url) {
  if (url.isEmpty) return false;
  final lower = url.toLowerCase();
  return lower.contains('blog.naver.com') ||
      lower.contains('m.blog.naver.com') ||
      lower.contains('naver.me') ||
      lower.contains('link.naver.com');
}

String _cleanInputUrl(String url) {
  var s = url.trim();
  while (s.isNotEmpty && "'\"<>)]}".contains(s[s.length - 1])) {
    s = s.substring(0, s.length - 1).trimRight();
  }
  return s;
}

String _maybeUnquoteIteratively(String value, {int maxRounds = 4}) {
  var prev = value;
  for (var i = 0; i < maxRounds; i++) {
    final decoded = Uri.decodeComponent(prev);
    if (decoded == prev) break;
    prev = decoded;
  }
  return prev;
}

bool _isBlogOrShortHost(String text) {
  final lower = text.toLowerCase();
  return lower.contains('blog.naver.com') ||
      lower.contains('m.blog.naver.com') ||
      lower.contains('naver.me');
}

/// 래퍼 URL(link.naver.com/bridge 등)에서 실제 블로그 URL을 꺼낸다.
String? _extractQueryBlogUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final host = uri.host.toLowerCase();
  if (!host.contains('link.naver.com')) return null;

  final candidates = <String>[];
  for (final key in ['url', 'link', 'target', 'redirect']) {
    final value = uri.queryParameters[key];
    if (value != null && value.isNotEmpty) {
      candidates.add(_maybeUnquoteIteratively(value));
    }
  }

  final dst = uri.queryParameters['dst'];
  if (dst != null && dst.isNotEmpty) {
    final decodedDst = _maybeUnquoteIteratively(dst);
    candidates.add(decodedDst);
    final inner = Uri.tryParse(decodedDst);
    if (inner != null) {
      for (final key in ['url', 'link', 'target']) {
        final value = inner.queryParameters[key];
        if (value != null && value.isNotEmpty) {
          candidates.add(_maybeUnquoteIteratively(value));
        }
      }
    }
  }

  for (final cand in candidates) {
    final c = cand.trim();
    if (c.isNotEmpty && _isBlogOrShortHost(c)) return c;
  }
  return null;
}

final _blogPathRe = RegExp(
  r'https?://(?:m\.)?blog\.naver\.com/([^/?#\s<>]+)/(\d+)',
  caseSensitive: false,
);

final _postViewUrlRe = RegExp(
  r'https?://(?:m\.)?blog\.naver\.com/PostView\.(?:naver|nhn)\?[^#\s<>]*',
  caseSensitive: false,
);

/// 문자열 어디에든 박혀 있는 블로그 단일 글 URL을 regex로 찾는다.
String? _findEmbeddedBlogUrl(String text) {
  final pathMatch = _blogPathRe.firstMatch(text);
  if (pathMatch != null) {
    return 'https://m.blog.naver.com/${pathMatch.group(1)}/${pathMatch.group(2)}';
  }

  for (final match in _postViewUrlRe.allMatches(text)) {
    final uri = Uri.tryParse(match.group(0)!);
    if (uri == null) continue;
    final blogId = uri.queryParameters['blogId'];
    final logNo = uri.queryParameters['logNo'];
    if (blogId != null &&
        blogId.isNotEmpty &&
        logNo != null &&
        RegExp(r'^\d+$').hasMatch(logNo)) {
      return 'https://m.blog.naver.com/$blogId/$logNo';
    }
  }
  return null;
}

/// 이미 정리된 URL 문자열에서 blogId/logNo만 추출 (unwrap 재진입 없음).
({String blogId, String logNo})? _extractNaverBlogIdsFromCleaned(String cleaned) {
  if (cleaned.isEmpty) return null;
  final uri = Uri.tryParse(cleaned);
  if (uri == null) return null;
  if (!uri.host.toLowerCase().contains('blog.naver.com')) return null;

  // 1) PostView.naver|nhn?blogId=xxx&logNo=yyy
  final qBlogId = uri.queryParameters['blogId'];
  final qLogNo = uri.queryParameters['logNo'];
  if (qBlogId != null &&
      qBlogId.isNotEmpty &&
      qLogNo != null &&
      qLogNo.isNotEmpty &&
      RegExp(r'^\d+$').hasMatch(qLogNo)) {
    return (blogId: qBlogId, logNo: qLogNo);
  }

  // 2) /{blogId}/{logNo}
  final segments =
      uri.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
  if (segments.length == 2) {
    final blogId = segments[0];
    final logNo = segments[1];
    if (blogId.isNotEmpty && RegExp(r'^\d+$').hasMatch(logNo)) {
      return (blogId: blogId, logNo: logNo);
    }
  }

  return null;
}

/// 단축·래퍼 URL을 풀어 실제 블로그 글 URL로 바꾼다.
///
/// ``naver.me`` 단축 URL은 클라에서 redirect 추적이 불가하므로 그대로 둔다.
/// 백엔드 `resolve_short_url`과 동일한 unwrap 규칙을 따른다.
String unwrapNaverBlogUrl(String url) {
  var current = _cleanInputUrl(url);
  if (current.isEmpty) return current;

  for (var i = 0; i < 6; i++) {
    var changed = false;

    final wrapped = _extractQueryBlogUrl(current);
    if (wrapped != null && wrapped != current) {
      current = wrapped;
      changed = true;
    }

    // extractNaverBlogIds()는 내부에서 unwrap을 호출하므로 여기서 쓰면 무한 재귀.
    if (_extractNaverBlogIdsFromCleaned(current) == null) {
      final embedded = _findEmbeddedBlogUrl(current);
      if (embedded != null && embedded != current) {
        current = embedded;
        changed = true;
      }
    }

    if (!changed) break;
  }

  return current;
}

/// 네이버 블로그 단일 글 URL에서 ``(blogId, logNo)`` 추출.
///
/// 단축 URL(`naver.me/...`)은 redirect 추적이 필요하므로 클라에서는 null을
/// 반환한다. 백엔드가 정규화한 URL로 호출하면 정상 추출된다.
({String blogId, String logNo})? extractNaverBlogIds(String url) {
  final cleaned = unwrapNaverBlogUrl(url);
  return _extractNaverBlogIdsFromCleaned(cleaned);
}

/// 파싱하기 좋은 모바일 페이지 URL을 만든다.
String toMobileNaverBlogUrl(String blogId, String logNo) {
  return 'https://m.blog.naver.com/$blogId/$logNo';
}

/// Firestore dedup용 키. 형식: ``"{blogId}__{logNo}"``.
///
/// 백엔드 `to_platform_key`와 정확히 동일한 형식이어야 한다.
String toNaverBlogPlatformKey(String blogId, String logNo) {
  return '${blogId}__$logNo';
}
