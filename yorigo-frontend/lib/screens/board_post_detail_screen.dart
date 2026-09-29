import 'dart:async';

import 'package:flutter/material.dart';
import '../widgets/app_toast.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/board_post.dart';
import '../models/recipe_models.dart' show formatServingsLabel;
import '../services/admin_service.dart';
import '../services/board_service.dart';
import '../services/recipe_service.dart';
import '../services/user_service.dart';
import '../utils/recipe_display_title.dart';
import '../utils/recipe_tag_filters.dart';
import '../theme/app_colors.dart';
import '../widgets/app_network_image.dart';
import 'recipe_detail_screen.dart';
import '../utils/review_display_date.dart';
import '../widgets/app_confirm_dialog.dart';
import '../widgets/community_feed_shimmer.dart';
import '../widgets/user_initial_avatar.dart';
import '../main.dart' show mainNavigatorKey;
import 'board_compose_screen.dart';

/// Read view for a single board post + comment thread. The author can
/// edit/delete from the overflow menu; anyone signed in can like / comment.
class BoardPostDetailScreen extends StatefulWidget {
  const BoardPostDetailScreen({super.key, required this.postId});

  final String postId;

  @override
  State<BoardPostDetailScreen> createState() => _BoardPostDetailScreenState();
}

class _BoardPostDetailScreenState extends State<BoardPostDetailScreen> {
  final _service = BoardService();
  final _userService = UserService();
  final _commentController = TextEditingController();
  final _commentFocus = FocusNode();
  final _scrollController = ScrollController();

  /// Cached `{uid -> userDoc map}` for rendering authors of post + comments
  /// without N round-trips. Filled on demand as new uids appear.
  final Map<String, Map<String, dynamic>> _userCache = {};
  final Set<String> _userLoadInFlight = {};

  /// Keep Firestore subscriptions stable. Recreating them on every rebuild
  /// sent StreamBuilder back to `waiting` and flashed the spinner.
  late final Stream<BoardPost?> _postStream;
  late final Stream<List<BoardComment>> _commentsStream;

  bool _commentSubmitting = false;
  bool _viewLogged = false;
  bool _popularBonusChecked = false;
  String? _myUid;
  bool _isAdmin = false;

  /// Optimistic like so the heart flips immediately instead of waiting
  /// for the transaction + snapshot round-trip (which felt broken).
  bool? _likedOverride;
  int? _likeCountOverride;

  String? _taggedMetaRecipeId;
  List<String> _taggedRecipeTags = const [];
  String? _taggedRecipeMetaLine;
  String? _taggedRecipeDisplayTitle;

  @override
  void initState() {
    super.initState();
    _myUid = FirebaseAuth.instance.currentUser?.uid;
    _postStream = _service.watchPost(widget.postId);
    _commentsStream = _service.watchComments(widget.postId);
    // Resolve admin role once so the overflow menu can show "삭제하기" for
    // moderators even on posts they don't own. Failure → false (default).
    unawaited(() async {
      try {
        final isAdmin = await AdminService.instance.isAdmin();
        if (mounted && isAdmin != _isAdmin) {
          setState(() => _isAdmin = isAdmin);
        }
      } catch (_) {}
    }());
    // Register view once after first frame. Failures are fine — it just
    // means the count won't bump for this session.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_viewLogged) {
        _viewLogged = true;
        unawaited(_service.registerView(widget.postId));
      }
    });
  }

  @override
  void dispose() {
    _commentController.dispose();
    _commentFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Returns the cached doc data for [uid], kicking off a background fetch
  /// the first time we see it. Always non-null so callers can index into the
  /// returned map directly.
  Map<String, dynamic> _userDocFor(String uid) {
    if (uid.isEmpty) return const {};
    final local = _userCache[uid];
    if (local != null) return local;
    final shared = UserDocCache.peek(uid);
    if (shared != null) {
      _userCache[uid] = shared;
      return shared;
    }
    if (!_userLoadInFlight.contains(uid)) {
      _userLoadInFlight.add(uid);
      unawaited(_loadUser(uid));
    }
    return const {};
  }

  String _displayName(String uid, {String? stored}) {
    final storedName = stored?.trim() ?? '';
    if (storedName.isNotEmpty) return storedName;
    final user = _userDocFor(uid);
    final name = (user['name'] as String?)?.trim() ?? '';
    if (name.isNotEmpty) return name;
    final handle = (user['handle'] as String?)?.trim() ?? '';
    if (handle.isNotEmpty) return handle;
    return '';
  }

  Future<void> _loadUser(String uid) async {
    try {
      final data = await UserDocCache.ensure(_userService, uid);
      if (!mounted) return;
      if (_userCache[uid] == data) return;
      setState(() {
        _userCache[uid] = data;
      });
    } catch (_) {
      if (mounted) setState(() => _userCache[uid] = const {});
    } finally {
      _userLoadInFlight.remove(uid);
    }
  }

  Future<void> _hydrateUsers(Iterable<String> uids) async {
    final missing = uids
        .where((uid) => uid.isNotEmpty && UserDocCache.peek(uid) == null)
        .toSet();
    if (missing.isEmpty) return;
    for (final uid in missing) {
      _userLoadInFlight.add(uid);
    }
    await UserDocCache.ensureAll(_userService, missing);
    if (!mounted) return;
    setState(() {
      for (final uid in missing) {
        _userCache[uid] = UserDocCache.peek(uid) ?? const {};
        _userLoadInFlight.remove(uid);
      }
    });
  }

  bool _isLiked(BoardPost post) => _likedOverride ?? post.isLikedBy(_myUid);

  int _likeCount(BoardPost post) => _likeCountOverride ?? post.likeCount;

  void _syncLikeOverride(BoardPost post) {
    if (_likedOverride == null) return;
    if (post.isLikedBy(_myUid) == _likedOverride) {
      _likedOverride = null;
      _likeCountOverride = null;
    }
  }

  Future<void> _toggleLike(BoardPost post) async {
    if (FirebaseAuth.instance.currentUser == null) {
      _requireLogin();
      return;
    }
    final wasLiked = _isLiked(post);
    final wasCount = _likeCount(post);
    final nextLiked = !wasLiked;
    final nextCount = (wasCount + (nextLiked ? 1 : -1)).clamp(0, 1 << 30);
    setState(() {
      _likedOverride = nextLiked;
      _likeCountOverride = nextCount;
    });
    try {
      await _service.toggleLike(post.id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _likedOverride = wasLiked;
        _likeCountOverride = wasCount;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('좋아요 처리 실패: $e')));
    }
  }

  Future<void> _submitComment() async {
    if (_commentSubmitting) return;
    final text = _commentController.text.trim();
    if (text.isEmpty) return;
    if (FirebaseAuth.instance.currentUser == null) {
      _requireLogin();
      return;
    }
    setState(() => _commentSubmitting = true);
    try {
      await _service.addComment(widget.postId, text);
      _commentController.clear();
      _commentFocus.unfocus();
      // Scroll to bottom so the new comment is visible.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('댓글 등록 실패: $e')));
    } finally {
      if (mounted) setState(() => _commentSubmitting = false);
    }
  }

  void _requireLogin() {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('로그인이 필요합니다')));
  }

  void _ensureTaggedRecipeMeta(BoardPost post) {
    final id = post.recipeId?.trim() ?? '';
    if (id.isEmpty || id == _taggedMetaRecipeId) return;
    _taggedMetaRecipeId = id;
    unawaited(() async {
      try {
        final parse = await RecipeService.shared.getRecipeById(id);
        if (!mounted || _taggedMetaRecipeId != id) return;
        final tags = filterRecipeTagsForDisplay(parse?.source['tags']).take(2).toList();
        final servings = parse?.recipe.servings;
        final dishTitle = recipeCardDishTitle(
          name: parse?.recipe.name,
          title: parse?.source['title']?.toString(),
          fallback: post.recipeTitle ?? '레시피',
        );
        setState(() {
          _taggedRecipeTags = tags;
          _taggedRecipeDisplayTitle = dishTitle;
          _taggedRecipeMetaLine = servings != null && servings > 0
              ? formatServingsLabel(servings)
              : null;
        });
      } catch (_) {}
    }());
  }

  Future<void> _openTaggedRecipe(String recipeId) async {
    if (recipeId.isEmpty) return;
    try {
      final parse = await RecipeService.shared.getRecipeById(recipeId);
      if (!mounted) return;
      if (parse == null) {
        showAppSnackBar(
          context,
          const SnackBar(content: Text('레시피를 찾을 수 없습니다')),
        );
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => RecipeDetailScreen(
            parseResponse: parse,
            recipeId: recipeId,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        SnackBar(content: Text('레시피를 열 수 없습니다: $e')),
      );
    }
  }

  bool _canOpenProfile(String userId, Map<String, dynamic> user) {
    if (userId.isEmpty) return false;
    if (userId == _myUid) return true;
    return !isSeedUserProfile(user);
  }

  Future<void> _openProfile(String userId) async {
    if (userId.isEmpty) return;
    // Own profile must stay on the main tab so the bottom bar remains.
    if (userId == _myUid) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      mainNavigatorKey.currentState?.navigateToProfile();
      return;
    }
    var user = _userCache[userId];
    if (user == null) {
      await _loadUser(userId);
      if (!mounted) return;
      user = _userCache[userId];
    }
    if (isSeedUserProfile(user)) return;
    if (!mounted) return;
    Navigator.pushNamed(context, '/profile', arguments: {'userId': userId});
  }

  bool _isOwner(BoardPost post) =>
      _myUid != null && _myUid == post.authorId;

  bool _canEdit(BoardPost post) => _isOwner(post);

  bool _canDelete(BoardPost post) => _isOwner(post) || _isAdmin;

  bool _canReport(BoardPost post) => !_isOwner(post) && !_isAdmin;

  void _reportPost() {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('신고가 접수되었습니다')));
  }

  Future<void> _openOverflow(BoardPost post) async {
    final canEdit = _canEdit(post);
    final canDelete = _canDelete(post);
    final canReport = _canReport(post);
    if (!canEdit && !canDelete && !canReport) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFE5E7EB),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 8),
              if (canEdit)
                ListTile(
                  leading: const Icon(Icons.edit_rounded),
                  title: const Text('수정하기'),
                  onTap: () => Navigator.pop(context, 'edit'),
                ),
              if (canDelete)
                ListTile(
                  leading: const Icon(Icons.delete_rounded, color: Colors.red),
                  title: const Text(
                    '삭제하기',
                    style: TextStyle(color: Colors.red),
                  ),
                  onTap: () => Navigator.pop(context, 'delete'),
                ),
              if (canReport)
                ListTile(
                  leading: const Icon(Icons.flag_outlined),
                  title: const Text('신고하기'),
                  onTap: () => Navigator.pop(context, 'report'),
                ),
            ],
          ),
        );
      },
    );
    if (action == null || !mounted) return;
    await _handleOverflowAction(action, post);
  }

  Future<void> _handleOverflowAction(String action, BoardPost post) async {
    switch (action) {
      case 'edit':
        final updated = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) => BoardComposeScreen.edit(post),
            fullscreenDialog: true,
          ),
        );
        if (updated == true && mounted) setState(() {});
        break;
      case 'delete':
        final ok = await AppConfirmDialog.show(
          context: context,
          title: '게시글을 삭제할까요?',
          description: '삭제한 게시글은 복구할 수 없습니다.',
          confirmLabel: '삭제',
          cancelLabel: '취소',
          destructive: true,
        );
        if (ok == true) {
          try {
            await _service.deletePost(post.id);
            if (mounted) Navigator.of(context).pop(true);
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('삭제 실패: $e')));
            }
          }
        }
        break;
      case 'report':
        _reportPost();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final bg = AppColors.getBackground(brightness);
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        centerTitle: true,
        title: const Text(
          '속닥속닥',
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: Color(0xFF111827),
            letterSpacing: -0.3,
          ),
        ),
      ),
      body: StreamBuilder<BoardPost?>(
        stream: _postStream,
        builder: (context, snap) {
          final post = snap.data;
          if (post == null &&
              snap.connectionState == ConnectionState.waiting) {
            return const BoardPostDetailShimmer();
          }
          if (post == null) {
            return const Center(
              child: Text(
                '삭제된 게시글이거나 접근 권한이 없어요',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 14,
                  color: Color(0xFF6B7280),
                ),
              ),
            );
          }
          _syncLikeOverride(post);
          _ensureTaggedRecipeMeta(post);
          unawaited(_hydrateUsers([post.authorId]));
          if (!_popularBonusChecked) {
            _popularBonusChecked = true;
            _service.checkAndClaimPopularPostBonus(post);
          }
          return Column(
            children: [
              Expanded(
                child: CustomScrollView(
                  controller: _scrollController,
                  slivers: [
                    SliverToBoxAdapter(child: _buildPostBody(post)),
                    _buildCommentsSliver(post),
                    const SliverToBoxAdapter(child: SizedBox(height: 80)),
                  ],
                ),
              ),
              _buildCommentInput(),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPostBody(BoardPost post) {
    final author = _userDocFor(post.authorId);
    final authorName = _displayName(post.authorId, stored: post.authorName);
    final photoUrl = resolveUserPhotoUrl(author);
    final canOpenAuthor = _canOpenProfile(post.authorId, author);
    final isLiked = _isLiked(post);
    final likeCount = _likeCount(post);
    final category = BoardCategory.fromId(post.category);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (category.id != BoardCategory.all.id) ...[
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: _CategoryChip(label: category.label),
                ),
                const SizedBox(height: 14),
              ],
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: canOpenAuthor
                          ? () => _openProfile(post.authorId)
                          : null,
                      behavior: HitTestBehavior.opaque,
                      child: _Avatar(
                        seed: post.authorId,
                        name: authorName,
                        photoUrl: photoUrl,
                        size: 40,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: GestureDetector(
                        onTap: canOpenAuthor
                            ? () => _openProfile(post.authorId)
                            : null,
                        behavior: HitTestBehavior.opaque,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              authorName,
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF111827),
                                letterSpacing: -0.3,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              formatCommunityTimeAgo(post.createdAt),
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 12,
                                color: Color(0xFF9CA3AF),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.more_horiz_rounded,
                        color: Color(0xFF9CA3AF),
                      ),
                      onPressed: () => _openOverflow(post),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(
                  post.title,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF111111),
                    height: 1.35,
                    letterSpacing: -0.4,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: SelectableText(
                  post.body,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 15.5,
                    height: 1.65,
                    color: Color(0xFF1F2937),
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              if (post.hasTaggedRecipe) ...[
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: _TaggedRecipeCard(
                    title: _taggedRecipeDisplayTitle ??
                        recipeCardDishTitle(title: post.recipeTitle),
                    thumbnailUrl: post.recipeThumbnailUrl ?? '',
                    tags: _taggedRecipeTags,
                    metaLine: _taggedRecipeMetaLine,
                    onTap: () => _openTaggedRecipe(post.recipeId ?? ''),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Row(
                  children: [
                    _MetaButton(
                      icon: isLiked
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      label: '$likeCount',
                      active: isLiked,
                      onTap: () => _toggleLike(post),
                    ),
                    const SizedBox(width: 16),
                    _MetaButton(
                      icon: Icons.chat_bubble_outline_rounded,
                      label: '${post.commentCount}',
                      onTap: () => _commentFocus.requestFocus(),
                    ),
                    const Spacer(),
                    Text(
                      '조회 ${post.viewCount}',
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF9CA3AF),
                        letterSpacing: -0.1,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCommentsSliver(BoardPost post) {
    return StreamBuilder<List<BoardComment>>(
      stream: _commentsStream,
      builder: (context, snap) {
        if (!snap.hasData &&
            snap.connectionState == ConnectionState.waiting) {
          return SliverList(
            delegate: SliverChildListDelegate(const [
              _CommentSectionHeader(count: 0),
              BoardCommentListShimmer(),
            ]),
          );
        }
        if (snap.hasError) {
          return SliverToBoxAdapter(
            child: Column(
              children: [
                _CommentSectionHeader(count: post.commentCount),
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 28, 20, 24),
                  child: Text(
                    '댓글을 불러오지 못했어요',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 13.5,
                      color: Color(0xFF9CA3AF),
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        final comments = snap.data ?? const <BoardComment>[];
        unawaited(_hydrateUsers(comments.map((c) => c.authorId)));
        if (comments.isEmpty) {
          return SliverToBoxAdapter(
            child: Column(
              children: [
                _CommentSectionHeader(count: 0),
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 28, 20, 24),
                  child: Text(
                    '첫 댓글을 남겨보세요',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 13.5,
                      color: Color(0xFF9CA3AF),
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        return SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              if (i == 0) {
                return _CommentSectionHeader(count: comments.length);
              }
              return _buildCommentRow(post, comments[i - 1]);
            },
            childCount: comments.length + 1,
          ),
        );
      },
    );
  }

  Widget _buildCommentRow(BoardPost post, BoardComment c) {
    final author = _userDocFor(c.authorId);
    final name = _displayName(c.authorId, stored: c.authorName);
    final photoUrl = resolveUserPhotoUrl(author);
    final canOpenAuthor = _canOpenProfile(c.authorId, author);
    final canDelete = c.authorId == _myUid || post.authorId == _myUid;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFF3F4F6), width: 1)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: canOpenAuthor ? () => _openProfile(c.authorId) : null,
            child: _Avatar(
              seed: c.authorId,
              name: name,
              photoUrl: photoUrl,
              size: 36,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: GestureDetector(
                        onTap: canOpenAuthor
                            ? () => _openProfile(c.authorId)
                            : null,
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 13.5,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF111111),
                            letterSpacing: -0.25,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      formatCommunityTimeAgo(c.createdAt),
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF9CA3AF),
                      ),
                    ),
                    if (canDelete)
                      GestureDetector(
                        onTap: () async {
                          final ok = await AppConfirmDialog.show(
                            context: context,
                            title: '댓글을 삭제할까요?',
                            confirmLabel: '삭제',
                            cancelLabel: '취소',
                            destructive: true,
                          );
                          if (ok != true) return;
                          try {
                            await _service.deleteComment(post.id, c.id);
                          } catch (e) {
                            if (mounted) {
                              showAppSnackBar(
                                context,
                                SnackBar(content: Text('삭제 실패: $e')),
                              );
                            }
                          }
                        },
                        behavior: HitTestBehavior.opaque,
                        child: const Padding(
                          padding: EdgeInsets.fromLTRB(8, 0, 8, 0),
                          child: Icon(
                            Icons.more_horiz_rounded,
                            size: 18,
                            color: Color(0xFF9CA3AF),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  c.text,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 14.5,
                    height: 1.5,
                    color: Color(0xFF1F2937),
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCommentInput() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFF1F3F5), width: 0.7)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Container(
                constraints: const BoxConstraints(minHeight: 40),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFF7F8FA),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: TextField(
                  controller: _commentController,
                  focusNode: _commentFocus,
                  maxLines: 5,
                  minLines: 1,
                  textInputAction: TextInputAction.newline,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 14,
                    color: Color(0xFF111827),
                  ),
                  decoration: const InputDecoration(
                    hintText: '따뜻한 댓글을 남겨주세요',
                    hintStyle: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 14,
                      color: Color(0xFF9CA3AF),
                    ),
                    border: InputBorder.none,
                    isCollapsed: true,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _commentController,
              builder: (context, value, _) {
                final canSend =
                    value.text.trim().isNotEmpty && !_commentSubmitting;
                return GestureDetector(
                  onTap: canSend ? _submitComment : null,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: canSend
                          ? const Color(0xFFFF7300)
                          : const Color(0xFFE5E7EB),
                      shape: BoxShape.circle,
                    ),
                    child: _commentSubmitting
                        ? const Padding(
                            padding: EdgeInsets.all(10),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          )
                        : Icon(
                            Icons.arrow_upward_rounded,
                            color: canSend
                                ? Colors.white
                                : const Color(0xFF9CA3AF),
                            size: 20,
                          ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

}

class _TaggedRecipeCard extends StatelessWidget {
  const _TaggedRecipeCard({
    required this.title,
    required this.thumbnailUrl,
    required this.onTap,
    this.tags = const [],
    this.metaLine,
  });

  final String title;
  final String thumbnailUrl;
  final VoidCallback onTap;
  final List<String> tags;
  final String? metaLine;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFF0F1F3)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 18,
              offset: Offset(0, 8),
            ),
            BoxShadow(
              color: Color(0x0A000000),
              blurRadius: 4,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: Row(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 8,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 44,
                  height: 55,
                  child: thumbnailUrl.isEmpty
                      ? const ColoredBox(
                          color: Color(0xFFEEF0F3),
                          child: Icon(
                            Icons.restaurant_rounded,
                            color: Color(0xFF9CA3AF),
                          ),
                        )
                      : AppNetworkImage(
                          imageUrl: thumbnailUrl,
                          fit: BoxFit.cover,
                          width: 44,
                          height: 55,
                        ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '태그된 레시피',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF9CA3AF),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    title,
                    maxLines: tags.isNotEmpty || (metaLine ?? '').isNotEmpty ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF111827),
                    ),
                  ),
                  if (tags.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    SizedBox(
                      height: 18,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: tags.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 4),
                        itemBuilder: (_, index) {
                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: const Color(0xFFF4F5F7),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              tags[index],
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF6B7280),
                                letterSpacing: -0.2,
                                height: 1,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ] else if ((metaLine ?? '').isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      metaLine!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF9CA3AF),
                        letterSpacing: -0.15,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Color(0xFF9CA3AF)),
          ],
        ),
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(width: 0.67, color: const Color(0xFFE5E7EB)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Color(0xFF4B5563),
          height: 1.4,
          letterSpacing: -0.2,
        ),
      ),
    );
  }
}

class _MetaButton extends StatelessWidget {
  const _MetaButton({
    required this.icon,
    required this.label,
    this.active = false,
    this.onTap,
  });
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? const Color(0xFFFF7300) : const Color(0xFF8B95A1);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: color,
                letterSpacing: -0.15,
                height: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommentSectionHeader extends StatelessWidget {
  const _CommentSectionHeader({required this.count});
  final int count;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFF1F3F5), width: 8)),
      ),
      child: Text(
        '댓글 $count',
        style: const TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 14,
          fontWeight: FontWeight.w800,
          color: Color(0xFF111827),
          letterSpacing: -0.25,
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.seed,
    required this.name,
    required this.size,
    this.photoUrl,
  });
  final String seed;
  final String name;
  final double size;
  final String? photoUrl;

  @override
  Widget build(BuildContext context) {
    final url = photoUrl;
    if (url != null && url.isNotEmpty) {
      return ClipOval(
        child: Image.network(
          url,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) =>
              UserInitialAvatar(seed: seed, name: name, size: size),
        ),
      );
    }
    return UserInitialAvatar(seed: seed, name: name, size: size);
  }
}
