/// Instagram URL에서 shortcode를 추출하는 유틸리티 함수들.
///
/// 지원하는 URL 형식:
/// - https://www.instagram.com/reel/{shortcode}/
/// - https://www.instagram.com/reels/{shortcode}/
/// - https://www.instagram.com/p/{shortcode}/
/// - https://www.instagram.com/tv/{shortcode}/
/// - 위 경로 + 쿼리 스트링/추가 세그먼트
///
/// Returns null if shortcode를 찾을 수 없는 경우.
({String type, String shortcode})? extractInstagramShortcode(String url) {
  if (url.isEmpty) return null;
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return null;
  if (!uri.host.toLowerCase().contains('instagram.com')) return null;

  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  for (var i = 0; i < segments.length - 1; i++) {
    final type = segments[i].toLowerCase();
    if (type == 'reel' || type == 'reels' || type == 'p' || type == 'tv') {
      final shortcode = segments[i + 1];
      // shortcode는 보통 11자 내외 영숫자/_/-.
      if (RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(shortcode)) {
        // `reels`는 `reel`과 동일하게 처리 — 임베드 경로는 둘 다 동일.
        final normalizedType = type == 'reels' ? 'reel' : type;
        return (type: normalizedType, shortcode: shortcode);
      }
    }
  }
  return null;
}

/// URL이 Instagram URL인지 확인합니다.
bool isInstagramUrl(String url) {
  if (url.isEmpty) return false;
  final lower = url.toLowerCase();
  return lower.contains('instagram.com') || lower.contains('instagr.am');
}

/// shortcode + type으로 Instagram 임베드 페이지 URL을 생성합니다.
///
/// [captioned]가 true면 캡션 박스가 함께 표시되는 `embed/captioned/` 사용.
/// 기본은 영상 영역만 깔끔히 노출되는 `embed/`.
String buildInstagramEmbedUrl({
  required String type,
  required String shortcode,
  bool captioned = false,
}) {
  final path = captioned ? 'embed/captioned' : 'embed';
  return 'https://www.instagram.com/$type/$shortcode/$path/';
}
