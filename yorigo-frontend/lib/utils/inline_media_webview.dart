import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

/// YouTube 모바일 임베드는 iframe 높이가 약 270 미만이면 "Watch on YouTube"
/// 미니 프리뷰로 빠진다. Android 는 FittedBox 로 viewport 를 속일 수 있지만
/// iOS PlatformView 는 Transform 합성이 깨지므로 박스 자체를 키운다.
class YoutubeEmbedLayout {
  YoutubeEmbedLayout._();

  static const double miniPreviewMinHeight = 300.0;
  static const double landscapeRatio = 16 / 9;

  /// 시네마 프레임에서 제목·재생바가 잘리지 않게 16:9 위아래로만 더한다.
  /// 300pt / 9:16 으로 키우면 세로 박스가 되어 영상이 다시 작아진다.
  static const double cinemaOverlayPad = 24.0;

  /// 보이는 시네마 박스를 이만큼 더 높여 오버레이가 덜 잘리게 한다.
  static const double cinemaOverlayExtraHeight = 20.0;

  /// 가로 YouTube 카드의 width:height. iOS 에서는 iframe 이 미니 프리뷰
  /// 임계값을 넘도록 박스를 조금 더 높게 잡는다.
  static double landscapeBoxAspectRatio(double boxWidth) {
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        boxWidth.isFinite &&
        boxWidth > 0) {
      final naturalHeight = boxWidth / landscapeRatio;
      if (naturalHeight < miniPreviewMinHeight) {
        return boxWidth / miniPreviewMinHeight;
      }
    }
    return landscapeRatio;
  }

  /// iOS 가로 롱폼: 16:9 시네마 비율 + 오버레이가 보일 만큼만 조금 더 높게.
  static double iosCinemaVisibleAspectRatio(double boxWidth) {
    if (!boxWidth.isFinite || boxWidth <= 0) return landscapeRatio;
    final naturalHeight = boxWidth / landscapeRatio;
    return boxWidth /
        (naturalHeight + cinemaOverlayPad * 2 + cinemaOverlayExtraHeight);
  }
}

/// iOS 에서 PlatformView(WKWebView) 를 `Clip.antiAlias` 로 자르면 영상면이
/// 비는 경우가 있어, 비디오 슬롯은 hard-edge 클립을 쓴다.
Clip get platformViewClipBehavior {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    return Clip.hardEdge;
  }
  return Clip.antiAlias;
}

/// iOS WKWebView 는 opacity 합성이 깨져 투명했다가 나타나도 검은 화면으로
/// 남는 경우가 있다. 썸네일 오버레이로 가리고 WebView 자체는 항상 불투명.
Widget wrapPlatformViewReveal({
  required bool revealed,
  required Widget child,
}) {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    return child;
  }
  return AnimatedOpacity(
    opacity: revealed ? 1 : 0,
    duration: const Duration(milliseconds: 220),
    child: child,
  );
}

/// 인라인 `<video>` 재생이 가능한 [WebViewController] 를 만든다.
///
/// iOS 기본값은 `allowsInlineMediaPlayback=false` 이고 오디오/비디오 모두
/// 사용자 제스처를 요구한다. 그러면 임베드가 네이티브 전체화면으로 빠지거나
/// 앱에서 호출한 `video.play()` 가 거절된다.
WebViewController createInlineMediaWebViewController({
  void Function(WebViewPermissionRequest request)? onPermissionRequest,
}) {
  late final PlatformWebViewControllerCreationParams params;
  if (WebViewPlatform.instance is WebKitWebViewPlatform) {
    params = WebKitWebViewControllerCreationParams(
      allowsInlineMediaPlayback: true,
      mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
    );
  } else {
    params = const PlatformWebViewControllerCreationParams();
  }

  final controller = WebViewController.fromPlatformCreationParams(
    params,
    onPermissionRequest: onPermissionRequest,
  );

  final platform = controller.platform;
  if (platform is AndroidWebViewController) {
    platform.setMediaPlaybackRequiresUserGesture(false);
  }

  return controller;
}
