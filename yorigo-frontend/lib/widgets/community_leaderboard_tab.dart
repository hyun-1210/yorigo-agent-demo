import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/community_leaderboard_service.dart';
import '../services/user_service.dart';
import 'app_network_image.dart';
import 'app_refresh_indicator.dart';
import 'community_feed_shimmer.dart';
import 'user_initial_avatar.dart';

class CommunityLeaderboardTab extends StatefulWidget {
  const CommunityLeaderboardTab({
    super.key,
    required this.topBar,
    required this.onProfileTap,
    this.scrollController,
  });

  final Widget topBar;
  final ValueChanged<String> onProfileTap;
  final ScrollController? scrollController;

  @override
  State<CommunityLeaderboardTab> createState() =>
      _CommunityLeaderboardTabState();
}

class _CommunityLeaderboardTabState extends State<CommunityLeaderboardTab> {
  final _service = CommunityLeaderboardService();
  final _userService = UserService();
  LeaderboardMetric _metric = LeaderboardMetric.reviews;
  LeaderboardPeriod _period = LeaderboardPeriod.days30;
  bool _followingOnly = false;
  Set<String>? _followingIds;
  Future<List<LeaderboardEntry>>? _future;

  @override
  void initState() {
    super.initState();
    _future = _service.fetch(metric: _metric, period: _period);
  }

  Future<Set<String>> _circleIds() async {
    if (_followingIds != null) return _followingIds!;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      _followingIds = <String>{};
      return _followingIds!;
    }
    final ids = await _userService.getFollowingIds(uid, limit: 200);
    _followingIds = {...ids, uid};
    return _followingIds!;
  }

  Future<void> _reload({bool forceRefresh = false}) async {
    Set<String>? only;
    if (_followingOnly) {
      only = await _circleIds();
    }
    final next = _service.fetch(
      metric: _metric,
      period: _period,
      onlyUserIds: only,
      forceRefresh: forceRefresh,
    );
    setState(() => _future = next);
    await next;
  }

  void _setMetric(LeaderboardMetric metric) {
    if (_metric == metric) return;
    setState(() => _metric = metric);
    _reload();
  }

  void _setFollowingOnly(bool value) {
    if (_followingOnly == value) return;
    setState(() => _followingOnly = value);
    _reload();
  }

  Future<void> _onPeriodSelected(LeaderboardPeriod period) async {
    if (period == _period) return;
    setState(() => _period = period);
    await _reload();
  }

  String get _metricLabel =>
      _metric == LeaderboardMetric.likes ? '좋아요' : '요리 기록';

  String get _metricHint {
    final who = _followingOnly ? '내가 팔로우한 사람' : '모든 사용자';
    return _metric == LeaderboardMetric.likes
        ? '$who의 요리 기록이 받은 좋아요 수'
        : '$who가 남긴 요리 기록 수';
  }

  @override
  Widget build(BuildContext context) {
    return AppRefreshIndicator(
      onRefresh: () => _reload(forceRefresh: true),
      child: FutureBuilder<List<LeaderboardEntry>>(
        future: _future,
        builder: (context, snap) {
          final loading =
              snap.connectionState == ConnectionState.waiting && !snap.hasData;
          final rows = snap.data ?? const <LeaderboardEntry>[];

          return ListView(
            controller: widget.scrollController,
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              widget.topBar,
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 16, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _MetricTab(
                      label: '전체',
                      selected: !_followingOnly,
                      onTap: () => _setFollowingOnly(false),
                    ),
                    const SizedBox(width: 16),
                    _MetricTab(
                      label: '팔로잉',
                      selected: _followingOnly,
                      onTap: () => _setFollowingOnly(true),
                    ),
                    const Spacer(),
                    PopupMenuButton<LeaderboardPeriod>(
                      tooltip: '',
                      padding: EdgeInsets.zero,
                      offset: const Offset(0, 32),
                      color: Colors.white,
                      surfaceTintColor: Colors.transparent,
                      shadowColor: const Color(0x1A000000),
                      elevation: 8,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: const BorderSide(color: Color(0xFFF3F4F6)),
                      ),
                      onSelected: _onPeriodSelected,
                      itemBuilder: (context) => [
                        for (final period in LeaderboardPeriod.values)
                          PopupMenuItem<LeaderboardPeriod>(
                            value: period,
                            height: 40,
                            child: Text(
                              period.label,
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 13.5,
                                fontWeight: period == _period
                                    ? FontWeight.w800
                                    : FontWeight.w600,
                                color: period == _period
                                    ? const Color(0xFFFF6B00)
                                    : const Color(0xFF111111),
                              ),
                            ),
                          ),
                      ],
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(8, 5, 6, 5),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF3F4F6),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _period.label,
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF6B7280),
                                letterSpacing: -0.2,
                              ),
                            ),
                            const Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 16,
                              color: Color(0xFF9CA3AF),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: _ScopeSegment(
                  leftLabel: '요리 기록',
                  rightLabel: '좋아요',
                  rightSelected: _metric == LeaderboardMetric.likes,
                  onLeft: () => _setMetric(LeaderboardMetric.reviews),
                  onRight: () => _setMetric(LeaderboardMetric.likes),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Text(
                  _metricHint,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF9CA3AF),
                    letterSpacing: -0.15,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 6),
                child: Row(
                  children: [
                    const Text(
                      '순위',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF9CA3AF),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _metricLabel,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF9CA3AF),
                      ),
                    ),
                  ],
                ),
              ),
              if (loading)
                const CommunityLeaderboardShimmer()
              else if (snap.hasError)
                const Padding(
                  padding: EdgeInsets.fromLTRB(24, 40, 24, 0),
                  child: Center(
                    child: Text(
                      '순위를 불러오지 못했어요',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 14,
                        color: Color(0xFF9CA3AF),
                      ),
                    ),
                  ),
                )
              else if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 40, 24, 0),
                  child: Center(
                    child: Text(
                      _followingOnly
                          ? (FirebaseAuth.instance.currentUser == null
                              ? '로그인하면 팔로잉한 사람 순위를 볼 수 있어요'
                              : '팔로잉한 사람의 기록이 아직 없어요')
                          : '아직 순위 데이터가 없어요',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 14,
                        color: Color(0xFF9CA3AF),
                      ),
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: Column(
                    children: [
                      for (final row in rows) ...[
                        _LeaderboardCard(
                          entry: row,
                          onTap: () => widget.onProfileTap(row.userId),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _MetricTab extends StatelessWidget {
  const _MetricTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 16,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              color: selected
                  ? const Color(0xFF111111)
                  : const Color(0xFF9CA3AF),
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 5),
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            height: 2,
            width: selected ? 18 : 0,
            decoration: BoxDecoration(
              color: const Color(0xFFFF6B00),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScopeSegment extends StatelessWidget {
  const _ScopeSegment({
    required this.leftLabel,
    required this.rightLabel,
    required this.rightSelected,
    required this.onLeft,
    required this.onRight,
  });

  final String leftLabel;
  final String rightLabel;
  final bool rightSelected;
  final VoidCallback onLeft;
  final VoidCallback onRight;

  static const _slideDuration = Duration(milliseconds: 380);
  static const _slideCurve = Curves.easeInOutCubicEmphasized;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFF4F5F7),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Stack(
          children: [
            Positioned.fill(
              child: AnimatedAlign(
                duration: _slideDuration,
                curve: _slideCurve,
                alignment: rightSelected
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: const FractionallySizedBox(
                  widthFactor: 0.5,
                  heightFactor: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.all(Radius.circular(999)),
                      boxShadow: [
                        BoxShadow(
                          color: Color(0x0F000000),
                          blurRadius: 4,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: _ScopeChip(
                    label: leftLabel,
                    selected: !rightSelected,
                    onTap: onLeft,
                  ),
                ),
                Expanded(
                  child: _ScopeChip(
                    label: rightLabel,
                    selected: rightSelected,
                    onTap: onRight,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ScopeChip extends StatelessWidget {
  const _ScopeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected
                ? const Color(0xFF111111)
                : const Color(0xFF9CA3AF),
            letterSpacing: -0.25,
            height: 1.2,
          ),
          child: Text(label, textAlign: TextAlign.center),
        ),
      ),
    );
  }
}

class _LeaderboardCard extends StatelessWidget {
  const _LeaderboardCard({
    required this.entry,
    required this.onTap,
  });

  final LeaderboardEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 10,
            offset: Offset(0, 3),
            spreadRadius: -2,
          ),
        ],
      ),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFF3F4F6)),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  child: Text(
                    '${entry.rank}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF111111),
                      height: 1,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _Avatar(
                  userId: entry.userId,
                  name: entry.name,
                  photoUrl: entry.photoUrl,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              entry.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF111111),
                                letterSpacing: -0.25,
                                height: 1.2,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF3F4F6),
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: Text(
                              'Lv.${entry.level}',
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF6B7280),
                                height: 1.1,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (entry.dishes.isNotEmpty ||
                          entry.handle.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              entry.dishes.isNotEmpty
                                  ? Icons.restaurant_outlined
                                  : Icons.alternate_email_rounded,
                              size: 12,
                              color: const Color(0xFF9CA3AF),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                entry.dishes.isNotEmpty
                                    ? entry.dishes.join(', ')
                                    : entry.handle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF9CA3AF),
                                  letterSpacing: -0.15,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${entry.score}',
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF6B7280),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.userId,
    required this.name,
    required this.photoUrl,
  });

  final String userId;
  final String name;
  final String photoUrl;

  @override
  Widget build(BuildContext context) {
    if (photoUrl.isNotEmpty) {
      return ClipOval(
        child: AppNetworkImage(
          imageUrl: photoUrl,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          memCacheWidth: 80,
          memCacheHeight: 80,
          placeholder: UserInitialAvatar(seed: userId, name: name, size: 40),
          errorWidget: UserInitialAvatar(seed: userId, name: name, size: 40),
        ),
      );
    }
    return UserInitialAvatar(seed: userId, name: name, size: 40);
  }
}
