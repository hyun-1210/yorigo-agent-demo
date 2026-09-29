import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';
import '../theme/app_colors.dart';
import 'app_network_image.dart';
import '../utils/inline_media_webview.dart';
import '../utils/youtube_utils.dart';
import 'inline_video_hero_poster.dart';

Future<void> _lockIosPortrait() async {
  // iOS는 landscape만 허용 중인 상태에서 portrait로 한 번에 줄이면
  // 회전이 무시되는 경우가 있어, 둘 다 허용한 뒤 세로로 좁힌다.
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await Future<void>.delayed(const Duration(milliseconds: 40));
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]);
}

/// Exposes seek / play / pause / position-polling to parents of [YouTubePlayerWidget].
class YouTubePlayerHandle {
  final void Function(double seconds) seekTo;
  final VoidCallback play;
  final VoidCallback pause;
  final Future<double> Function() getCurrentTime;

  /// When enabled, the player counteracts play/pause events that weren't
  /// initiated through this handle (e.g. Android audio-focus changes caused
  /// by SpeechRecognizer grabbing/releasing focus).
  final void Function(bool enabled) setPlaybackGuard;

  const YouTubePlayerHandle({
    required this.seekTo,
    required this.play,
    required this.pause,
    required this.getCurrentTime,
    required this.setPlaybackGuard,
  });
}

/// Pre-warms a YouTube IFrame WebView so the first video loads faster.
///
/// Call [YoutubePrewarmer.instance.warmUp()] early in the app lifecycle
/// (e.g. after Firebase init). It creates a throwaway controller that
/// forces the WebView engine and YouTube IFrame JS to initialize in the
/// background. The controller is disposed after the JS is loaded.
class YoutubePrewarmer {
  YoutubePrewarmer._();
  static final instance = YoutubePrewarmer._();

  bool _warmed = false;

  void warmUp() {
    if (kIsWeb || _warmed) return;
    _warmed = true;
    // Use a well-known short, always-embeddable video to bootstrap.
    // autoPlay=false + mute=true so nothing is audible or visible.
    final controller = YoutubePlayerController.fromVideoId(
      videoId: 'jNQXAC9IVRw',
      autoPlay: false,
      params: const YoutubePlayerParams(
        showControls: false,
        showFullscreenButton: false,
        mute: true,
        playsInline: true,
        enableCaption: false,
        origin: 'https://www.youtube-nocookie.com',
      ),
    );
    // Give the WebView engine ~4 seconds to fully initialize, then dispose.
    Future.delayed(const Duration(seconds: 3), () {
      controller.close();
      debugPrint('[YoutubePrewarmer] WebView engine pre-warmed and disposed');
    });
  }
}

/// YouTube 영상을 앱 내에서 재생하는 위젯.
///
/// 모바일에서는 [`youtube_player_iframe`](https://pub.dev/packages/youtube_player_iframe)
/// 패키지의 IFrame Player API 래퍼를 사용해 재생하고, 웹 환경에서는 외부
/// YouTube 링크로 이동합니다. 이 패키지는 `webview_flutter`를 내부적으로
/// 사용하지만, YouTube의 임베더 검증(150/152/153 등)에 대응하는 로직과
/// 풀스크린/광고 정책 호환성이 라이브러리 차원에서 관리되어 우리가 직접
/// 핸들링하지 않아도 됩니다.
class YouTubePlayerWidget extends StatefulWidget {
  final String videoId;
  final bool autoPlay;
  final bool showControls;
  final String? thumbnailUrl;
  final VoidCallback? onClose;
  final Function(bool)? onFullscreenChanged;
  final bool isFullscreenPage;

  /// Called once the internal controller is ready, providing a [YouTubePlayerHandle]
  /// for seek, play, pause, and position polling.
  final void Function(YouTubePlayerHandle handle)? onControllerReady;

  /// User paused via native player controls (not via app handle).
  final VoidCallback? onUserPausedInPlayer;

  /// User pressed play via native player controls (not via app handle).
  final VoidCallback? onUserPlayedInPlayer;

  /// 실제 재생이 처음 시작될 때 1회.
  final VoidCallback? onFirstPlay;

  /// 세션 시청이 끝날 때(영상 종료·위젯 dispose). 누적 ms.
  final void Function(int durationMs)? onWatchEnded;

  /// IFrame 이 알려 준 실제 영상 길이(초). iOS 숏폼/롱폼 재분류용.
  final void Function(double durationSec)? onDurationKnown;

  /// 플레이어 영역의 가로:세로 비율.
  ///
  /// - 일반 가로 영상: `16/9` (기본값)
  /// - YouTube Shorts: `1.0` (정사각형 프레임 안에 9:16 숏폼 플레이어).
  ///   iOS는 그 박스 안에서 세로 플레이어를 써서 타임라인·전체화면이
  ///   잘리지 않게 한다.
  ///
  /// 풀스크린 페이지(`isFullscreenPage == true`)에서는 화면 전체를 사용
  /// 하므로 이 값은 무시되고 16:9로 고정 렌더링됩니다.
  final double aspectRatio;

  /// 이 초부터 이어서 재생. 풀스크린 전환 시 인라인 플레이어 위치를 넘긴다.
  final double startSeconds;

  const YouTubePlayerWidget({
    super.key,
    required this.videoId,
    this.autoPlay = false,
    this.showControls = true,
    this.thumbnailUrl,
    this.onClose,
    this.onFullscreenChanged,
    this.isFullscreenPage = false,
    this.onControllerReady,
    this.onUserPausedInPlayer,
    this.onUserPlayedInPlayer,
    this.onFirstPlay,
    this.onWatchEnded,
    this.onDurationKnown,
    this.aspectRatio = 16 / 9,
    this.startSeconds = 0,
  });

  @override
  State<YouTubePlayerWidget> createState() => _YouTubePlayerWidgetState();
}

class _YouTubePlayerWidgetState extends State<YouTubePlayerWidget> {
  YoutubePlayerController? _controller;
  WebViewController? _iosEmbedController;
  StreamSubscription<YoutubePlayerValue>? _valueSub;
  StreamSubscription<YoutubeVideoState>? _videoStateSub;

  bool _isReady = false;
  bool _hasLoadError = false;
  bool _playerDidPlay = false;
  bool _firstPlayReported = false;
  bool _didApplyStartSeconds = false;
  DateTime? _playingStartedAt;
  int _accumulatedPlayMs = 0;
  double _lastKnownSeconds = 0;
  Timer? _readyTimeoutTimer;
  Timer? _errorFallbackTimer;

  // Audio-focus playback guard: prevents SpeechRecognizer's audio-focus
  // grab/release from toggling the YouTube WebView's play state.
  bool _playbackGuard = false;
  PlayerState? _intendedPlayerState;
  bool _pauseFromApp = false;
  bool _playFromApp = false;

  /// Throttles [YoutubePlayerController.isMuted] / [unMute] work on busy streams.
  DateTime? _lastYoutubeAudibleAttempt;
  bool _didReportDuration = false;
  Timer? _iosShortsLayoutTimer;
  Timer? _iosShortsWatchdogTimer;
  Timer? _iosShortsErrorProbeTimer;
  /// iOS: 숏폼 플레이어가 실패·지연되면 1:1 박스 안에서 16:9 시네마로 넘긴다.
  bool _iosCinemaFallback = false;
  bool _iosShortsHealthy = false;

  final OverlayPortalController _overlayPortalController =
      OverlayPortalController();
  final GlobalKey _youtubeViewKey = GlobalKey();
  bool _isInlineFullscreen = false;

  // Stage 1: reveal the WebView so slow-loading videos can show up.
  static const Duration _readyTimeout = Duration(seconds: 12);
  // Stage 2: if still no meaningful player state after reveal, treat as error.
  static const Duration _errorFallbackDelay = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    if (kIsWeb) return;
    if (_useDirectShortsEmbed) {
      _initIosDirectEmbed();
      return;
    }
    _initController();
    _startIosLayoutTimer();
  }

  /// 숏폼(1:1 박스)만 nocookie `/embed` WebView. 가로 롱폼은 IFrame 패키지.
  /// youtube.com 을 부모 origin 으로 쓰면 152-4, 모바일 UA 는 Playback ID.
  bool get _useDirectShortsEmbed {
    return !kIsWeb && widget.aspectRatio <= 1.0;
  }

  /// 부모·플레이어 모두 nocookie. youtube.com 위장은 152-4, yorigo.com
  /// baseUrl 은 상세 진입 즉시 Safari 로 나갔다.
  static const String _kIosEmbedPageOrigin = 'https://www.youtube-nocookie.com';
  static const String _kIosEmbedPlayerHost = 'https://www.youtube-nocookie.com';
  /// iPad Safari UA: 모바일 Shorts HTML5(Playback ID)를 피하고 WebKit 과 맞춘다.
  static const String _kIosDesktopEmbedUserAgent =
      'Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
  static const String _kAndroidDesktopEmbedUserAgent =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

  String _iosDirectEmbedHtml() {
    final id = widget.videoId;
    final auto = widget.autoPlay ? 1 : 0;
    final controls = widget.showControls ? 1 : 0;
    final start = widget.startSeconds > 0.25 ? widget.startSeconds.round() : 0;
    final startParam = start > 0 ? '&start=$start' : '';
    final origin = Uri.encodeQueryComponent(_kIosEmbedPageOrigin);
    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
  <meta name="referrer" content="strict-origin-when-cross-origin">
  <style>
    html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
    iframe { position: absolute; inset: 0; width: 100%; height: 100%; border: 0; }
  </style>
</head>
<body>
  <iframe
    id="yt"
    src="$_kIosEmbedPlayerHost/embed/$id?playsinline=1&rel=0&modestbranding=1&controls=$controls&fs=0&enablejsapi=1&origin=$origin&widget_referrer=$origin&autoplay=$auto$startParam"
    referrerpolicy="strict-origin-when-cross-origin"
    allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; fullscreen; web-share"
    allowfullscreen
    title="YouTube"></iframe>
  <script>
    function yorigoCmd(func, args) {
      var f = document.getElementById('yt');
      if (!f || !f.contentWindow) return;
      var payload = JSON.stringify({event:'command', func: func, args: args || []});
      try { f.contentWindow.postMessage(payload, '$_kIosEmbedPlayerHost'); } catch (e) {}
      try { f.contentWindow.postMessage(payload, '*'); } catch (e) {}
    }
    var frame = document.getElementById('yt');
    frame.addEventListener('load', function() {
      try {
        frame.contentWindow.postMessage('{"event":"listening","id":1}', '$_kIosEmbedPlayerHost');
        yorigoCmd('addEventListener', ['onStateChange']);
      } catch (e) {}
    });
    var lastState = null;
    var lastTSent = 0;
    var readySent = false;
    var durationSent = false;
    window.addEventListener('message', function(event) {
      var origin = String(event.origin || '');
      if (origin.indexOf('youtube.com') === -1 &&
          origin.indexOf('youtube-nocookie.com') === -1) return;
      var data = event.data;
      if (typeof data === 'string') {
        try { data = JSON.parse(data); } catch (e) { return; }
      }
      if (!data || typeof data !== 'object') return;
      if (!readySent && (data.event === 'onReady' || data.event === 'initialDelivery')) {
        readySent = true;
        try { YorigoYt.postMessage('ready'); } catch (e) {}
      }
      var info = data.info;
      var state = null;
      if (data.event === 'onStateChange' && typeof info === 'number') {
        state = info;
      } else if (info && typeof info === 'object') {
        if (typeof info.playerState === 'number') state = info.playerState;
        if (!durationSent && typeof info.duration === 'number' && info.duration > 0.5) {
          durationSent = true;
          try { YorigoYt.postMessage('d:' + info.duration); } catch (e) {}
        }
        if (typeof info.currentTime === 'number') {
          var now = Date.now();
          if (now - lastTSent >= 250) {
            lastTSent = now;
            try { YorigoYt.postMessage('t:' + info.currentTime); } catch (e) {}
          }
        }
      }
      if (typeof state === 'number' && state !== lastState) {
        lastState = state;
        try { YorigoYt.postMessage('state:' + state); } catch (e) {}
      }
    });
  </script>
</body>
</html>
''';
  }

  void _onDirectEmbedBridgeMessage(String raw) {
    if (!mounted || raw.isEmpty) return;
    if (raw == 'ready') {
      if (!_isReady || !_iosShortsHealthy) {
        setState(() {
          _isReady = true;
          _iosShortsHealthy = true;
        });
      }
      _applyDirectEmbedStartSecondsIfNeeded();
      return;
    }
    if (raw.startsWith('t:')) {
      final t = double.tryParse(raw.substring(2));
      if (t != null && t >= 0) _lastKnownSeconds = t;
      return;
    }
    if (raw.startsWith('d:')) {
      final d = double.tryParse(raw.substring(2));
      if (d != null && d > 0.5) {
        _reportDurationIfKnown(
          Duration(milliseconds: (d * 1000).round()),
        );
      }
      return;
    }
    if (!raw.startsWith('state:')) return;
    final state = int.tryParse(raw.substring(6));
    if (state == null) return;
    _handleDirectEmbedPlayerState(state);
  }

  void _handleDirectEmbedPlayerState(int state) {
    // IFrame API: 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued.
    if (_playbackGuard && _intendedPlayerState != null) {
      if (state == 2 && _intendedPlayerState == PlayerState.playing) {
        _playFromApp = true;
        _runIosEmbedCmd('playVideo');
        return;
      }
      if (state == 1 && _intendedPlayerState == PlayerState.paused) {
        _pauseFromApp = true;
        _runIosEmbedCmd('pauseVideo');
        return;
      }
    }
    if (state == 1) {
      if (_playFromApp) {
        _playFromApp = false;
      } else if (_intendedPlayerState != PlayerState.playing) {
        widget.onUserPlayedInPlayer?.call();
      }
      _markPlaybackStarted();
      if (mounted && (!_isReady || !_iosShortsHealthy)) {
        setState(() {
          _isReady = true;
          _iosShortsHealthy = true;
        });
      }
    } else if (state == 2) {
      if (_pauseFromApp) {
        _pauseFromApp = false;
      } else {
        widget.onUserPausedInPlayer?.call();
      }
      _pausePlaybackClock();
    } else if (state == 0) {
      _flushWatchEnded();
    }
  }

  void _runIosEmbedCmd(String func, [List<Object> args = const <Object>[]]) {
    final controller = _iosEmbedController;
    if (controller == null) return;
    final encoded = args.map((a) => a is String ? "'$a'" : '$a').join(',');
    unawaited(
      controller.runJavaScript('yorigoCmd("$func", [$encoded]);'),
    );
  }

  void _initIosDirectEmbed() {
    final controller = createInlineMediaWebViewController();
    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..enableZoom(false)
      ..setUserAgent(
        defaultTargetPlatform == TargetPlatform.iOS
            ? _kIosDesktopEmbedUserAgent
            : _kAndroidDesktopEmbedUserAgent,
      )
      ..addJavaScriptChannel(
        'YorigoYt',
        onMessageReceived: (message) {
          _onDirectEmbedBridgeMessage(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) {
            if (!mounted || _hasLoadError) return;
            _readyTimeoutTimer?.cancel();
            setState(() {
              _isReady = true;
              _iosShortsHealthy = true;
            });
            _applyDirectEmbedStartSecondsIfNeeded();
          },
          onWebResourceError: (error) {
            debugPrint(
              '[YouTubePlayerWidget] iOS embed resource error: ${error.description}',
            );
          },
          onNavigationRequest: (request) {
            return isYouTubeEmbedNavigationAllowed(request.url)
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
        ),
      );

    _readyTimeoutTimer?.cancel();
    _readyTimeoutTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted || _hasLoadError || _isReady) return;
      setState(() {
        _isReady = true;
        _iosShortsHealthy = true;
      });
    });

    setState(() {
      _iosEmbedController = controller;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        controller.loadHtmlString(
          _iosDirectEmbedHtml(),
          baseUrl: '$_kIosEmbedPageOrigin/',
        ),
      );
    });

    widget.onControllerReady?.call(YouTubePlayerHandle(
      seekTo: (double seconds) {
        _lastKnownSeconds = seconds;
        _runIosEmbedCmd('seekTo', [seconds, true]);
      },
      play: () {
        _playFromApp = true;
        _intendedPlayerState = PlayerState.playing;
        _runIosEmbedCmd('playVideo');
        if (mounted && !_iosShortsHealthy) {
          setState(() {
            _iosShortsHealthy = true;
            _isReady = true;
          });
        }
      },
      pause: () {
        _pauseFromApp = true;
        _intendedPlayerState = PlayerState.paused;
        _runIosEmbedCmd('pauseVideo');
      },
      getCurrentTime: () async => _lastKnownSeconds,
      setPlaybackGuard: (bool enabled) {
        _playbackGuard = enabled;
        if (!enabled) _intendedPlayerState = null;
      },
    ));
  }

  /// 9:16 WebView 안에 숏폼 플레이어를 맞춘다. 16:9로 키우면 타임라인·
  /// 전체화면이 1:1 박스에서 잘린다.
  void _applyIosShortsPlayerLayout() {
    if (!_useIosShortsPlayerLayout) return;
    final controller = _controller;
    if (controller == null) return;
    unawaited(
      controller.webViewController.runJavaScript(_kIosShortsLayoutJs),
    );
  }

  /// 숏폼 실패 시: 1:1 박스 안에서 16:9 시네마를 키워 가운데만 보이게 한다.
  void _applyIosCinemaInSquareLayout() {
    if (!_isIosCinemaInSquare) return;
    final controller = _controller;
    if (controller == null) return;
    unawaited(
      controller.webViewController.runJavaScript(_kIosCinemaInSquareJs),
    );
  }

  void _startIosLayoutTimer() {
    _iosShortsLayoutTimer?.cancel();
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    if (widget.aspectRatio > 1.0) return;
    _iosShortsLayoutTimer = Timer.periodic(
      const Duration(milliseconds: 400),
      (timer) {
        if (!mounted || timer.tick > 25) {
          timer.cancel();
          return;
        }
        if (_iosCinemaFallback) {
          _applyIosCinemaInSquareLayout();
        } else {
          _applyIosShortsPlayerLayout();
        }
      },
    );
  }

  static const String _kIosShortsLayoutJs = r'''
(function() {
  var w = document.documentElement.clientWidth;
  var h = document.documentElement.clientHeight;
  if (w < 2 || h < 2) return;
  var styleId = 'yorigo-shorts-layout';
  var style = document.getElementById(styleId);
  if (!style) {
    style = document.createElement('style');
    style.id = styleId;
    document.head.appendChild(style);
  }
  style.textContent = [
    'html,body{width:100%!important;height:100%!important;margin:0!important;background:#000!important;overflow:hidden!important;}',
    '.embed-container{position:absolute!important;inset:0!important;width:100%!important;height:100%!important;transform:none!important;}',
    '.embed-container iframe{width:100%!important;height:100%!important;}'
  ].join('');
  function size() {
    if (typeof player === 'undefined' || !player || !player.setSize) return;
    player.setSize(w, h);
  }
  window.onresize = function() {};
  size();
})();
''';

  static const String _kIosCinemaInSquareJs = r'''
(function() {
  var w = document.documentElement.clientWidth;
  var h = document.documentElement.clientHeight;
  if (w < 2 || h < 2) return;
  var playerH = h < 300 ? 300 : h;
  var playerW = playerH * 16 / 9;
  var styleId = 'yorigo-shorts-layout';
  var style = document.getElementById(styleId);
  if (!style) {
    style = document.createElement('style');
    style.id = styleId;
    document.head.appendChild(style);
  }
  style.textContent = [
    'html,body{width:100%!important;height:100%!important;margin:0!important;background:#000!important;overflow:hidden!important;}',
    '.embed-container{position:absolute!important;top:0!important;left:50%!important;bottom:auto!important;right:auto!important;width:' + playerW + 'px!important;height:' + playerH + 'px!important;transform:translateX(-50%)!important;}',
    '.embed-container iframe{width:100%!important;height:100%!important;}'
  ].join('');
  function size() {
    if (typeof player === 'undefined' || !player || !player.setSize) return;
    player.setSize(playerW, playerH);
  }
  window.onresize = function() {};
  size();
})();
''';

  static const String _kIosPlaybackErrorProbeJs = r'''
(function(){
  function textOf(doc) {
    try {
      return (doc && doc.documentElement && doc.documentElement.innerText) || '';
    } catch (e) { return ''; }
  }
  try {
    var t = textOf(document);
    var iframes = document.getElementsByTagName('iframe');
    for (var i = 0; i < iframes.length; i++) {
      try {
        var inner = iframes[i].contentDocument ||
            (iframes[i].contentWindow && iframes[i].contentWindow.document);
        t += textOf(inner);
      } catch (e) {}
    }
    if (/please try again later/i.test(t) || /playback id/i.test(t) || /나중에 다시 시도/i.test(t) || /재생할 수 없습니다/i.test(t) || /video player configuration error/i.test(t)) {
      return 'error';
    }
  } catch (e) {}
  return 'ok';
})();
''';

  /// iPhone UA 는 WKWebView 안에서 Shorts HTML5 플레이어를 켜고
  /// "Please try again later. Playback ID" 로 죽는 경우가 많다.
  /// iPad UA 는 일반 embed 플레이어를 줘서 숏폼도 재생된다. 박스는 9:16.
  static const String _kIosEmbedUserAgent =
      'Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

  void _initController() {
    final startSeconds =
        widget.startSeconds > 0.25 ? widget.startSeconds : null;
    _lastKnownSeconds = widget.startSeconds;
    final bool iosLandscapeInline = !kIsWeb &&
        !widget.isFullscreenPage &&
        widget.aspectRatio > 1.0 &&
        defaultTargetPlatform == TargetPlatform.iOS;
    final bool iosShortFormInline = _useIosShortsPlayerLayout;
    final bool iosCinemaInSquare = _isIosCinemaInSquare;
    final controller = YoutubePlayerController.fromVideoId(
      videoId: widget.videoId,
      autoPlay: widget.autoPlay,
      startSeconds: startSeconds,
      params: YoutubePlayerParams(
        showControls: widget.showControls,
        // 우리가 만든 풀스크린 버튼을 쓸 것이므로 라이브러리 기본
        // 풀스크린 버튼은 끈다.
        showFullscreenButton: false,
        mute: false,
        playsInline: true,
        // 영상 종료 후 추천 영상이 같은 채널 것만 뜨도록 제한
        // (YouTube IFrame API의 rel=0과 동일)
        strictRelatedVideos: true,
        enableCaption: false,
        // 숏폼은 youtube.com 과 iframe_api 출처를 맞춰야 한다.
        // nocookie host + youtube.com iframe_api 는 Shorts 에서
        // Playback ID / 153 으로 죽는다. Android·iOS 롱폼은 기존 nocookie.
        origin: (iosShortFormInline || iosCinemaInSquare)
            ? 'https://www.youtube.com'
            : 'https://www.youtube-nocookie.com',
        // iOS WKWebView 기본(iPhone) UA 는 Shorts HTML5 가 재생 실패한다.
        userAgent: (iosLandscapeInline || iosCinemaInSquare || iosShortFormInline)
            ? _kIosEmbedUserAgent
            : null,
      ),
    );

    _valueSub = controller.stream.listen(_onPlayerValue);
    _videoStateSub = controller.videoStateStream.listen((state) {
      final seconds = state.position.inMilliseconds / 1000.0;
      if (seconds > 0) _lastKnownSeconds = seconds;
    });

    _readyTimeoutTimer?.cancel();
    _readyTimeoutTimer = Timer(_readyTimeout, () {
      if (!mounted) return;
      if (_isReady || _hasLoadError) return;
      debugPrint(
        '[YouTubePlayerWidget] ready timeout — revealing player (IFrame state slow)',
      );
      setState(() {
        _isReady = true;
      });
      _applyStartSecondsIfNeeded();
      _applyIosShortsPlayerLayout();
      if (_isIosShortFormInline) return;
      // Stage 2: if no meaningful player state arrives after reveal,
      // the embed is truly broken — fall back to thumbnail.
      _errorFallbackTimer?.cancel();
      _errorFallbackTimer = Timer(_errorFallbackDelay, () {
        if (!mounted) return;
        if (_playerDidPlay || _hasLoadError) return;
        debugPrint(
          '[YouTubePlayerWidget] error fallback — no playback after reveal, showing thumbnail',
        );
        setState(() {
          _hasLoadError = true;
        });
      });
    });

    setState(() {
      _controller = controller;
    });
    if (iosShortFormInline) {
      _armIosShortsWatchdog();
    }

    unawaited(() async {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted || _didReportDuration) return;
      try {
        final seconds = await controller.duration;
        _reportDurationIfKnown(
          Duration(milliseconds: (seconds * 1000).round()),
        );
      } catch (_) {}
    }());

    widget.onControllerReady?.call(YouTubePlayerHandle(
      seekTo: (double seconds) {
        _controller?.seekTo(seconds: seconds, allowSeekAhead: true);
      },
      play: () {
        _playFromApp = true;
        _intendedPlayerState = PlayerState.playing;
        _controller?.playVideo();
        unawaited(_ensureYoutubeAudible());
      },
      pause: () {
        _pauseFromApp = true;
        _intendedPlayerState = PlayerState.paused;
        _controller?.pauseVideo();
      },
      getCurrentTime: () async {
        try {
          final t = await _controller?.currentTime;
          if (t != null && t > 0) {
            _lastKnownSeconds = t;
            return t;
          }
        } catch (_) {}
        return _lastKnownSeconds;
      },
      setPlaybackGuard: (bool enabled) {
        _playbackGuard = enabled;
        if (!enabled) _intendedPlayerState = null;
      },
    ));
  }

  Future<void> _ensureYoutubeAudible() async {
    final c = _controller;
    if (!mounted || c == null || _hasLoadError) return;
    final now = DateTime.now();
    if (_lastYoutubeAudibleAttempt != null &&
        now.difference(_lastYoutubeAudibleAttempt!) <
            const Duration(milliseconds: 450)) {
      return;
    }
    _lastYoutubeAudibleAttempt = now;
    try {
      if (await c.isMuted) {
        await c.unMute();
      }
      final vol = await c.volume;
      if (vol < 1) {
        await c.setVolume(100);
      }
    } catch (_) {}
  }

  void _reportDurationIfKnown(Duration duration) {
    if (_didReportDuration || !mounted) return;
    final seconds = duration.inMilliseconds / 1000.0;
    if (seconds <= 0.5) return;
    _didReportDuration = true;
    rememberYouTubePlaybackDuration(widget.videoId, seconds);
    widget.onDurationKnown?.call(seconds);
  }

  bool get _isIosSquareBox {
    return !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        !widget.isFullscreenPage &&
        widget.aspectRatio <= 1.0;
  }

  bool get _isIosCinemaInSquare => _isIosSquareBox && _iosCinemaFallback;

  /// 인라인 1:1 숏폼 + 세로 전체화면 숏폼.
  bool get _useIosShortsPlayerLayout {
    return !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        widget.aspectRatio <= 1.0 &&
        !_iosCinemaFallback;
  }

  void _armIosShortsWatchdog() {
    _iosShortsWatchdogTimer?.cancel();
    _iosShortsErrorProbeTimer?.cancel();
    if (!_isIosShortFormInline) return;
    _iosShortsWatchdogTimer = Timer(const Duration(milliseconds: 2500), () {
      if (!mounted || _iosCinemaFallback) return;
      if (_iosShortsHealthy) return;
      _failoverIosShortsToCinema('timeout');
    });
    // `cued` 만으로는 안쪽 HTML5 가 살아 있다고 볼 수 없다. 사용자가
    // 나중에 재생을 눌러 Playback ID 가 떠도 잡을 수 있게 유지한다.
    _iosShortsErrorProbeTimer = Timer.periodic(
      const Duration(milliseconds: 350),
      (timer) {
        if (!mounted || _iosCinemaFallback || timer.tick > 120) {
          timer.cancel();
          return;
        }
        unawaited(_probeIosShortsPlaybackError());
      },
    );
  }

  Future<void> _probeIosShortsPlaybackError() async {
    if (!_isIosShortFormInline || _iosCinemaFallback) return;
    final controller = _controller;
    if (controller == null) return;
    try {
      final raw = await controller.webViewController
          .runJavaScriptReturningResult(_kIosPlaybackErrorProbeJs);
      final text = raw.toString().toLowerCase();
      if (text.contains('error')) {
        _failoverIosShortsToCinema('html-error');
      }
    } catch (_) {}
  }

  void _playFromIosPoster() {
    if (!mounted || _hasLoadError) return;
    _playFromApp = true;
    _intendedPlayerState = PlayerState.playing;
    if (_useDirectShortsEmbed) {
      setState(() {
        _iosShortsHealthy = true;
        _isReady = true;
      });
      _runIosEmbedCmd('playVideo');
      return;
    }
    if (_isIosShortFormInline && !_iosShortsHealthy) {
      setState(() {
        _iosShortsHealthy = true;
        _isReady = true;
      });
      _applyIosShortsPlayerLayout();
    } else if (!_isReady) {
      setState(() => _isReady = true);
    }
    _controller?.playVideo();
    unawaited(_ensureYoutubeAudible());
  }

  void _failoverIosShortsToCinema(String reason) {
    if (!mounted || _iosCinemaFallback || !_isIosSquareBox) return;
    debugPrint('[YouTubePlayerWidget] shorts → cinema fallback ($reason)');
    _iosShortsWatchdogTimer?.cancel();
    _iosShortsErrorProbeTimer?.cancel();
    _readyTimeoutTimer?.cancel();
    _errorFallbackTimer?.cancel();
    _iosShortsLayoutTimer?.cancel();
    _valueSub?.cancel();
    _videoStateSub?.cancel();
    final old = _controller;
    _controller = null;
    unawaited(old?.close());
    _isReady = false;
    _hasLoadError = false;
    _playerDidPlay = false;
    _didApplyStartSeconds = false;
    _iosCinemaFallback = true;
    _iosShortsHealthy = false;
    _initController();
    _startIosLayoutTimer();
  }

  void _onPlayerValue(YoutubePlayerValue value) {
    if (!mounted) return;

    final isErrorState = value.error != YoutubeError.none;
    if (isErrorState && !_hasLoadError) {
      debugPrint(
        '[YouTubePlayerWidget] YouTube error received: ${value.error}',
      );
      if (_isIosShortFormInline) {
        _failoverIosShortsToCinema('api-error:${value.error}');
        return;
      }
      _readyTimeoutTimer?.cancel();
      _errorFallbackTimer?.cancel();
      setState(() {
        _hasLoadError = true;
        _isReady = true;
      });
      return;
    }

    // Reveal as soon as the IFrame reports this video (often before cued/buffering).
    final meta = value.metaData;
    if (!_isReady &&
        !_hasLoadError &&
        meta.videoId.isNotEmpty &&
        meta.videoId == widget.videoId) {
      _playerDidPlay = true;
      _readyTimeoutTimer?.cancel();
      _errorFallbackTimer?.cancel();
      setState(() {
        _isReady = true;
        _hasLoadError = false;
      });
      _applyStartSecondsIfNeeded();
      if (_isIosCinemaInSquare) {
        _applyIosCinemaInSquareLayout();
      } else {
        _applyIosShortsPlayerLayout();
      }
    }

    _reportDurationIfKnown(meta.duration);

    final state = value.playerState;

    // Detect user-driven pause/play (not from our app API).
    if (state == PlayerState.paused) {
      if (_pauseFromApp) {
        _pauseFromApp = false;
      } else {
        widget.onUserPausedInPlayer?.call();
      }
    }
    if (state == PlayerState.playing) {
      if (_playFromApp) {
        _playFromApp = false;
      } else if (_intendedPlayerState != PlayerState.playing) {
        widget.onUserPlayedInPlayer?.call();
      }
    }

    // Audio-focus guard: Android SpeechRecognizer grabs/releases audio focus
    // on every listen session cycle, which causes the YouTube WebView to
    // pause (focus lost) and play (focus regained). Counteract these
    // unwanted state changes by enforcing whatever state our code last set.
    if (_playbackGuard && _intendedPlayerState != null) {
      if (state == PlayerState.paused &&
          _intendedPlayerState == PlayerState.playing) {
        debugPrint('[YouTubePlayerWidget] guard: reverting unwanted pause');
        _playFromApp = true;
        _controller?.playVideo();
        return;
      }
      if (state == PlayerState.playing &&
          _intendedPlayerState == PlayerState.paused) {
        debugPrint('[YouTubePlayerWidget] guard: reverting unwanted play');
        _pauseFromApp = true;
        _controller?.pauseVideo();
        return;
      }
    }

    if (state == PlayerState.playing && !_hasLoadError) {
      _markPlaybackStarted();
      unawaited(_ensureYoutubeAudible());
    } else if (state == PlayerState.paused) {
      _pausePlaybackClock();
    } else if (state == PlayerState.ended) {
      _flushWatchEnded();
    }

    final isMeaningfulState = state == PlayerState.playing ||
        state == PlayerState.paused ||
        state == PlayerState.buffering ||
        state == PlayerState.cued ||
        state == PlayerState.ended;
    if (isMeaningfulState) {
      _playerDidPlay = true;
      _iosShortsHealthy = true;
      // cued/paused 는 안쪽 플레이어가 아직 죽을 수 있다. 실제로
      // 버퍼/재생이 시작됐을 때만 오류 탐지를 멈춘다.
      if (state == PlayerState.playing ||
          state == PlayerState.buffering ||
          state == PlayerState.ended) {
        _iosShortsWatchdogTimer?.cancel();
        _iosShortsErrorProbeTimer?.cancel();
      } else {
        _iosShortsWatchdogTimer?.cancel();
      }
      _readyTimeoutTimer?.cancel();
      _errorFallbackTimer?.cancel();
      if (!_isReady) {
        setState(() {
          _isReady = true;
          _hasLoadError = false;
        });
        _applyStartSecondsIfNeeded();
      }
    }
  }

  void _applyDirectEmbedStartSecondsIfNeeded() {
    if (_didApplyStartSeconds) return;
    final start = widget.startSeconds;
    if (start <= 0.25) {
      _didApplyStartSeconds = true;
      return;
    }
    _didApplyStartSeconds = true;
    _lastKnownSeconds = start;
    _runIosEmbedCmd('seekTo', [start, true]);
  }

  void _applyStartSecondsIfNeeded() {
    if (_didApplyStartSeconds) return;
    final start = widget.startSeconds;
    if (start <= 0.25) {
      _didApplyStartSeconds = true;
      return;
    }
    _didApplyStartSeconds = true;
    final c = _controller;
    if (c == null) return;
    unawaited(() async {
      try {
        await c.seekTo(seconds: start, allowSeekAhead: true);
        if (widget.autoPlay) {
          _playFromApp = true;
          _intendedPlayerState = PlayerState.playing;
          await c.playVideo();
          unawaited(_ensureYoutubeAudible());
        }
      } catch (_) {}
    }());
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
  void dispose() {
    if (_isInlineFullscreen) {
      _overlayPortalController.hide();
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        unawaited(_lockIosPortrait());
      } else {
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
      }
    }
    _flushWatchEnded();
    _readyTimeoutTimer?.cancel();
    _errorFallbackTimer?.cancel();
    _iosShortsLayoutTimer?.cancel();
    _iosShortsWatchdogTimer?.cancel();
    _iosShortsErrorProbeTimer?.cancel();
    _valueSub?.cancel();
    _videoStateSub?.cancel();
    _controller?.close();
    final embed = _iosEmbedController;
    _iosEmbedController = null;
    if (embed != null) {
      unawaited(() async {
        try {
          await embed.runJavaScript('yorigoCmd("pauseVideo", []);');
        } catch (_) {}
        try {
          await embed.loadRequest(Uri.parse('about:blank'));
        } catch (_) {}
      }());
    }
    super.dispose();
  }

  bool get _shouldRotateFullscreen {
    // iOS는 앱 사용 중 가로로 두지 않는다. 숏폼·롱폼 모두 세로 전체화면.
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return false;
    }
    return true;
  }

  bool get _isIosShortFormInline => _isIosSquareBox && !_iosCinemaFallback;

  Future<void> _enterInlineFullscreen() async {
    if (_isInlineFullscreen || _controller == null || _hasLoadError) return;
    setState(() => _isInlineFullscreen = true);
    _overlayPortalController.show();
    widget.onFullscreenChanged?.call(true);
    if (_shouldRotateFullscreen) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  Future<void> _exitInlineFullscreen() async {
    if (!_isInlineFullscreen) return;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _lockIosPortrait();
    } else {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
    if (!mounted) return;
    _overlayPortalController.hide();
    setState(() => _isInlineFullscreen = false);
    widget.onFullscreenChanged?.call(false);
  }

  Future<void> _toggleFullscreen() async {
    if (_useDirectShortsEmbed ||
        _isIosSquareBox ||
        widget.isFullscreenPage) {
      if (widget.isFullscreenPage) {
        widget.onFullscreenChanged?.call(false);
        if (mounted) Navigator.of(context).pop();
        return;
      }
      widget.onFullscreenChanged?.call(true);
      _pauseFromApp = true;
      _intendedPlayerState = PlayerState.paused;
      _runIosEmbedCmd('pauseVideo');
      _controller?.pauseVideo();
      final shortsPortrait = !_iosCinemaFallback;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _YouTubeFullscreenPage(
            videoId: widget.videoId,
            showControls: widget.showControls,
            thumbnailUrl: widget.thumbnailUrl,
            startSeconds: _lastKnownSeconds,
            portrait: true,
            aspectRatio: shortsPortrait ? 9 / 16 : 16 / 9,
            onExit: () => widget.onFullscreenChanged?.call(false),
          ),
        ),
      );
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await _lockIosPortrait();
      }
      if (mounted) widget.onFullscreenChanged?.call(false);
      return;
    }
    if (_isInlineFullscreen) {
      await _exitInlineFullscreen();
      return;
    }
    await _enterInlineFullscreen();
  }

  Widget _buildKeyedYoutubePlayer(double aspectRatio) {
    return YoutubePlayer(
      key: _useIosShortsPlayerLayout ? null : _youtubeViewKey,
      controller: _controller!,
      aspectRatio: aspectRatio,
      backgroundColor: Colors.black,
      enableFullScreenOnVerticalDrag: false,
    );
  }

  Widget _buildFullscreenOverlay(BuildContext context) {
    final bool landscape = widget.aspectRatio > 1.0;
    final double aspect = landscape ? 16 / 9 : widget.aspectRatio;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        unawaited(_exitInlineFullscreen());
      },
      child: Material(
        color: Colors.black,
        child: SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: AspectRatio(
                  aspectRatio: aspect,
                  child: _buildKeyedYoutubePlayer(aspect),
                ),
              ),
              _buildFullscreenControl(),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: widget.isFullscreenPage
            ? BorderRadius.zero
            : BorderRadius.circular(12),
      ),
      child: ClipRRect(
        borderRadius: widget.isFullscreenPage
            ? BorderRadius.zero
            : BorderRadius.circular(12),
        clipBehavior: platformViewClipBehavior,
        child: kIsWeb
            ? _buildWebFallbackPlayer()
            : (_isInlineFullscreen
                  ? const ColoredBox(color: Colors.black)
                  : _buildMobilePlayer()),
      ),
    );
    if (_useDirectShortsEmbed ||
        _isIosSquareBox ||
        widget.isFullscreenPage) {
      return player;
    }
    return OverlayPortal(
      controller: _overlayPortalController,
      overlayLocation: OverlayChildLocation.rootOverlay,
      overlayChildBuilder: _buildFullscreenOverlay,
      child: player,
    );
  }

  /// 웹 환경용 플레이어 (외부 링크 fallback)
  Widget _buildWebFallbackPlayer() {
    final youtubeUrl = 'https://www.youtube.com/watch?v=${widget.videoId}';
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: Colors.black,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.play_circle_outline,
              color: Colors.white,
              size: 64,
            ),
            const SizedBox(height: 16),
            const Text(
              '웹 환경에서는 YouTube에서 재생됩니다',
              style: TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () async {
                final uri = Uri.parse(youtubeUrl);
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.platformDefault);
                }
              },
              icon: const Icon(Icons.open_in_new),
              label: const Text('YouTube에서 보기'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }

  /// 숏폼: youtube-nocookie `/embed` iframe. 썸네일은 로드 중에만 덮고
  /// 탭은 WebView 로 통과시킨다. iOS·Android 동일.
  Widget _buildIosDirectEmbedPlayer() {
    final embed = _iosEmbedController;
    return Stack(
      alignment: Alignment.center,
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        if (embed != null)
          WebViewWidget(controller: embed)
        else
          _buildPosterLoadingOverlay(),
        if (!_isReady && embed != null)
          Positioned.fill(
            child: IgnorePointer(
              child: _buildPosterLoadingOverlay(),
            ),
          ),
        if (_hasLoadError) Positioned.fill(child: _buildLoadErrorOverlay()),
        if (!_hasLoadError) _buildFullscreenControl(),
      ],
    );
  }

  /// 모바일 환경용 플레이어 (youtube_player_iframe 사용)
  ///
  /// `YoutubePlayer`는 내부적으로 자기 크기를 `aspectRatio`로 잡는다.
  /// 부모 박스 비율이 다르면 남는 공간이 생기므로 Stack 가운데 정렬 +
  /// 검정 배경으로 깔끔하게 레터박싱한다.
  ///
  /// - 일반 영상(16:9): `aspectRatio = 16/9`로 부모 박스를 채움
  /// - Shorts(9:16): 호출부에서 `aspectRatio = 1`을 주면 1:1 박스에
  ///   세로 영상이 들어가 영상 영역이 16:9 대비 훨씬 커진다.
  ///
  /// 풀스크린 페이지에서는 가로 회전이라 16:9가 자연스러우므로 `aspectRatio`
  /// 파라미터를 무시하고 16:9로 고정한다.
  ///
  /// 가로(`aspectRatio > 1`)일 때만 FittedBox + SizedBox(logical viewport) 트릭을
  /// 적용한다. 이유: YouTube IFrame Player의 mobile embed UI는 viewport height가
  /// 약 270px 미만으로 떨어지면 자동으로 "Watch on YouTube" 미니 프리뷰 모드로
  /// 빠져 영상을 박스 가운데 작게 letterbox한다. 카드 너비(약 344dp) × 16:9
  /// 박스는 height가 약 193dp로 이 임계값 아래라 가로 영상이 박스에 꽉 차지
  /// 않았다.
  ///
  /// logical viewport 크기는 "임계값을 살짝만 넘기는 선"까지만 키운다.
  /// 예전에는 720으로 크게 띄운 뒤 ~0.27배로 축소했는데, 그러면 YouTube가
  /// 큰 viewport 기준으로 그린 컨트롤(제목/재생바/버튼)이 그대로 같은 비율로
  /// 줄어들어 박스 대비 너무 작아 보였다. 실제 박스 높이가 임계값보다 크면
  /// 트릭 없이 native 크기로 그리고, 작을 때만 _kMinLogicalHeight까지만
  /// 올려 컨트롤이 박스 크기에 맞춰 자연스럽게 보이도록 한다. Shorts(1:1)는
  /// 박스 height가 충분해 트릭 불필요.
  Widget _buildMobilePlayer() {
    if (_useDirectShortsEmbed) {
      return _buildIosDirectEmbedPlayer();
    }
    final controller = _controller;
    if (controller == null) {
      return _buildLoadingView();
    }

    final effectiveAspectRatio = _useIosShortsPlayerLayout
        ? 9 / 16
        : (_isIosCinemaInSquare ? 1.0 : widget.aspectRatio);

    Widget buildPlayer(double playerAspectRatio) {
      return _buildKeyedYoutubePlayer(playerAspectRatio);
    }

    final Widget basePlayer = buildPlayer(effectiveAspectRatio);

    // 가로 영상 + 인라인(non-fullscreen) 케이스에 한해 logical viewport를 키워
    // YouTube embed의 height-기반 미니 프리뷰 모드 임계값을 회피한다.
    // iOS WKWebView 는 FittedBox(Transform) 합성이 깨지므로 iframe 만
    // 300pt 로 키운 뒤 시네마 박스에 맞게 클립한다. 박스는 16:9보다
    // 조금만 높아 제목·재생바가 잘리지 않는다.
    final bool needsLogicalUpscale = effectiveAspectRatio > 1.0 &&
        defaultTargetPlatform != TargetPlatform.iOS;
    final bool needsIosLandscapeClip = !kIsWeb &&
        effectiveAspectRatio > 1.0 &&
        !widget.isFullscreenPage &&
        defaultTargetPlatform == TargetPlatform.iOS;
    Widget playerWidget = basePlayer;
    if (_isIosCinemaInSquare) {
      playerWidget = LayoutBuilder(
        builder: (context, constraints) {
          final boxW = constraints.maxWidth;
          final boxH = constraints.maxHeight;
          if (!boxW.isFinite || !boxH.isFinite || boxW < 8 || boxH < 8) {
            return basePlayer;
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _applyIosCinemaInSquareLayout();
          });
          return SizedBox(
            width: boxW,
            height: boxH,
            child: basePlayer,
          );
        },
      );
    } else if (_useIosShortsPlayerLayout) {
      playerWidget = LayoutBuilder(
        builder: (context, constraints) {
          final boxW = constraints.maxWidth;
          final boxH = constraints.maxHeight;
          if (!boxW.isFinite || !boxH.isFinite || boxW < 8 || boxH < 8) {
            return basePlayer;
          }
          var playerW = boxH * 9 / 16;
          var playerH = boxH;
          if (playerW > boxW) {
            playerW = boxW;
            playerH = playerW * 16 / 9;
          }
          if (_isReady) {
            unawaited(controller.setSize(playerW, playerH));
          }
          return Center(
            child: SizedBox(
              width: playerW,
              height: playerH,
              child: basePlayer,
            ),
          );
        },
      );
    } else if (needsLogicalUpscale) {
      // YouTube mini-preview 임계값(약 270) 위에 약간의 여유.
      // 이 값을 너무 키우면 컨트롤이 다시 작아진다.
      const double minLogicalHeight = 300.0;
      playerWidget = LayoutBuilder(
        builder: (context, constraints) {
          final double actualHeight = constraints.maxHeight;
          if (!actualHeight.isFinite ||
              actualHeight <= 0 ||
              actualHeight >= minLogicalHeight) {
            return basePlayer;
          }
          final double logicalHeight = minLogicalHeight;
          final double logicalWidth = logicalHeight * effectiveAspectRatio;
          return FittedBox(
            fit: BoxFit.fill,
            alignment: Alignment.center,
            child: SizedBox(
              width: logicalWidth,
              height: logicalHeight,
              child: basePlayer,
            ),
          );
        },
      );
    } else if (needsIosLandscapeClip) {
      const double minLogicalHeight = YoutubeEmbedLayout.miniPreviewMinHeight;
      playerWidget = LayoutBuilder(
        builder: (context, constraints) {
          final double actualWidth = constraints.maxWidth;
          final double actualHeight = constraints.maxHeight;
          if (!actualWidth.isFinite ||
              !actualHeight.isFinite ||
              actualWidth <= 0 ||
              actualHeight <= 0 ||
              actualHeight >= minLogicalHeight) {
            return basePlayer;
          }
          final double iframeAspect = actualWidth / minLogicalHeight;
          if (_isReady) {
            unawaited(
              controller.setSize(actualWidth, minLogicalHeight),
            );
          }
          return ClipRect(
            clipBehavior: platformViewClipBehavior,
            child: OverflowBox(
              alignment: Alignment.center,
              minWidth: actualWidth,
              maxWidth: actualWidth,
              minHeight: minLogicalHeight,
              maxHeight: minLogicalHeight,
              child: SizedBox(
                width: actualWidth,
                height: minLogicalHeight,
                child: buildPlayer(iframeAspect),
              ),
            ),
          );
        },
      );
    }

    final Widget revealedPlayer = wrapPlatformViewReveal(
      revealed: _isIosShortFormInline
          ? (_iosShortsHealthy && !_hasLoadError)
          : (_isReady && !_hasLoadError),
      child: playerWidget,
    );

    return Stack(
      alignment: Alignment.center,
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        revealedPlayer,
        if (_isIosShortFormInline
            ? !_iosShortsHealthy
            : !_isReady)
          Positioned.fill(
            child: defaultTargetPlatform == TargetPlatform.iOS
                ? GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _playFromIosPoster,
                    child: _buildPosterLoadingOverlay(),
                  )
                : _buildPosterLoadingOverlay(),
          ),
        if (_hasLoadError) Positioned.fill(child: _buildLoadErrorOverlay()),
        // 임베드 자체가 거부된 상태에서는 풀스크린이 의미가 없으므로 버튼을
        // 숨긴다. 외부 YouTube로의 이동은 부모(creator bar의 "원본 영상"
        // 알약)에서 처리한다.
        if (!_hasLoadError) _buildFullscreenControl(),
      ],
    );
  }

  Widget _buildPosterLoadingOverlay() {
    // YouTube 썸네일은 항상 16:9 캔버스로 발급되며 Shorts는 9:16 컨텐츠가
    // 그 안에 letterbox로 들어 있다. 1:1 박스에서 contain으로 띄우면 이중
    // letterbox로 검정이 거대해져, cover로 캔버스 letterbox 띠를 잘라낸다.
    return InlineVideoHeroPoster(
      thumbnailUrl: widget.thumbnailUrl,
      backgroundColor: Colors.black,
      imageFit: BoxFit.cover,
      showCenterPlayGlyph: true,
    );
  }

  Widget _buildLoadingView() => _buildPosterLoadingOverlay();

  /// 임베드 실패 시 썸네일을 그대로 노출하는 fallback.
  ///
  /// YouTube IFrame Player가 던지는 에러(101/150 외부 임베드 차단, 100 영상
  /// 비공개·삭제, 지역 제한 등)는 우리가 우회할 수 없는 정책 거부라 검정
  /// 에러 화면 대신 영상 썸네일을 그대로 깔아 둔다. 외부 YouTube로의 이동은
  /// 부모(creator bar의 "원본 영상" 알약 버튼)에서 처리한다.
  ///
  /// YouTube 썸네일은 항상 16:9 캔버스라 1:1 박스에 contain으로 넣으면 위아래
  /// 검정이 크게 남는다(Shorts의 경우 캔버스 자체에 9:16 컨텐츠가 letterbox로
  /// 들어 있어 이중 letterbox). cover로 캔버스 letterbox 띠를 잘라내면 박스에
  /// 꽉 차게 그려진다.
  Widget _buildLoadErrorOverlay() {
    final thumb = widget.thumbnailUrl;
    return GestureDetector(
      onTap: () async {
        final uri = Uri.parse(
          'https://www.youtube.com/watch?v=${widget.videoId}',
        );
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
      child: Container(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (thumb != null && thumb.isNotEmpty)
              AppNetworkImage(
                imageUrl: thumb,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                errorWidget: const SizedBox.shrink(),
              ),
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.play_circle_outline, color: Colors.white, size: 22),
                    SizedBox(width: 8),
                    Text(
                      'YouTube에서 보기',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 풀스크린 진입/종료 버튼.
  ///
  /// 영상 우상단은 YouTube 자체 컨트롤(오디오 음소거, CC, 더보기 등)과 외부
  /// "원본 영상" 버튼이 모이는 자리라 겹침이 심했다. 그래서 풀스크린 버튼만
  /// 영상 우하단으로 이동시켜 충돌을 피한다. 진입 시 자동으로 영상이 열리는
  /// UX로 바뀌면서 X(닫기) 버튼은 의미가 약해져 제거했다 — 풀스크린 페이지
  /// 에서는 같은 풀스크린 버튼이 종료 역할을 한다.
  Widget _buildFullscreenControl() {
    return Positioned(
      right: 8,
      bottom: 8,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _toggleFullscreen,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              shape: BoxShape.circle,
            ),
            child: Icon(
              (_isInlineFullscreen || widget.isFullscreenPage)
                  ? Icons.fullscreen_exit
                  : Icons.fullscreen,
              color: Colors.white,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}

class _YouTubeFullscreenPage extends StatefulWidget {
  final String videoId;
  final bool showControls;
  final String? thumbnailUrl;
  final VoidCallback? onExit;
  final double startSeconds;
  final bool portrait;
  final double aspectRatio;

  const _YouTubeFullscreenPage({
    required this.videoId,
    required this.showControls,
    this.thumbnailUrl,
    this.onExit,
    this.startSeconds = 0,
    this.portrait = false,
    this.aspectRatio = 16 / 9,
  });

  @override
  State<_YouTubeFullscreenPage> createState() => _YouTubeFullscreenPageState();
}

class _YouTubeFullscreenPageState extends State<_YouTubeFullscreenPage> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (widget.portrait ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      unawaited(_lockIosPortrait());
    } else {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  @override
  void dispose() {
    widget.onExit?.call();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    unawaited(_lockIosPortrait());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: YouTubePlayerWidget(
          videoId: widget.videoId,
          autoPlay: true,
          showControls: widget.showControls,
          thumbnailUrl: widget.thumbnailUrl,
          isFullscreenPage: true,
          aspectRatio: widget.aspectRatio,
          startSeconds: widget.startSeconds,
          onClose: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }
}
