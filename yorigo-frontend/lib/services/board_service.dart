import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/board_post.dart';
import 'analytics_service.dart';
import 'rewards_service.dart';

/// CRUD + query layer for the community 게시판.
///
/// Collections used:
///   `board_posts/{postId}` — post documents
///   `board_posts/{postId}/comments/{commentId}` — flat comment thread
///   `board_posts/{postId}/views/{uid}` — one doc per uid so view counts
///     don't inflate on refresh from the same person
class BoardService {
  BoardService({FirebaseFirestore? firestore, FirebaseAuth? auth})
    : _firestore = firestore ?? FirebaseFirestore.instance,
      _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  CollectionReference<Map<String, dynamic>> get _postsCol =>
      _firestore.collection('board_posts');

  Future<String> _currentAuthorName() async {
    final user = _auth.currentUser;
    if (user == null) return '';
    final fromAuth = user.displayName?.trim() ?? '';
    if (fromAuth.isNotEmpty) return fromAuth;
    try {
      final snap = await _firestore.collection('users').doc(user.uid).get();
      final data = snap.data();
      final name = (data?['name'] as String?)?.trim() ?? '';
      if (name.isNotEmpty) return name;
      return (data?['handle'] as String?)?.trim() ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Real-time stream of posts, newest first, optionally filtered by
  /// [categoryId]. Hidden posts are filtered client-side because the rules
  /// already block reads on hidden rows for non-owners.
  Stream<List<BoardPost>> watchPosts({String? categoryId, int limit = 200}) {
    return _postsCol
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) => _filterPosts(snap.docs, categoryId));
  }

  /// One-shot fetch (used for non-streaming entry points like pull-to-refresh
  /// in screens that don't want a live subscription).
  Future<List<BoardPost>> fetchPosts({
    String? categoryId,
    int limit = 200,
    Source source = Source.serverAndCache,
  }) async {
    final snap = await _postsCol
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .get(GetOptions(source: source));
    return _filterPosts(snap.docs, categoryId);
  }

  List<BoardPost> _filterPosts(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    String? categoryId,
  ) {
    final filterCategory =
        categoryId != null &&
        categoryId.isNotEmpty &&
        categoryId != BoardCategory.all.id;
    return docs
        .map(BoardPost.fromDoc)
        .where((post) => !post.isHidden)
        .where((post) => !filterCategory || post.category == categoryId)
        .toList();
  }

  Future<BoardPost?> getPost(String id) async {
    final snap = await _postsCol.doc(id).get();
    if (!snap.exists) return null;
    return BoardPost.fromDoc(snap);
  }

  /// Posts that tagged this recipe. Equality-only so no composite index.
  Future<List<BoardPost>> fetchPostsForRecipe({
    String? recipeId,
    String? recipeTitle,
    int limit = 40,
  }) async {
    final seen = <String>{};
    final out = <BoardPost>[];

    Future<void> collect(Query<Map<String, dynamic>> query) async {
      final snap = await query.limit(limit).get();
      for (final doc in snap.docs) {
        final post = BoardPost.fromDoc(doc);
        if (post.isHidden || !seen.add(post.id)) continue;
        out.add(post);
      }
    }

    final id = recipeId?.trim() ?? '';
    if (id.isNotEmpty) {
      try {
        await collect(_postsCol.where('recipeId', isEqualTo: id));
      } catch (_) {}
    }
    final title = recipeTitle?.trim() ?? '';
    if (title.isNotEmpty) {
      try {
        await collect(_postsCol.where('recipeTitle', isEqualTo: title));
      } catch (_) {}
    }
    return out;
  }

  Stream<BoardPost?> watchPost(String id) {
    return _postsCol
        .doc(id)
        .snapshots()
        .map((snap) => snap.exists ? BoardPost.fromDoc(snap) : null);
  }

  /// Create a new post. Returns the new post id. Throws `StateError` if the
  /// user is signed out or required fields are empty.
  Future<String> createPost({
    required String category,
    required String title,
    required String body,
    String? recipeId,
    String? recipeTitle,
    String? recipeThumbnailUrl,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw StateError('로그인이 필요합니다');
    }
    final trimmedTitle = title.trim();
    final trimmedBody = body.trim();
    if (trimmedTitle.isEmpty) {
      throw ArgumentError('제목을 입력해주세요');
    }
    if (trimmedBody.isEmpty) {
      throw ArgumentError('내용을 입력해주세요');
    }
    final taggedId = recipeId?.trim() ?? '';
    final authorName = await _currentAuthorName();
    final doc = await _postsCol.add({
      'authorId': user.uid,
      if (authorName.isNotEmpty) 'authorName': authorName,
      'category': category,
      'title': trimmedTitle,
      'body': trimmedBody,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'likeCount': 0,
      'commentCount': 0,
      'viewCount': 0,
      'isHidden': false,
      'likedBy': <String>[],
      if (taggedId.isNotEmpty) ...{
        'recipeId': taggedId,
        'recipeTitle': (recipeTitle ?? '').trim(),
        'recipeThumbnailUrl': (recipeThumbnailUrl ?? '').trim(),
      },
    });
    // 최소 글자수 미달 게시물은 낮은 포인트로 다운그레이드 (품질 게이트).
    unawaited(
      RewardsService.instance.claimPostCreatedExp(
        postId: doc.id,
        bodyLength: trimmedBody.length,
      ),
    );
    unawaited(
      AnalyticsService().trackContentCreated(
        contentType: 'board_post',
        contentId: doc.id,
        categoryId: category,
      ),
    );
    return doc.id;
  }

  Future<void> updatePost(
    String id, {
    required String category,
    required String title,
    required String body,
    String? recipeId,
    String? recipeTitle,
    String? recipeThumbnailUrl,
  }) async {
    final trimmedTitle = title.trim();
    final trimmedBody = body.trim();
    if (trimmedTitle.isEmpty || trimmedBody.isEmpty) {
      throw ArgumentError('제목과 내용을 모두 입력해주세요');
    }
    final taggedId = recipeId?.trim() ?? '';
    await _postsCol.doc(id).update({
      'category': category,
      'title': trimmedTitle,
      'body': trimmedBody,
      'updatedAt': FieldValue.serverTimestamp(),
      if (taggedId.isEmpty) ...{
        'recipeId': FieldValue.delete(),
        'recipeTitle': FieldValue.delete(),
        'recipeThumbnailUrl': FieldValue.delete(),
      } else ...{
        'recipeId': taggedId,
        'recipeTitle': (recipeTitle ?? '').trim(),
        'recipeThumbnailUrl': (recipeThumbnailUrl ?? '').trim(),
      },
    });
  }

  Future<void> deletePost(String id) async {
    await _postsCol.doc(id).delete();
  }

  /// Toggle like for the current user. Uses a transaction so the counter and
  /// the `likedBy` array stay in sync even with concurrent taps.
  Future<bool> toggleLike(String postId) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw StateError('로그인이 필요합니다');
    }
    final ref = _postsCol.doc(postId);
    String? authorId;
    final liked = await _firestore.runTransaction<bool>((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) {
        throw StateError('이미 삭제된 게시글입니다');
      }
      final data = snap.data() as Map<String, dynamic>;
      authorId = data['authorId']?.toString();
      final likedBy = ((data['likedBy'] as List?) ?? const <dynamic>[])
          .map((e) => e.toString())
          .toSet();
      final currentCount = (data['likeCount'] as num?)?.toInt() ?? 0;
      final isLiked = likedBy.contains(user.uid);
      if (isLiked) {
        tx.update(ref, {
          'likedBy': FieldValue.arrayRemove(<String>[user.uid]),
          'likeCount': (currentCount - 1).clamp(0, 1 << 30),
        });
        return false;
      } else {
        tx.update(ref, {
          'likedBy': FieldValue.arrayUnion(<String>[user.uid]),
          'likeCount': currentCount + 1,
        });
        return true;
      }
    });
    if (liked) {
      unawaited(
        RewardsService.instance.claimLikeExp(
          contentId: postId,
          authorId: authorId,
        ),
      );
    }
    unawaited(
      AnalyticsService().trackContentLiked(
        contentType: 'board_post',
        contentId: postId,
        liked: liked,
        authorId: authorId,
      ),
    );
    return liked;
  }

  /// "인기글 도달" 보너스(좋아요 30개↑, 게시글당 1회)는 좋아요를 누른 사람이
  /// 아니라 글쓴이에게 지급돼야 한다. RewardsService.claim은 호출자 본인의
  /// Firebase 세션으로만 지급 가능하므로(보안상 타인 앞 지급 불가), 작성자
  /// 본인이 자신의 게시물을 조회하는 시점(피드/내 게시물 목록 등)에 캐치업
  /// 방식으로 지급한다. 서버 idempotency key가 중복 지급을 막아주므로 이
  /// 메서드는 여러 번 호출해도 안전하다.
  void checkAndClaimPopularPostBonus(BoardPost post) {
    final user = _auth.currentUser;
    if (user == null || post.authorId != user.uid) return;
    RewardsService.instance.claimAuthorSocialMilestones(
      contentId: post.id,
      authorId: post.authorId,
      likeCount: post.likeCount,
      commentCount: post.commentCount,
    );
  }

  /// Increment view count once per uid. Idempotent — calling repeatedly from
  /// the same uid is cheap (just a no-op `set` on a marker doc) and won't
  /// double-count.
  Future<void> registerView(String postId) async {
    final user = _auth.currentUser;
    if (user == null) return;
    final markerRef = _postsCol.doc(postId).collection('views').doc(user.uid);
    final marker = await markerRef.get();
    if (marker.exists) return;
    final batch = _firestore.batch();
    batch.set(markerRef, {'viewedAt': FieldValue.serverTimestamp()});
    batch.update(_postsCol.doc(postId), {'viewCount': FieldValue.increment(1)});
    await batch.commit();
    unawaited(
      AnalyticsService().logCardEvent(
        'impression',
        screen: 'community',
        sectionId: 'board_post_view',
        cardId: postId,
        contentType: 'board_post',
      ),
    );
  }

  // -------------- Comments --------------

  CollectionReference<Map<String, dynamic>> _commentsCol(String postId) =>
      _postsCol.doc(postId).collection('comments');

  Stream<List<BoardComment>> watchComments(String postId) {
    // Filter hidden rows client-side so we don't need a composite
    // `isHidden + createdAt` index (missing index made the stream fail
    // and the UI looked empty even after commentCount ticked up).
    return _commentsCol(postId)
        .orderBy('createdAt', descending: false)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map(BoardComment.fromDoc)
              .where((c) => !c.isHidden)
              .toList(),
        );
  }

  Future<void> addComment(String postId, String text) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw StateError('로그인이 필요합니다');
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('내용을 입력해주세요');
    }
    final commentsCol = _commentsCol(postId);
    final postRef = _postsCol.doc(postId);
    final batch = _firestore.batch();
    final commentRef = commentsCol.doc();
    final authorName = await _currentAuthorName();
    batch.set(commentRef, {
      'authorId': user.uid,
      if (authorName.isNotEmpty) 'authorName': authorName,
      'text': trimmed,
      'createdAt': FieldValue.serverTimestamp(),
      'isHidden': false,
    });
    batch.update(postRef, {'commentCount': FieldValue.increment(1)});
    await batch.commit();
    // 스팸/무의미 반복 텍스트 최소 방어 — 너무 짧은 댓글은 포인트 미지급.
    if (trimmed.length >= 5) {
      unawaited(
        RewardsService.instance.claimCommentExp(
          commentId: commentRef.id,
          sourceRef: postId,
          textLength: trimmed.length,
        ),
      );
    }
    unawaited(
      AnalyticsService().trackContentCreated(
        contentType: 'board_comment',
        contentId: commentRef.id,
        parentId: postId,
      ),
    );
  }

  Future<void> deleteComment(String postId, String commentId) async {
    final postRef = _postsCol.doc(postId);
    final commentRef = _commentsCol(postId).doc(commentId);
    final batch = _firestore.batch();
    batch.delete(commentRef);
    batch.update(postRef, {'commentCount': FieldValue.increment(-1)});
    await batch.commit();
  }
}

/// Comment on a board post.
class BoardComment {
  const BoardComment({
    required this.id,
    required this.authorId,
    this.authorName,
    required this.text,
    required this.createdAt,
    this.isHidden = false,
  });

  final String id;
  final String authorId;
  final String? authorName;
  final String text;
  final DateTime createdAt;
  final bool isHidden;

  factory BoardComment.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    DateTime createdAt;
    final raw = data['createdAt'];
    if (raw is Timestamp) {
      createdAt = raw.toDate();
    } else if (raw is DateTime) {
      createdAt = raw;
    } else {
      createdAt = DateTime.now();
    }
    return BoardComment(
      id: doc.id,
      authorId: (data['authorId'] as String?) ?? '',
      authorName: (data['authorName'] as String?)?.trim(),
      text: (data['text'] as String?) ?? '',
      createdAt: createdAt,
      isHidden: data['isHidden'] == true,
    );
  }
}
