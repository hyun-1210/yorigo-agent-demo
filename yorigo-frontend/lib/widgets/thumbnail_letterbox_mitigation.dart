import 'package:flutter/widgets.dart';

/// 썸네일 파일 안에 그려진 레터박스/필러박스(검은 띠)는 픽셀 단위로 제거할 수 없고,
/// 슬롯 안에서 확대·중앙 클립으로 가장자리 띠를 잘라 **틱톡에 가깝게** 보이게 하는 휴리스틱.
///
/// 유튜브 쇼츠 등은 **좌우 띠**가 많아 기본값으로 [scaleX] > [scaleY] 를 둡니다.
/// 음식이 잘릴 수 있으므로 필요 시 배율만 조정하면 됩니다.
class ThumbnailLetterboxMitigation extends StatelessWidget {
  const ThumbnailLetterboxMitigation({
    super.key,
    required this.platform,
    required this.imageUrl,

    /// 원본 영상 URL(파싱 시). Storage 썸네일만 있을 때 유튜브 여부 판별용.
    this.sourceUrl = '',
    this.scaleX = 1.52,
    this.scaleY = 1.28,
    required this.child,
  });

  final String platform;
  final String imageUrl;
  final String sourceUrl;
  final double scaleX;
  final double scaleY;
  final Widget child;

  static bool _isYouTubeSource({
    required String platform,
    required String imageUrl,
    String? sourceUrl,
  }) {
    final p = platform.toLowerCase().trim();
    if (p == 'youtube' || p.contains('youtube')) return true;
    final u = imageUrl.toLowerCase();
    if (u.contains('ytimg.com')) return true;
    final s = (sourceUrl ?? '').toLowerCase().trim();
    return s.contains('youtube.com') ||
        s.contains('youtu.be') ||
        s.contains('youtube-nocookie.com') ||
        s.contains('/shorts/');
  }

  static bool appliesTo({
    required String platform,
    required String imageUrl,
    String? sourceUrl,
  }) {
    final u = imageUrl.toLowerCase();
    // If already using pre-cropped storage variant, skip extra UI scaling.
    if (u.contains('recipe_thumbnails/cropped/') ||
        u.contains('recipe_thumbnails%2fcropped%2f')) {
      return false;
    }

    // yt-dlp extractor_key는 대개 `youtube`이나, 버전/클라이언트에 따라 `youtubetab` 등으로 올 수 있음.
    return _isYouTubeSource(
      platform: platform,
      imageUrl: imageUrl,
      sourceUrl: sourceUrl,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!appliesTo(
      platform: platform,
      imageUrl: imageUrl,
      sourceUrl: sourceUrl,
    )) {
      return child;
    }
    final sx = scaleX <= 1.0 ? 1.0 : scaleX;
    final sy = scaleY <= 1.0 ? 1.0 : scaleY;
    if (sx <= 1.0 && sy <= 1.0) return child;
    return ClipRect(
      child: Transform(
        transform: Matrix4.identity()..scale(sx, sy, 1.0),
        alignment: Alignment.center,
        filterQuality: FilterQuality.low,
        child: child,
      ),
    );
  }
}
