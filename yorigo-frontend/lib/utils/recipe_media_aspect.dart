/// 레시피 원본 영상이 가로(롱폼)인지 세로(숏폼)인지 판별한다.
///
/// 판별 우선순위
/// 1. 백엔드가 yt-dlp 로 뽑아 `source` 에 실어 준 `width`/`height`
/// 2. `source.is_short` (유튜브 `/shorts/` URL + 해상도로 백엔드가 계산)
/// 3. 원본 URL 의 `/shorts/`, `/reel/` 경로
/// 4. 플랫폼 기본값 (틱톡·릴스는 세로, 유튜브는 가로)
///
/// 카드 슬롯 비율은 원본 비율을 그대로 쓰지 않고 가로 16:9 / 세로 9:16 /
/// 정사각 1:1 로 스냅한다. 그리드에서 높이가 제각각이면 지저분해 보인다.
library;

enum RecipeMediaShape { landscape, portrait, square }

class RecipeMediaAspect {
  const RecipeMediaAspect._();

  static const double landscapeRatio = 16 / 9;
  static const double portraitRatio = 9 / 16;
  static const double squareRatio = 1;

  /// 인스타는 저장 시 4:5 로 크롭한 썸네일을 쓰므로 9:16 대신 4:5 로 보여 준다.
  static const double instagramRatio = 4 / 5;

  /// 네이버 블로그·출처 미상은 기존 카드 비율(4:5)을 유지한다.
  static const double fallbackRatio = 4 / 5;

  static Map<String, dynamic> _sourceOf(Map<String, dynamic> recipe) {
    final raw = recipe['source'];
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return const <String, dynamic>{};
  }

  static String platformOf(Map<String, dynamic> recipe) {
    final source = _sourceOf(recipe);
    final p =
        (source['platform'] ?? recipe['sourcePlatform'] ?? '')
            .toString()
            .toLowerCase()
            .trim();
    if (p.isNotEmpty) return p;
    final url = sourceUrlOf(recipe).toLowerCase();
    if (url.contains('youtube.com') || url.contains('youtu.be')) {
      return 'youtube';
    }
    if (url.contains('instagram.com')) return 'instagram';
    if (url.contains('tiktok.com')) return 'tiktok';
    if (url.contains('blog.naver.com')) return 'naver_blog';
    return '';
  }

  static String sourceUrlOf(Map<String, dynamic> recipe) {
    final source = _sourceOf(recipe);
    final direct = (recipe['sourceUrl'] ?? source['url'] ?? '').toString();
    return direct.trim();
  }

  /// 세로 영상이면 true, 가로면 false, 판단 근거가 없으면 null.
  static bool? isShortForm(Map<String, dynamic> recipe) {
    final source = _sourceOf(recipe);

    final width = (source['width'] as num?)?.toDouble();
    final height = (source['height'] as num?)?.toDouble();
    if (width != null && height != null && width > 0 && height > 0) {
      final ratio = width / height;
      if (ratio >= 1.2) return false;
      if (ratio <= 0.85) return true;
      return null; // 정사각에 가까움
    }

    final isShort = source['is_short'];
    if (isShort is bool) return isShort;

    final url = sourceUrlOf(recipe).toLowerCase();
    if (url.contains('/shorts/')) return true;
    if (url.contains('/reel/') || url.contains('/reels/')) return true;

    final platform = platformOf(recipe);
    if (platform.contains('tiktok')) return true;
    if (platform.contains('instagram')) return true;
    if (platform.contains('youtube')) return false;
    return null;
  }

  static RecipeMediaShape shapeOf(Map<String, dynamic> recipe) {
    final short = isShortForm(recipe);
    if (short == true) return RecipeMediaShape.portrait;
    if (short == false) return RecipeMediaShape.landscape;
    return RecipeMediaShape.square;
  }

  /// 카드 썸네일 슬롯의 가로/세로 비율(width / height).
  static double aspectRatioOf(Map<String, dynamic> recipe) {
    final platform = platformOf(recipe);
    switch (shapeOf(recipe)) {
      case RecipeMediaShape.landscape:
        return landscapeRatio;
      case RecipeMediaShape.portrait:
        if (platform.contains('instagram')) return instagramRatio;
        return portraitRatio;
      case RecipeMediaShape.square:
        if (platform.contains('instagram')) return instagramRatio;
        if (platform.contains('naver')) return fallbackRatio;
        return fallbackRatio;
    }
  }

  static bool isLandscape(Map<String, dynamic> recipe) =>
      shapeOf(recipe) == RecipeMediaShape.landscape;
}
