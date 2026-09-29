import 'dart:async';

import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../services/analytics_service.dart';
import 'app_network_image.dart';

/// 홈 상단 KREAM형 포스터 캐러셀.
/// 실측(크림 홈 스크린샷): 카드 ≈ 1.11:1, viewport ≈ 0.94, radius 16,
/// 좌우 peek + 우측 하단 `n / total >`.
///
/// 이미지 교체: [assets/images/home_poster_1.png] ~ [_3.png]
/// 포스터 카드 impression 중복 방지 — 앱 프로세스 동안 posterId 당 1회.
final Set<String> _homePosterImpressionFired = <String>{};

class HomePosterItem {
  const HomePosterItem({
    required this.assetPath,
    this.id,
    this.imageUrl,
    this.title,
    this.subtitle,
    this.onTap,
    /// 카드가 이미지보다 좁을 때 잘리는 기준. 오른쪽 피사체 보호용 기본값.
    this.imageAlignment = Alignment.centerRight,
  });

  final String? id;
  final String assetPath;
  final String? imageUrl;
  final String? title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Alignment imageAlignment;
}

class HomePosterCarousel extends StatefulWidget {
  const HomePosterCarousel({
    super.key,
    this.items = HomePosterCarousel.defaultItems,
  });

  /// 폴백용. 실제 홈에서는 [HomePosterCurations.carouselItems] 를 넘긴다.
  static const List<HomePosterItem> defaultItems = [
    HomePosterItem(
      id: 'poster_fallback_1',
      assetPath: 'assets/images/home_poster_1.png',
      title: '더위야,\n물러가라',
      subtitle: '더운 날 둘이 먹기 좋은 시원한 메뉴',
    ),
    HomePosterItem(
      id: 'poster_fallback_2',
      assetPath: 'assets/images/home_poster_2.png',
      title: '설탕은 빼고,\n맛은 그대로',
      subtitle: '마이노멀로 완성하는 저당 저녁',
    ),
    HomePosterItem(
      id: 'poster_fallback_3',
      assetPath: 'assets/images/home_poster_3.png',
      title: '서툴러도 괜찮아,\n오늘도 한 그릇 완성',
      subtitle: '요리가 처음인 우리를 위한 쉬운 저녁',
    ),
  ];

  final List<HomePosterItem> items;

  /// 크림 실측(437/394)보다 세로를 아주 조금 짧게
  static const double aspectRatio = 437 / 372;

  /// 크림 merchandising panel radius
  static const double radius = 16;

  /// 크림 홈 실측 peek (너무 넓게 튀어나오지 않게)
  static const double viewportFraction = 0.94;

  /// 카드 사이 간격
  static const double itemGap = 8;

  /// 탭 → 포스터
  static const double topGap = 12;

  /// 자동 넘김 간격
  static const Duration autoPlayInterval = Duration(seconds: 4);

  @override
  State<HomePosterCarousel> createState() => _HomePosterCarouselState();
}

class _HomePosterCarouselState extends State<HomePosterCarousel> {
  static const int _loopBase = 1000;

  late final PageController _controller;
  late final int _initialPage;
  Timer? _autoTimer;
  bool _userDragging = false;

  bool get _loop => widget.items.length > 1;

  @override
  void initState() {
    super.initState();
    final n = widget.items.length;
    _initialPage = _loop ? n * _loopBase : 0;
    _controller = PageController(
      viewportFraction: HomePosterCarousel.viewportFraction,
      initialPage: _initialPage,
    );
    _startAutoPlay();
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _startAutoPlay() {
    _autoTimer?.cancel();
    if (!_loop || !mounted) return;
    _autoTimer = Timer.periodic(
      HomePosterCarousel.autoPlayInterval,
      (_) => _goNext(),
    );
  }

  void _goNext() {
    if (!_loop || !mounted || _userDragging) return;
    if (!_controller.hasClients) return;
    final current = _controller.page?.round() ?? _initialPage;
    _controller.animateToPage(
      current + 1,
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
    );
  }

  int _realIndex(int page) {
    final n = widget.items.length;
    if (n == 0) return 0;
    return page % n;
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    if (items.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final pageWidth =
            constraints.maxWidth * HomePosterCarousel.viewportFraction;
        final cardWidth = pageWidth - HomePosterCarousel.itemGap;
        final height = cardWidth / HomePosterCarousel.aspectRatio;

        return SizedBox(
          height: height,
          child: Listener(
            onPointerDown: (_) {
              _userDragging = true;
              _autoTimer?.cancel();
            },
            onPointerUp: (_) {
              _userDragging = false;
              _startAutoPlay();
            },
            onPointerCancel: (_) {
              _userDragging = false;
              _startAutoPlay();
            },
            child: PageView.builder(
              controller: _controller,
              // 무한 루프: 1번에서 왼쪽 스와이프 → 3번
              itemCount: _loop ? null : items.length,
              physics: const BouncingScrollPhysics(),
              padEnds: true,
              onPageChanged: (_) {
                if (!_userDragging) _startAutoPlay();
              },
              itemBuilder: (context, i) {
                final real = _realIndex(i);
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HomePosterCarousel.itemGap / 2,
                  ),
                  child: _PosterCard(
                    item: items[real],
                    index: real,
                    total: items.length,
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _PosterCard extends StatelessWidget {
  const _PosterCard({
    required this.item,
    required this.index,
    required this.total,
  });

  final HomePosterItem item;
  final int index;
  final int total;

  bool get _hasTitle =>
      item.title != null && item.title!.trim().isNotEmpty;

  Widget _posterImage() {
    final url = item.imageUrl?.trim() ?? '';
    final fallback = Image.asset(
      item.assetPath,
      fit: BoxFit.cover,
      alignment: item.imageAlignment,
      filterQuality: FilterQuality.high,
      errorBuilder: (_, __, ___) => _PosterPlaceholder(index: index),
    );
    if (url.startsWith('http')) {
      return AppNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        errorWidget: fallback,
      );
    }
    return fallback;
  }

  @override
  Widget build(BuildContext context) {
    final Widget card = GestureDetector(
      onTap: item.onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(HomePosterCarousel.radius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _posterImage(),
            // 크림과 동일: 하단 가독용 그라데이션
            const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x00000000),
                      Color(0x00000000),
                      Color(0x66000000),
                      Color(0x99000000),
                    ],
                    stops: [0.0, 0.42, 0.72, 1.0],
                  ),
                ),
              ),
            ),
            if (_hasTitle)
              Positioned(
                left: 18,
                right: 88,
                bottom: 18,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.title!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: -0.5,
                        height: 1.28,
                      ),
                    ),
                    if (item.subtitle != null &&
                        item.subtitle!.trim().isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        item.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          color: Color(0xF2FFFFFF),
                          letterSpacing: -0.2,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            Positioned(
              right: 14,
              bottom: 14,
              child: _PageBadge(
                current: index + 1,
                total: total,
              ),
            ),
          ],
        ),
      ),
    );
    final posterId = item.id?.trim() ?? '';
    if (posterId.isEmpty) return card;
    return VisibilityDetector(
      key: Key('home_poster_impression_$posterId'),
      onVisibilityChanged: (info) {
        if (info.visibleFraction < 0.5) return;
        if (!_homePosterImpressionFired.add(posterId)) return;
        unawaited(
          AnalyticsService().trackHomePosterEvent(
            eventType: 'impression',
            posterId: posterId,
            posterTitle: item.title,
            position: index,
          ),
        );
      },
      child: card,
    );
  }
}

class _PageBadge extends StatelessWidget {
  const _PageBadge({required this.current, required this.total});

  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 22,
      padding: const EdgeInsets.fromLTRB(8, 0, 6, 0),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0x66000000),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$current / $total',
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.white,
              letterSpacing: -0.2,
              height: 1.0,
            ),
          ),
          const SizedBox(width: 2),
          const Icon(
            Icons.arrow_forward_ios,
            size: 8,
            color: Colors.white,
          ),
        ],
      ),
    );
  }
}

class _PosterPlaceholder extends StatelessWidget {
  const _PosterPlaceholder({required this.index});

  final int index;

  static const _gradients = [
    [Color(0xFF2A2A2A), Color(0xFF111111)],
    [Color(0xFF3A2F2A), Color(0xFF1A1410)],
    [Color(0xFF2A3038), Color(0xFF101418)],
  ];

  @override
  Widget build(BuildContext context) {
    final colors = _gradients[index % _gradients.length];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
      child: const SizedBox.expand(),
    );
  }
}
