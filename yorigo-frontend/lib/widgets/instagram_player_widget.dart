import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kDebugMode, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../theme/app_colors.dart';
import '../utils/inline_media_webview.dart';
import '../utils/instagram_utils.dart';
import 'app_network_image.dart';
import 'inline_video_hero_poster.dart';

/// Instagram WebView 안의 `<video>` element를 외부에서 제어하기 위한 핸들.
///
/// IG 임베드 페이지는 instagram.com 도메인을 main frame으로 로드하므로 우리
/// JS가 same-origin context에서 `document.querySelector('video')`로 직접
/// 접근 가능하다. 이를 활용해 seek/play/pause를 노출하고, Android
/// SpeechRecognizer audio focus 충돌로 발생하는 의도치 않은 pause를 자동으로
/// 되돌리는 guard도 동일 JS 안에서 동작시킨다.
///
/// [seekBy] / [seekTo]는 DOM의 `<video>`에 `currentTime`을 씁니다. same-origin으로
/// 비디오에 닿는 임베드/iframe에서는 동작하나, IG가 플레이어를 막 교체하거나
/// 접근 불가면 실패할 수 있다.
class InstagramPlayerHandle {
  final VoidCallback play;
  final VoidCallback pause;
  final VoidCallback restart;
  final void Function(double deltaSeconds) seekBy;
  final void Function(double seconds) seekTo;
  final void Function(double seconds) seekToAndPlay;
  final void Function(bool enabled) setPlaybackGuard;
  final void Function(bool halted) setHalted;
  final Future<double> Function() getCurrentTime;

  const InstagramPlayerHandle({
    required this.play,
    required this.pause,
    required this.restart,
    required this.seekBy,
    required this.seekTo,
    required this.seekToAndPlay,
    required this.setPlaybackGuard,
    required this.setHalted,
    required this.getCurrentTime,
  });
}

/// Pre-warms WKWebView + Instagram TLS so the first Reel embed is not a cold start.
///
/// iOS only. Android Chromium 은 시작 시 추가 WebView + instagram.com 로드가
/// 메모리/렉 부담이 커서 상세에서 임베드를 열 때 만든다.
///
/// Call [InstagramPrewarmer.instance.warmUp] early in the app lifecycle
/// (same place as [YoutubePrewarmer]).
class InstagramPrewarmer {
  InstagramPrewarmer._();
  static final instance = InstagramPrewarmer._();

  bool _warmed = false;

  void warmUp() {
    if (kIsWeb || _warmed) return;
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      _warmed = true;
      return;
    }
    _warmed = true;
    try {
      final controller = createInlineMediaWebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.black);
      unawaited(
        controller.loadRequest(
          Uri.parse('https://www.instagram.com/embed.js'),
          headers: const {'Referer': 'https://www.instagram.com/'},
        ),
      );
      Future<void>.delayed(const Duration(seconds: 4), () {
        try {
          controller.loadRequest(Uri.parse('about:blank'));
        } catch (_) {}
        debugPrint('[InstagramPrewarmer] WebView + instagram.com warmed');
      });
    } catch (e) {
      debugPrint('[InstagramPrewarmer] warm-up skipped: $e');
    }
  }
}

/// Instagram Reels/Posts/IGTV를 앱 내에서 임베드 재생하는 위젯.
///
/// `https://www.instagram.com/{type}/{shortcode}/embed/` 페이지를 `webview_flutter`로
/// 로드한다. 모바일에서만 인앱 임베드를 지원하고, `kIsWeb`에서는 외부 링크 폴백.
///
/// 임베드 페이지 안의 "View on Instagram" 등 `/embed` 이탈은 WebView 안에서
/// 따라가지 않는다. `l.instagram.com` 심과 `/embed` 경로만 허용한다.
/// `<video>` 주입이 늦는 경우 폴링 후 `embed/captioned/`로 한 번 더 시도하고,
/// Android에서 그래도 없으면 썸네일만 두고 상세의 「원본 영상」에 맡긴다.
///
/// 재생은 항상 Instagram **임베드 WebView** 안에서만 이루어져 조회수가 크리에이터에게 반영된다.
/// (직접 CDN MP4를 ``video_player``로 재생하는 방식은 사용하지 않는다.)
///
/// 상단·하단 크롬, 로그인 권유 모달 등은 **안정적인 DOM 힌트**\ (`nav`, `header`,
/// fixed/sticky 상단 띠, ``[role="dialog"]`` + 텍스트 휴리스틱)로 숨기고,
/// 필요 시 문서 **스크롤**만으로 프레임을 내린다. ``clip-path``/``body`` 음수 오프셋으로
/// 상단만 잘라내는 방식은 하단이 함께 잘리므로 쓰지 않는다.
///
/// 페이지 로드 후 `<video>` element 존재 여부를 JS로 확인해 게시물 삭제 등
/// 200 OK + 에러 HTML 케이스를 우리 폴백(썸네일 표시)으로 전환한다.
class InstagramPlayerWidget extends StatefulWidget {
  final String type;
  final String shortcode;
  final String? thumbnailUrl;
  final VoidCallback? onClose;

  /// 1.0 = 정사각형. Reels/Posts는 보통 1:1 또는 4:5/9:16. 부모 박스 비율을
  /// 그대로 따르되, 자체적으로 별도 비율 제약을 두진 않는다.
  final double aspectRatio;

  /// 내부 컨트롤러가 준비되면 video element 제어 handle을 제공.
  final void Function(InstagramPlayerHandle handle)? onControllerReady;

  /// User paused via native embed controls (not via app handle).
  final VoidCallback? onUserPausedInPlayer;

  /// User pressed play via native embed controls (not via app handle).
  final VoidCallback? onUserPlayedInPlayer;

  /// 세션에서 실제 재생이 처음 시작된 뒤 1회. Mixpanel/GCS `play`에 쓴다.
  final VoidCallback? onFirstPlay;

  /// 위젯이 내려가거나 영상이 바뀌면 누적 재생 ms. 1초 미만은 생략.
  final void Function(int durationMs)? onWatchEnded;

  const InstagramPlayerWidget({
    super.key,
    required this.type,
    required this.shortcode,
    this.thumbnailUrl,
    this.onClose,
    this.aspectRatio = 1.0,
    this.onControllerReady,
    this.onUserPausedInPlayer,
    this.onUserPlayedInPlayer,
    this.onFirstPlay,
    this.onWatchEnded,
  });

  @override
  State<InstagramPlayerWidget> createState() => _InstagramPlayerWidgetState();
}

class _InstagramPlayerWidgetState extends State<InstagramPlayerWidget> {
  WebViewController? _controller;
  bool _isReady = false;
  bool _hasLoadError = false;
  DateTime? _playingStartedAt;
  int _accumulatedPlayMs = 0;
  bool _firstPlayReported = false;

  /// `<video>` + JS bridge installed and paused — safe to reveal WebView and play.
  bool _videoBridgeReady = false;

  /// Android: captioned 재시도까지 했는데도 `<video>`가 없음.
  /// IG가 인라인 재생을 막는 릴 — WebView(그리드) 대신 썸네일만 둔다.
  bool _inlineVideoUnavailable = false;

  /// Queued seek target when user taps a step before the video bridge is ready.
  double? _pendingSeekToAndPlaySec;

  /// True after [InstagramPlayerHandle.play] / restart requests JS playback (optional — embed is visible without this).
  bool _heroPlayRequested = false;

  /// When false, the next successful reveal runs `__yorigoIgRestart` instead of `__yorigoIgPlay`.
  bool _playbackKindRestart = false;

  /// Embed document painted — show WebView even before `<video>` exists.
  /// iOS IG often injects `<video>` only after the user taps play.
  bool _embedSurfaceReady = false;

  /// WebView is shown once the embed document is up; thumbnail covers loading
  /// and IG-blocked embeds ([_inlineVideoUnavailable]).
  /// Android는 `<video>`가 붙기 전에는 WebView를 올리지 않는다(프로필 그리드 방지).
  bool get _showWebToUser =>
      _embedSurfaceReady &&
      !_hasLoadError &&
      !_inlineVideoUnavailable &&
      (_videoBridgeReady || _isIos);

  Timer? _lateVideoBridgeTimer;

  static bool get _isIos =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  Timer? _readyTimeoutTimer;
  Timer? _layoutJankCoverTimer;
  bool _layoutJankCoverVisible = false;

  /// iOS: Watch-on-Instagram 전용 임베드는 썸네일+CTA로 가린다.
  /// 재생 가능한 임베드는 플레이어를 바로 보여 주고 이 커버를 쓰지 않는다.
  Timer? _iosFramingCoverTimer;
  Timer? _iosFramingCoverFallbackTimer;
  bool _iosFramingCoverVisible = true;

  /// iOS: 인앱 재생이 안 되고 가운데 "Watch on Instagram"만 있는 임베드.
  bool _iosWatchOnInstagramOnly = false;
  bool _iosDidPrecacheThumb = false;
  final GlobalKey _iosWebViewKey = GlobalKey();

  /// `false` = black slot (easy embed / generic video); `true` = IG blue-black (never-miss popup flow).
  bool _useIgEmbedLetterboxChrome = false;

  Color get _slotLetterboxColor => _useIgEmbedLetterboxChrome
      ? AppColors.instagramBrowserLetterbox
      : Colors.black;

  String get _slotLetterboxCss => _useIgEmbedLetterboxChrome
      ? AppColors.instagramBrowserLetterboxCss
      : '#000000';

  Timer? _afterNeverMissStripPollTimer;

  /// From JS `__yorigoIgNeverMissEver` (popup / never-miss flow).
  bool _igNeverMissEverDetected = false;

  /// Blue letterbox + 8px strip when embed is never-miss type and the WebView surface is active.
  bool get _neverMissUiChromeActive =>
      _igNeverMissEverDetected && _videoBridgeReady && !_hasLoadError;

  /// Black strip at top when [_neverMissUiChromeActive]; blocks stray taps on IG chrome.
  static const double _afterNeverMissTopBlackBarPx = 8.0;

  static const Duration _afterNeverMissStripPollInterval =
      Duration(milliseconds: 400);

  static const String _neverMissEverProbeJs = r'''
(function(){
  try { return window.__yorigoIgNeverMissEver === true ? 1 : 0; }
  catch (e) { return 0; }
})()
''';

  static const String _watchCtaProbeJs = r'''
(function(){
  try { return window.__yorigoIgWatchCta === true ? 1 : 0; }
  catch (e) { return 0; }
})()
''';

  /// Covers the WebView briefly while injected zoom/scroll runs so the first
  /// frames are not visible (short — shorter after late `<video>` attach).
  static const Duration _layoutJankCoverAfterVideoMs = Duration(milliseconds: 180);

  /// iOS: layout inject 직후 watch CTA 판정이 올 시간을 준 뒤 재생 가능하면 커버를 벗긴다.
  static const Duration _iosFramingCoverAfterLayout = Duration(milliseconds: 400);

  /// iOS: layout inject가 없어도 재생 가능 임베드의 커버를 벗기는 상한.
  static const Duration _iosFramingCoverFallback = Duration(milliseconds: 1600);

  /// iOS 전용: 브릿지 설치 전에 넣어 첫 탭 재생이 suppress-pause에 먹히지 않게 한다.
  static const String _iosPlaybackIntentPreludeJs = r'''
window.__yorigoIgIos = true;
window.__yorigoIgAllowPlaybackEarly = true;
''';

  /// iOS: 썸네일을 WKWebView 안에서 그려 플랫폼 뷰 펀치스루를 피한다.
  static const String _iosHtmlPosterBootstrapJs = r'''
(function(){
  window.__yorigoIgIos = true;
  function host() {
    return document.documentElement || document.body;
  }
  function applyChrome() {
    if (window.__yorigoIgPosterHidden || window.__yorigoIgWatchCta !== true) {
      var gone = document.getElementById('yorigo-ig-poster');
      if (gone) gone.style.display = 'none';
      return;
    }
    var root = document.getElementById('yorigo-ig-poster');
    if (!root) {
      root = document.createElement('div');
      root.id = 'yorigo-ig-poster';
      root.setAttribute('data-yorigo-poster', '1');
      root.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:#000;overflow:hidden;';
      var img = document.createElement('img');
      img.id = 'yorigo-ig-poster-img';
      img.alt = '';
      img.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;object-fit:cover;pointer-events:none;';
      root.appendChild(img);
      var play = document.createElement('div');
      play.id = 'yorigo-ig-poster-play';
      play.style.cssText = 'position:absolute;left:50%;top:50%;width:16px;height:18px;margin:-9px 0 0 -8px;display:none;pointer-events:none;';
      var tri = document.createElement('div');
      tri.style.cssText = 'width:0;height:0;border-top:9px solid transparent;border-bottom:9px solid transparent;border-left:16px solid #fff;';
      play.appendChild(tri);
      root.appendChild(play);
      var cta = document.createElement('div');
      cta.id = 'yorigo-ig-poster-cta';
      cta.textContent = 'Instagram에서 보기';
      cta.style.cssText = 'position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);display:none;align-items:center;justify-content:center;background:rgba(255,255,255,0.94);border-radius:999px;padding:10px 16px;box-shadow:0 2px 8px rgba(0,0,0,0.2);font:700 13px/1.2 -apple-system,BlinkMacSystemFont,sans-serif;color:#2C2A27;white-space:nowrap;pointer-events:auto;';
      root.appendChild(cta);
      root.addEventListener('pointerdown', function(ev) {
        if (window.__yorigoIgPosterArmed === true && window.__yorigoIgWatchCta !== true) return;
        ev.preventDefault();
        ev.stopPropagation();
      }, true);
      root.addEventListener('click', function(ev) {
        if (window.__yorigoIgWatchCta !== true) return;
        ev.preventDefault();
        ev.stopPropagation();
        try { YorigoIgUserControl.postMessage('open_instagram'); } catch (eC) {}
      }, true);
      var h = host();
      if (h) h.appendChild(root);
    } else {
      var h2 = host();
      if (h2 && root.parentNode !== h2) h2.appendChild(root);
      root.style.display = 'block';
    }
    var imgEl = document.getElementById('yorigo-ig-poster-img');
    var src = window.__yorigoIgPosterThumb || '';
    if (imgEl && src && imgEl.getAttribute('data-src') !== src) {
      imgEl.setAttribute('data-src', src);
      var isIg = /instagram|cdninstagram|fbcdn\.net/i.test(src);
      try { imgEl.referrerPolicy = isIg ? 'origin' : 'no-referrer'; } catch (eR) {}
      imgEl.src = src;
    }
    var watch = window.__yorigoIgWatchCta === true;
    var playEl = document.getElementById('yorigo-ig-poster-play');
    var ctaEl = document.getElementById('yorigo-ig-poster-cta');
    if (playEl) playEl.style.display = 'none';
    if (ctaEl) ctaEl.style.display = watch ? 'flex' : 'none';
    root.style.pointerEvents = watch ? 'auto' : 'none';
  }
  function hidePoster() {
    window.__yorigoIgPosterHidden = true;
    var root = document.getElementById('yorigo-ig-poster');
    if (root) root.style.display = 'none';
  }
  window.__yorigoIgHidePoster = hidePoster;
  window.__yorigoIgArmPoster = function(on) {
    window.__yorigoIgPosterArmed = !!on;
    applyChrome();
  };
  window.__yorigoIgSetWatchOnly = function(on) {
    window.__yorigoIgWatchCta = !!on;
    if (on) window.__yorigoIgPosterArmed = false;
    applyChrome();
  };
  window.__yorigoIgEnsurePoster = applyChrome;
  if (!window.__yorigoIgPosterEvents) {
    window.__yorigoIgPosterEvents = true;
    function onArmedPointer() {
      if (window.__yorigoIgIos === true && window.__yorigoIgWatchCta !== true) return;
      if (window.__yorigoIgWatchCta === true) return;
      if (window.__yorigoIgPosterArmed !== true) return;
      if (window.__yorigoIgPosterHidden) return;
      window.__yorigoIgUserIntentPlay = true;
      window.__yorigoIgAllowPlaybackEarly = true;
      window.__yorigoIgHalted = false;
      window.__yorigoIgLastTrustedPointerMs = Date.now();
      hidePoster();
      try { YorigoIgUserControl.postMessage('poster_play'); } catch (eP) {}
    }
    document.addEventListener('pointerdown', onArmedPointer, true);
    document.addEventListener('touchstart', onArmedPointer, true);
    document.addEventListener('playing', function(ev) {
      try {
        if (!ev.target || String(ev.target.tagName).toLowerCase() !== 'video') return;
        if (window.__yorigoIgIos === true && window.__yorigoIgWatchCta !== true) return;
        if (window.__yorigoIgWatchCta === true) return;
        if (window.__yorigoIgPosterArmed !== true) return;
        hidePoster();
        try { YorigoIgUserControl.postMessage('poster_play'); } catch (e0) {}
      } catch (e1) {}
    }, true);
  }
  applyChrome();
})();
''';

  /// Instagram mobile WebView: two experiences, **selected in JS** via ``__yorigoIgNeverMissEver``.
  /// - **Easy embed** (inline video, no popup): **smaller** slot zoom + tighter fit.
  /// - **Popup / no-embed flow** (never-miss, tap-to-play): **larger** slot zoom + looser fit.
  double _layoutZoomEasyEmbed = 1.0;

  /// Larger [baseZ] after interstitial / web-player flow (wider than easy-embed slot zoom).
  double _layoutZoomPopupFlow = 1.0;

  /// Downward document scroll (px) for **inline / easy embed** only (`!__yorigoIgNeverMissEver`).
  /// Injected **without** width-factor scaling so **10** stays **10** in the document.
  static const double _embedDocScrollPx = 10.0;

  /// Scroll after **Never miss a post** (or while the post-dismiss tuning window is active).
  static const double _embedDocScrollPxAfterNeverMiss = 300.0;

  /// Clean layout scroll when video is ready but user already saw never-miss (`postNeverMissClean`).
  static const double _embedDocScrollPxCleanLayout = 56.0;

  /// Width factor at which [_embedDocScrollPxAfterNeverMiss] / [_embedDocScrollPxCleanLayout]
  /// were tuned (**1.0** = full slot width). Not applied to [_embedDocScrollPx] (easy embed).
  static const double _embedDocScrollTunedAtWidthFactor = 1.0;

  /// Clean-path: easy embed — **below 1** shrinks fitted zoom (narrower frame).
  static const double _embedCleanLayoutZoomMulEasyEmbed = 0.85;

  /// Clean-path: popup flow — slight upward nudge after fit (undo prior over-shrink).
  static const double _embedCleanLayoutZoomMulPopupFlow = 1.03;

  /// Extra shrink on **easy embed only** at end of clean **and** mitigate paths (watch CTA etc.).
  /// **1.0** disables. Use when clean-path-only tweaks seem to have no effect.
  static const double _embedEasyExtraZoomMul = 0.82;

  static const double _embedCleanLayoutShiftUpPx = 0.0;

  static const double _embedCleanLayoutClipTopPx = 0.0;
  String? _lastAppliedLayoutSignature;
  double? _lastLayoutScheduleBoxW;
  double? _lastLayoutScheduleBoxH;

  /// Tracks which embed URL we loaded (standard vs captioned fallback).
  late String _loadedEmbedUrl;
  bool _triedCaptionedEmbed = false;
  int _videoProbeSession = 0;

  static const Duration _readyTimeout = Duration(seconds: 6);

  /// Desktop Chrome UA — IG 임베드가 모바일 WebView에서 `<video>`를 늦게/안 넣는
  /// 경우가 있어 임베드 HTML을 더 자주 맞춘다.
  static const String _instagramEmbedUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  /// How wide the embedded WebView is vs the layout slot: **effective width =
  /// `constraints.maxWidth * _embedWebViewWidthFactor`** (see [_buildMobilePlayer]).
  ///
  /// - **1.0** — WebView matches slot width (video spans full box width).
  /// - **Below 1.0** — narrower WebView, **centered** in the black box, so the player is
  ///   visibly smaller with side margins. [_scheduleLayoutZoomApply] uses this same width.
  /// - Greater than **1.0** — wider surface, centered; [ClipRRect] clips the sides.
  static const double _embedWebViewWidthFactor = 0.82;

  /// Scales [_embedDocScrollPx] values from [_embedDocScrollTunedAtWidthFactor] to
  /// the active [_embedWebViewWidthFactor] before injection.
  double get _embedDocScrollScale =>
      _embedDocScrollTunedAtWidthFactor / _embedWebViewWidthFactor;

  /// Caps scaled scroll so a very small width factor cannot push huge offsets.
  static const double _embedDocScrollPxMax = 720.0;

  double _clampScroll(double y) =>
      y.clamp(0.0, _embedDocScrollPxMax).toDouble();

  /// Slot height slack when mapping 9:16 into [boxH]: shared by both modes before per-mode mul.
  static const double _embedSlotHeightFitFactor = 0.99;

  /// **Easy embed** (``!`` ``__yorigoIgNeverMissEver``): smaller / narrower. Capped by [_embedZoomMaxEasyEmbed].
  static const double _embedPageZoomMulEasyEmbed = 0.92;

  /// **Popup / web-player flow**: larger zoom to restore width after dismiss. Capped by [_embedZoomMaxPopupFlow].
  static const double _embedPageZoomMulPopupFlow = 1.56;

  static const double _embedZoomMin = 0.22;
  static const double _embedZoomMaxEasyEmbed = 2.35;
  static const double _embedZoomMaxPopupFlow = 2.8;

  static const int _videoProbeAttempts = 12;
  static const Duration _videoProbeFirstDelay = Duration.zero;
  static const Duration _videoProbeInterval = Duration(milliseconds: 120);

  /// Posts `video_ready` on [YorigoIgUserControl] as soon as a `<video>` appears.
  static const String _videoReadyWatcherJs = r'''
(function(){
  if (window.__yorigoIgVideoWatch) return;
  window.__yorigoIgVideoWatch = true;
  function ping(){
    try {
      if (document.querySelector('video')) {
        try { YorigoIgUserControl.postMessage('video_ready'); } catch (e0) {}
        return true;
      }
      var frames = document.querySelectorAll('iframe');
      for (var i = 0; i < frames.length; i++) {
        try {
          var doc = frames[i].contentDocument;
          if (doc && doc.querySelector('video')) {
            try { YorigoIgUserControl.postMessage('video_ready'); } catch (e1) {}
            return true;
          }
        } catch (e2) {}
      }
    } catch (e3) {}
    return false;
  }
  if (ping()) return;
  var obs = new MutationObserver(function(){
    if (ping()) { try { obs.disconnect(); } catch (e4) {} }
  });
  try {
    var root = document.documentElement || document.body;
    if (root) obs.observe(root, { childList: true, subtree: true });
  } catch (e5) {}
})();
''';

  static const String _inlineVideoPlayingJs = r'''
(function(){
  try {
    var v = document.querySelector('video');
    if (v && !v.paused) return 1;
    var frames = document.querySelectorAll('iframe');
    for (var i = 0; i < frames.length; i++) {
      try {
        var doc = frames[i].contentDocument;
        var x = doc && doc.querySelector('video');
        if (x && !x.paused) return 1;
      } catch (e) {}
    }
  } catch (e2) {}
  return 0;
})()
''';

  static const String _videoCountJs = r'''
(function(){
  function countInDoc(d) {
    if (!d) return 0;
    return d.querySelectorAll('video').length;
  }
  var n = countInDoc(document);
  if (n > 0) return n;
  var frames = document.querySelectorAll('iframe');
  for (var i = 0; i < frames.length; i++) {
    try {
      var doc = frames[i].contentDocument;
      var c = countInDoc(doc);
      if (c > 0) return c;
    } catch (e) {}
  }
  return 0;
})()
''';

  String _embedLayoutJs(
    double zoomEasyEmbed,
    double zoomPopupFlow,
    double docScrollPristinePx,
    double docScrollAfterNeverMissPx,
    double docScrollCleanLayoutPx,
    double cleanLayoutZoomMulEasyEmbed,
    double cleanLayoutZoomMulPopupFlow,
    double easyExtraZoomMul,
    double cleanLayoutShiftUpPx,
    double cleanLayoutClipTopPx,
    String letterboxCss,
  ) {
    final zE = zoomEasyEmbed.toStringAsFixed(4);
    final zP = zoomPopupFlow.toStringAsFixed(4);
    final syP = docScrollPristinePx.round();
    final syN = docScrollAfterNeverMissPx.round();
    final syC = docScrollCleanLayoutPx.round();
    final zCleanE = cleanLayoutZoomMulEasyEmbed.toStringAsFixed(4);
    final zCleanP = cleanLayoutZoomMulPopupFlow.toStringAsFixed(4);
    final zEasyX = easyExtraZoomMul.toStringAsFixed(4);
    final su = cleanLayoutShiftUpPx.round();
    final clip = cleanLayoutClipTopPx.round();
    final slotBgCss = letterboxCss;
    return '''
(function(){
  window.__yorigoIgScriptT = Date.now();
  if (typeof window.__yorigoIgNeverMissEver !== 'boolean') {
    window.__yorigoIgNeverMissEver = false;
  }

  var igLetterboxBg = '$slotBgCss';

  var baseZEasyEmbed = $zE;
  var baseZPopupFlow = $zP;
  function layoutBaseZ() {
    return window.__yorigoIgNeverMissEver ? baseZPopupFlow : baseZEasyEmbed;
  }
  var docScrollYPristine = $syP;
  var docScrollYMitigate = $syN;
  var docScrollYCleanFit = $syC;
  var cleanLayoutZoomMulEasy = $zCleanE;
  var cleanLayoutZoomMulPopup = $zCleanP;
  var easyExtraMul = $zEasyX;
  var cleanLayoutShiftUpPx = $su;
  var cleanLayoutClipTopPx = $clip;
  function effectiveScrollY() {
    if (window.__yorigoIgNeverMissEver) return docScrollYMitigate;
    if (window.__yorigoIgPostNeverMissLayoutUntil &&
        Date.now() < window.__yorigoIgPostNeverMissLayoutUntil) {
      return docScrollYMitigate;
    }
    return docScrollYPristine;
  }
  var minZoom = 0.20;
  var postPopupZoomMul = 0.92;
  var postPopupNeverMissMs = 14000;

  function applyLayoutCssToDoc(doc, cssText) {
    try {
      var el = doc.getElementById('yorigo-ig-layout');
      if (!el) {
        el = doc.createElement('style');
        el.id = 'yorigo-ig-layout';
        (doc.head || doc.documentElement).appendChild(el);
      }
      el.textContent = cssText;
    } catch (e) {}
  }

  function forEachSameOriginIframeDoc(fn) {
    var frames = document.querySelectorAll('iframe');
    for (var i = 0; i < frames.length; i++) {
      try {
        var d = frames[i].contentDocument;
        if (d) fn(d);
      } catch (e0) {}
    }
  }

  /// Hide login / signup walls by copy — avoid brittle hashed class names.
  /// Skips **Never miss a post** so auto-dismiss can still run.
  function suppressLoginWallOverlays(doc) {
    var vw = doc.defaultView || window;
    try {
      var nodes = doc.querySelectorAll('[role="dialog"],[aria-modal="true"]');
      for (var i = 0; i < nodes.length; i++) {
        var el = nodes[i];
        var st = vw.getComputedStyle(el);
        if (st.display === 'none' || st.visibility === 'hidden' || Number(st.opacity) < 0.05) continue;
        var r = el.getBoundingClientRect();
        if (r.width < 80 || r.height < 80) continue;
        var t = ((el.innerText || '') + ' ' + (el.getAttribute('aria-label') || '')).toLowerCase();
        if (/never\\s+miss|miss\\s+a\\s+post|게시물을\\s*놓치지/.test(t)) continue;
        var loginWall = /log in to instagram|log in to continue|sign up for instagram|\\bsign up\\b|create an account|see photos and videos from|로그인|회원가입|instagram 계정|계속하려면|로그인하여|로그인이 필요/.test(t);
        if (loginWall) {
          el.style.setProperty('display', 'none', 'important');
          el.style.setProperty('pointer-events', 'none', 'important');
        }
      }
    } catch (e1) {}
  }

  /// Fixed / sticky strips that contain account login links (header or footer bars).
  function hideFixedLoginChromeAncestors(doc) {
    var vw = doc.defaultView || window;
    try {
      var links = doc.querySelectorAll('a[href*="/accounts/login/"],a[href*="instagram.com/accounts/login"],a[href*="/accounts/emailsignup"]');
      for (var i = 0; i < links.length; i++) {
        var el = links[i];
        for (var up = 0; up < 10 && el; up++) {
          var st = vw.getComputedStyle(el);
          if (st.position === 'fixed' || st.position === 'sticky') {
            var r = el.getBoundingClientRect();
            var vh = vw.innerHeight || 900;
            if (r.width >= 72 && r.height >= 28 && r.top >= -2 && r.bottom <= vh + 6) {
              if (!el.getAttribute('data-yorigo-ig-kill')) {
                el.setAttribute('data-yorigo-ig-kill', '1');
                el.style.setProperty('display', 'none', 'important');
              }
            }
            break;
          }
          el = el.parentElement;
        }
      }
    } catch (e2) {}
  }

  function hideFixedTopStrip(doc) {
    try {
      var vw = doc.defaultView || window;
      var all = doc.querySelectorAll('*');
      for (var i = 0; i < all.length; i++) {
        var el = all[i];
        try {
          var tag = (el.tagName || '').toLowerCase();
          if (tag === 'video' || tag === 'audio') continue;
          var st = vw.getComputedStyle(el);
          if (st.display === 'none' || st.visibility === 'hidden' || Number(st.opacity) < 0.04) continue;
          if (st.position !== 'fixed' && st.position !== 'sticky') continue;
          var r = el.getBoundingClientRect();
          if (r.top <= 8 && r.height >= 8 && r.height <= 200 && r.width >= 40) {
            el.style.setProperty('display', 'none', 'important');
          }
        } catch (e0) {}
      }
    } catch (e1) {}
  }

  function stripChromeInReachableDocs() {
    suppressLoginWallOverlays(document);
    hideFixedLoginChromeAncestors(document);
    hideFixedTopStrip(document);
    forEachSameOriginIframeDoc(suppressLoginWallOverlays);
    forEachSameOriginIframeDoc(hideFixedLoginChromeAncestors);
    forEachSameOriginIframeDoc(hideFixedTopStrip);
  }

  function docText(win) {
    try {
      return (win.document.body && win.document.body.innerText) || '';
    } catch (e) { return ''; }
  }

  function embedShowsWatchOverlayCta() {
    var patterns = ['watch on instagram', 'view on instagram', 'instagram에서 보기', 'continue watching'];
    var all = document.querySelectorAll('a,button,[role="button"]');
    var vh = window.innerHeight || (document.documentElement && document.documentElement.clientHeight) || 600;
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      try {
        var st = window.getComputedStyle(el);
        if (st.display === 'none' || st.visibility === 'hidden' || Number(st.opacity) < 0.06) {
          continue;
        }
        var t = (el.textContent || '').trim().toLowerCase();
        if (t.length > 100) continue;
        var hit = false;
        for (var p = 0; p < patterns.length; p++) {
          if (t.indexOf(patterns[p]) >= 0) { hit = true; break; }
        }
        if (!hit) continue;
        var r = el.getBoundingClientRect();
        if (r.width < 40 || r.height < 14) continue;
        var footerBar = r.top > vh * 0.86 && r.height < 36 && r.width < 300;
        if (footerBar) continue;
        var cy = r.top + r.height * 0.5;
        if (cy < vh * 0.18 || cy > vh * 0.82) continue;
        return true;
      } catch (e) {}
    }
    return false;
  }

  function docHasNeverMiss(win) {
    var t = docText(win);
    return /never\\s+miss/i.test(t) || /miss\\s+a\\s+post/i.test(t) || /게시물을\\s*놓치지/i.test(t);
  }

  function hasVisibleBlockingModal(win) {
    try {
      var nodes = win.document.querySelectorAll('[role="dialog"],[aria-modal="true"]');
      for (var i = 0; i < nodes.length; i++) {
        var el = nodes[i];
        var st = win.getComputedStyle(el);
        var r = el.getBoundingClientRect();
        if (st.display === 'none' || st.visibility === 'hidden' || Number(st.opacity) < 0.08) {
          continue;
        }
        if (r.width > 88 && r.height > 88) {
          return true;
        }
      }
    } catch (e) {}
    return false;
  }

  function findClickableWithText(root, patterns) {
    var all = root.querySelectorAll('a,button,[role="button"]');
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      var txt = (el.textContent || '').trim().toLowerCase();
      if (txt.length > 200) continue;
      for (var j = 0; j < patterns.length; j++) {
        if (txt.indexOf(patterns[j]) >= 0) return el;
      }
    }
    return null;
  }

  function safeClick(el) {
    if (!el) return;
    try {
      el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
    } catch (e) {
      try { el.click(); } catch (e2) {}
    }
  }

  function autoDismissAndProceed() {
    if (docHasNeverMiss(window)) {
      var dismiss = findClickableWithText(document, ['not now', 'maybe later', 'no thanks', 'close', '나중에', '취소', '닫기']);
      if (dismiss) { safeClick(dismiss); return; }
      var closes = document.querySelectorAll('[aria-label="Close"],[aria-label="close"],[aria-label="닫기"]');
      if (closes.length) { safeClick(closes[closes.length - 1]); return; }
    }
    if (window.__yorigoIgIos === true) return;
    var now = Date.now();
    if (!window.__yorigoIgLastWatchClick || (now - window.__yorigoIgLastWatchClick > 5000)) {
      if (embedShowsWatchOverlayCta()) {
        var wbtn = findClickableWithText(document, ['watch on instagram', 'view on instagram', 'instagram에서 보기']);
        if (wbtn) {
          window.__yorigoIgLastWatchClick = now;
          safeClick(wbtn);
        }
      }
    }
  }

  function findVideoMeta() {
    var v = document.querySelector('video');
    if (v) return { el: v, win: window };
    var frames = document.querySelectorAll('iframe');
    for (var i = 0; i < frames.length; i++) {
      try {
        var doc = frames[i].contentDocument;
        var w = frames[i].contentWindow;
        if (doc && w) {
          v = doc.querySelector('video');
          if (v) return { el: v, win: w };
        }
      } catch (e) {}
    }
    return null;
  }

  function isInlineVideoPlaying() {
    try {
      var m = findVideoMeta();
      return !!(m && m.el && !m.el.paused);
    } catch (eP) {
      return false;
    }
  }

  function videoLooksReady(meta) {
    if (!meta) return false;
    var v = meta.el;
    if (v.readyState < 2) return false;
    if (v.videoWidth < 16 || v.videoHeight < 16) return false;
    if (embedShowsWatchOverlayCta()) return false;
    return true;
  }

  function needsChromeMitigation(meta) {
    if (!window.__yorigoIgNeverMissEver &&
        meta &&
        videoLooksReady(meta) &&
        !embedShowsWatchOverlayCta()) {
      return false;
    }
    if (window.__yorigoIgPostNeverMissLayoutUntil &&
        Date.now() < window.__yorigoIgPostNeverMissLayoutUntil) {
      return true;
    }
    if (embedShowsWatchOverlayCta()) return true;
    if (!meta) return true;
    return !videoLooksReady(meta);
  }

  /// True once blocking UI is gone and `<video>` is usable — same zoom path as a
  /// first-load embed, even if we previously saw never-miss (``__yorigoIgNeverMissEver``).
  function isCleanVideoLayout(meta) {
    if (!meta) return false;
    if (docHasNeverMiss(window)) return false;
    if (hasVisibleBlockingModal(window)) return false;
    if (embedShowsWatchOverlayCta()) return false;
    if (!videoLooksReady(meta)) return false;
    return true;
  }

  function applyStyle(z, scrollY, altWin, shiftUpPx) {
    var su = (typeof shiftUpPx === 'number' && shiftUpPx > 0) ? Math.round(shiftUpPx) : 0;
    var oy = su > 0 ? 'hidden' : 'auto';
    var ct = (typeof cleanLayoutClipTopPx === 'number' && cleanLayoutClipTopPx > 0) ? Math.round(cleanLayoutClipTopPx) : 0;
    var clipCss = (su > 0 && ct > 0) ? 'clip-path:inset('+ct+'px 0 0 0)!important;-webkit-clip-path:inset('+ct+'px 0 0 0)!important;' : '';
    var htmlClip = su > 0 ? 'html{overflow:hidden!important;height:100%!important;max-height:100vh!important;'+clipCss+'}' : '';
    var bodyUp = su > 0 ? (ct > 0 ? ct + su : su) : 0;
    var bodyShift = bodyUp > 0 ? 'position:relative!important;top:-'+bodyUp+'px!important;' : '';
    var chrome = 'nav,header,footer,[role="banner"],[role="contentinfo"]{display:none!important;}';
    var layoutCss = chrome + ' html,body{background:'+igLetterboxBg+'!important;margin:0!important;padding:0!important;overflow-x:hidden!important;overflow-y:'+oy+'!important;min-height:100%!important;overscroll-behavior-y:contain;} '+htmlClip+' body{zoom:'+z+'; -webkit-text-size-adjust:100%;'+bodyShift+'}';
    applyLayoutCssToDoc(document, layoutCss);
    try {
      if (altWin && altWin !== window && altWin.document) applyLayoutCssToDoc(altWin.document, layoutCss);
    } catch (eAlt) {}
    function touchDocs(fn) {
      fn(document);
      try {
        if (altWin && altWin !== window && altWin.document) fn(altWin.document);
      } catch (eD) {}
    }
    touchDocs(suppressLoginWallOverlays);
    touchDocs(hideFixedLoginChromeAncestors);
    touchDocs(hideFixedTopStrip);
    function setDocScroll(w, y) {
      if (!w) return;
      try {
        var yi = Math.max(0, Math.round(y));
        w.scrollTo(0, yi);
        var d = w.document;
        if (d && d.documentElement) {
          d.documentElement.scrollTop = yi;
          d.documentElement.scrollLeft = 0;
        }
        if (d && d.scrollingElement) {
          d.scrollingElement.scrollTop = yi;
          d.scrollingElement.scrollLeft = 0;
        }
        if (d && d.body) {
          d.body.scrollTop = yi;
          d.body.scrollLeft = 0;
        }
      } catch (e) {}
    }
    setDocScroll(window, scrollY);
    if (altWin && altWin !== window) setDocScroll(altWin, scrollY);
    try {
      requestAnimationFrame(function() {
        setDocScroll(window, scrollY);
        if (altWin && altWin !== window) setDocScroll(altWin, scrollY);
        requestAnimationFrame(function() {
          setDocScroll(window, scrollY);
          if (altWin && altWin !== window) setDocScroll(altWin, scrollY);
        });
      });
    } catch (eRaf) {}
    window.__yorigoIgLastZ = z;
    window.__yorigoIgLastScroll = scrollY;
  }

  function scheduleFitWhenPopupClear() {
    clearTimeout(window.__yorigoIgPostDismissFitT);
    window.__yorigoIgPostDismissFitT = setTimeout(function() {
      window.__yorigoIgPostDismissFitT = null;
      fitFromVideo();
    }, 700);
  }

  function fitFromVideo() {
    // 재생 중에는 줌/클릭/pause를 다시 넣지 않는다. 상세에서 재생 직후
    // 레이아웃 타이머가 영상을 멈추던 원인.
    if (isInlineVideoPlaying()) return;
    try {
      var watchNow = embedShowsWatchOverlayCta();
      if (watchNow && window.__yorigoIgWatchCta !== true) {
        window.__yorigoIgWatchCta = true;
        try { YorigoIgUserControl.postMessage('watch_cta'); } catch (eW) {}
      }
    } catch (eWx) {}
    if (docHasNeverMiss(window)) {
      window.__yorigoIgNeverMissEver = true;
    }
    var neverMissBefore = docHasNeverMiss(window);
    autoDismissAndProceed();
    stripChromeInReachableDocs();

    if (docHasNeverMiss(window) || hasVisibleBlockingModal(window)) {
      scheduleFitWhenPopupClear();
      return;
    }

    if (neverMissBefore) {
      window.__yorigoIgNeverMissEver = true;
      window.__yorigoIgPostNeverMissLayoutUntil = Date.now() + postPopupNeverMissMs;
      scheduleFitWhenPopupClear();
      setTimeout(function() {
        fitFromVideo();
      }, 950);
      return;
    }

    if (!window.__yorigoIgInstalled) {
      try {
        var pv = document.querySelector('video');
        if (pv) {
          pv.removeAttribute('autoplay');
          pv.autoplay = false;
        }
      } catch (eP) {}
    }
    var meta = findVideoMeta();
    if (isCleanVideoLayout(meta)) {
      var postNeverMissClean = !!window.__yorigoIgNeverMissEver;
      var zp = layoutBaseZ();
      var sc = postNeverMissClean ? docScrollYCleanFit : docScrollYPristine;
      var sh = 0;
      var awp = meta.win;
      var vidp = meta.el;
      var vhp = awp.innerHeight || (awp.document.documentElement && awp.document.documentElement.clientHeight) || 600;
      // Easy embed: tighter bottom fit (smaller). Popup flow: looser band.
      var vCut = postNeverMissClean ? 3 : 14;
      var vShr = postNeverMissClean ? 4 : 16;
      var vFac = postNeverMissClean ? 0.999 : 0.997;
      for (var jp = 0; jp < 12; jp++) {
        applyStyle(zp, sc, awp, sh);
        var rp = vidp.getBoundingClientRect();
        var chp = false;
        if (rp.bottom > vhp - vCut) {
          zp = Math.max(minZoom, zp * (vhp - vShr) / rp.bottom * vFac);
          chp = true;
        }
        if (!chp) break;
      }
      zp = zp * (postNeverMissClean ? cleanLayoutZoomMulPopup : cleanLayoutZoomMulEasy);
      zp = Math.max(zp, minZoom);
      if (!postNeverMissClean && easyExtraMul < 0.9999) {
        zp = zp * easyExtraMul;
        zp = Math.max(zp, minZoom);
      }
      applyStyle(zp, sc, awp, sh);
      if (window.ResizeObserver && vidp) {
        if (window.__yorigoIgVideoEl !== vidp) {
          if (window.__yorigoIgVideoRo) { try { window.__yorigoIgVideoRo.disconnect(); } catch (eR1) {} }
          window.__yorigoIgVideoEl = vidp;
          window.__yorigoIgVideoRo = new ResizeObserver(function() {
            clearTimeout(window.__yorigoIgRoT);
            window.__yorigoIgRoT = setTimeout(fitFromVideo, 100);
          });
          try { window.__yorigoIgVideoRo.observe(vidp); } catch (eR2) {}
        }
      }
      return;
    }
    var mitigate = needsChromeMitigation(meta);
    var postPopup = window.__yorigoIgPostNeverMissLayoutUntil &&
        Date.now() < window.__yorigoIgPostNeverMissLayoutUntil;
    var igNm = !!window.__yorigoIgNeverMissEver;
    var popZ = postPopup ? (igNm ? 1.0 : postPopupZoomMul) : 1.0;
    var z = layoutBaseZ() * popZ;
    if (mitigate && !postPopup) {
      z *= igNm ? 1.07 : 1.02;
    }
    var aw = meta ? meta.win : null;
    if (!meta) {
      if (!window.__yorigoIgNeverMissEver && easyExtraMul < 0.9999) {
        z = z * easyExtraMul;
        z = Math.max(z, minZoom);
      }
      applyStyle(z, effectiveScrollY(), null, 0);
      return;
    }
    var vid = meta.el;
    var win = meta.win;
    var vh = win.innerHeight || (win.document.documentElement && win.document.documentElement.clientHeight) || 600;
    var bMit = igNm ? 12 : 22;
    var bPop = igNm ? 16 : 30;
    var bCln = igNm ? 8 : 14;
    var bottomPad = postPopup ? bPop : (mitigate ? bMit : bCln);
    var iter;
    for (iter = 0; iter < 14; iter++) {
      applyStyle(z, effectiveScrollY(), aw, 0);
      var r = vid.getBoundingClientRect();
      var changed = false;
      if (r.bottom > vh - bottomPad) {
        var ratio = (vh - bottomPad - 2) / r.bottom;
        var tight = mitigate ? (postPopup ? (igNm ? 0.992 : 0.984) : (igNm ? 0.995 : 0.991)) : (igNm ? 0.999 : 0.998);
        z = Math.max(minZoom, z * ratio * tight);
        changed = true;
      }
      if (r.height > vh * (mitigate ? (postPopup ? (igNm ? 0.92 : 0.886) : (igNm ? 0.96 : 0.927)) : (igNm ? 0.975 : 0.948))) {
        var target = postPopup ? (igNm ? 0.88 : 0.845) : (mitigate ? (igNm ? 0.92 : 0.886) : (igNm ? 0.94 : 0.906));
        z = Math.max(minZoom, z * (vh * target / r.height));
        changed = true;
      }
      if (!changed) break;
    }
    if (!igNm && easyExtraMul < 0.9999) {
      z = z * easyExtraMul;
      z = Math.max(z, minZoom);
    }
    applyStyle(z, effectiveScrollY(), aw, 0);
    if (window.ResizeObserver && vid) {
      if (window.__yorigoIgVideoEl !== vid) {
        if (window.__yorigoIgVideoRo) { try { window.__yorigoIgVideoRo.disconnect(); } catch (e1) {} }
        window.__yorigoIgVideoEl = vid;
        window.__yorigoIgVideoRo = new ResizeObserver(function() {
          clearTimeout(window.__yorigoIgRoT);
          window.__yorigoIgRoT = setTimeout(fitFromVideo, 100);
        });
        try { window.__yorigoIgVideoRo.observe(vid); } catch (e2) {}
      }
    }
  }

  if (window.__yorigoIgLayoutObserver) {
    try { window.__yorigoIgLayoutObserver.disconnect(); } catch (e3) {}
  }
  var debT = null;
  function debouncedFit() {
    clearTimeout(debT);
    debT = setTimeout(fitFromVideo, 140);
  }
  window.__yorigoIgLayoutObserver = new MutationObserver(debouncedFit);
  var root = document.body || document.documentElement;
  try {
    window.__yorigoIgLayoutObserver.observe(root, { subtree: true, childList: true });
  } catch (e4) {}

  window.__yorigoIgRefit = fitFromVideo;
  window.__yorigoIgStripChrome = stripChromeInReachableDocs;
  stripChromeInReachableDocs();
  setTimeout(fitFromVideo, 50);
  debouncedFit();
  setTimeout(fitFromVideo, 450);
  setTimeout(fitFromVideo, 1100);
  setTimeout(fitFromVideo, 2400);
  setTimeout(fitFromVideo, 4500);
  try {
    if (window.__yorigoIgIos === true && window.__yorigoIgEnsurePoster) {
      window.__yorigoIgEnsurePoster();
    }
  } catch (ePoster) {}
})();
''';
  }

  Future<bool> _isInlineVideoPlaying() async {
    final controller = _controller;
    if (controller == null) return false;
    try {
      final raw =
          await controller.runJavaScriptReturningResult(_inlineVideoPlayingJs);
      return _coerceJsBoolInt(raw);
    } catch (_) {
      return false;
    }
  }

  Future<void> _applyEmbedLayoutFromController() async {
    final controller = _controller;
    if (controller == null) return;
    if (await _isInlineVideoPlaying()) return;
    final sc = _embedDocScrollScale;
    // Pristine = easy embed only: fixed px, not scaled with WebView width.
    final syP = _clampScroll(_embedDocScrollPx);
    // `<video>`가 없으면 never-miss 스크롤(약 366px)이 프로필 그리드를 보여 준다.
    final syN = _videoBridgeReady
        ? _clampScroll(_embedDocScrollPxAfterNeverMiss * sc)
        : syP;
    final syC = _clampScroll(_embedDocScrollPxCleanLayout * sc);
    final sig =
        '${_videoBridgeReady}_${_layoutZoomEasyEmbed.toStringAsFixed(4)}_${_layoutZoomPopupFlow.toStringAsFixed(4)}_slot_${_slotLetterboxCss}_ig_${syP.toStringAsFixed(0)}_${syN.toStringAsFixed(0)}_${syC.toStringAsFixed(0)}_${_embedCleanLayoutZoomMulEasyEmbed.toStringAsFixed(3)}_${_embedCleanLayoutZoomMulPopupFlow.toStringAsFixed(3)}_${_embedEasyExtraZoomMul.toStringAsFixed(3)}_${_embedCleanLayoutShiftUpPx.toStringAsFixed(0)}_${_embedCleanLayoutClipTopPx.toStringAsFixed(0)}';
    if (_lastAppliedLayoutSignature == sig) return;
    _lastAppliedLayoutSignature = sig;
    try {
      debugPrint(
        '======== [yorigo IG] $_igLayoutDiagRev inject scroll(px): pristine=${syP.toStringAsFixed(0)} neverMiss=${syN.toStringAsFixed(0)} clean=${syC.toStringAsFixed(0)} (scale=${sc.toStringAsFixed(3)} tunedAt=$_embedDocScrollTunedAtWidthFactor width=$_embedWebViewWidthFactor)',
      );
      await controller.runJavaScript(
        _embedLayoutJs(
          _layoutZoomEasyEmbed,
          _layoutZoomPopupFlow,
          syP,
          syN,
          syC,
          _embedCleanLayoutZoomMulEasyEmbed,
          _embedCleanLayoutZoomMulPopupFlow,
          _embedEasyExtraZoomMul,
          _embedCleanLayoutShiftUpPx,
          _embedCleanLayoutClipTopPx,
          _slotLetterboxCss,
        ),
      );
      _scheduleIosPlayableReveal(_iosFramingCoverAfterLayout);
      unawaited(_injectIosHtmlPoster());
      if (kDebugMode) {
        unawaited(_logIgLayoutAfterInject(controller));
      }
    } catch (e) {
      debugPrint('[InstagramPlayerWidget] layout JS failed: $e');
      _ensureIosPlayableRevealFallback();
    }
  }

  /// Confirms injected layout ran and reports JS-side never-miss flag + last zoom.
  static const String _igLayoutDiagRev = 'IG_LAYOUT_V3';

  Future<void> _logIgLayoutAfterInject(WebViewController controller) async {
    Future<void> probe(String tag) async {
      final raw = await controller.runJavaScriptReturningResult(
        r"(function(){try{return JSON.stringify({neverMiss:!!window.__yorigoIgNeverMissEver,lastZ:typeof window.__yorigoIgLastZ==='number'?window.__yorigoIgLastZ:null});}catch(e){return JSON.stringify({err:String(e)})}})()",
      );
      debugPrint(
        '======== [yorigo IG] $_igLayoutDiagRev $tag: $raw | dart easyZ=${_layoutZoomEasyEmbed.toStringAsFixed(3)} popupZ=${_layoutZoomPopupFlow.toStringAsFixed(3)} easyExtra=${_embedEasyExtraZoomMul.toStringAsFixed(3)}',
      );
    }

    try {
      final shortUrl = _loadedEmbedUrl.length > 72
          ? '${_loadedEmbedUrl.substring(0, 72)}…'
          : _loadedEmbedUrl;
      debugPrint(
        '======== [yorigo IG] $_igLayoutDiagRev layout inject ok | url=$shortUrl',
      );
      await probe('JS state (immediate)');
      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      if (!mounted) return;
      await probe('JS state (after ~1.6s fit)');
    } catch (e) {
      debugPrint(
        '======== [yorigo IG] $_igLayoutDiagRev layout diag failed: $e',
      );
    }
  }

  void _scheduleLayoutJankCover(Duration hold) {
    _layoutJankCoverTimer?.cancel();
    if (!mounted) return;
    setState(() => _layoutJankCoverVisible = true);
    _layoutJankCoverTimer = Timer(hold, () {
      if (!mounted) return;
      setState(() => _layoutJankCoverVisible = false);
    });
  }

  void _hideIosFramingCover() {
    _iosFramingCoverTimer?.cancel();
    _iosFramingCoverFallbackTimer?.cancel();
    _iosFramingCoverTimer = null;
    _iosFramingCoverFallbackTimer = null;
    unawaited(_runJs(
      r'try{window.__yorigoIgHidePoster&&window.__yorigoIgHidePoster();}catch(e){}',
    ));
    if (!mounted || !_iosFramingCoverVisible) return;
    setState(() => _iosFramingCoverVisible = false);
  }

  /// 재생 가능한 임베드: 검은 포스터/가짜 재생 버튼을 걷고 실제 플레이어를 보여 준다.
  void _revealIosPlayablePlayer() {
    if (!mounted || !_isIos || _iosWatchOnInstagramOnly || _hasLoadError) {
      return;
    }
    _hideIosFramingCover();
  }

  void _scheduleIosPlayableReveal(Duration hold) {
    if (!_isIos ||
        !_iosFramingCoverVisible ||
        _iosWatchOnInstagramOnly ||
        !mounted) {
      return;
    }
    _iosFramingCoverFallbackTimer?.cancel();
    _iosFramingCoverFallbackTimer = null;
    _iosFramingCoverTimer?.cancel();
    _iosFramingCoverTimer = Timer(hold, _revealIosPlayablePlayer);
  }

  /// layout inject가 없어도 재생 가능 임베드가 포스터에 갇히지 않게 한다.
  void _ensureIosPlayableRevealFallback() {
    if (!_isIos ||
        !_iosFramingCoverVisible ||
        _iosWatchOnInstagramOnly ||
        !mounted) {
      return;
    }
    _iosFramingCoverFallbackTimer ??=
        Timer(_iosFramingCoverFallback, _revealIosPlayablePlayer);
  }

  void _markIosWatchOnInstagramOnly() {
    if (!_isIos || !mounted || _iosWatchOnInstagramOnly) return;
    _iosFramingCoverTimer?.cancel();
    _iosFramingCoverFallbackTimer?.cancel();
    _iosFramingCoverTimer = null;
    _iosFramingCoverFallbackTimer = null;
    setState(() {
      _iosWatchOnInstagramOnly = true;
      _iosFramingCoverVisible = true;
    });
    unawaited(_injectIosHtmlPoster());
  }

  Future<void> _injectIosHtmlPoster() async {
    if (!_isIos || _hasLoadError) return;
    // 재생 가능 임베드에 HTML 검정 포스터를 씌우면 실제 플레이어가 가려진다.
    if (!_iosWatchOnInstagramOnly) {
      await _runJs(
        r'try{window.__yorigoIgHidePoster&&window.__yorigoIgHidePoster();}catch(e){}',
      );
      return;
    }
    final thumbJs = jsonEncode(widget.thumbnailUrl?.trim() ?? '');
    await _runJs('''
window.__yorigoIgIos = true;
window.__yorigoIgPosterThumb = $thumbJs;
window.__yorigoIgPosterArmed = false;
window.__yorigoIgWatchCta = true;
window.__yorigoIgPosterHidden = false;
$_iosHtmlPosterBootstrapJs
''');
  }

  void _onIosPosterPlayFromWebView() {
    if (!mounted || _iosWatchOnInstagramOnly || _hasLoadError) return;
    if (_heroPlayRequested && !_iosFramingCoverVisible) return;
    _heroPlayRequested = true;
    _playbackKindRestart = false;
    if (_iosFramingCoverVisible) {
      _hideIosFramingCover();
    }
    widget.onUserPlayedInPlayer?.call();
  }

  static Map<String, String>? _iosImageHeadersFor(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('cdninstagram') ||
        lower.contains('fbcdn.net') ||
        lower.contains('instagram.com')) {
      return InlineVideoHeroPoster.instagramThumbnailHeaders;
    }
    return null;
  }

  void _precacheIosThumbnail() {
    final url = widget.thumbnailUrl?.trim() ?? '';
    if (url.isEmpty) return;
    final headers = _iosImageHeadersFor(url);
    unawaited(
      precacheImage(
        CachedNetworkImageProvider(
          url,
          headers: headers,
          cacheKey: url,
        ),
        context,
      ),
    );
  }

  Future<void> _installControlBridge(WebViewController controller) async {
    if (_isIos) {
      await controller.runJavaScript(_iosPlaybackIntentPreludeJs);
      await _injectIosHtmlPoster();
    }
    await controller.runJavaScript(_controlBridgeJs);
  }

  void _scheduleLayoutZoomApply({
    required double boxW,
    required double boxH,
  }) {
    if (_lastLayoutScheduleBoxW == boxW &&
        _lastLayoutScheduleBoxH == boxH) {
      return;
    }
    _lastLayoutScheduleBoxW = boxW;
    _lastLayoutScheduleBoxH = boxH;

    final webViewWidth = boxW * _embedWebViewWidthFactor;
    final estVideoH = webViewWidth * 16 / 9;
    var slotZoom = 1.0;
    if (estVideoH > boxH) {
      slotZoom = ((boxH * _embedSlotHeightFitFactor) / estVideoH)
          .clamp(_embedZoomMin, _embedZoomMaxEasyEmbed);
    }
    final nextEasy = (slotZoom * _embedPageZoomMulEasyEmbed)
        .clamp(_embedZoomMin, _embedZoomMaxEasyEmbed);
    final nextPopup = (slotZoom * _embedPageZoomMulPopupFlow)
        .clamp(_embedZoomMin, _embedZoomMaxPopupFlow);
    debugPrint(
      '======== [yorigo IG] $_igLayoutDiagRev slot compute: box=${boxW.toStringAsFixed(0)}x${boxH.toStringAsFixed(0)} webViewW=${webViewWidth.toStringAsFixed(0)} (factor=$_embedWebViewWidthFactor) estVH=${estVideoH.toStringAsFixed(0)} slotZ=${slotZoom.toStringAsFixed(3)} -> easy=${nextEasy.toStringAsFixed(3)} popup=${nextPopup.toStringAsFixed(3)} (easyExtra=${_embedEasyExtraZoomMul.toStringAsFixed(3)} applies in JS when neverMiss=false)',
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if ((nextEasy - _layoutZoomEasyEmbed).abs() < 0.001 &&
          (nextPopup - _layoutZoomPopupFlow).abs() < 0.001) {
        _applyEmbedLayoutFromController();
        return;
      }
      _layoutZoomEasyEmbed = nextEasy;
      _layoutZoomPopupFlow = nextPopup;
      _lastAppliedLayoutSignature = null;
      _applyEmbedLayoutFromController();
    });
  }

  /// IG 임베드 페이지 안의 `<video>` element를 제어하는 헬퍼 JS.
  /// Instagram 자동재생은 처음에만 막고, WebView 안에서 탭 재생/일시정지는 그대로 동작하게 한다.
  static const String _controlBridgeJs = r'''
  (function(){
    if (window.__yorigoIgInstalled) return;
    /** Dart sets this when the hero overlay is tapped, before the bridge may exist — disables autoplay-suppression pause once user asked to play. */
    function findVideo() {
      var v = document.querySelector('video');
      if (v) return v;
      var frames = document.querySelectorAll('iframe');
      for (var i = 0; i < frames.length; i++) {
        try {
          var doc = frames[i].contentDocument;
          if (doc) {
            v = doc.querySelector('video');
            if (v) return v;
          }
        } catch (e) {}
      }
      return null;
    }
    var vid = findVideo();
    if (!vid) return;
    window.__yorigoIgInstalled = true;
    if (typeof window.__yorigoIgUserIntentPlay !== 'boolean') {
      window.__yorigoIgUserIntentPlay = false;
    }
    function syncVidRef() {
      var live = findVideo();
      if (!live) return;
      try {
        if (!vid || !vid.isConnected) {
          vid = live;
        }
      } catch (e) {
        vid = live;
      }
    }
    function ensureInlinePlaybackAttrs(t) {
      if (!t) return;
      try {
        t.setAttribute('playsinline', '');
        t.setAttribute('webkit-playsinline', '');
        t.playsInline = true;
      } catch (e) {}
    }
    if (window.__yorigoIgIos === true) {
      ensureInlinePlaybackAttrs(vid);
      window.__yorigoIgFromAppApi = false;
      window.__yorigoIgHalted = false;
      function markFromAppApi() {
        window.__yorigoIgFromAppApi = true;
        setTimeout(function() { window.__yorigoIgFromAppApi = false; }, 280);
      }
      function playVideo() {
        syncVidRef();
        if (!vid) return;
        ensureInlinePlaybackAttrs(vid);
        try {
          var p = vid.play();
          if (p && typeof p.catch === 'function') p.catch(function(){});
        } catch (e) {}
      }
      vid.addEventListener('play', function() {
        try { YorigoIgUserControl.postMessage('user_play'); } catch (e) {}
      });
      vid.addEventListener('pause', function() {
        if (window.__yorigoIgFromAppApi) return;
        try { YorigoIgUserControl.postMessage('user_pause'); } catch (e) {}
      });
      window.__yorigoIgSetGuard = function(){};
      window.__yorigoIgSetHalted = function(h){ window.__yorigoIgHalted = !!h; };
      window.__yorigoIgAssistPlaybackChrome = function(){};
      window.__yorigoIgPlay = function(){
        markFromAppApi();
        playVideo();
      };
      window.__yorigoIgPause = function(){
        markFromAppApi();
        syncVidRef();
        try { if (vid) vid.pause(); } catch (e) {}
      };
      window.__yorigoIgRestart = function(){
        markFromAppApi();
        syncVidRef();
        try { if (vid) vid.currentTime = 0; } catch (e) {}
        playVideo();
      };
      window.__yorigoIgSeekBy = function(d){
        syncVidRef();
        if (!vid) return;
        try { vid.currentTime = Math.max(0, (vid.currentTime || 0) + Number(d)); } catch (e) {}
      };
      window.__yorigoIgSeekTo = function(t){
        syncVidRef();
        if (!vid) return;
        try {
          var x = Number(t);
          if (!isFinite(x) || x < 0) return;
          var dur = vid.duration;
          if (isFinite(dur) && dur > 0.1) {
            x = Math.min(x, Math.max(0, dur - 0.05));
          }
          vid.currentTime = x;
        } catch (e) {}
      };
      window.__yorigoIgSeekToAndPlay = function(t){
        markFromAppApi();
        window.__yorigoIgSeekTo(t);
        playVideo();
      };
      window.__yorigoIgGetTime = function(){
        syncVidRef();
        if (!vid) return 0;
        try { return vid.currentTime || 0; } catch (e) { return 0; }
      };
      return;
    }
    var suppressAutoplayPause = window.__yorigoIgAllowPlaybackEarly !== true;
    // iOS: `<video>`는 사용자가 이미 재생을 탭한 뒤에야 생기는 경우가 많다.
    // suppress 상태로 브릿지를 붙이면 그 탭이 즉시 pause 된다.
    if (window.__yorigoIgIos === true) {
      suppressAutoplayPause = false;
      if (!vid.paused) {
        window.__yorigoIgUserIntentPlay = true;
      }
    }
    function ensureVideoAudible() {
      syncVidRef();
      var t = findVideo() || vid;
      if (!t) return;
      ensureInlinePlaybackAttrs(t);
      // iOS: 재생 중에 muted를 바꾸면 WKWebView가 곧바로 pause 한다.
      if (window.__yorigoIgIos === true && !t.paused) return;
      try {
        t.muted = false;
        t.defaultMuted = false;
        t.removeAttribute('muted');
        if (typeof t.volume === 'number') {
          t.volume = 1.0;
        }
      } catch (e) {}
    }
    function playVideo() {
      syncVidRef();
      if (!vid) return;
      ensureInlinePlaybackAttrs(vid);
      try {
        var p = vid.play();
        if (p && typeof p.then === 'function') {
          p.then(function() {
            if (window.__yorigoIgIos === true) {
              ensureInlinePlaybackAttrs(vid);
              return;
            }
            ensureVideoAudible();
          }).catch(function() {
            try {
              vid.muted = true;
              var p2 = vid.play();
              if (p2 && typeof p2.then === 'function') {
                p2.then(function() {
                  if (window.__yorigoIgIos !== true) ensureVideoAudible();
                }).catch(function(){});
              }
            } catch (e2) {}
          });
        }
      } catch (e) {}
    }
    try {
      ensureInlinePlaybackAttrs(vid);
      vid.removeAttribute('autoplay');
      vid.autoplay = false;
      // iOS: <video> often appears only after the user already tapped play.
      // Pausing here would immediately stop that tap.
      if (vid.paused &&
          window.__yorigoIgAllowPlaybackEarly !== true &&
          !window.__yorigoIgUserIntentPlay) {
        vid.pause();
      }
    } catch (e) {}
    window.__yorigoIgFromAppApi = false;
    window.__yorigoIgLastTrustedPointerMs = 0;
    function markFromAppApi() {
      window.__yorigoIgFromAppApi = true;
      setTimeout(function() { window.__yorigoIgFromAppApi = false; }, 280);
    }
    function noteUserPlaybackIntent(ev) {
      suppressAutoplayPause = false;
      if (ev && ev.isTrusted) {
        window.__yorigoIgUserIntentPlay = true;
        window.__yorigoIgLastTrustedPointerMs = Date.now();
      }
    }
    vid.addEventListener('pointerdown', noteUserPlaybackIntent, true);
    vid.addEventListener('touchstart', noteUserPlaybackIntent, true);
    document.addEventListener('pointerdown', function(ev) {
      if (!vid) return;
      var r = vid.getBoundingClientRect();
      var x = ev.clientX;
      var y = ev.clientY;
      if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) {
        noteUserPlaybackIntent(ev);
      }
    }, true);
      vid.addEventListener('play', function() {
        if (window.__yorigoIgIos === true) {
          suppressAutoplayPause = false;
          window.__yorigoIgUserIntentPlay = true;
          return;
        }
        if (suppressAutoplayPause && !window.__yorigoIgUserIntentPlay) {
          try { vid.pause(); } catch (e) {}
        }
      });
    var guardOn = false;
    var intendedPlaying = false;
    var assistStopped = false;
    var __yorigoIgAssistTimeouts = [];
    if (window.__yorigoIgIos === true && vid && !vid.paused) {
      intendedPlaying = true;
    }
    vid.addEventListener('playing', function() {
      if (window.__yorigoIgIos === true) {
        ensureInlinePlaybackAttrs(vid);
        intendedPlaying = true;
        window.__yorigoIgUserIntentPlay = true;
      } else {
        ensureVideoAudible();
      }
      if (window.__yorigoIgFromAppApi) return;
      var recentPointer = (Date.now() - window.__yorigoIgLastTrustedPointerMs) < 3000;
      if (recentPointer && window.__yorigoIgHalted) {
        try { YorigoIgUserControl.postMessage('user_play'); } catch (e) {}
      }
    }, true);
    vid.addEventListener('timeupdate', function() {
      if (assistStopped || !intendedPlaying) return;
      var vx = findVideo();
      if (!vx || vx.paused) return;
      try {
        if (vx.currentTime >= 0.12) {
          markPlaybackAssistDone();
        }
      } catch (e) {}
    }, true);
    window.__yorigoIgHalted = false;
    function resumeIfIosIntentStillPlay() {
      if (window.__yorigoIgHalted) return;
      if (!(intendedPlaying || window.__yorigoIgUserIntentPlay)) return;
      var live = findVideo() || vid;
      if (!live || !live.paused) return;
      playVideo();
      setTimeout(function() {
        if (window.__yorigoIgHalted) return;
        var v2 = findVideo() || vid;
        if (v2 && v2.paused) clickIgLabeledPlayChrome();
      }, 80);
    }
    vid.addEventListener('pause', function(){
      if (window.__yorigoIgIos === true) {
        if (window.__yorigoIgFromAppApi) return;
        var t = 0;
        try { t = vid.currentTime || 0; } catch (eT) {}
        var recentPointer = (Date.now() - (window.__yorigoIgLastTrustedPointerMs || 0)) < 700;
        var stable = t >= 0.75;
        if (recentPointer && stable) {
          window.__yorigoIgHalted = true;
          intendedPlaying = false;
          assistStopped = true;
          window.__yorigoIgUserIntentPlay = false;
          clearAssistTimeoutsOnly();
          try { YorigoIgUserControl.postMessage('user_pause'); } catch (e) {}
          return;
        }
        if (!window.__yorigoIgHalted && (intendedPlaying || window.__yorigoIgUserIntentPlay)) {
          setTimeout(resumeIfIosIntentStillPlay, 60);
        }
        return;
      }
      if (window.__yorigoIgFromAppApi) {
        // App-driven pause — don't intercept.
      } else {
        var recentPointer = (Date.now() - window.__yorigoIgLastTrustedPointerMs) < 3000;
        if (recentPointer) {
          window.__yorigoIgHalted = true;
          intendedPlaying = false;
          assistStopped = true;
          clearAssistTimeoutsOnly();
          try { YorigoIgUserControl.postMessage('user_pause'); } catch (e) {}
          return;
        }
      }
      if (guardOn && intendedPlaying && !window.__yorigoIgHalted) {
        setTimeout(function(){
          if (guardOn && intendedPlaying && !window.__yorigoIgHalted) {
            playVideo();
          }
        }, 50);
      }
    });
    window.__yorigoIgSetGuard = function(on){ guardOn = !!on; };
    window.__yorigoIgSetHalted = function(h){
      window.__yorigoIgHalted = !!h;
      if (h) {
        assistStopped = true;
        intendedPlaying = false;
        window.__yorigoIgUserIntentPlay = false;
        clearAssistTimeoutsOnly();
      }
    };
    function tapClientPoint(cx, cy) {
      try {
        var el = document.elementFromPoint(cx, cy);
        if (!el || el === document.body || el === document.documentElement) return;
        try { el.click(); } catch (ce) {}
      } catch (e) {}
    }
    function clearAssistTimeoutsOnly() {
      var i;
      for (i = 0; i < __yorigoIgAssistTimeouts.length; i++) {
        clearTimeout(__yorigoIgAssistTimeouts[i]);
      }
      __yorigoIgAssistTimeouts.length = 0;
    }
    function markPlaybackAssistDone() {
      assistStopped = true;
      clearAssistTimeoutsOnly();
    }
    function shouldKickIgOverlay(v) {
      if (!v) return false;
      if (window.__yorigoIgIos === true) {
        return !!v.paused;
      }
      if (window.__yorigoIgNeverMissEver) {
        return !!v.paused;
      }
      if (v.paused) return true;
      try {
        if (v.readyState <= 2 && v.currentTime < 0.35) return true;
      } catch (e) {}
      return false;
    }
    function clickIgLabeledPlayChrome() {
      var nodes = document.querySelectorAll('[role="button"],button,a,a[href="#"],a[role="link"],div[role="button"],[tabindex="0"]');
      var i, n, al, t;
      for (i = 0; i < nodes.length; i++) {
        n = nodes[i];
        al = (n.getAttribute('aria-label') || n.getAttribute('title') || '').toLowerCase();
        t = (n.innerText || '').trim().toLowerCase();
        var hay = al + ' | ' + t;
        if ((/\bplay\b|play video|watch video|tap to play|재생|동영상|비디오/.test(hay)) &&
            !/playlist|upload|gallery|clip/i.test(hay)) {
          try {
            n.click();
            return true;
          } catch (e) {}
        }
      }
      return false;
    }
    function playbackAssistWave(wave) {
      if (assistStopped || !intendedPlaying) return;
      syncVidRef();
      var v0 = findVideo();
      if (window.__yorigoIgIos === true && v0 && !v0.paused) {
        markPlaybackAssistDone();
        return;
      }
      ensureVideoAudible();
      if (window.__yorigoIgNeverMissEver && wave === 0) {
        tryNeverMissUnmuteChrome();
      }
      if (v0 && !v0.paused) return;
      if (clickIgLabeledPlayChrome()) return;
      var v = findVideo();
      if (!v || !shouldKickIgOverlay(v)) return;
      var r = v.getBoundingClientRect();
      if (r.width < 4 || r.height < 4) return;
      var cx = r.left + r.width * 0.5;
      if (wave === 0) {
        tapClientPoint(cx, r.top + r.height * 0.5);
      } else if (wave === 1) {
        tapClientPoint(cx, r.top + r.height * 0.46);
        tapClientPoint(cx, r.top + r.height * 0.54);
      } else {
        tapClientPoint(cx, r.top + r.height * 0.42);
        tapClientPoint(cx, r.top + r.height * 0.5);
        tapClientPoint(cx, r.top + r.height * 0.58);
      }
    }
    function schedulePlaybackAssistWaves() {
      clearAssistTimeoutsOnly();
      var delays = [360, 920, 2000];
      var wi;
      for (wi = 0; wi < delays.length; wi++) {
        (function(wave) {
          var tid = setTimeout(function() {
            if (assistStopped || !intendedPlaying || !window.__yorigoIgUserIntentPlay) return;
            var vx = findVideo();
            if (vx && !vx.paused && vx.currentTime > 0.08) {
              markPlaybackAssistDone();
              return;
            }
            playbackAssistWave(wave);
          }, delays[wave]);
          __yorigoIgAssistTimeouts.push(tid);
        })(wi);
      }
    }
    function tryNeverMissUnmuteChrome() {
      var v = findVideo();
      if (!v) return;
      var wasMuted = !!v.muted;
      ensureVideoAudible();
      v = findVideo();
      if (!v) return;
      var nodes = document.querySelectorAll('[role="button"],button,a[href="#"],a[role="link"]');
      var i, n, al, t, rr;
      for (i = 0; i < nodes.length; i++) {
        n = nodes[i];
        al = (n.getAttribute('aria-label') || n.getAttribute('title') || '').toLowerCase();
        t = (n.innerText || '').toLowerCase();
        if (/unmute|sound on|turn sound on|tap for sound|재생.*음|음소거 해제|소리\s*켜|소리\s*켜기/.test(al + ' ' + t)) {
          try { n.click(); return; } catch (e1) {}
        }
      }
      if (!v.muted && !wasMuted) {
        return;
      }
      if (v.muted) {
        try {
          v.muted = false;
          if (typeof v.volume === 'number') v.volume = 1;
        } catch (e0) {}
        if (!v.muted) {
          return;
        }
        var vr = v.getBoundingClientRect();
        for (i = 0; i < nodes.length; i++) {
          n = nodes[i];
          rr = n.getBoundingClientRect();
          if (rr.width < 6 || rr.height < 6) continue;
          if (rr.left >= vr.right - vr.width * 0.35 && rr.top >= vr.bottom - vr.height * 0.28) {
            try { n.click(); return; } catch (e2) {}
          }
        }
        var vr2 = v.getBoundingClientRect();
        tapClientPoint(vr2.right - vr2.width * 0.11, vr2.bottom - vr2.height * 0.11);
        tapClientPoint(vr2.right - vr2.width * 0.07, vr2.bottom - vr2.height * 0.09);
      }
    }
    window.__yorigoIgAssistPlaybackChrome = function() {
      if (assistStopped) return;
      playbackAssistWave(1);
    };
    window.__yorigoIgPlay = function(){
      markFromAppApi();
      syncVidRef();
      if (!vid) return;
      window.__yorigoIgHalted = false;
      assistStopped = false;
      clearAssistTimeoutsOnly();
      suppressAutoplayPause = false;
      window.__yorigoIgUserIntentPlay = true;
      intendedPlaying = true;
      playVideo();
      var nm = !!window.__yorigoIgNeverMissEver;
      if (nm) {
        tryNeverMissUnmuteChrome();
        setTimeout(function() {
          if (!assistStopped && intendedPlaying) tryNeverMissUnmuteChrome();
        }, 520);
      }
      schedulePlaybackAssistWaves();
    };
    window.__yorigoIgPause = function(){
      markFromAppApi();
      assistStopped = true;
      clearAssistTimeoutsOnly();
      syncVidRef();
      if (!vid) return;
      window.__yorigoIgUserIntentPlay = false;
      intendedPlaying = false;
      try { vid.pause(); } catch(e){}
    };
    window.__yorigoIgRestart = function(){
      markFromAppApi();
      syncVidRef();
      if (!vid) return;
      window.__yorigoIgHalted = false;
      assistStopped = false;
      clearAssistTimeoutsOnly();
      suppressAutoplayPause = false;
      window.__yorigoIgUserIntentPlay = true;
      intendedPlaying = true;
      try { vid.currentTime = 0; } catch(e){}
      playVideo();
      var nm = !!window.__yorigoIgNeverMissEver;
      if (nm) {
        tryNeverMissUnmuteChrome();
        setTimeout(function() {
          if (!assistStopped && intendedPlaying) tryNeverMissUnmuteChrome();
        }, 480);
      }
      schedulePlaybackAssistWaves();
    };
    window.__yorigoIgSeekBy = function(d){
      syncVidRef();
      if (!vid) return;
      try { vid.currentTime = Math.max(0, (vid.currentTime || 0) + Number(d)); } catch(e){}
    };
    window.__yorigoIgSeekTo = function(t){
      syncVidRef();
      if (!vid) return;
      try {
        var x = Number(t);
        if (!isFinite(x) || x < 0) return;
        var dur = vid.duration;
        if (isFinite(dur) && dur > 0.1) {
          x = Math.min(x, Math.max(0, dur - 0.05));
        }
        vid.currentTime = x;
      } catch(e){}
    };
    window.__yorigoIgSeekToAndPlay = function(t){
      markFromAppApi();
      syncVidRef();
      if (!vid) return;
      window.__yorigoIgHalted = false;
      window.__yorigoIgAllowPlaybackEarly = true;
      assistStopped = false;
      clearAssistTimeoutsOnly();
      suppressAutoplayPause = false;
      window.__yorigoIgUserIntentPlay = true;
      intendedPlaying = true;
      try {
        var x = Number(t);
        if (!isFinite(x) || x < 0) return;
        var dur = vid.duration;
        if (isFinite(dur) && dur > 0.1) {
          x = Math.min(x, Math.max(0, dur - 0.05));
        }
        vid.currentTime = x;
      } catch(e){}
      playVideo();
      var nm = !!window.__yorigoIgNeverMissEver;
      if (nm) {
        tryNeverMissUnmuteChrome();
        setTimeout(function() {
          if (!assistStopped && intendedPlaying) tryNeverMissUnmuteChrome();
        }, 520);
      }
      schedulePlaybackAssistWaves();
    };
    window.__yorigoIgGetTime = function(){
      syncVidRef();
      if (!vid) return 0;
      try { return vid.currentTime || 0; } catch(e){ return 0; }
    };
  })();
  ''';

  String get _externalUrl =>
      'https://www.instagram.com/${widget.type}/${widget.shortcode}/';

  @override
  void initState() {
    super.initState();
    if (kIsWeb) return;
    unawaited(_initController());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_isIos && !_iosDidPrecacheThumb) {
      _iosDidPrecacheThumb = true;
      _precacheIosThumbnail();
    }
  }

  bool _isActiveEmbedUrl(String requestUrl) {
    final a = Uri.tryParse(requestUrl);
    final b = Uri.tryParse(_loadedEmbedUrl);
    if (a == null || b == null) return false;
    return a.host.toLowerCase() == b.host.toLowerCase() && a.path == b.path;
  }

  bool _isPassthroughMediaNavigation(String url) {
    final lower = url.toLowerCase();
    if (lower.startsWith('about:') ||
        lower.startsWith('blob:') ||
        lower.startsWith('data:')) {
      return true;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    return host.contains('cdninstagram') ||
        host.contains('fbcdn.net') ||
        host.contains('facebook.com') ||
        host.endsWith('fb.com') ||
        (host.contains('instagram.com') &&
            (lower.contains('/static/') ||
                lower.contains('.mp4') ||
                lower.contains('/hls') ||
                lower.contains('/v/t')));
  }

  bool _isInstagramLinkShimHost(String host) {
    final h = host.toLowerCase();
    return h == 'l.instagram.com' || h.endsWith('.l.instagram.com');
  }

  /// Match IG blue-black chrome when never-miss embed is detected and the bridge is active.
  void _applyNeverMissChromeIfEligible() {
    if (!mounted || _hasLoadError) return;
    if (!_videoBridgeReady) return;
    if (_igNeverMissEverDetected) {
      unawaited(_alignLetterboxToInstagramEmbed());
    } else {
      unawaited(_resetLetterboxToBlack());
    }
  }

  /// Match IG embed chrome (blue-black) only in **never-miss / popup** flows.
  Future<void> _alignLetterboxToInstagramEmbed() async {
    if (!mounted || _hasLoadError) return;
    if (await _isInlineVideoPlaying()) return;
    final c = _controller;
    if (c == null) return;
    setState(() => _useIgEmbedLetterboxChrome = true);
    _lastAppliedLayoutSignature = null;
    try {
      await c.setBackgroundColor(AppColors.instagramBrowserLetterbox);
    } catch (_) {}
    await _applyEmbedLayoutFromController();
  }

  /// Easy embed: stay black and keep injected `igLetterboxBg` as `#000000`.
  Future<void> _resetLetterboxToBlack() async {
    if (!mounted || _hasLoadError) return;
    if (await _isInlineVideoPlaying()) return;
    final c = _controller;
    if (c == null) return;
    setState(() => _useIgEmbedLetterboxChrome = false);
    _lastAppliedLayoutSignature = null;
    try {
      await c.setBackgroundColor(Colors.black);
    } catch (_) {}
    await _applyEmbedLayoutFromController();
  }

  Future<void> _initController() async {
    _loadedEmbedUrl = buildInstagramEmbedUrl(
      type: widget.type,
      shortcode: widget.shortcode,
      captioned: false,
    );

    final controller = createInlineMediaWebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black);

    controller.addJavaScriptChannel(
      'YorigoIgUserControl',
      onMessageReceived: (message) {
        if (!mounted) return;
        if (message.message == 'user_pause') {
          _pausePlaybackClock();
          widget.onUserPausedInPlayer?.call();
        } else if (message.message == 'user_play') {
          _markPlaybackStarted();
          widget.onUserPlayedInPlayer?.call();
        } else if (message.message == 'video_ready') {
          unawaited(_tryInstallBridgeIfVideoPresent());
        } else if (message.message == 'watch_cta') {
          _markIosWatchOnInstagramOnly();
        } else if (message.message == 'open_instagram') {
          unawaited(_launchExternal(_externalUrl));
        } else if (message.message == 'poster_play') {
          _onIosPosterPlayFromWebView();
        }
      },
    );

    controller.setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (!mounted || _hasLoadError) return;
            if (progress >= 35 && !_embedSurfaceReady) {
              setState(() {
                _isReady = true;
                _embedSurfaceReady = true;
              });
              _ensureIosPlayableRevealFallback();
              unawaited(_runJs(_videoReadyWatcherJs));
              unawaited(_applyEmbedLayoutFromController());
              unawaited(_injectIosHtmlPoster());
              _startLateVideoBridgePolling();
            }
          },
          onPageStarted: (_) {
            if (!mounted) return;
            if (_isIos) {
              unawaited(_runJs(_iosPlaybackIntentPreludeJs));
            }
            unawaited(_runJs(_videoReadyWatcherJs));
            unawaited(_injectIosHtmlPoster());
          },
          onPageFinished: (_) async {
            if (!mounted) return;
            _readyTimeoutTimer?.cancel();
            _lastAppliedLayoutSignature = null;
            if (_videoBridgeReady) {
              unawaited(_applyEmbedLayoutFromController());
              return;
            }
            final session = ++_videoProbeSession;
            setState(() {
              _isReady = true;
              _embedSurfaceReady = true;
            });
            _restartAfterNeverMissStripPolling();
            unawaited(_runJs(_videoReadyWatcherJs));
            unawaited(_applyEmbedLayoutFromController());
            unawaited(_injectIosHtmlPoster());
            unawaited(_runJs(
              r'try{window.__yorigoIgStripChrome&&window.__yorigoIgStripChrome();window.__yorigoIgRefit&&window.__yorigoIgRefit();}catch(e){}',
            ));
            if (!mounted || session != _videoProbeSession) return;
            await _checkVideoPresenceAndInstallBridge(probeSession: session);
          },
          onWebResourceError: (error) {
            if (!mounted) return;
            if (error.isForMainFrame == true) {
              debugPrint(
                '[InstagramPlayerWidget] main-frame error: ${error.description}',
              );
              _stopAfterNeverMissStripPolling();
              _stopLateVideoBridgePolling();
              setState(() {
                _hasLoadError = true;
                _isReady = true;
                _embedSurfaceReady = false;
                _inlineVideoUnavailable = false;
                _igNeverMissEverDetected = false;
                _useIgEmbedLetterboxChrome = false;
              });
            }
          },
          onNavigationRequest: (request) {
            final reqUri = Uri.tryParse(request.url);
            if (reqUri == null) return NavigationDecision.navigate;

            if (_isPassthroughMediaNavigation(request.url)) {
              return NavigationDecision.navigate;
            }

            if (_isActiveEmbedUrl(request.url)) {
              return NavigationDecision.navigate;
            }

            final host = reqUri.host.toLowerCase();
            final path = reqUri.path.toLowerCase();

            if (path.contains('/embed')) {
              return NavigationDecision.navigate;
            }

            if (_isInstagramLinkShimHost(host)) {
              return NavigationDecision.navigate;
            }

            final igHost =
                host.contains('instagram.com') || host.contains('instagr.am');
            if (igHost) {
              // /embed 를 벗어나면 로그인·Watch on Instagram·프로필 그리드가 된다.
              // 인앱 재생이 안 되는 릴은 썸네일 + 상세의 「원본 영상」으로 둔다.
              return NavigationDecision.prevent;
            }

            _launchExternal(request.url);
            return NavigationDecision.prevent;
          },
        ),
      );

    // Attach the platform view first so WKWebView can start loading/painting
    // instead of waiting for loadRequest to return.
    if (mounted) {
      setState(() {
        _controller = controller;
      });
    }

    // Chrome desktop UA makes IG serve an MSE player that WKWebView cannot
    // play, so `<video>` never appears. Keep Safari's default UA on iOS.
    if (!_isIos) {
      await controller.setUserAgent(_instagramEmbedUserAgent);
    }
    if (!mounted) return;
    unawaited(
      controller.loadRequest(
        Uri.parse(_loadedEmbedUrl),
        headers: const {'Referer': 'https://www.instagram.com/'},
      ),
    );

    _readyTimeoutTimer?.cancel();
    _readyTimeoutTimer = Timer(_readyTimeout, () {
      if (!mounted) return;
      if (_isReady || _hasLoadError) return;
      debugPrint(
        '[InstagramPlayerWidget] ready timeout — page load continued without bridge',
      );
      setState(() {
        _isReady = true;
        _embedSurfaceReady = true;
        _videoBridgeReady = false;
      });
      _ensureIosPlayableRevealFallback();
      _restartAfterNeverMissStripPolling();
    });

    if (!mounted) return;

    widget.onControllerReady?.call(InstagramPlayerHandle(
      play: _onTransportPlay,
      pause: () =>
          _runJs('window.__yorigoIgPause && window.__yorigoIgPause();'),
      restart: _onTransportRestart,
      seekBy: (delta) => _runJs(
        'window.__yorigoIgSeekBy && window.__yorigoIgSeekBy(${delta.toStringAsFixed(2)});',
      ),
      seekTo: (seconds) => _runJs(
        'window.__yorigoIgSeekTo && window.__yorigoIgSeekTo(${seconds.toStringAsFixed(3)});',
      ),
      seekToAndPlay: (seconds) => _seekToAndPlayFromUser(seconds),
      setPlaybackGuard: (on) => _runJs(
        'window.__yorigoIgSetGuard && window.__yorigoIgSetGuard(${on ? 'true' : 'false'});',
      ),
      setHalted: (h) => _runJs(
        'window.__yorigoIgSetHalted && window.__yorigoIgSetHalted(${h ? 'true' : 'false'});',
      ),
      getCurrentTime: () async {
        final c = _controller;
        if (c == null) return 0.0;
        try {
          final raw = await c.runJavaScriptReturningResult(
            'window.__yorigoIgGetTime ? window.__yorigoIgGetTime() : 0',
          );
          return double.tryParse(raw.toString()) ?? 0.0;
        } catch (_) {
          return 0.0;
        }
      },
    ));
  }

  Future<void> _checkVideoPresenceAndInstallBridge({
    required int probeSession,
  }) async {
    final controller = _controller;
    if (controller == null) return;

    for (var attempt = 0; attempt < _videoProbeAttempts; attempt++) {
      if (!mounted || probeSession != _videoProbeSession) return;
      await Future.delayed(
        attempt == 0 ? _videoProbeFirstDelay : _videoProbeInterval,
      );
      if (!mounted || probeSession != _videoProbeSession) return;
      try {
        final result =
            await controller.runJavaScriptReturningResult(_videoCountJs);
        final count = int.tryParse(result.toString().trim()) ?? 0;
        if (count > 0) {
          if (!_isIos) {
            _lastAppliedLayoutSignature = null;
            unawaited(_applyEmbedLayoutFromController());
          }
          if (!mounted || probeSession != _videoProbeSession) return;
          await _installControlBridge(controller);
          if (!_isIos) {
            unawaited(controller.runJavaScript(
              r'try{window.__yorigoIgRefit&&window.__yorigoIgRefit();}catch(e){}',
            ));
          }
          // Android: pause until the user/app asks to play.
          // iOS: `<video>` often appears only after the user already tapped —
          // pausing here would stop that tap.
          if (!_isIos) {
            unawaited(controller.runJavaScript(
              r'try{window.__yorigoIgPause&&window.__yorigoIgPause();}catch(e){}',
            ));
          }
          if (!mounted || probeSession != _videoProbeSession) return;
          _stopLateVideoBridgePolling();
          setState(() {
            _videoBridgeReady = true;
            _embedSurfaceReady = true;
            _inlineVideoUnavailable = false;
          });
          if (_isIos) {
            _ensureIosPlayableRevealFallback();
          } else {
            _scheduleLayoutJankCover(_layoutJankCoverAfterVideoMs);
            _applyNeverMissChromeIfEligible();
            _tryRevealAndStartPlayback();
          }
          return;
        }
      } catch (e) {
        debugPrint('[InstagramPlayerWidget] presence check failed: $e');
        break;
      }
    }

    if (!mounted || probeSession != _videoProbeSession) return;

    if (!_triedCaptionedEmbed && !_isIos) {
      _triedCaptionedEmbed = true;
      _loadedEmbedUrl = buildInstagramEmbedUrl(
        type: widget.type,
        shortcode: widget.shortcode,
        captioned: true,
      );
      _lastAppliedLayoutSignature = null;
        if (mounted) {
        setState(() {
          _videoBridgeReady = false;
          _embedSurfaceReady = false;
          _inlineVideoUnavailable = false;
          _useIgEmbedLetterboxChrome = false;
          _igNeverMissEverDetected = false;
        });
      }
      try {
        await controller.setBackgroundColor(Colors.black);
      } catch (_) {}
      try {
        await controller.loadRequest(
          Uri.parse(_loadedEmbedUrl),
          headers: const {'Referer': 'https://www.instagram.com/'},
        );
      } catch (e) {
        debugPrint('[InstagramPlayerWidget] captioned embed reload failed: $e');
        _stopAfterNeverMissStripPolling();
        setState(() => _hasLoadError = true);
      }
      return;
    }

    // iOS: `<video>`가 탭 뒤에 붙는 경우가 있어 임베드를 유지한다.
    // Android: captioned까지 없으면 IG가 인라인을 막은 것 — 그리드 대신 썸네일.
    debugPrint(
      '[InstagramPlayerWidget] no <video> yet — '
      '${_isIos ? 'keeping embed visible for tap-to-play' : 'showing thumbnail'}',
    );
    if (mounted) {
      setState(() {
        _embedSurfaceReady = true;
        _inlineVideoUnavailable = !_isIos;
      });
    }
    _ensureIosPlayableRevealFallback();
    _startLateVideoBridgePolling();
  }

  void _stopLateVideoBridgePolling() {
    _lateVideoBridgeTimer?.cancel();
    _lateVideoBridgeTimer = null;
  }

  void _startLateVideoBridgePolling() {
    _stopLateVideoBridgePolling();
    if (!mounted || _hasLoadError) return;
    _lateVideoBridgeTimer =
        Timer.periodic(const Duration(milliseconds: 700), (_) {
      unawaited(_tryInstallBridgeIfVideoPresent());
    });
    unawaited(_tryInstallBridgeIfVideoPresent());
  }

  Future<void> _tryInstallBridgeIfVideoPresent() async {
    if (!mounted || _hasLoadError || _videoBridgeReady) {
      if (_videoBridgeReady) _stopLateVideoBridgePolling();
      return;
    }
    final controller = _controller;
    if (controller == null) return;
    try {
      final result =
          await controller.runJavaScriptReturningResult(_videoCountJs);
      final count = int.tryParse(result.toString().trim()) ?? 0;
      if (count <= 0) return;
      if (!_isIos) {
        _lastAppliedLayoutSignature = null;
        unawaited(_applyEmbedLayoutFromController());
      }
      await _installControlBridge(controller);
      if (!mounted) return;
      _stopLateVideoBridgePolling();
      setState(() {
        _videoBridgeReady = true;
        _embedSurfaceReady = true;
        _inlineVideoUnavailable = false;
      });
      _revealIosPlayablePlayer();
      if (!_isIos) {
        _applyNeverMissChromeIfEligible();
        _tryRevealAndStartPlayback();
      }
    } catch (_) {}
  }

  bool _coerceJsBoolInt(dynamic raw) {
    if (raw == true || raw == 1) return true;
    final s = raw.toString().trim();
    return s == '1' || s == '"1"' || s == 'true';
  }

  void _stopAfterNeverMissStripPolling() {
    _afterNeverMissStripPollTimer?.cancel();
    _afterNeverMissStripPollTimer = null;
  }

  void _restartAfterNeverMissStripPolling() {
    _stopAfterNeverMissStripPolling();
    if (!mounted) return;
    if (_hasLoadError || !_isReady || _controller == null) {
        return;
      }
    _afterNeverMissStripPollTimer =
        Timer.periodic(_afterNeverMissStripPollInterval, (_) {
      unawaited(_pollAfterNeverMissStripOnce());
    });
    unawaited(_pollAfterNeverMissStripOnce());
  }

  Future<void> _pollAfterNeverMissStripOnce() async {
    final c = _controller;
    if (!mounted || c == null || !_isReady || _hasLoadError) return;
    try {
      final raw = await c.runJavaScriptReturningResult(_neverMissEverProbeJs);
      final show = _coerceJsBoolInt(raw);
      if (!mounted) return;
      if (show != _igNeverMissEverDetected) {
        setState(() => _igNeverMissEverDetected = show);
        _applyNeverMissChromeIfEligible();
      }
      if (_isIos && !_iosWatchOnInstagramOnly) {
        final watchRaw =
            await c.runJavaScriptReturningResult(_watchCtaProbeJs);
        if (!mounted) return;
        if (_coerceJsBoolInt(watchRaw)) {
          _markIosWatchOnInstagramOnly();
        }
      }
    } catch (_) {}
  }

  Future<void> _runJs(String js) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.runJavaScript(js);
    } catch (e) {
      debugPrint('[InstagramPlayerWidget] runJs failed: $e');
    }
  }

  void _seekToAndPlayFromUser(double seconds) {
    if (_hasLoadError || _inlineVideoUnavailable) return;

    // Fast path: bridge ready → dispatch JS directly without intermediate calls.
    if (_videoBridgeReady) {
      unawaited(
        _runJs(
          'window.__yorigoIgSeekToAndPlay && window.__yorigoIgSeekToAndPlay(${seconds.toStringAsFixed(3)});',
        ),
      );
      if (!_heroPlayRequested) {
        setState(() {
          _heroPlayRequested = true;
          _playbackKindRestart = false;
        });
      }
      return;
    }

    // Slow path: bridge not ready yet → queue for later.
    _pendingSeekToAndPlaySec = seconds;
    unawaited(
      _runJs(r'try{window.__yorigoIgAllowPlaybackEarly=true;}catch(e){}'),
    );
    setState(() {
      _heroPlayRequested = true;
      _playbackKindRestart = false;
    });
    if (!_isIos) {
      _applyNeverMissChromeIfEligible();
    }
    _tryRevealAndStartPlayback();
  }

  void _onTransportPlay() {
    if (_hasLoadError || _inlineVideoUnavailable) return;
    _markPlaybackStarted();
    widget.onUserPlayedInPlayer?.call();
    unawaited(
      _runJs(
        r'try{window.__yorigoIgAllowPlaybackEarly=true;}catch(e){}',
      ),
    );
    if (_isIos && _iosFramingCoverVisible) {
      _hideIosFramingCover();
    }
    setState(() {
      _heroPlayRequested = true;
      _playbackKindRestart = false;
    });
    if (!_isIos) {
      _applyNeverMissChromeIfEligible();
    }
    _tryRevealAndStartPlayback();
  }

  void _onTransportRestart() {
    if (_hasLoadError || _inlineVideoUnavailable) return;
    _markPlaybackStarted();
    unawaited(
      _runJs(
        r'try{window.__yorigoIgAllowPlaybackEarly=true;}catch(e){}',
      ),
    );
    setState(() {
      _heroPlayRequested = true;
      _playbackKindRestart = true;
    });
    if (!_isIos) {
      _applyNeverMissChromeIfEligible();
    }
    _tryRevealAndStartPlayback();
  }

  /// Reveals the WebView (if [_showWebToUser]) and starts playback or restart JS.
  void _tryRevealAndStartPlayback() {
    if (!_heroPlayRequested ||
        !_videoBridgeReady ||
        _inlineVideoUnavailable ||
        _hasLoadError ||
        !mounted) {
      return;
    }
    if (!_isIos) {
      _scheduleLayoutJankCover(_layoutJankCoverAfterVideoMs);
    }
    final pendingSeek = _pendingSeekToAndPlaySec;
    if (pendingSeek != null) {
      _pendingSeekToAndPlaySec = null;
      unawaited(
        _runJs(
          'window.__yorigoIgSeekToAndPlay && window.__yorigoIgSeekToAndPlay(${pendingSeek.toStringAsFixed(3)});',
        ),
      );
      return;
    }
    if (_playbackKindRestart) {
      _playbackKindRestart = false;
      unawaited(
        _runJs('window.__yorigoIgRestart && window.__yorigoIgRestart();'),
      );
    } else {
      unawaited(_runJs('window.__yorigoIgPlay && window.__yorigoIgPlay();'));
    }
  }

  Future<void> _launchExternal(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _markPlaybackStarted() {
    _playingStartedAt ??= DateTime.now();
    if (_firstPlayReported) return;
    _firstPlayReported = true;
    widget.onFirstPlay?.call();
  }

  void _pausePlaybackClock() {
    final started = _playingStartedAt;
    if (started == null) return;
    _accumulatedPlayMs += DateTime.now().difference(started).inMilliseconds;
    _playingStartedAt = null;
  }

  void _flushWatchEnded() {
    _pausePlaybackClock();
    final ms = _accumulatedPlayMs;
    _accumulatedPlayMs = 0;
    if (ms < 1000) return;
    widget.onWatchEnded?.call(ms);
  }

  @override
  void didUpdateWidget(InstagramPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.type != widget.type ||
        oldWidget.shortcode != widget.shortcode) {
      _flushWatchEnded();
      _firstPlayReported = false;
    }
  }

  @override
  void dispose() {
    _flushWatchEnded();
    _readyTimeoutTimer?.cancel();
    _layoutJankCoverTimer?.cancel();
    _iosFramingCoverTimer?.cancel();
    _iosFramingCoverFallbackTimer?.cancel();
    _stopLateVideoBridgePolling();
    _stopAfterNeverMissStripPolling();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: _slotLetterboxColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        clipBehavior: platformViewClipBehavior,
        child: kIsWeb ? _buildWebFallback() : _buildMobilePlayer(),
      ),
    );
    return player;
  }

  Widget _buildWebFallback() {
    const topBlock = 8.0;
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.hardEdge,
      children: [
        Container(
      width: double.infinity,
      height: double.infinity,
          color: _slotLetterboxColor,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.play_circle_outline,
                color: Colors.white, size: 64),
            const SizedBox(height: 16),
            const Text(
              '웹 환경에서는 Instagram에서 재생됩니다',
              style: TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => _launchExternal(_externalUrl),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Instagram에서 보기'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
          ],
        ),
        ),
      ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: topBlock,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: ColoredBox(color: _slotLetterboxColor),
          ),
        ),
      ],
    );
  }

  Widget _buildMobilePlayer() {
    final controller = _controller;
    if (controller == null) {
      return _isIos ? _buildIosPosterOverlay() : _buildHeroCoverStack();
    }
    return LayoutBuilder(builder: (context, constraints) {
      final boxW = constraints.maxWidth;
      final boxH = constraints.maxHeight;
      _scheduleLayoutZoomApply(boxW: boxW, boxH: boxH);

      final webViewWidth = boxW * _embedWebViewWidthFactor;
      final iosCover =
          _isIos && _iosFramingCoverVisible && !_hasLoadError;

    return Stack(
      alignment: Alignment.center,
      children: [
          Positioned.fill(
              child: ColoredBox(color: _slotLetterboxColor)),
          if (!_hasLoadError)
            _isIos
                ? Positioned(
                    left: iosCover ? -2 : (boxW - webViewWidth) / 2,
                    top: iosCover ? -2 : 0,
                    width: iosCover ? 1 : webViewWidth,
                    height: iosCover ? 1 : boxH,
                    child: IgnorePointer(
                      ignoring: iosCover || !_showWebToUser,
                      child: WebViewWidget(
                        key: _iosWebViewKey,
                        controller: controller,
                      ),
                    ),
                  )
                : wrapPlatformViewReveal(
                    revealed: _showWebToUser,
                    child: IgnorePointer(
                      ignoring: !_showWebToUser,
                      child: SizedBox(
                        width: webViewWidth,
                        height: boxH,
                        child: WebViewWidget(controller: controller),
                      ),
                    ),
                  ),
          if (iosCover)
            Positioned.fill(child: _buildIosPosterOverlay()),
          if (_neverMissUiChromeActive &&
              _showWebToUser &&
              !_hasLoadError)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: _afterNeverMissTopBlackBarPx,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: ColoredBox(color: _slotLetterboxColor),
              ),
            ),
          if (!_isIos && !_hasLoadError && !_showWebToUser)
            Positioned.fill(child: _buildHeroCoverStack()),
        if (_hasLoadError)
          Positioned.fill(child: _buildLoadErrorOverlay()),
          if (!_isIos &&
              _layoutJankCoverVisible &&
              _showWebToUser &&
              !_hasLoadError)
            Positioned.fill(child: _buildLayoutJankMask()),
        ],
      );
    });
  }

  /// Hero thumbnail while the `<video>` bridge is not ready; optional loading spinner.
  Widget _buildHeroCoverStack() {
    return Stack(
        fit: StackFit.expand,
      clipBehavior: Clip.hardEdge,
        children: [
        _buildPosterLoadingOverlay(),
        ],
    );
  }

  /// iOS: 로딩 중·Watch-on-Instagram 전용일 때만 썸네일로 슬롯을 채운다.
  Widget _buildIosPosterOverlay() {
    final url = widget.thumbnailUrl?.trim() ?? '';
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0;
    final memW = ((MediaQuery.sizeOf(context).width * dpr).round())
        .clamp(400, 1200);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _iosWatchOnInstagramOnly
          ? () => unawaited(_launchExternal(_externalUrl))
          : null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.black),
          InlineVideoHeroPoster(
            thumbnailUrl: url.isEmpty ? null : url,
            backgroundColor: Colors.black,
            imageFit: BoxFit.cover,
            showCenterPlayGlyph: false,
            fadeInDuration: Duration.zero,
            placeholderColor: Colors.black,
            memCacheWidth: memW,
            imageHttpHeaders: _iosImageHeadersFor(url),
          ),
          if (_iosWatchOnInstagramOnly)
            Center(child: _buildIosWatchOnInstagramPill()),
        ],
      ),
    );
  }

  Widget _buildIosWatchOnInstagramPill() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xF0FFFFFF),
        borderRadius: BorderRadius.circular(999),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Text(
          'Instagram에서 보기',
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Color(0xFF2C2A27),
          ),
        ),
      ),
    );
  }

  /// Brief solid mask while injected zoom/layout settles — first WebView paint after reveal.
  Widget _buildLayoutJankMask() {
    return ColoredBox(color: _slotLetterboxColor);
  }

  Widget _buildPosterLoadingOverlay() {
    return InlineVideoHeroPoster(
      thumbnailUrl: widget.thumbnailUrl,
      backgroundColor: _slotLetterboxColor,
      imageFit: BoxFit.contain,
      showCenterPlayGlyph: false,
      showInstagramTopTapBlock: _neverMissUiChromeActive,
      imageHttpHeaders: InlineVideoHeroPoster.instagramThumbnailHeaders,
    );
  }

  /// 임베드 실패(게시물 삭제 / 비공개 / 잘못된 링크 등) 시 보여줄 fallback.
  ///
  /// 사용자 요청에 따라 알약 버튼은 제거하고 썸네일만 깔끔하게 노출. 박스
  /// 탭 시 외부 Instagram 앱으로 이동.
  Widget _buildLoadErrorOverlay() {
    final thumb = widget.thumbnailUrl;
    return GestureDetector(
      onTap: () => _launchExternal(_externalUrl),
      child: Container(
        color: _slotLetterboxColor,
        child: (thumb != null && thumb.isNotEmpty)
            ? AppNetworkImage(
                imageUrl: thumb,
                fit: BoxFit.contain,
                width: double.infinity,
                height: double.infinity,
                errorWidget: const SizedBox.shrink(),
              )
            : const SizedBox.expand(),
      ),
    );
  }
}
