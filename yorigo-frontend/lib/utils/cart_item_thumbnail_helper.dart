import '../services/recipe_service.dart';
import 'recipe_thumbnail_resolver.dart';

/// Resolves cart-item thumbnail / platform / sourceUrl from Firestore meta when possible.
class CartItemThumbnailHelper {
  const CartItemThumbnailHelper._();

  /// Parse-time fallback (no [thumbnailUrlCropped] on parseResponse).
  static String thumbnailFromParseResponse(dynamic parseResponse) {
    try {
      final source = parseResponse.source;
      if (source is Map) {
        final large = (source['thumbnail_large'] as String?)?.trim() ?? '';
        if (large.isNotEmpty) return large;
        final thumb = (source['thumbnail'] as String?)?.trim() ?? '';
        if (thumb.isNotEmpty) return thumb;
      }
    } catch (_) {}
    return '';
  }

  static void applyParseSourceFields(
    Map<String, dynamic> out,
    dynamic parseResponse,
  ) {
    try {
      final source = parseResponse?.source;
      if (source is! Map) return;
      if ((out['platform'] as String?)?.trim().isEmpty ?? true) {
        final platform = (source['platform'] as String?)?.trim() ?? '';
        if (platform.isNotEmpty) out['platform'] = platform;
      }
      if ((out['sourceUrl'] as String?)?.trim().isEmpty ?? true) {
        final url = (source['url'] as String?)?.trim() ?? '';
        if (url.isNotEmpty) out['sourceUrl'] = url;
      }
      if ((out['thumbnailUrl'] as String?)?.trim().isEmpty ?? true) {
        final thumb = thumbnailFromParseResponse(parseResponse);
        if (thumb.isNotEmpty) out['thumbnailUrl'] = thumb;
      }
    } catch (_) {}
  }

  /// Returns a copy of [cartItem] with resolved thumbnail/platform/sourceUrl.
  static Future<Map<String, dynamic>> enrichCartItem(
    Map<String, dynamic> cartItem, {
    Map<String, dynamic>? recipeDocHint,
    dynamic parseResponseForThumbnail,
  }) async {
    final out = Map<String, dynamic>.from(cartItem);
    final recipeId = out['recipeId']?.toString().trim() ?? '';
    final cartFallbackThumb = (out['thumbnailUrl'] as String?)?.trim() ?? '';

    if (parseResponseForThumbnail != null) {
      applyParseSourceFields(out, parseResponseForThumbnail);
    }

    var thumb = '';
    var platform = (out['platform'] as String?)?.trim() ?? '';
    var sourceUrl = (out['sourceUrl'] as String?)?.trim() ?? '';

    if (recipeDocHint != null && recipeDocHint.isNotEmpty) {
      thumb = RecipeThumbnailResolver.resolve(
        Map<String, dynamic>.from(recipeDocHint),
        preferCroppedForInstagram: true,
      );
      if (platform.isEmpty) {
        platform = _platformFromRecipeMap(recipeDocHint);
      }
      if (sourceUrl.isEmpty) {
        sourceUrl = _sourceUrlFromRecipeMap(recipeDocHint);
      }
    } else if (recipeId.isNotEmpty) {
      final meta = await RecipeService.shared.getRecipeMetaForIds([recipeId]);
      final recipeMeta = meta[recipeId];
      if (recipeMeta != null) {
        thumb = (recipeMeta['thumbnailUrl'] as String?)?.trim() ?? '';
        if (platform.isEmpty) {
          platform = (recipeMeta['platform'] as String?)?.trim() ?? '';
        }
        if (sourceUrl.isEmpty) {
          sourceUrl = (recipeMeta['sourceUrl'] as String?)?.trim() ?? '';
        }
      }
    }

    if (thumb.isEmpty) {
      thumb = (out['thumbnailUrl'] as String?)?.trim() ?? cartFallbackThumb;
    }

    if (thumb.isNotEmpty) out['thumbnailUrl'] = thumb;
    if (platform.isNotEmpty) out['platform'] = platform;
    if (sourceUrl.isNotEmpty) out['sourceUrl'] = sourceUrl;
    return out;
  }

  static String _platformFromRecipeMap(Map<String, dynamic> data) {
    final source = data['source'];
    if (source is Map) {
      final fromSource = (source['platform'] as String?)?.trim() ?? '';
      if (fromSource.isNotEmpty) return fromSource;
    }
    return (data['platform'] as String?)?.trim() ??
        (data['sourcePlatform'] as String?)?.trim() ??
        '';
  }

  static String _sourceUrlFromRecipeMap(Map<String, dynamic> data) {
    final top = (data['sourceUrl'] as String?)?.trim() ?? '';
    if (top.isNotEmpty) return top;
    final source = data['source'];
    if (source is Map) {
      return (source['url'] as String?)?.trim() ?? '';
    }
    return '';
  }
}
