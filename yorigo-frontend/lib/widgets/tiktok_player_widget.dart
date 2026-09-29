import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../theme/app_colors.dart';
import '../utils/inline_media_webview.dart';
import '../utils/tiktok_utils.dart';
import 'app_network_image.dart';
import 'inline_video_hero_poster.dart';

/// TikTok 영상을 앱 내에서 임베드 재생하는 위젯.
///
/// 공식 oEmbed API(`https://www.tiktok.com/oembed?url=...`)를 호출해 받은
/// `html`(blockquote + embed.js)을 `webview_flutter`로 로드한다. 토큰/리뷰
/// 불필요·공개 API. `kIsWeb`이거나 oEmbed 호출이 실패하면 외부 링크 폴백.
///
/// oEmbed 네트워크와 [WebViewController] 생성·부착을 겹쳐 첫 페인트까지 시간을 줄인다.
class TikTokPlayerWidget extends StatefulWidget {
  final String videoUrl;
  final String? thumbnailUrl;
  final VoidCallback? onClose;
  final double aspectRatio;

  const TikTokPlayerWidget({
    super.key,
    required this.videoUrl,
    this.thumbnailUrl,
    this.onClose,
    this.aspectRatio = 1.0,
  });

  @override
  State<TikTokPlayerWidget> createState() => _TikTokPlayerWidgetState();
}

class _TikTokPlayerWidgetState extends State<TikTokPlayerWidget> {
  WebViewController? _controller;
  bool _isReady = false;
  bool _hasLoadError = false;
  /// iOS: 임베드 스케일이 끝나기 전에는 썸네일로 덮고 탭을 막는다.
  bool _iosEmbedFitted = false;
  Timer? _readyTimeoutTimer;
  String? _oembedThumbnailUrl;
  double _iosBoxW = 0;
  double _iosBoxH = 0;

  static bool get _isIos =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  void _rememberIosBox(double boxW, double boxH) {
    if (!_isIos) return;
    if (!boxW.isFinite || !boxH.isFinite || boxW < 8 || boxH < 8) return;
    final same = (boxW - _iosBoxW).abs() < 0.5 && (boxH - _iosBoxH).abs() < 0.5;
    _iosBoxW = boxW;
    _iosBoxH = boxH;
    if (same) return;
    _pushIosFit();
  }

  void _pushIosFit() {
    if (!_isIos || _hasLoadError) return;
    final controller = _controller;
    if (controller == null) return;
    if (_iosBoxW < 8 || _iosBoxH < 8) return;
    unawaited(
      controller.runJavaScript(
        'window.__yorigoTtFitW=${_iosBoxW.toStringAsFixed(1)};'
        'window.__yorigoTtFitH=${_iosBoxH.toStringAsFixed(1)};'
        'if(window.__yorigoTtFit)window.__yorigoTtFit();',
      ),
    );
  }

  static bool _isAllowedEmbedHost(String host) {
    final h = host.toLowerCase();
    return h.contains('tiktok') ||
        h.contains('tiktokv.com') ||
        h.contains('tiktokcdn') ||
        h.contains('byteoversea') ||
        h.contains('bytecdntp') ||
        h.contains('ttwstatic') ||
        h.contains('bytedance') ||
        h.contains('ibyteimg') ||
        h.contains('muscdn');
  }

  static const Duration _readyTimeout = Duration(seconds: 12);

  /// Unmutes `<video>` nodes TikTok often loads muted for autoplay policy.
  static const String _unmuteVideosJs = '''
(function(){
  function u(){
    try {
      var vids = document.querySelectorAll('video');
      for (var i = 0; i < vids.length; i++) {
        var v = vids[i];
        v.muted = false;
        v.defaultMuted = false;
        v.removeAttribute('muted');
        v.setAttribute('playsinline', '');
        v.setAttribute('webkit-playsinline', '');
        v.playsInline = true;
        if (typeof v.volume === 'number') v.volume = 1;
      }
    } catch (e) {}
  }
  u();
  setTimeout(u, 400);
  setTimeout(u, 1200);
})();
''';

  @override
  void initState() {
    super.initState();
    if (kIsWeb) return;
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // Start network while the WebView native view spin-ups (controller attached in setState below).
    final oembedFuture = fetchTikTokOEmbed(widget.videoUrl);

    final controller = createInlineMediaWebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black);

    if (_isIos) {
      controller.addJavaScriptChannel(
        'YorigoTtFit',
        onMessageReceived: (message) {
          if (!mounted || _hasLoadError) return;
          if (message.message == 'ready') {
            _onIosEmbedFitted();
          }
        },
      );
    }

    controller.setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (!mounted) return;
            if (!_isIos) {
              _readyTimeoutTimer?.cancel();
            }
            setState(() {
              _isReady = true;
            });
            unawaited(() async {
              final c = _controller;
              if (c != null) await c.runJavaScript(_unmuteVideosJs);
            }());
            _pushIosFit();
          },
          onWebResourceError: (error) {
            if (!mounted) return;
            if (error.isForMainFrame == true) {
              debugPrint(
                '[TikTokPlayerWidget] main-frame error: ${error.description}',
              );
              setState(() {
                _hasLoadError = true;
                _isReady = true;
                _iosEmbedFitted = true;
              });
            }
          },
          onNavigationRequest: (request) {
            final reqUri = Uri.tryParse(request.url);
            if (reqUri == null) return NavigationDecision.navigate;

            // about:blank 초기 로드 / data: URL / embed.js / embed iframe은 허용.
            if (request.url.startsWith('about:') ||
                request.url.startsWith('data:') ||
                request.url.startsWith('blob:')) {
              return NavigationDecision.navigate;
            }

            final host = reqUri.host.toLowerCase();
            // player/v1, embed/v2, cdn, static 등 임베드 파이프라인 전체를 허용.
            // 경로를 /embed 로만 제한하면 iframe 재생이 막혀 검은 화면이 된다.
            if (_isAllowedEmbedHost(host)) {
              return NavigationDecision.navigate;
            }

            // 그 외 사용자 클릭에 의한 이탈은 외부 앱으로.
            _launchExternal(request.url);
            return NavigationDecision.prevent;
          },
        ),
      );

    _readyTimeoutTimer?.cancel();
    _readyTimeoutTimer = Timer(_readyTimeout, () {
      if (!mounted || _hasLoadError) return;
      if (_isIos) {
        if (_iosEmbedFitted) return;
        debugPrint(
          '[TikTokPlayerWidget] iOS fit timeout — revealing player',
        );
        setState(() {
          _isReady = true;
          _iosEmbedFitted = true;
        });
        return;
      }
      if (_isReady) return;
      debugPrint(
        '[TikTokPlayerWidget] ready timeout — revealing WebView',
      );
      setState(() => _isReady = true);
    });

    if (!mounted) return;
    setState(() {
      _controller = controller;
    });

    final oembed = await oembedFuture;
    if (!mounted) return;
    if (oembed == null) {
      setState(() {
        _hasLoadError = true;
        _isReady = true;
        _iosEmbedFitted = true;
      });
      return;
    }

    final freshThumb = oembed.thumbnailUrl?.trim();
    if (freshThumb != null && freshThumb.isNotEmpty) {
      setState(() => _oembedThumbnailUrl = freshThumb);
    }

    await controller.loadHtmlString(
      wrapTikTokEmbedHtml(
        oembed.html,
        containInBox: _isIos,
      ),
    );
    _pushIosFit();
  }

  void _onIosEmbedFitted() {
    if (!_isIos || !mounted || _hasLoadError || _iosEmbedFitted) return;
    _readyTimeoutTimer?.cancel();
    setState(() {
      _isReady = true;
      _iosEmbedFitted = true;
    });
  }

  Future<void> _launchExternal(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  void dispose() {
    _readyTimeoutTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        clipBehavior: platformViewClipBehavior,
        child: kIsWeb ? _buildWebFallback() : _buildMobilePlayer(),
      ),
    );
  }

  Widget _buildWebFallback() {
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.play_circle_outline,
                color: Colors.white, size: 64),
            const SizedBox(height: 16),
            const Text(
              '웹 환경에서는 TikTok에서 재생됩니다',
              style: TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => _launchExternal(widget.videoUrl),
              icon: const Icon(Icons.open_in_new),
              label: const Text('TikTok에서 보기'),
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
    );
  }

  Widget _buildMobilePlayer() {
    final controller = _controller;
    final webView = controller == null
        ? null
        : wrapPlatformViewReveal(
            revealed: _isReady && !_hasLoadError,
            child: WebViewWidget(controller: controller),
          );
    if (!_isIos) {
      return Stack(
        alignment: Alignment.center,
        children: [
          const Positioned.fill(child: ColoredBox(color: Colors.black)),
          if (webView != null) webView,
          if (!_isReady) Positioned.fill(child: _buildPosterLoadingOverlay()),
          if (_hasLoadError)
            Positioned.fill(child: _buildLoadErrorOverlay()),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final boxW = constraints.maxWidth;
        final boxH = constraints.maxHeight;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _rememberIosBox(boxW, boxH);
        });
        final revealed = _iosEmbedFitted && !_hasLoadError;
        return Stack(
          alignment: Alignment.center,
          children: [
            const Positioned.fill(child: ColoredBox(color: Colors.black)),
            if (webView != null)
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: !revealed,
                  child: webView,
                ),
              ),
            if (!revealed)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: _buildPosterLoadingOverlay(showPlayGlyph: false),
                ),
              ),
            if (_hasLoadError)
              Positioned.fill(child: _buildLoadErrorOverlay()),
          ],
        );
      },
    );
  }

  String? get _posterUrl {
    final fresh = _oembedThumbnailUrl?.trim();
    if (fresh != null && fresh.isNotEmpty) return fresh;
    final stored = widget.thumbnailUrl?.trim();
    if (stored != null && stored.isNotEmpty) return stored;
    return null;
  }

  Widget _buildPosterLoadingOverlay({bool showPlayGlyph = true}) {
    return InlineVideoHeroPoster(
      thumbnailUrl: _posterUrl,
      backgroundColor: Colors.black,
      imageFit: BoxFit.contain,
      showCenterPlayGlyph: showPlayGlyph,
    );
  }

  Widget _buildLoadErrorOverlay() {
    final thumb = _posterUrl;
    return GestureDetector(
      onTap: () => _launchExternal(widget.videoUrl),
      child: Container(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (thumb != null && thumb.isNotEmpty)
              AppNetworkImage(
                imageUrl: thumb,
                fit: BoxFit.contain,
                width: double.infinity,
                height: double.infinity,
                errorWidget: const SizedBox.shrink(),
              ),
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.play_circle_outline,
                        color: Colors.white, size: 22),
                    SizedBox(width: 8),
                    Text(
                      'TikTok에서 보기',
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
}
