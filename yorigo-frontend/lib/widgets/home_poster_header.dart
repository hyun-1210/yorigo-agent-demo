import 'dart:async';

import 'package:flutter/material.dart';

import '../constants/home_poster_curations.dart';
import '../services/home_cms_service.dart';
import 'home_feed_tabs.dart';
import 'home_poster_carousel.dart';

/// 홈 상단: 커뮤니티형 탭 + 포스터 캐러셀.
class HomePosterHeader extends StatefulWidget {
  const HomePosterHeader({
    super.key,
    required this.selectedTabIndex,
    required this.onTabSelected,
  });

  final int selectedTabIndex;
  final ValueChanged<int> onTabSelected;

  @override
  State<HomePosterHeader> createState() => _HomePosterHeaderState();
}

class _HomePosterHeaderState extends State<HomePosterHeader> {
  @override
  void initState() {
    super.initState();
    unawaited(_loadCms());
  }

  Future<void> _loadCms() async {
    await HomeCmsService.instance.ensureLoaded();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final showPoster = widget.selectedTabIndex == 0;
    final curations = HomeCmsService.instance.postersOrFallback;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        HomeFeedTabs(
          tabs: HomeFeedTabs.defaultTabs,
          selectedIndex: widget.selectedTabIndex,
          onSelected: widget.onTabSelected,
        ),
        if (showPoster) ...[
          const SizedBox(height: HomePosterCarousel.topGap),
          HomePosterCarousel(
            items: HomePosterCurations.carouselItemsFor(
              context,
              curations,
              cmsUpdatedAt: HomeCmsService.instance.analyticsUpdatedAt,
            ),
          ),
        ],
      ],
    );
  }
}
