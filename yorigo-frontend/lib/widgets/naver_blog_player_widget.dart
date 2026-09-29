import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb, Factory;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../theme/app_colors.dart';
import '../utils/inline_media_webview.dart';
import 'app_network_image.dart';
import 'inline_video_hero_poster.dart';

/// 네이버 블로그 글을 디테일 스크린의 영상 자리에 인라인으로 임베드하는 위젯.
///
/// 영상 임베드(YouTube/IG/TikTok)와 다르게 oEmbed가 없어 실제 글 페이지(`m.blog.naver.com`)
/// 를 그대로 WebView에 로드한다. 본문 스크롤은 WebView 내부에서 이뤄진다.
///
/// kIsWeb 환경에서는 외부 링크 폴백.
class NaverBlogPlayerWidget extends StatefulWidget {
  final String url;
  final String? thumbnailUrl;
  final double aspectRatio;

  const NaverBlogPlayerWidget({
    super.key,
    required this.url,
    this.thumbnailUrl,
    this.aspectRatio = 16 / 9,
  });

  @override
  State<NaverBlogPlayerWidget> createState() => _NaverBlogPlayerWidgetState();
}

class _NaverBlogPlayerWidgetState extends State<NaverBlogPlayerWidget> {
  WebViewController? _controller;
  bool _isReady = false;
  bool _hasLoadError = false;
  double _progress = 0;
  Timer? _readyTimeoutTimer;

  static const Duration _readyTimeout = Duration(seconds: 15);

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
    _initController();
  }

  void _initController() {
    final controller = createInlineMediaWebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (!mounted) return;
            setState(() => _progress = progress / 100.0);
            // Show the WebView a bit before onPageFinished once the main document is mostly there.
            if (!_isReady && progress >= 88) {
              _readyTimeoutTimer?.cancel();
              setState(() {
                _isReady = true;
                _progress = progress / 100.0;
              });
            }
          },
          onPageFinished: (_) {
            if (!mounted) return;
            _readyTimeoutTimer?.cancel();
            setState(() {
              _isReady = true;
              _progress = 1.0;
            });
            unawaited(() async {
              final c = _controller;
              if (c != null) await c.runJavaScript(_unmuteVideosJs);
            }());
          },
          onWebResourceError: (error) {
            if (!mounted) return;
            if (error.isForMainFrame == true) {
              debugPrint(
                '[NaverBlogPlayerWidget] main-frame error: ${error.description}',
              );
              setState(() {
                _hasLoadError = true;
                _isReady = true;
              });
            }
          },
          onNavigationRequest: (request) {
            final reqUri = Uri.tryParse(request.url);
            if (reqUri == null) return NavigationDecision.navigate;

            if (request.url.startsWith('about:') ||
                request.url.startsWith('data:') ||
                request.url.startsWith('blob:')) {
              return NavigationDecision.navigate;
            }

            final host = reqUri.host.toLowerCase();
            // 네이버/카카오 자원 호스트는 인라인 허용 (이미지/스크립트/iframe 등)
            if (host.contains('naver.com') ||
                host.contains('naver.net') ||
                host.contains('pstatic.net') ||
                host.contains('blogfiles.pstatic.net') ||
                host.contains('phinf.pstatic.net')) {
              return NavigationDecision.navigate;
            }

            // 그 외 사용자 클릭으로 외부 도메인 이탈은 외부 앱으로 핸드오프
            _launchExternal(request.url);
            return NavigationDecision.prevent;
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));

    _readyTimeoutTimer?.cancel();
    _readyTimeoutTimer = Timer(_readyTimeout, () {
      if (!mounted) return;
      if (_isReady || _hasLoadError) return;
      debugPrint('[NaverBlogPlayerWidget] ready timeout — revealing WebView');
      setState(() => _isReady = true);
    });

    setState(() {
      _controller = controller;
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
            const Icon(Icons.open_in_new, color: Colors.white, size: 56),
            const SizedBox(height: 16),
            const Text(
              '웹 환경에서는 네이버 블로그에서 열립니다',
              style: TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => _launchExternal(widget.url),
              icon: const Icon(Icons.open_in_new),
              label: const Text('네이버 블로그에서 보기'),
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
    return Stack(
      alignment: Alignment.topCenter,
      children: [
        const Positioned.fill(child: ColoredBox(color: Colors.black)),
        if (controller != null)
          wrapPlatformViewReveal(
            revealed: _isReady && !_hasLoadError,
            // WebView 가 vertical drag 의 owner 가 되도록 EagerGestureRecognizer
            // 를 등록한다. 이게 없으면 부모 SingleChildScrollView 가 vertical
            // drag 를 가로채서 사용자가 블로그 본문 대신 디테일 화면이 스크롤되는
            // 현상이 발생한다.
            child: WebViewWidget(
              controller: controller,
              gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
                Factory<EagerGestureRecognizer>(
                  () => EagerGestureRecognizer(),
                ),
              },
            ),
          ),
        if (!_isReady) Positioned.fill(child: _buildPosterLoadingOverlay()),
        if (_hasLoadError) Positioned.fill(child: _buildLoadErrorOverlay()),
        if (_progress > 0 && _progress < 1.0 && !_hasLoadError)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(
              value: _progress,
              minHeight: 2,
              backgroundColor: Colors.transparent,
              valueColor: const AlwaysStoppedAnimation(AppColors.primary),
            ),
          ),
      ],
    );
  }

  Widget _buildPosterLoadingOverlay() {
    return InlineVideoHeroPoster(
      thumbnailUrl: widget.thumbnailUrl,
      backgroundColor: Colors.black,
      imageFit: BoxFit.contain,
    );
  }

  Widget _buildLoadErrorOverlay() {
    final thumb = widget.thumbnailUrl;
    return GestureDetector(
      onTap: () => _launchExternal(widget.url),
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
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.open_in_new, color: Colors.white, size: 22),
                    SizedBox(width: 8),
                    Text(
                      '네이버 블로그에서 보기',
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
