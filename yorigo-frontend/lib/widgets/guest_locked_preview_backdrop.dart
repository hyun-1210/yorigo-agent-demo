import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'ios_liquid_glass_tab_bar.dart';

/// 로그인 전 잠금 탭의 블러 프리뷰 배경.
///
/// 프리뷰 PNG는 약 330×550이라 iOS(extendBody + 긴 화면)에서 cover 하면
/// 뒤 화면이 세로로 늘어져 보인다. iOS만 가로 기준 비율 유지.
class GuestLockedPreviewBackdrop extends StatelessWidget {
  const GuestLockedPreviewBackdrop({
    super.key,
    required this.asset,
    this.backgroundColor = const Color(0xFFF9FAFB),
    this.extendAboveBy = 0,
  });

  final String asset;
  final Color backgroundColor;

  /// Android 전용: 커뮤니티 상단 탭바 뒤로 프리뷰를 밀어 넣는다.
  final double extendAboveBy;

  bool get _isIos =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Widget build(BuildContext context) {
    if (_isIos) {
      final image = _blurredPreview(
        fit: BoxFit.fitWidth,
        clip: true,
        backgroundColor: backgroundColor,
      );
      if (extendAboveBy > 0) {
        return Positioned(
          top: -extendAboveBy,
          left: 0,
          right: 0,
          bottom: 0,
          child: image,
        );
      }
      return image;
    }

    if (extendAboveBy > 0) {
      return Positioned(
        top: -extendAboveBy,
        left: 0,
        right: 0,
        bottom: 0,
        child: IgnorePointer(
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 2.5, sigmaY: 2.5),
            child: Image.asset(
              asset,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
            ),
          ),
        ),
      );
    }

    return IgnorePointer(
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 2.5, sigmaY: 2.5),
        child: SizedBox.expand(
          child: Image.asset(
            asset,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
          ),
        ),
      ),
    );
  }

  Widget _blurredPreview({
    required BoxFit fit,
    required bool clip,
    required Color backgroundColor,
  }) {
    Widget image = IgnorePointer(
      child: ColoredBox(
        color: backgroundColor,
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 2.5, sigmaY: 2.5),
          child: SizedBox.expand(
            child: Image.asset(
              asset,
              fit: fit,
              alignment: Alignment.topCenter,
            ),
          ),
        ),
      ),
    );
    if (clip) {
      image = ClipRect(child: image);
    }
    return image;
  }
}

/// 로그인 유도 카드를 냉장고 탭과 같은 시각적 중심에 둔다.
///
/// iOS는 바디가 네이티브 탭바 뒤로 연장돼, bottom SafeArea가 없는 탭은
/// 카드가 아래로 내려간다. 탭바 높이만큼 아래를 비워 냉장고와 맞춘다.
class GuestLockedPromptAlign extends StatelessWidget {
  const GuestLockedPromptAlign({
    super.key,
    required this.child,
    this.extraTopLift = 0,
  });

  final Widget child;

  /// 커뮤니티처럼 본문 위에 추가 탭바가 있을 때 보정 (보통 음수).
  final double extraTopLift;

  @override
  Widget build(BuildContext context) {
    final isIos = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    Widget prompt = Center(child: child);
    if (isIos) {
      final bottom = IosLiquidGlassTabBar.overlayChromeInset(context);
      if (bottom > 0) {
        prompt = Padding(
          padding: EdgeInsets.only(bottom: bottom),
          child: prompt,
        );
      }
    }
    if (extraTopLift != 0) {
      prompt = Transform.translate(
        offset: Offset(0, extraTopLift),
        child: prompt,
      );
    }
    return prompt;
  }
}
