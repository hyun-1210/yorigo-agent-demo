import 'package:cloud_firestore/cloud_firestore.dart';

/// A community 게시판 post. Lightweight, text-first content (think Karrot 동네생활,
/// Naver Cafe). Reviews and recipe-tied posts live in the `reviews` collection;
/// this is the open-ended discussion equivalent.
class BoardPost {
  const BoardPost({
    required this.id,
    required this.authorId,
    this.authorName,
    required this.category,
    required this.title,
    required this.body,
    required this.createdAt,
    this.updatedAt,
    this.likeCount = 0,
    this.commentCount = 0,
    this.viewCount = 0,
    this.isHidden = false,
    this.likedBy = const <String>{},
    this.recipeId,
    this.recipeTitle,
    this.recipeThumbnailUrl,
  });

  /// Firestore document id.
  final String id;

  /// Author's Firebase Auth uid (== users/{uid}).
  final String authorId;

  /// Denormalized display name so the detail screen can paint immediately.
  final String? authorName;

  /// One of [BoardCategory.id]s. We store the id string so we can rename
  /// labels without touching old rows.
  final String category;

  /// Short title shown in the list and at the top of the detail screen.
  final String title;

  /// Plain-text body. Markdown / rich content can come later if needed.
  final String body;

  final DateTime createdAt;
  final DateTime? updatedAt;

  final int likeCount;
  final int commentCount;
  final int viewCount;

  /// Set true by the report flow / admins; hidden rows are still readable by
  /// owner & admin but the feed filters them out.
  final bool isHidden;

  /// UIDs who liked this post (used to render the optimistic heart state).
  /// Kept as a Set to avoid duplicates when arrays grow.
  final Set<String> likedBy;

  /// Optional tagged recipe. Thumbnail is denormalized so the list
  /// can render without a second recipe fetch.
  final String? recipeId;
  final String? recipeTitle;
  final String? recipeThumbnailUrl;

  bool get hasTaggedRecipe =>
      (recipeId != null && recipeId!.isNotEmpty) ||
      (recipeThumbnailUrl != null && recipeThumbnailUrl!.isNotEmpty);

  factory BoardPost.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    return BoardPost.fromMap(doc.id, data);
  }

  factory BoardPost.fromMap(String id, Map<String, dynamic> data) {
    return BoardPost(
      id: id,
      authorId: (data['authorId'] as String?) ?? '',
      authorName: (data['authorName'] as String?)?.trim(),
      category: (data['category'] as String?) ?? BoardCategory.all.id,
      title: (data['title'] as String?) ?? '',
      body: (data['body'] as String?) ?? '',
      createdAt: _readDate(data['createdAt']) ?? DateTime.now(),
      updatedAt: _readDate(data['updatedAt']),
      likeCount: (data['likeCount'] as num?)?.toInt() ?? 0,
      commentCount: (data['commentCount'] as num?)?.toInt() ?? 0,
      viewCount: (data['viewCount'] as num?)?.toInt() ?? 0,
      isHidden: data['isHidden'] == true,
      likedBy: ((data['likedBy'] as List?) ?? const <dynamic>[])
          .map((e) => e.toString())
          .toSet(),
      recipeId: (data['recipeId'] as String?)?.trim(),
      recipeTitle: (data['recipeTitle'] as String?)?.trim(),
      recipeThumbnailUrl: (data['recipeThumbnailUrl'] as String?)?.trim(),
    );
  }

  static DateTime? _readDate(dynamic raw) {
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    return null;
  }

  bool isLikedBy(String? uid) =>
      uid != null && uid.isNotEmpty && likedBy.contains(uid);
}

/// User-facing board categories. Keep ids stable; labels can change.
class BoardCategory {
  const BoardCategory({required this.id, required this.label});

  final String id;
  final String label;

  static const all = BoardCategory(id: 'all', label: '전체');
  static const question = BoardCategory(id: 'question', label: '질문');
  static const today = BoardCategory(id: 'today', label: '오늘식사');
  static const share = BoardCategory(id: 'share', label: '레시피공유');
  static const fridge = BoardCategory(id: 'fridge', label: '냉장고파먹기');
  static const brag = BoardCategory(id: 'brag', label: '자랑');
  static const chat = BoardCategory(id: 'chat', label: '잡담');

  /// Categories shown in the filter pills. [all] is the first (default).
  static const List<BoardCategory> values = <BoardCategory>[
    all,
    question,
    today,
    share,
    fridge,
    brag,
    chat,
  ];

  /// Categories the compose sheet lets the author choose from
  /// (everything except the synthetic "전체").
  static const List<BoardCategory> writable = <BoardCategory>[
    question,
    today,
    share,
    fridge,
    brag,
    chat,
  ];

  static BoardCategory fromId(String? id) {
    if (id == null || id.isEmpty) return all;
    for (final c in values) {
      if (c.id == id) return c;
    }
    return all;
  }
}
