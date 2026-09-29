import 'package:flutter/material.dart';
import '../services/recipe_service.dart';
import '../utils/recipe_thumbnail_resolver.dart';
import 'app_media_query_merge_nav_insets.dart';
import 'app_network_image.dart';

class PickRecipeForReviewResult {
  const PickRecipeForReviewResult({
    required this.recipeId,
    required this.cookedAt,
  });

  final String recipeId;
  final DateTime cookedAt;
}

/// Bottom sheet: pick a saved recipe to attach a diary / review entry.
/// Pops with recipe id + cooked date, or null if dismissed without selection.
class PickRecipeForReviewSheet extends StatefulWidget {
  const PickRecipeForReviewSheet({super.key});
  static const directReviewId = '__direct_review__';

  static Future<PickRecipeForReviewResult?> show(BuildContext context) {
    return showModalBottomSheet<PickRecipeForReviewResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: false,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const PickRecipeForReviewSheet(),
    );
  }

  @override
  State<PickRecipeForReviewSheet> createState() =>
      _PickRecipeForReviewSheetState();
}

class _PickRecipeForReviewSheetState extends State<PickRecipeForReviewSheet> {
  late final Future<List<Map<String, dynamic>>> _recipesFuture;

  bool _isReadyRecipeBookItem(Map<String, dynamic> recipe) {
    final id = (recipe['id'] as String? ?? '').trim();
    if (id.isEmpty || id.startsWith('opt_')) return false;

    final status = (recipe['status'] as String? ?? 'completed').toLowerCase();
    if (status == 'parsing' || status == 'error' || status == 'cancelled') {
      return false;
    }

    final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? {};
    final title = ((recipe['title'] as String?) ??
            (recipeData['title'] as String?) ??
            (recipeData['name'] as String?) ??
            '')
        .trim();
    if (title.isEmpty || title == '분석 중..' || title.startsWith('분석 중')) {
      return false;
    }
    return true;
  }

  void _popWith(String recipeId) {
    final now = DateTime.now();
    Navigator.pop(
      context,
      PickRecipeForReviewResult(
        recipeId: recipeId,
        cookedAt: DateTime(now.year, now.month, now.day),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _recipesFuture = RecipeService.shared
        .getSavedRecipesForExplore(limit: 100)
        .timeout(
          const Duration(seconds: 8),
          onTimeout: () => const <Map<String, dynamic>>[],
        );
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.sizeOf(context).height * 0.88;
    final bottomInset = appSystemNavBottomInset(context);

    return AppMediaQueryMergeNavInsets(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Material(
          color: Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE5E7EB),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '요리 기록 남기기',
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF111111),
                                letterSpacing: -0.4,
                                height: 1.2,
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: () => Navigator.pop(context),
                            behavior: HitTestBehavior.opaque,
                            child: const SizedBox(
                              width: 28,
                              height: 28,
                              child: Icon(
                                Icons.close_rounded,
                                size: 20,
                                color: Color(0xFF9CA3AF),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const SizedBox(
                        width: double.infinity,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '원하는 날짜·사진·멘트로 나만의 요리 다이어리를 꾸며보세요',
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF6B7280),
                              height: 1.3,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 22),
                child: _DirectReviewCard(
                  onTap: () => _popWith(
                    PickRecipeForReviewSheet.directReviewId,
                  ),
                ),
              ),
              Expanded(
                child: FutureBuilder<List<Map<String, dynamic>>>(
                  future: _recipesFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting &&
                        !snapshot.hasData) {
                      return const _RecipeListLoadingState();
                    }
                    final all = snapshot.data ?? [];
                    final ready = all.where(_isReadyRecipeBookItem).toList();

                    if (ready.isEmpty) {
                      return Padding(
                        padding: EdgeInsets.fromLTRB(
                          24,
                          8,
                          24,
                          32 + bottomInset,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              all.isEmpty ? '저장한 레시피가 없어요' : '분석이 끝난 레시피가 없어요',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF374151),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              all.isEmpty
                                  ? '저장한 레시피 없이도 위에서 바로 기록할 수 있어요'
                                  : '레시피 분석이 완료되면 여기에서 선택할 수 있어요',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: Color(0xFF9CA3AF),
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ColoredBox(
                          color: Colors.white,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
                            child: Row(
                              children: [
                                const Text(
                                  '저장한 레시피에서 고르기',
                                  style: TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF6B7280),
                                    letterSpacing: -0.2,
                                  ),
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  '${ready.length}',
                                  style: const TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFFFF6B00),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Expanded(
                          child: ClipRect(
                            child: ListView.separated(
                            padding: EdgeInsets.fromLTRB(
                              16,
                              8,
                              16,
                              24 + bottomInset,
                            ),
                            itemCount: ready.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final recipe = ready[index];
                              final id = recipe['id'] as String? ?? '';
                              final recipeData =
                                  recipe['recipe'] as Map<String, dynamic>? ??
                                  {};
                              final title =
                                  recipe['title'] as String? ??
                                  recipeData['title'] as String? ??
                                  recipeData['name'] as String? ??
                                  '레시피';
                              final thumb = RecipeThumbnailResolver.resolve(
                                recipe,
                              );

                              return _RecipeRow(
                                title: title,
                                thumb: thumb,
                                onTap: id.isEmpty
                                    ? null
                                    : () => _popWith(id),
                              );
                            },
                          ),
                          ),
                        ),
                      ],
                    );
                  },
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

const _kCardRadius = 16.0;

class _DirectReviewCard extends StatelessWidget {
  const _DirectReviewCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_kCardRadius),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 6,
            offset: Offset(0, 1),
          ),
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 18,
            offset: Offset(0, 4),
            spreadRadius: -2,
          ),
        ],
      ),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_kCardRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(_kCardRadius),
              border: Border.all(color: const Color(0xFFF3F4F6)),
            ),
            padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
            child: const Row(
              children: [
                _DirectReviewIcon(),
                SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '요리 바로 기록하기',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF111111),
                          height: 1.25,
                          letterSpacing: -0.3,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        '레시피 없이 직접 만든 요리를 기록해요',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF6B7280),
                          height: 1.35,
                        ),
                      ),
                    ],
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

class _DirectReviewIcon extends StatelessWidget {
  const _DirectReviewIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFFF850F),
            Color(0xFFFF6400),
          ],
        ),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFF6B00).withValues(alpha: 0.22),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: const Icon(
        Icons.add_a_photo_rounded,
        color: Colors.white,
        size: 21,
      ),
    );
  }
}

class _RecipeRow extends StatelessWidget {
  const _RecipeRow({
    required this.title,
    required this.thumb,
    required this.onTap,
  });

  final String title;
  final String thumb;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    const radius = 14.0;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 10,
            offset: Offset(0, 3),
            spreadRadius: -2,
          ),
        ],
      ),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(radius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: const Color(0xFFF3F4F6)),
            ),
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: thumb.isNotEmpty
                        ? AppNetworkImage(
                            imageUrl: thumb,
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                            memCacheWidth: 80,
                            memCacheHeight: 80,
                            placeholder: const _ThumbFallback(),
                            errorWidget: const _ThumbFallback(),
                          )
                        : const _ThumbFallback(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF111111),
                      height: 1.2,
                      letterSpacing: -0.25,
                    ),
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: Color(0xFFD1D5DB),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ThumbFallback extends StatelessWidget {
  const _ThumbFallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF7F8FA), Color(0xFFEEF0F3)],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.restaurant_outlined,
          color: const Color(0xFFC7C7CC),
          size: 18,
        ),
      ),
    );
  }
}

class _RecipeListLoadingState extends StatelessWidget {
  const _RecipeListLoadingState();

  @override
  Widget build(BuildContext context) {
    return _ShimmerScope(
      linearGradient: _shimmerGradient,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Matches the loaded "저장한 레시피에서 고르기" header position/height
          // so skeleton cards land exactly where real cards will appear.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
            child: _ShimmerLoading(
              isLoading: true,
              child: Container(
                width: 140,
                height: 13,
                decoration: BoxDecoration(
                  color: _shimmerSkeletonColor,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: EdgeInsets.fromLTRB(
                16,
                2,
                16,
                24 + appSystemNavBottomInset(context),
              ),
              itemCount: 6,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                return const _ShimmerLoading(
                  isLoading: true,
                  child: _RecipeSkeletonCard(),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _RecipeSkeletonCard extends StatelessWidget {
  const _RecipeSkeletonCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFF3F4F6)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _shimmerSkeletonColor,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 132,
                height: 11,
                decoration: BoxDecoration(
                  color: _shimmerSkeletonColor,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// --- Shimmer: same sliding diagonal style used in cart/home loaders ---
const _shimmerSkeletonColor = Color(0xFFEBECF0);

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
  static _ShimmerScopeState? of(BuildContext context) =>
      context.findAncestorStateOfType<_ShimmerScopeState>();
  const _ShimmerScope({required this.linearGradient, this.child});
  final LinearGradient linearGradient;
  final Widget? child;
  @override
  _ShimmerScopeState createState() => _ShimmerScopeState();
}

class _ShimmerScopeState extends State<_ShimmerScope>
    with SingleTickerProviderStateMixin {
  late AnimationController _shimmerController;
  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController.unbounded(vsync: this)
      ..repeat(min: -0.5, max: 1.5, period: const Duration(milliseconds: 1400));
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  LinearGradient get gradient => LinearGradient(
    colors: widget.linearGradient.colors,
    stops: widget.linearGradient.stops,
    begin: widget.linearGradient.begin,
    end: widget.linearGradient.end,
    transform: _SlidingDiagonalGradientTransform(
      slidePercent: _shimmerController.value,
    ),
  );
  bool get isSized =>
      (context.findRenderObject() as RenderBox?)?.hasSize ?? false;

  Listenable get shimmerChanges => _shimmerController;
  @override
  Widget build(BuildContext context) =>
      widget.child ?? const SizedBox.shrink();
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
    if (widget.isLoading && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isLoading) return widget.child;
    final shimmer = _ShimmerScope.of(context);
    if (shimmer == null || !shimmer.isSized) return widget.child;
    final gradient = shimmer.gradient;
    final ro = context.findRenderObject();
    if (ro is! RenderBox) return widget.child;
    final childBounds = Rect.fromLTWH(0, 0, ro.size.width, ro.size.height);
    return ShaderMask(
      blendMode: BlendMode.srcATop,
      shaderCallback: (_) => gradient.createShader(childBounds),
      child: widget.child,
    );
  }
}
