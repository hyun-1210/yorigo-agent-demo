import 'package:flutter/foundation.dart' show kIsWeb;
import '../config/environment_config.dart';

class RecipeThumbnailResolver {
  const RecipeThumbnailResolver._();

  /// Resolve recipe thumbnail URL with a single, shared priority.
  ///
  /// Priority:
  /// 0) thumbnailUrlCropped
  /// 1) thumbnailUrlLarge
  /// 2) thumbnailUrl
  /// 3) thumbnail_url (legacy snake_case compatibility)
  /// 4) nested recipe.thumbnailUrl / recipe.thumbnail_url
  /// 5) source.thumbnail / source.thumbnail_url
  ///
  /// On Flutter Web, Instagram CDN URLs are automatically proxied through
  /// the backend to avoid CORS blocks.
  static String resolve(
    Map<String, dynamic> recipe, {
    bool includeCropped = true,
    bool preferCroppedForInstagram = true,
  }) {
    String pick(dynamic value) => (value as String?)?.trim() ?? '';
    // 네이버 블로그 레시피의 og:image 는 §30 사적복제 안전구간 안에서만 — 즉
    // 본인 디바이스 로컬에서 머지된 경우에만 사용한다. RecipeService 가 본인
    // 로컬 본문에서 og_image_url 을 꺼내 `_localThumbnailUrl` (`_` prefix 는
    // Firestore 에 다시 쓰지 않는다는 컨벤션) 으로 주입한다. Firestore 에 잘못
    // 남아 있는 외부 URL 은 무시한다.
    if (_isNaverBlogRecipe(recipe)) {
      final localOnly = pick(recipe['_localThumbnailUrl']);
      return localOnly;
    }
    final isInstagram = _isInstagramRecipe(recipe);
    final isInstagramOrTikTok = _isInstagramOrTikTokRecipe(recipe);

    // 인스타/틱톡은 목록 카드에서 원본 비율 느낌을 유지하기 위해
    // storage 200x200(card)보다 large를 우선 사용한다.
    // (없으면 기존 카드 URL로 fallback)
    if (includeCropped &&
        (!isInstagramOrTikTok || (preferCroppedForInstagram && isInstagram))) {
      final cropped = pick(recipe['thumbnailUrlCropped']);
      if (cropped.isNotEmpty) return _maybeProxy(cropped);
    }

    final large = pick(recipe['thumbnailUrlLarge']);
    if (large.isNotEmpty) return _maybeProxy(large);

    final card = pick(recipe['thumbnailUrl']);
    if (card.isNotEmpty) return _maybeProxy(card);

    final legacyTop = pick(recipe['thumbnail_url']);
    if (legacyTop.isNotEmpty) return _maybeProxy(legacyTop);

    final nestedRecipe = recipe['recipe'];
    if (nestedRecipe is Map) {
      final nestedRecipeMap = Map<String, dynamic>.from(nestedRecipe);
      final nestedCard = pick(nestedRecipeMap['thumbnailUrl']);
      if (nestedCard.isNotEmpty) return _maybeProxy(nestedCard);
      final nestedLegacy = pick(nestedRecipeMap['thumbnail_url']);
      if (nestedLegacy.isNotEmpty) return _maybeProxy(nestedLegacy);
    }

    final source = recipe['source'];
    if (source is Map) {
      final sourceMap = Map<String, dynamic>.from(source);
      final sourceThumb = pick(sourceMap['thumbnail']);
      if (sourceThumb.isNotEmpty) return _maybeProxy(sourceThumb);
      final sourceLegacy = pick(sourceMap['thumbnail_url']);
      if (sourceLegacy.isNotEmpty) return _maybeProxy(sourceLegacy);
    }

    return '';
  }

  static bool _isInstagramOrTikTokRecipe(Map<String, dynamic> recipe) {
    final source = recipe['source'];
    final sourceMap = source is Map ? Map<String, dynamic>.from(source) : null;
    final platform =
        (sourceMap?['platform'] as String? ??
                recipe['platform'] as String? ??
                '')
            .toLowerCase()
            .trim();
    if (platform.contains('instagram') || platform.contains('tiktok')) {
      return true;
    }

    final sourceUrl =
        (recipe['sourceUrl'] as String? ?? sourceMap?['url'] as String? ?? '')
            .toLowerCase()
            .trim();
    return sourceUrl.contains('instagram.com') ||
        sourceUrl.contains('instagr.am') ||
        sourceUrl.contains('tiktok.com') ||
        sourceUrl.contains('vt.tiktok.com');
  }

  static bool _isNaverBlogRecipe(Map<String, dynamic> recipe) {
    final source = recipe['source'];
    final sourceMap = source is Map ? Map<String, dynamic>.from(source) : null;
    final platform =
        (sourceMap?['platform'] as String? ??
                recipe['platform'] as String? ??
                '')
            .toLowerCase()
            .trim();
    if (platform == 'naver_blog' || platform.contains('naver')) return true;
    final sourceUrl =
        (recipe['sourceUrl'] as String? ?? sourceMap?['url'] as String? ?? '')
            .toLowerCase()
            .trim();
    return sourceUrl.contains('blog.naver.com') ||
        sourceUrl.contains('m.blog.naver.com') ||
        sourceUrl.contains('naver.me') ||
        sourceUrl.contains('link.naver.com');
  }

  static bool _isInstagramRecipe(Map<String, dynamic> recipe) {
    final source = recipe['source'];
    final sourceMap = source is Map ? Map<String, dynamic>.from(source) : null;
    final platform =
        (sourceMap?['platform'] as String? ??
                recipe['platform'] as String? ??
                '')
            .toLowerCase()
            .trim();
    if (platform.contains('instagram')) return true;
    final sourceUrl =
        (recipe['sourceUrl'] as String? ?? sourceMap?['url'] as String? ?? '')
            .toLowerCase()
            .trim();
    return sourceUrl.contains('instagram.com') ||
        sourceUrl.contains('instagr.am');
  }

  /// On Flutter Web, route Instagram CDN URLs through the backend proxy
  /// to bypass CORS. On native platforms the CDN URL works directly.
  static String _maybeProxy(String url) {
    if (!kIsWeb) return url;
    if (!_needsProxy(url)) return url;
    final base = EnvironmentConfig.baseUrl;
    return '$base/proxy_image?url=${Uri.encodeComponent(url)}';
  }

  static bool _needsProxy(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.contains('cdninstagram.com') || host.contains('instagram.com');
  }
}
