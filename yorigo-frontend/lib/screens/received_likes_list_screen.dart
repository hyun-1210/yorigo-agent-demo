import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../widgets/app_media_query_merge_nav_insets.dart';
import '../widgets/app_refresh_indicator.dart';
import '../services/review_service.dart';
import '../services/user_service.dart';
import '../widgets/app_network_image.dart';
import 'review_detail_screen.dart';

/// Reviews by [userId] that have at least one like, with liker hints. Tap opens detail.
class ReceivedLikesListScreen extends StatefulWidget {
  const ReceivedLikesListScreen({super.key, required this.userId});

  final String userId;

  @override
  State<ReceivedLikesListScreen> createState() =>
      _ReceivedLikesListScreenState();
}

class _ReceivedLikesListScreenState extends State<ReceivedLikesListScreen> {
  final ReviewService _reviewService = ReviewService();
  final UserService _userService = UserService();

  bool _loading = true;
  List<Map<String, dynamic>> _allSorted = [];
  List<Map<String, dynamic>> _withLikes = [];
  final Map<String, Map<String, dynamic>> _userCache = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  DateTime? _reviewDate(Map<String, dynamic> r) {
    final ts = r['createdAt'];
    if (ts is Timestamp) return ts.toDate();
    if (ts is DateTime) return ts;
    return null;
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await _reviewService.getUserReviews(widget.userId);
      list.sort((a, b) {
        final dateA = _reviewDate(a);
        final dateB = _reviewDate(b);
        if (dateA == null && dateB == null) return 0;
        if (dateA == null) return 1;
        if (dateB == null) return -1;
        return dateB.compareTo(dateA);
      });

      final withLikes = list.where((r) {
        final c = (r['likeCount'] as num?)?.toInt() ?? 0;
        return c > 0;
      }).toList();

      withLikes.sort((a, b) {
        final la = (a['likeCount'] as num?)?.toInt() ?? 0;
        final lb = (b['likeCount'] as num?)?.toInt() ?? 0;
        if (lb != la) return lb.compareTo(la);
        final da = _reviewDate(a);
        final db = _reviewDate(b);
        if (da == null || db == null) return 0;
        return db.compareTo(da);
      });

      final likerIds = <String>{};
      for (final r in withLikes) {
        final likedBy = r['likedBy'];
        if (likedBy is List) {
          for (final id in likedBy) {
            if (id is String && id.isNotEmpty) likerIds.add(id);
          }
        }
      }
      for (final uid in likerIds) {
        if (_userCache.containsKey(uid)) continue;
        try {
          final doc = await _userService.getUserDocument(uid);
          final data = doc.data() as Map<String, dynamic>?;
          _userCache[uid] = data ?? {};
        } catch (e) {
          debugPrint('[ReceivedLikesListScreen] user $uid: $e');
          _userCache[uid] = {};
        }
      }

      if (mounted) {
        setState(() {
          _allSorted = list;
          _withLikes = withLikes;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('[ReceivedLikesListScreen] load error: $e');
      if (mounted) {
        setState(() {
          _allSorted = [];
          _withLikes = [];
          _loading = false;
        });
      }
    }
  }

  String _likerSummary(Map<String, dynamic> review) {
    final likeCount = (review['likeCount'] as num?)?.toInt() ?? 0;
    final likedBy = List<String>.from(review['likedBy'] as List? ?? []);
    if (likedBy.isEmpty) {
      return '좋아요 $likeCount개';
    }
    final labels = <String>[];
    for (var i = 0; i < likedBy.length && labels.length < 3; i++) {
      final uid = likedBy[i];
      final d = _userCache[uid] ?? {};
      final handle = d['handle'] as String? ?? '';
      final name = d['name'] as String? ?? '';
      if (handle.isNotEmpty) {
        labels.add(handle.startsWith('@') ? handle : '@$handle');
      } else if (name.isNotEmpty) {
        labels.add(name);
      } else {
        labels.add('사용자');
      }
    }
    final shown = labels.length;
    final rest = likedBy.length - shown;
    var s = labels.join(', ');
    if (rest > 0) {
      s += ' 외 $rest명';
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF111111)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          '받은 좋아요',
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Color(0xFF111111),
          ),
        ),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _withLikes.isEmpty
              ? Center(
                  child: Text(
                    '아직 받은 좋아요가 없어요',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey.shade600,
                    ),
                  ),
                )
              : AppRefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      12,
                      16,
                      24 + appSystemNavBottomInset(context),
                    ),
                    itemCount: _withLikes.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final review = _withLikes[index];
                      final photoUrl = review['photoUrl'] as String?;
                      final title =
                          review['recipeTitle'] as String? ?? '레시피';
                      final globalIndex = _allSorted.indexWhere(
                        (r) => r['id'] == review['id'],
                      );
                      final openIndex = globalIndex >= 0 ? globalIndex : 0;

                      return Material(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (context) => ReviewDetailScreen(
                                  allReviews: _allSorted,
                                  initialIndex: openIndex,
                                ),
                              ),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: SizedBox(
                                    width: 56,
                                    height: 56,
                                    child: photoUrl != null &&
                                            photoUrl.isNotEmpty
                                        ? AppNetworkImage(
                                            imageUrl: photoUrl,
                                            width: 56,
                                            height: 56,
                                            fit: BoxFit.cover,
                                            // Width-only cap preserves
                                            // source aspect ratio on decode.
                                            memCacheWidth: 112,
                                          )
                                        : Container(
                                            color: const Color(0xFFFDF2F8),
                                            child: const Icon(
                                              Icons.favorite,
                                              color: Color(0xFFEC4899),
                                            ),
                                          ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontFamily: 'Pretendard',
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF111111),
                                          height: 1.3,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        _likerSummary(review),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
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
                                const Icon(
                                  Icons.chevron_right,
                                  color: Color(0xFF9CA3AF),
                                  size: 22,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
