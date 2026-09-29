import 'package:flutter/material.dart';

/// First-load skeleton for the community feed. Matches post layout:
/// avatar header, 1:1 photo, overlapping recipe card, actions, caption.
class CommunityFeedShimmer extends StatelessWidget {
  const CommunityFeedShimmer({
    super.key,
    this.cardCount = 2,
    this.includeFollowingRail = false,
  });

  final int cardCount;
  final bool includeFollowingRail;

  @override
  Widget build(BuildContext context) {
    return _ShimmerScope(
      linearGradient: _shimmerGradient,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (includeFollowingRail) const _FollowingRailSkeleton(),
          for (var i = 0; i < cardCount; i++) ...[
            if (i > 0) const SizedBox(height: 20),
            const _ShimmerLoading(
              isLoading: true,
              child: _FeedPostSkeleton(),
            ),
          ],
        ],
      ),
    );
  }
}

/// First-load skeleton for a board post detail: author, title, body, actions.
class BoardPostDetailShimmer extends StatelessWidget {
  const BoardPostDetailShimmer({super.key});

  @override
  Widget build(BuildContext context) {
    return _ShimmerScope(
      linearGradient: _shimmerGradient,
      child: const _ShimmerLoading(
        isLoading: true,
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Bone(width: 44, height: 22, radius: 99),
              SizedBox(height: 16),
              Row(
                children: [
                  _Bone.circle(40),
                  SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Bone(width: 88, height: 13, radius: 4),
                        SizedBox(height: 6),
                        _Bone(width: 52, height: 10, radius: 4),
                      ],
                    ),
                  ),
                ],
              ),
              SizedBox(height: 18),
              _Bone(width: 220, height: 20, radius: 5),
              SizedBox(height: 12),
              _Bone(width: double.infinity, height: 13, radius: 4),
              SizedBox(height: 8),
              _Bone(width: 260, height: 13, radius: 4),
              SizedBox(height: 24),
              Row(
                children: [
                  _Bone(width: 36, height: 16, radius: 4),
                  SizedBox(width: 18),
                  _Bone(width: 36, height: 16, radius: 4),
                  SizedBox(width: 18),
                  _Bone(width: 18, height: 16, radius: 4),
                  Spacer(),
                  _Bone(width: 52, height: 12, radius: 4),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class BoardCommentListShimmer extends StatelessWidget {
  const BoardCommentListShimmer({super.key, this.rowCount = 3});

  final int rowCount;

  @override
  Widget build(BuildContext context) {
    return _ShimmerScope(
      linearGradient: _shimmerGradient,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: Column(
          children: [
            for (var i = 0; i < rowCount; i++) ...[
              if (i > 0) const SizedBox(height: 18),
              const _ShimmerLoading(
                isLoading: true,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Bone.circle(34),
                    SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Bone(width: 72, height: 12, radius: 4),
                          SizedBox(height: 6),
                          _Bone(width: 44, height: 10, radius: 4),
                          SizedBox(height: 8),
                          _Bone(width: double.infinity, height: 12, radius: 4),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 프로필 활동 기록 탭 스켈레톤. 레벨·출석·통계 카드 배치와 맞춘다.
class ProfileActivityShimmer extends StatelessWidget {
  const ProfileActivityShimmer({super.key});

  @override
  Widget build(BuildContext context) {
    return _ShimmerScope(
      linearGradient: _shimmerGradient,
      child: const _ShimmerLoading(
        isLoading: true,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              _ActivityCardBone(
                child: Column(
                  children: [
                    Row(
                      children: [
                        _Bone(width: 108, height: 16, radius: 4),
                        Spacer(),
                        _Bone(width: 56, height: 18, radius: 99),
                      ],
                    ),
                    SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(child: _Bone(height: 10, radius: 99)),
                        SizedBox(width: 12),
                        _Bone(width: 76, height: 11, radius: 4),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(height: 12),
              _ActivityCardBone(
                child: Column(
                  children: [
                    Row(
                      children: [
                        _Bone(width: 68, height: 15, radius: 4),
                        SizedBox(width: 6),
                        _Bone(width: 28, height: 22, radius: 5),
                        Spacer(),
                        _Bone(width: 16, height: 16, radius: 4),
                      ],
                    ),
                    SizedBox(height: 18),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _Bone.circle(28),
                        _Bone.circle(28),
                        _Bone.circle(28),
                        _Bone.circle(28),
                        _Bone.circle(28),
                        _Bone.circle(28),
                        _Bone.circle(28),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: _StatCardBone()),
                  SizedBox(width: 12),
                  Expanded(child: _StatCardBone()),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 프로필 요리 일기 캘린더 스켈레톤.
class ProfileDiaryShimmer extends StatelessWidget {
  const ProfileDiaryShimmer({super.key});

  @override
  Widget build(BuildContext context) {
    return _ShimmerScope(
      linearGradient: _shimmerGradient,
      child: const _ShimmerLoading(
        isLoading: true,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(child: _Bone(height: 10, radius: 4)),
                  SizedBox(width: 10),
                  Expanded(child: _Bone(height: 10, radius: 4)),
                  SizedBox(width: 10),
                  Expanded(child: _Bone(height: 10, radius: 4)),
                  SizedBox(width: 10),
                  Expanded(child: _Bone(height: 10, radius: 4)),
                  SizedBox(width: 10),
                  Expanded(child: _Bone(height: 10, radius: 4)),
                  SizedBox(width: 10),
                  Expanded(child: _Bone(height: 10, radius: 4)),
                  SizedBox(width: 10),
                  Expanded(child: _Bone(height: 10, radius: 4)),
                ],
              ),
              SizedBox(height: 12),
              _DiaryWeekBone(),
              SizedBox(height: 6),
              _DiaryWeekBone(),
              SizedBox(height: 6),
              _DiaryWeekBone(),
              SizedBox(height: 6),
              _DiaryWeekBone(),
              SizedBox(height: 6),
              _DiaryWeekBone(),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActivityCardBone extends StatelessWidget {
  const _ActivityCardBone({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFF3F4F6)),
      ),
      child: child,
    );
  }
}

class _StatCardBone extends StatelessWidget {
  const _StatCardBone();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 18, 20, 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFF3F4F6)),
      ),
      child: const Row(
        children: [
          _Bone.circle(36),
          SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Bone(width: 56, height: 10, radius: 4),
              SizedBox(height: 8),
              _Bone(width: 36, height: 16, radius: 4),
            ],
          ),
        ],
      ),
    );
  }
}

class _DiaryCellBone extends StatelessWidget {
  const _DiaryCellBone();

  @override
  Widget build(BuildContext context) {
    return const AspectRatio(
      aspectRatio: 1,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _bone,
          borderRadius: BorderRadius.all(Radius.circular(10)),
        ),
      ),
    );
  }
}

class _DiaryWeekBone extends StatelessWidget {
  const _DiaryWeekBone();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Expanded(child: _DiaryCellBone()),
        SizedBox(width: 6),
        Expanded(child: _DiaryCellBone()),
        SizedBox(width: 6),
        Expanded(child: _DiaryCellBone()),
        SizedBox(width: 6),
        Expanded(child: _DiaryCellBone()),
        SizedBox(width: 6),
        Expanded(child: _DiaryCellBone()),
        SizedBox(width: 6),
        Expanded(child: _DiaryCellBone()),
        SizedBox(width: 6),
        Expanded(child: _DiaryCellBone()),
      ],
    );
  }
}

/// First-load skeleton for the ranking tab. Matches a ranking row:
/// rank, avatar, name + level chip, subtitle, score.
class CommunityLeaderboardShimmer extends StatelessWidget {
  const CommunityLeaderboardShimmer({super.key, this.rowCount = 8});

  final int rowCount;

  @override
  Widget build(BuildContext context) {
    return _ShimmerScope(
      linearGradient: _shimmerGradient,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        child: Column(
          children: [
            for (var i = 0; i < rowCount; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              const _ShimmerLoading(
                isLoading: true,
                child: _LeaderboardRowSkeleton(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LeaderboardRowSkeleton extends StatelessWidget {
  const _LeaderboardRowSkeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFF3F4F6)),
      ),
      child: const Row(
        children: [
          _Bone(width: 18, height: 14, radius: 4),
          SizedBox(width: 10),
          _Bone.circle(40),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _Bone(width: 72, height: 13, radius: 4),
                    SizedBox(width: 6),
                    _Bone(width: 36, height: 16, radius: 99),
                  ],
                ),
                SizedBox(height: 6),
                _Bone(width: 112, height: 10, radius: 4),
              ],
            ),
          ),
          SizedBox(width: 8),
          _Bone(width: 22, height: 13, radius: 4),
        ],
      ),
    );
  }
}

class _FollowingRailSkeleton extends StatelessWidget {
  const _FollowingRailSkeleton();

  @override
  Widget build(BuildContext context) {
    return const _ShimmerLoading(
      isLoading: true,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 10, 16, 18),
        child: Row(
          children: [
            _Bone.circle(54),
            SizedBox(width: 14),
            _Bone.circle(54),
            SizedBox(width: 14),
            _Bone.circle(54),
            SizedBox(width: 14),
            _Bone.circle(54),
          ],
        ),
      ),
    );
  }
}

class _FeedPostSkeleton extends StatelessWidget {
  const _FeedPostSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              _Bone.circle(34),
              SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _Bone(width: 78, height: 11, radius: 4),
                        SizedBox(width: 6),
                        _Bone(width: 32, height: 14, radius: 99),
                      ],
                    ),
                    SizedBox(height: 6),
                    _Bone(width: 42, height: 8, radius: 4),
                  ],
                ),
              ),
              _Bone(width: 18, height: 4, radius: 99),
            ],
          ),
        ),
        const AspectRatio(
          aspectRatio: 1,
          child: ColoredBox(color: _bone),
        ),
        Transform.translate(
          offset: const Offset(0, -18),
          child: const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: _RecipeCardBone(),
          ),
        ),
        Transform.translate(
          offset: const Offset(0, -6),
          child: const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _Bone.circle(22),
                    SizedBox(width: 8),
                    _Bone(width: 18, height: 10, radius: 4),
                    SizedBox(width: 14),
                    _Bone.circle(20),
                    SizedBox(width: 8),
                    _Bone(width: 16, height: 10, radius: 4),
                    Spacer(),
                    _Bone(width: 18, height: 18, radius: 4),
                  ],
                ),
                SizedBox(height: 10),
                _Bone(width: double.infinity, height: 11, radius: 4),
                SizedBox(height: 6),
                _Bone(width: 168, height: 11, radius: 4),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _RecipeCardBone extends StatelessWidget {
  const _RecipeCardBone();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F5F7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFECEEF1)),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _Bone(height: 12, radius: 4)),
              SizedBox(width: 24),
              _Bone(width: 16, height: 16, radius: 4),
            ],
          ),
          SizedBox(height: 10),
          Row(
            children: [
              _Bone(width: 52, height: 18, radius: 99),
              SizedBox(width: 6),
              _Bone(width: 44, height: 18, radius: 99),
              SizedBox(width: 6),
              _Bone(width: 48, height: 18, radius: 99),
            ],
          ),
        ],
      ),
    );
  }
}

class _Bone extends StatelessWidget {
  const _Bone({
    this.width,
    required this.height,
    this.radius = 6,
  });

  const _Bone.circle(double size)
      : width = size,
        height = size,
        radius = 99;

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: _bone,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

const _bone = Color(0xFFEBECF0);

const _shimmerGradient = LinearGradient(
  colors: [
    Color(0xFFFFFFFF),
    Color(0xFFFFFFFF),
    Color(0xFFF6F2FF),
    Color(0xFFF2F6FF),
    Color(0xFFFFFFFF),
    Color(0xFFFFFFFF),
  ],
  stops: [0.0, 0.44, 0.48, 0.52, 0.56, 1.0],
  begin: Alignment(-1.0, -1.0),
  end: Alignment(1.0, 1.0),
  tileMode: TileMode.clamp,
);

class _SlidingDiagonalGradientTransform extends GradientTransform {
  const _SlidingDiagonalGradientTransform({required this.slidePercent});
  final double slidePercent;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(
      bounds.width * slidePercent,
      bounds.height * slidePercent,
      0.0,
    );
  }
}

class _ShimmerScope extends StatefulWidget {
  const _ShimmerScope({required this.linearGradient, required this.child});

  static _ShimmerScopeState? of(BuildContext context) =>
      context.findAncestorStateOfType<_ShimmerScopeState>();

  final LinearGradient linearGradient;
  final Widget child;

  @override
  State<_ShimmerScope> createState() => _ShimmerScopeState();
}

class _ShimmerScopeState extends State<_ShimmerScope>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController.unbounded(vsync: this)
      ..repeat(min: -0.5, max: 1.5, period: const Duration(milliseconds: 1400));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  LinearGradient get gradient => LinearGradient(
        colors: widget.linearGradient.colors,
        stops: widget.linearGradient.stops,
        begin: widget.linearGradient.begin,
        end: widget.linearGradient.end,
        transform: _SlidingDiagonalGradientTransform(
          slidePercent: _controller.value,
        ),
      );

  bool get isSized =>
      (context.findRenderObject() as RenderBox?)?.hasSize ?? false;

  Size get size => (context.findRenderObject() as RenderBox).size;

  Listenable get shimmerChanges => _controller;

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ShimmerLoading extends StatefulWidget {
  const _ShimmerLoading({required this.isLoading, required this.child});

  final bool isLoading;
  final Widget child;

  @override
  State<_ShimmerLoading> createState() => _ShimmerLoadingState();
}

class _ShimmerLoadingState extends State<_ShimmerLoading> {
  Listenable? _shimmerChanges;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _shimmerChanges?.removeListener(_onShimmerChange);
    _shimmerChanges = _ShimmerScope.of(context)?.shimmerChanges;
    _shimmerChanges?.addListener(_onShimmerChange);
  }

  @override
  void dispose() {
    _shimmerChanges?.removeListener(_onShimmerChange);
    super.dispose();
  }

  void _onShimmerChange() {
    if (widget.isLoading) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isLoading) return widget.child;
    final shimmer = _ShimmerScope.of(context);
    if (shimmer == null || !shimmer.isSized) {
      return widget.child;
    }
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return widget.child;
    final bounds = Rect.fromLTWH(0, 0, ro.size.width, ro.size.height);
    return ShaderMask(
      blendMode: BlendMode.srcATop,
      shaderCallback: (_) => shimmer.gradient.createShader(bounds),
      child: widget.child,
    );
  }
}
