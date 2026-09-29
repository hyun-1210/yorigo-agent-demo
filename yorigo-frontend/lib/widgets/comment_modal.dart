import 'dart:async';

import 'package:flutter/material.dart';
import 'app_toast.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../theme/app_colors.dart';
import 'app_media_query_merge_nav_insets.dart';
import 'app_network_image.dart';
import 'user_initial_avatar.dart';
import '../services/user_service.dart';
import '../services/review_service.dart';
import '../services/rewards_service.dart';
import '../services/admin_service.dart';
import 'review_post_action_sheets.dart';
import 'app_confirm_dialog.dart';
import 'app_prompt_dialog.dart';

class CommentModal extends StatefulWidget {
  final String reviewId;
  final Map<String, dynamic> review;

  const CommentModal({super.key, required this.reviewId, required this.review});

  @override
  State<CommentModal> createState() => _CommentModalState();
}

class _CommentModalState extends State<CommentModal> {
  final UserService _userService = UserService();
  final ReviewService _reviewService = ReviewService();
  final TextEditingController _commentController = TextEditingController();
  final TextEditingController _editCommentController = TextEditingController();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final Map<String, Map<String, dynamic>> _userDataCache = {};
  final Set<String> _loadingUserIds = {};
  late Stream<List<Map<String, dynamic>>> _commentsStream;
  List<Map<String, dynamic>> _lastComments = const [];
  bool _userFlushScheduled = false;
  String? _currentUserPhotoUrl;
  String? _currentUserName;
  String? _currentUserHandle;
  bool _isSubmitting = false;
  String? _editingCommentId;
  String? _replyToCommentId;
  String? _replyToUserName;
  final ScrollController _scrollController = ScrollController();
  Set<String>? _expandedReplyParents;
  Set<String> get _expandedReplies =>
      _expandedReplyParents ??= <String>{};
  bool _isAdminUser = false;

  @override
  void initState() {
    super.initState();
    _commentsStream = _reviewService.getCommentsStream(
      widget.reviewId,
      limit: 200,
    );
    _loadCurrentUserPhoto();
    _loadAdminRole();
    RewardsService.instance.claimAuthorSocialMilestones(
      contentId: widget.reviewId,
      authorId: widget.review['userId']?.toString(),
      likeCount: (widget.review['likeCount'] as num?)?.toInt() ?? 0,
      commentCount: (widget.review['commentCount'] as num?)?.toInt() ?? 0,
    );
    final reviewUserId = widget.review['userId'] as String?;
    if (reviewUserId != null && reviewUserId.isNotEmpty) {
      _scheduleUserLoad(reviewUserId);
    }
  }

  Future<void> _loadAdminRole() async {
    try {
      final isAdmin = await AdminService.instance.isAdmin();
      if (!mounted || !isAdmin || _isAdminUser) return;
      setState(() {
        _isAdminUser = true;
        _commentsStream = _reviewService.getCommentsStream(
          widget.reviewId,
          limit: 200,
          includeHiddenForAdmin: true,
        );
      });
    } catch (e) {
      print('[CommentModal] Error loading admin role: $e');
    }
  }

  Future<void> _loadCurrentUserPhoto() async {
    final user = _auth.currentUser;
    if (user != null) {
      try {
        final userDoc = await _userService.getUserDocument(user.uid);
        final userData = userDoc.data() as Map<String, dynamic>?;
        if (mounted) {
          setState(() {
            _currentUserPhotoUrl = userData != null
                ? resolveUserPhotoUrl(userData)
                : null;
            _currentUserName = userData?['name'] as String?;
            _currentUserHandle = userData?['handle'] as String?;
          });
        }
      } catch (e) {
        print('[CommentModal] Error loading current user photo: $e');
      }
    }
  }

  void _seedCommentAuthor(Map<String, dynamic> comment) {
    final uid = comment['userId'] as String? ?? '';
    if (uid.isEmpty || _userDataCache.containsKey(uid)) return;
    final name = _nonEmptyName(comment['userName'] as String?);
    final fallback = name.isNotEmpty
        ? name
        : _nonEmptyName(comment['name'] as String?);
    final photo = (comment['userPhotoUrl'] as String?)?.trim() ?? '';
    if (fallback.isEmpty && photo.isEmpty) return;
    _userDataCache[uid] = {
      if (fallback.isNotEmpty) 'name': fallback,
      if (photo.isNotEmpty) 'photoUrl': photo,
    };
  }

  void _scheduleUserLoad(String userId) {
    if (userId.isEmpty ||
        _userDataCache.containsKey(userId) ||
        _loadingUserIds.contains(userId)) {
      return;
    }
    _loadingUserIds.add(userId);
    if (_userFlushScheduled) return;
    _userFlushScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _userFlushScheduled = false;
      unawaited(_flushUserLoads());
    });
  }

  Future<void> _flushUserLoads() async {
    final ids = _loadingUserIds
        .where((id) => !_userDataCache.containsKey(id))
        .toList();
    if (ids.isEmpty) return;
    final loaded = <String, Map<String, dynamic>>{};
    await Future.wait(
      ids.map((id) async {
        try {
          final userDoc = await _userService.getUserDocument(id);
          loaded[id] = (userDoc.data() as Map<String, dynamic>?) ?? {};
        } catch (e) {
          print('[CommentModal] Error loading user data: $e');
          loaded[id] = {};
        }
      }),
    );
    if (!mounted) return;
    setState(() {
      for (final entry in loaded.entries) {
        final existing = _userDataCache[entry.key];
        final incoming = Map<String, dynamic>.from(entry.value);
        final incomingName = _nonEmptyName(incoming['name'] as String?);
        if (incomingName.isEmpty) {
          final kept = _nonEmptyName(existing?['name'] as String?);
          if (kept.isNotEmpty) incoming['name'] = kept;
        }
        _userDataCache[entry.key] = incoming;
      }
    });
  }

  @override
  void dispose() {
    _commentController.dispose();
    _editCommentController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _submitComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty) return;

    final user = _auth.currentUser;
    if (user == null) {
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('로그인이 필요합니다'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      final replyParentId = _replyToCommentId;
      await _reviewService.createComment(
        reviewId: widget.reviewId,
        text: text,
        parentCommentId: _replyToCommentId,
      );
      _commentController.clear();
      if (mounted) {
        setState(() {
          if (replyParentId != null) {
            _expandedReplies.add(replyParentId);
          }
          _replyToCommentId = null;
          _replyToUserName = null;
        });
      }

      if (mounted && _scrollController.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scrollController.hasClients) return;
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOut,
          );
        });
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 
          SnackBar(
            content: Text('댓글 작성 중 오류가 발생했습니다: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Future<void> _startEditComment(Map<String, dynamic> comment) async {
    setState(() {
      _editingCommentId = comment['id'] as String?;
      _editCommentController.text = comment['text'] as String? ?? '';
    });
  }

  Future<void> _cancelEdit() async {
    setState(() {
      _editingCommentId = null;
      _editCommentController.clear();
    });
  }

  Future<void> _updateComment(String commentId) async {
    final text = _editCommentController.text.trim();
    if (text.isEmpty) {
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('댓글 내용을 입력해주세요'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      await _reviewService.updateComment(
        reviewId: widget.reviewId,
        commentId: commentId,
        newText: text,
      );
      setState(() {
        _editingCommentId = null;
        _editCommentController.clear();
      });
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 
          SnackBar(
            content: Text('댓글 수정 중 오류가 발생했습니다: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Future<void> _deleteComment(
    String commentId, {
    bool allowAdminOverride = false,
  }) async {
    final confirmed = await AppConfirmDialog.show(
      context: context,
      title: '댓글을 삭제할까요?',
      description: '삭제된 댓글은 복구할 수 없어요.',
      confirmLabel: '삭제',
      destructive: true,
    );

    if (confirmed != true) return;

    try {
      await _reviewService.deleteComment(
        reviewId: widget.reviewId,
        commentId: commentId,
        allowAdminOverride: allowAdminOverride,
      );
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 
          SnackBar(
            content: Text('댓글 삭제 중 오류가 발생했습니다: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _toggleCommentLike(
    String commentId,
    Map<String, dynamic> comment,
  ) async {
    try {
      await _reviewService.toggleCommentLike(
        reviewId: widget.reviewId,
        commentId: commentId,
      );
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 
          SnackBar(
            content: Text('좋아요 처리 중 오류가 발생했습니다: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<String?> _promptHiddenReason({
    required bool hidden,
    String initialValue = '',
  }) {
    return AppPromptDialog.show(
      context: context,
      title: hidden ? '숨김 사유를 입력해주세요' : '숨김 해제 사유를 입력해주세요',
      hintText: '사유를 입력해주세요',
      initialValue: initialValue,
    );
  }

  Future<void> _toggleCommentHidden({
    required String commentId,
    required bool hidden,
    String? existingReason,
  }) async {
    final reason = await _promptHiddenReason(
      hidden: hidden,
      initialValue: existingReason ?? '',
    );
    if (reason == null || reason.isEmpty) return;

    try {
      await _reviewService.setCommentHidden(
        reviewId: widget.reviewId,
        commentId: commentId,
        hidden: hidden,
        reason: reason,
      );
      if (mounted) {
        showAppSnackBar(context, 
          SnackBar(
            content: Text(hidden ? '댓글을 숨김 처리했습니다' : '댓글 숨김을 해제했습니다'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 
          SnackBar(
            content: Text('댓글 숨김 처리 중 오류가 발생했습니다: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _showReportDialog(String commentId) async {
    await showReviewReportBottomSheet(
      context,
      type: 'comment',
      targetId: commentId,
      reviewId: widget.reviewId,
    );
  }

  void _startReply(Map<String, dynamic> comment) {
    final commentId = comment['id'] as String? ?? '';
    if (commentId.isEmpty) return;
    final parent = (comment['parentCommentId'] as String?)?.trim();
    final targetId = (parent != null && parent.isNotEmpty) ? parent : commentId;
    final userName = _commentAuthorName(comment);
    setState(() {
      _replyToCommentId = targetId;
      _replyToUserName = userName.isEmpty ? null : userName;
      _expandedReplies.add(targetId);
    });
  }

  void _cancelReply() {
    setState(() {
      _replyToCommentId = null;
      _replyToUserName = null;
    });
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '';
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inMinutes < 1) {
      return '방금';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes}분';
    } else if (difference.inDays < 1) {
      return '${difference.inHours}시간';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}일';
    } else {
      return '${date.month}/${date.day}';
    }
  }

  bool _isEdited(Map<String, dynamic> comment) {
    return comment['isEdited'] == true;
  }

  DateTime? _asDate(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  int _createdAtMs(Map<String, dynamic> comment) {
    return _asDate(comment['createdAt'])?.millisecondsSinceEpoch ?? 0;
  }

  String? _parentIdOf(Map<String, dynamic> comment) {
    final parent = (comment['parentCommentId'] as String?)?.trim();
    if (parent == null || parent.isEmpty) return null;
    return parent;
  }

  String _rootIdOf(
    Map<String, dynamic> comment,
    Map<String, Map<String, dynamic>> byId,
  ) {
    var current = comment;
    for (var i = 0; i < 8; i++) {
      final parent = _parentIdOf(current);
      if (parent == null || !byId.containsKey(parent)) {
        return current['id'] as String? ?? '';
      }
      current = byId[parent]!;
    }
    return current['id'] as String? ?? '';
  }

  String _reviewAuthorName() {
    final reviewUserId = widget.review['userId'] as String?;
    if (reviewUserId != null && _userDataCache.containsKey(reviewUserId)) {
      final name = _userDataCache[reviewUserId]?['name'] as String?;
      if (name != null && name.isNotEmpty) return name;
    }
    final fallback =
        widget.review['userName'] as String? ??
        widget.review['authorName'] as String?;
    return (fallback != null && fallback.isNotEmpty) ? fallback : '';
  }

  String _nonEmptyName(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty || v == '사용자') return '';
    return v.startsWith('@') ? v.substring(1) : v;
  }

  String _commentAuthorName(Map<String, dynamic> comment) {
    final commentUserId = comment['userId'] as String? ?? '';
    final cached = _userDataCache[commentUserId];
    final cachedName = _nonEmptyName(cached?['name'] as String?);
    if (cachedName.isNotEmpty) return cachedName;

    for (final key in ['userName', 'name', 'authorName', 'handle', 'userHandle']) {
      final fromComment = _nonEmptyName(comment[key] as String?);
      if (fromComment.isNotEmpty) return fromComment;
    }

    if (commentUserId.isNotEmpty && commentUserId == _auth.currentUser?.uid) {
      final mine = _nonEmptyName(_currentUserName);
      if (mine.isNotEmpty) return mine;
      final handle = _nonEmptyName(_currentUserHandle);
      if (handle.isNotEmpty) return handle;
    }
    return '';
  }

  String? _commentPhotoUrl(Map<String, dynamic> comment) {
    final commentUserId = comment['userId'] as String? ?? '';
    final cached = _userDataCache[commentUserId];
    if (cached != null) {
      final cachedPhoto = resolveUserPhotoUrl(cached);
      if (cachedPhoto != null && cachedPhoto.isNotEmpty) return cachedPhoto;
    }
    for (final key in ['userPhotoUrl', 'photoUrl', 'profileImageUrl']) {
      final raw = (comment[key] as String?)?.trim() ?? '';
      if (raw.isNotEmpty) return raw;
    }
    return null;
  }

  String _inputHintText() {
    if (_replyToCommentId != null) {
      final target = _nonEmptyName(_replyToUserName);
      if (target.isNotEmpty) return '$target님에게 댓글 달기';
      return '답글 달기';
    }
    final author = _reviewAuthorName();
    if (author.isNotEmpty) return '$author님에게 댓글 달기';
    return '댓글 달기';
  }

  Widget _buildThreadedList(
    BuildContext context, {
    required List<Map<String, dynamic>> comments,
    required Brightness brightness,
    required User? currentUser,
  }) {
    final byId = <String, Map<String, dynamic>>{
      for (final comment in comments)
        if ((comment['id'] as String?)?.isNotEmpty == true)
          comment['id'] as String: comment,
    };

    final roots = comments.where((comment) {
      final parent = _parentIdOf(comment);
      return parent == null || !byId.containsKey(parent);
    }).toList()
      ..sort((a, b) => _createdAtMs(a).compareTo(_createdAtMs(b)));

    final repliesByRoot = <String, List<Map<String, dynamic>>>{};
    for (final comment in comments) {
      final parent = _parentIdOf(comment);
      if (parent == null) continue;
      final rootId = _rootIdOf(comment, byId);
      final selfId = comment['id'] as String? ?? '';
      if (rootId.isEmpty || rootId == selfId) continue;
      repliesByRoot.putIfAbsent(rootId, () => []).add(comment);
    }
    for (final replies in repliesByRoot.values) {
      replies.sort((a, b) => _createdAtMs(a).compareTo(_createdAtMs(b)));
    }

    final children = <Widget>[];
    for (final root in roots) {
      final rootId = root['id'] as String? ?? '';
      final replies = repliesByRoot[rootId] ?? const [];
      final expanded = _expandedReplies.contains(rootId);
      children.add(
        _buildCommentRow(
          context,
          comment: root,
          brightness: brightness,
          currentUser: currentUser,
          isReply: false,
          replyCount: replies.length,
          repliesExpanded: expanded,
        ),
      );
      if (replies.isEmpty || !expanded) continue;
      for (final reply in replies) {
        children.add(
          _buildCommentRow(
            context,
            comment: reply,
            brightness: brightness,
            currentUser: currentUser,
            isReply: true,
          ),
        );
      }
    }

    return ListView(
      controller: _scrollController,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 20),
      children: children,
    );
  }

  Widget _buildCommentRow(
    BuildContext context, {
    required Map<String, dynamic> comment,
    required Brightness brightness,
    required User? currentUser,
    required bool isReply,
    int replyCount = 0,
    bool repliesExpanded = false,
  }) {
    final commentId = comment['id'] as String? ?? '';
    final commentUserId = comment['userId'] as String? ?? '';
    final userName = _commentAuthorName(comment);
    final userPhotoUrl = _commentPhotoUrl(comment);
    final commentText = comment['text'] as String? ?? '';
    final createdAt = _asDate(comment['createdAt']);
    final likeCount = (comment['likeCount'] as num?)?.toInt() ?? 0;
    final isLiked = _reviewService.isCommentLiked(comment);
    final isOwner = commentUserId == currentUser?.uid;
    final isEditing = _editingCommentId == commentId;
    final isEdited = _isEdited(comment);
    final isHiddenComment = comment['isHidden'] == true;
    final hiddenReason = comment['hiddenReason'] as String?;
    final muted = AppColors.getTextTertiary(brightness);
    final secondary = AppColors.getTextSecondary(brightness);
    final primary = AppColors.getTextPrimary(brightness);
    final commentIdForToggle = commentId;

    if (isEditing) {
      return Padding(
        padding: EdgeInsets.fromLTRB(isReply ? 56 : 16, 10, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _CommentAvatar(
                  radius: 16,
                  photoUrl: userPhotoUrl,
                  seed: commentUserId,
                  name: userName,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _editCommentController,
                    decoration: InputDecoration(
                      hintText: '댓글을 수정하세요...',
                      hintStyle: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 14,
                        color: muted,
                      ),
                      filled: true,
                      fillColor: AppColors.getBackgroundSecondary(brightness),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(
                          color: AppColors.primary,
                          width: 1.2,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                    ),
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      color: primary,
                      fontSize: 14,
                    ),
                    maxLines: null,
                    autofocus: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _isSubmitting ? null : _cancelEdit,
                  child: Text(
                    '취소',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      color: secondary,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _isSubmitting
                      ? null
                      : () => _updateComment(commentId),
                  child: const Text(
                    '수정',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      color: AppColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    final isNew = createdAt != null &&
        DateTime.now().difference(createdAt) < const Duration(hours: 24);
    final actionStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 12,
      fontWeight: FontWeight.w500,
      color: muted,
      height: 1.2,
    );

    const nameStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 13.5,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.25,
      height: 1,
      leadingDistribution: TextLeadingDistribution.even,
    );
    final nameStrut = const StrutStyle(
      fontFamily: 'Pretendard',
      fontSize: 13.5,
      height: 1,
      forceStrutHeight: true,
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(isReply ? 56 : 16, 14, 12, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CommentAvatar(
            radius: 16,
            photoUrl: userPhotoUrl,
            seed: commentUserId,
            name: userName,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 18,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                    Flexible(
                      child: Text(
                        userName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: nameStyle.copyWith(color: primary),
                        strutStyle: nameStrut,
                      ),
                    ),
                    if (isNew) ...[
                      const SizedBox(width: 5),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1.5,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFD1D5DB),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'new',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                            height: 1.1,
                            letterSpacing: -0.1,
                          ),
                        ),
                      ),
                    ],
                    if (isEdited) ...[
                      const SizedBox(width: 5),
                      Text(
                        '수정됨',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: muted,
                        ),
                      ),
                    ],
                    if (isHiddenComment && _isAdminUser) ...[
                      const SizedBox(width: 5),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.primaryLight,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          '숨김됨',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 6),
                    Text(
                      _formatDate(createdAt),
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: muted,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _commentOverflowButton(
                      brightness: brightness,
                      commentId: commentId,
                      comment: comment,
                      isOwner: isOwner,
                      isHiddenComment: isHiddenComment,
                      hiddenReason: hiddenReason,
                    ),
                  ],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  commentText,
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 14,
                    height: 1.35,
                    letterSpacing: -0.2,
                    color: primary,
                  ),
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () => _startReply(comment),
                  child: Text('답글 달기', style: actionStyle),
                ),
                if (replyCount > 0) ...[
                  const SizedBox(height: 6),
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        if (repliesExpanded) {
                          _expandedReplies.remove(commentIdForToggle);
                        } else {
                          _expandedReplies.add(commentIdForToggle);
                        }
                      });
                    },
                    child: Text(
                      repliesExpanded
                          ? '답글 숨기기'
                          : '답글 $replyCount개 더보기',
                      style: actionStyle,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => _toggleCommentLike(commentId, comment),
            behavior: HitTestBehavior.opaque,
            child: Column(
              children: [
                Icon(
                  isLiked
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  size: 18,
                  color: isLiked ? const Color(0xFFE5484D) : muted,
                ),
                if (likeCount > 0) ...[
                  const SizedBox(height: 2),
                  Text(
                    '$likeCount',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _onCommentOverflowSelected(
    String value, {
    required String commentId,
    required Map<String, dynamic> comment,
    required String? hiddenReason,
  }) {
    if (value == 'report') {
      _showReportDialog(commentId);
    } else if (value == 'edit') {
      _startEditComment(comment);
    } else if (value == 'delete') {
      _deleteComment(commentId);
    } else if (value == 'admin_delete') {
      _deleteComment(commentId, allowAdminOverride: true);
    } else if (value == 'admin_hide') {
      _toggleCommentHidden(
        commentId: commentId,
        hidden: true,
        existingReason: hiddenReason,
      );
    } else if (value == 'admin_unhide') {
      _toggleCommentHidden(
        commentId: commentId,
        hidden: false,
        existingReason: hiddenReason,
      );
    }
  }

  Widget _commentOverflowButton({
    required Brightness brightness,
    required String commentId,
    required Map<String, dynamic> comment,
    required bool isOwner,
    required bool isHiddenComment,
    required String? hiddenReason,
  }) {
    const menuText = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: Color(0xFF111111),
      letterSpacing: -0.2,
      height: 1.2,
    );
    const reportColor = Color(0xFFEF4444);

    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      tooltip: '',
      offset: const Offset(0, 8),
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      shadowColor: const Color(0x1A000000),
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFF3F4F6)),
      ),
      child: SizedBox(
        width: 16,
        height: 16,
        child: Icon(
          Icons.more_horiz_rounded,
          size: 15,
          color: AppColors.getTextTertiary(brightness),
        ),
      ),
      onSelected: (value) {
        _onCommentOverflowSelected(
          value,
          commentId: commentId,
          comment: comment,
          hiddenReason: hiddenReason,
        );
      },
      itemBuilder: (context) {
        final items = <PopupMenuEntry<String>>[];
        if (isOwner) {
          items.add(
            const PopupMenuItem<String>(
              value: 'edit',
              child: Text('수정', style: menuText),
            ),
          );
          items.add(
            const PopupMenuItem<String>(
              value: 'delete',
              child: Text(
                '삭제',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: reportColor,
                  letterSpacing: -0.2,
                  height: 1.2,
                ),
              ),
            ),
          );
        }
        if (!isOwner && !_isAdminUser) {
          items.add(
            const PopupMenuItem<String>(
              value: 'report',
              child: Row(
                children: [
                  Icon(
                    Icons.flag_outlined,
                    size: 16,
                    color: reportColor,
                  ),
                  SizedBox(width: 8),
                  Text(
                    '신고하기',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: reportColor,
                      letterSpacing: -0.2,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        if (_isAdminUser) {
          items.add(
            PopupMenuItem<String>(
              value: isHiddenComment ? 'admin_unhide' : 'admin_hide',
              child: Text(
                isHiddenComment ? '숨김 해제' : '숨기기',
                style: menuText,
              ),
            ),
          );
          items.add(
            const PopupMenuItem<String>(
              value: 'admin_delete',
              child: Text(
                '삭제',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: reportColor,
                  letterSpacing: -0.2,
                  height: 1.2,
                ),
              ),
            ),
          );
        }
        return items;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final user = _auth.currentUser;
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    final screenHeight = MediaQuery.of(context).size.height;

    return AppMediaQueryMergeNavInsets(
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(bottom: keyboardHeight),
        child: Container(
          height: screenHeight * 0.75,
          decoration: BoxDecoration(
            color: AppColors.getBackground(brightness),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.getBorderSecondary(brightness),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 10),
                child: Row(
                  children: [
                    Text(
                      '댓글',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.35,
                        color: AppColors.getTextPrimary(brightness),
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      splashRadius: 18,
                      icon: Icon(
                        Icons.close_rounded,
                        size: 20,
                        color: AppColors.getTextTertiary(brightness),
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Divider(
                height: 1,
                thickness: 1,
                color: AppColors.getBorder(brightness),
              ),
              // Comments list with StreamBuilder
              Expanded(
                child: StreamBuilder<List<Map<String, dynamic>>>(
                  stream: _commentsStream,
                  builder: (context, snapshot) {
                    if (snapshot.hasError &&
                        !snapshot.hasData &&
                        _lastComments.isEmpty) {
                      return Center(
                        child: Text(
                          '댓글을 불러오는 중 오류가 발생했습니다',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 14,
                            color: AppColors.getTextSecondary(brightness),
                          ),
                        ),
                      );
                    }

                    final comments = snapshot.data ?? _lastComments;
                    if (snapshot.hasData) {
                      _lastComments = comments;
                    }

                    if (comments.isEmpty) {
                      if (snapshot.connectionState ==
                              ConnectionState.waiting &&
                          !snapshot.hasData) {
                        return const SizedBox.expand();
                      }
                      return Center(
                        child: Text(
                          '댓글이 없습니다',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 14,
                            color: AppColors.getTextTertiary(brightness),
                          ),
                        ),
                      );
                    }

                    for (final comment in comments) {
                      _seedCommentAuthor(comment);
                      final userId = comment['userId'] as String?;
                      if (userId != null) _scheduleUserLoad(userId);
                    }
                    final reviewUserId = widget.review['userId'] as String?;
                    if (reviewUserId != null) {
                      _scheduleUserLoad(reviewUserId);
                    }

                    return _buildThreadedList(
                      context,
                      comments: comments,
                      brightness: brightness,
                      currentUser: user,
                    );
                  },
                ),
              ),
              // Comment input (SafeArea keeps field above system nav / home indicator)
              if (user != null)
                SafeArea(
                  top: false,
                  left: false,
                  right: false,
                  bottom: keyboardHeight <= 0,
                  minimum: EdgeInsets.zero,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(
                          color: AppColors.getBorder(brightness),
                          width: 1,
                        ),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_replyToCommentId != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _nonEmptyName(_replyToUserName).isNotEmpty
                                        ? '${_nonEmptyName(_replyToUserName)}님에게 답글 작성 중'
                                        : '답글 작성 중',
                                    style: TextStyle(
                                      fontFamily: 'Pretendard',
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: AppColors.getTextSecondary(
                                        brightness,
                                      ),
                                    ),
                                  ),
                                ),
                                GestureDetector(
                                  onTap: _cancelReply,
                                  child: Text(
                                    '취소',
                                    style: TextStyle(
                                      fontFamily: 'Pretendard',
                                      fontSize: 12,
                                      color: AppColors.primary,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        Row(
                          children: [
                            _CommentAvatar(
                              radius: 16,
                              photoUrl: _currentUserPhotoUrl,
                              seed:
                                  (_auth.currentUser?.uid.isNotEmpty == true)
                                  ? _auth.currentUser!.uid
                                  : (_currentUserHandle ??
                                        _currentUserName ??
                                        ''),
                              name: (_currentUserName?.isNotEmpty == true)
                                  ? _currentUserName!
                                  : (_currentUserHandle?.isNotEmpty == true
                                        ? _currentUserHandle!
                                        : '나'),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextField(
                                controller: _commentController,
                                decoration: InputDecoration(
                                  hintText: _inputHintText(),
                                  hintStyle: TextStyle(
                                    fontFamily: 'Pretendard',
                                    color: AppColors.getTextTertiary(
                                      brightness,
                                    ),
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  filled: true,
                                  fillColor: AppColors.getBackgroundSecondary(
                                    brightness,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(22),
                                    borderSide: BorderSide.none,
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(22),
                                    borderSide: BorderSide.none,
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(22),
                                    borderSide: const BorderSide(
                                      color: AppColors.primary,
                                      width: 1.2,
                                    ),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 11,
                                  ),
                                  isDense: true,
                                ),
                                style: TextStyle(
                                  fontFamily: 'Pretendard',
                                  color: AppColors.getTextPrimary(brightness),
                                  fontSize: 14,
                                ),
                                maxLines: null,
                                textInputAction: TextInputAction.send,
                                onSubmitted: (_) => _submitComment(),
                              ),
                            ),
                            const SizedBox(width: 8),
                            ListenableBuilder(
                              listenable: _commentController,
                              builder: (context, _) {
                                final canSend = !_isSubmitting &&
                                    _commentController.text.trim().isNotEmpty;
                                return GestureDetector(
                                  onTap: canSend ? _submitComment : null,
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 160),
                                    width: 34,
                                    height: 34,
                                    decoration: BoxDecoration(
                                      color: canSend
                                          ? AppColors.primary
                                          : const Color(0xFFE8EAED),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      Icons.arrow_upward_rounded,
                                      size: 18,
                                      color: canSend
                                          ? Colors.white
                                          : const Color(0xFF9CA3AF),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                )
              else
                SafeArea(
                  top: false,
                  left: false,
                  right: false,
                  bottom: true,
                  minimum: EdgeInsets.zero,
                  maintainBottomViewPadding: true,
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    child: Center(
                      child: Text(
                        '댓글을 작성하려면 로그인이 필요합니다',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 13.5,
                          color: AppColors.getTextTertiary(brightness),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Circular avatar used inside the comment modal. Renders the user's photo
/// when available, otherwise the shared pastel `color + first letter` chip
/// so empty-profile users always look the same across the app.
class _CommentAvatar extends StatelessWidget {
  const _CommentAvatar({
    required this.radius,
    required this.photoUrl,
    required this.seed,
    required this.name,
  });

  final double radius;
  final String? photoUrl;
  final String seed;
  final String name;

  @override
  Widget build(BuildContext context) {
    final size = radius * 2;
    final hasPhoto = photoUrl != null && photoUrl!.isNotEmpty;
    if (hasPhoto) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: AppColors.primary.withOpacity(0.1),
        backgroundImage: AppNetworkImage.imageProviderForAvatar(photoUrl!),
      );
    }
    return UserInitialAvatar(seed: seed, name: name, size: size);
  }
}
