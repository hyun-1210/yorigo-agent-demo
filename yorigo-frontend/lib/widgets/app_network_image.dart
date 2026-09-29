import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../theme/app_colors.dart';
import '../utils/tiktok_utils.dart';

/// 네트워크 이미지를 캐시 + 메모리/디스크 리사이즈로 로딩하는 공통 위젯.
/// [Image.network] 대신 사용하면 재방문 시 캐시에서 빠르게 표시되고,
/// [memCacheWidth]/[memCacheHeight]로 디코딩 크기를 제한해 메모리를 줄일 수 있습니다.
class AppNetworkImage extends StatefulWidget {
  const AppNetworkImage({
    super.key,
    required this.imageUrl,
    this.mediaSourceUrl,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.memCacheWidth,
    this.memCacheHeight,
    this.maxWidthDiskCache,
    this.maxHeightDiskCache,
    this.cacheKey,
    this.placeholder,
    this.errorWidget,
    this.brightness,

    /// When true, no fade when the image appears (avoids "reloading" feel on cached images).
    this.fadeInImmediately = true,
  });

  final String imageUrl;

  /// 원본 영상/포스트 URL. TikTok CDN 썸네일이 만료(403)됐을 때 oEmbed로 갱신한다.
  final String? mediaSourceUrl;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// 디코딩 시 메모리 캐시 크기 제한 (픽셀). 작을수록 메모리 절약.
  final int? memCacheWidth;
  final int? memCacheHeight;

  /// 디스크에 저장할 최대 크기 제한 (픽셀).
  final int? maxWidthDiskCache;
  final int? maxHeightDiskCache;

  final String? cacheKey;
  final Widget? placeholder;
  final Widget? errorWidget;
  final Brightness? brightness;
  final bool fadeInImmediately;

  /// 피드/카드용 큰 이미지 권장 값 (화면 폭 기준).
  static const int feedImageCacheSize = 800;

  /// 아바타/작은 썸네일용 권장 값 (~50px 위젯 @3x).
  static const int avatarCacheSize = 150;

  /// 일반 목록 썸네일용 (정사각형 근사, ~140px 위젯 @2x).
  static const int listThumbCacheSize = 280;

  /// 레시피북 가로 카드(84×108 @3x).
  static const int recipeBookThumbMemCacheWidth = 252;
  static const int recipeBookThumbMemCacheHeight = 324;

  /// 홈 트렌드 캐러셀(140×175 @3x).
  static const int carouselThumbMemCacheWidth = 420;
  static const int carouselThumbMemCacheHeight = 525;

  @override
  State<AppNetworkImage> createState() => _AppNetworkImageState();

  /// [CircleAvatar.backgroundImage] 등에 넣을 때 사용.
  /// 작은 크기로 캐시해 다운로드·메모리를 줄입니다.
  static ImageProvider imageProviderForAvatar(
    String imageUrl, {
    int size = avatarCacheSize,
  }) {
    return CachedNetworkImageProvider(
      imageUrl,
      maxWidth: size,
      maxHeight: size,
    );
  }

  /// 피드/카드용 큰 이미지의 ImageProvider (필요 시 사용).
  static ImageProvider imageProviderForFeed(String imageUrl) {
    return CachedNetworkImageProvider(
      imageUrl,
      maxWidth: feedImageCacheSize,
      maxHeight: feedImageCacheSize,
    );
  }
}

class _AppNetworkImageState extends State<AppNetworkImage> {
  String? _freshTikTokUrl;
  bool _refreshStarted = false;
  bool _refreshDone = false;

  @override
  void initState() {
    super.initState();
    _maybeRefreshTikTokThumbnail();
  }

  @override
  void didUpdateWidget(covariant AppNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl ||
        oldWidget.mediaSourceUrl != widget.mediaSourceUrl) {
      _freshTikTokUrl = null;
      _refreshStarted = false;
      _refreshDone = false;
      _maybeRefreshTikTokThumbnail();
    }
  }

  bool _needsTikTokRefresh(String imageUrl, String sourceUrl) {
    if (!isTikTokUrl(sourceUrl)) return false;
    final trimmed = imageUrl.trim();
    if (trimmed.isEmpty) return true;
    return isTikTokCdnThumbnailUrl(trimmed);
  }

  void _maybeRefreshTikTokThumbnail() {
    final source = widget.mediaSourceUrl?.trim() ?? '';
    if (!_needsTikTokRefresh(widget.imageUrl, source) || _refreshStarted) {
      return;
    }
    _refreshStarted = true;
    fetchTikTokOEmbed(source).then((oembed) {
      if (!mounted) return;
      final fresh = oembed?.thumbnailUrl?.trim() ?? '';
      setState(() {
        _refreshDone = true;
        if (fresh.isNotEmpty) _freshTikTokUrl = fresh;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final effectiveBrightness = brightnessOrTheme(context);
    final source = widget.mediaSourceUrl?.trim() ?? '';
    final waitingForFresh =
        _needsTikTokRefresh(widget.imageUrl, source) && !_refreshDone;
    final displayUrl = _freshTikTokUrl?.trim().isNotEmpty == true
        ? _freshTikTokUrl!
        : widget.imageUrl.trim();

    if (displayUrl.isEmpty || waitingForFresh) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: widget.placeholder ??
            Container(
              color: AppColors.getBackgroundSecondary(effectiveBrightness),
            ),
      );
    }

    return CachedNetworkImage(
      imageUrl: displayUrl,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      memCacheWidth: widget.memCacheWidth,
      memCacheHeight: widget.memCacheHeight,
      maxWidthDiskCache: widget.maxWidthDiskCache,
      maxHeightDiskCache: widget.maxHeightDiskCache,
      cacheKey: widget.cacheKey ?? displayUrl,
      useOldImageOnUrlChange: true,
      fadeInDuration: widget.fadeInImmediately
          ? Duration.zero
          : const Duration(milliseconds: 500),
      fadeOutDuration: widget.fadeInImmediately
          ? Duration.zero
          : const Duration(milliseconds: 500),
      placeholder: (_, __) =>
          widget.placeholder ??
          Container(
            color: AppColors.getBackgroundSecondary(effectiveBrightness),
          ),
      errorWidget: (_, __, ___) =>
          widget.errorWidget ??
          Icon(
            Icons.broken_image_outlined,
            size: (widget.width != null && widget.height != null)
                ? (widget.width! < widget.height! ? widget.width! : widget.height!)
                : 48,
            color: AppColors.getTextTertiary(effectiveBrightness),
          ),
    );
  }

  Brightness brightnessOrTheme(BuildContext context) {
    return widget.brightness ?? Theme.of(context).brightness;
  }
}
