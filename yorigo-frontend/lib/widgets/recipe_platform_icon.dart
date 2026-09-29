import 'package:flutter/material.dart';

/// 레시피 카드 creator 옆 유튜브/인스타/틱톡 플랫폼 아이콘.
/// 홈 [HomeStyleRecipeCard] 와 동일한 에셋·크기를 쓴다.
class RecipePlatformIcon extends StatelessWidget {
  const RecipePlatformIcon({
    super.key,
    required this.platform,
    this.size = 23,
    this.fallbackColor = const Color(0xFF9CA3AF),
  });

  final String platform;
  final double size;
  final Color fallbackColor;

  static String? assetPathFor(String platform) {
    final p = platform.toLowerCase().trim();
    if (p == 'youtube' || p.contains('youtube')) {
      return 'lib/assets/youtube-app-icon-hd.png';
    }
    if (p == 'instagram' ||
        p == 'instagramweb' ||
        p.contains('instagram')) {
      return 'lib/assets/instagram-app-icon-hd.png';
    }
    if (p == 'tiktok' || p == 'tiktokweb' || p.contains('tiktok')) {
      return 'lib/assets/tiktok-app-icon-hd.png';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final assetPath = assetPathFor(platform);
    final fallbackIcon = Icon(
      Icons.video_library,
      size: size * 0.59,
      color: fallbackColor,
    );
    if (assetPath == null) {
      return SizedBox(
        width: size,
        height: size,
        child: fallbackIcon,
      );
    }
    return SizedBox(
      width: size,
      height: size,
      child: Image.asset(
        assetPath,
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => fallbackIcon,
      ),
    );
  }
}
