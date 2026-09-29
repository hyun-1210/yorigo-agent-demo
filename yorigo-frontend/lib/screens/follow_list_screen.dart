import 'package:flutter/material.dart';
import '../services/user_service.dart';
import '../widgets/app_media_query_merge_nav_insets.dart';
import '../widgets/app_network_image.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/default_profile_avatar.dart';

enum FollowListKind { followers, following }

/// Lists followers or people this user follows, with avatar / name / handle.
/// Tapping a row opens that user's profile via named route (no circular imports).
class FollowListScreen extends StatefulWidget {
  const FollowListScreen({super.key, required this.userId, required this.kind});

  final String userId;
  final FollowListKind kind;

  @override
  State<FollowListScreen> createState() => _FollowListScreenState();
}

class _FollowListScreenState extends State<FollowListScreen> {
  final UserService _userService = UserService();
  bool _loading = true;
  List<Map<String, dynamic>> _users = [];

  String get _title => widget.kind == FollowListKind.followers ? '팔로워' : '팔로잉';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = widget.kind == FollowListKind.followers
          ? await _userService.getFollowers(widget.userId, limit: 500)
          : await _userService.getFollowing(widget.userId, limit: 500);
      if (mounted) {
        setState(() {
          _users = list;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('[FollowListScreen] load error: $e');
      if (mounted) {
        setState(() {
          _users = [];
          _loading = false;
        });
      }
    }
  }

  void _openProfile(String uid) {
    Navigator.of(
      context,
    ).pushNamed('/profile', arguments: <String, dynamic>{'userId': uid});
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
        title: Text(
          _title,
          style: const TextStyle(
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
          : _users.isEmpty
          ? Center(
              child: Text(
                widget.kind == FollowListKind.followers
                    ? '아직 팔로워가 없어요'
                    : '아직 팔로잉이 없어요',
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
                  8,
                  16,
                  24 + appSystemNavBottomInset(context),
                ),
                itemCount: _users.length,
                separatorBuilder: (_, __) => const SizedBox(height: 4),
                itemBuilder: (context, index) {
                  final u = _users[index];
                  final uid = u['uid'] as String? ?? '';
                  final name = (u['name'] as String?)?.trim() ?? '';
                  final handleRaw = (u['handle'] as String?)?.trim() ?? '';
                  final handle = handleRaw.isEmpty
                      ? ''
                      : (handleRaw.startsWith('@') ? handleRaw : '@$handleRaw');
                  final photoUrl = u['photoUrl'] as String?;
                  final titleText = name.isNotEmpty
                      ? name
                      : (handle.isNotEmpty ? handle : '사용자');
                  final subtitle = name.isNotEmpty && handle.isNotEmpty
                      ? handle
                      : (name.isNotEmpty ? '' : '');

                  return Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: uid.isEmpty ? null : () => _openProfile(uid),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            ClipOval(
                              child: SizedBox(
                                width: 48,
                                height: 48,
                                child: photoUrl != null && photoUrl.isNotEmpty
                                    ? Image(
                                        image:
                                            AppNetworkImage.imageProviderForAvatar(
                                              photoUrl,
                                            ),
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) =>
                                            DefaultProfileAvatar(
                                              size: 48,
                                              seed: uid.isNotEmpty
                                                  ? uid
                                                  : titleText,
                                              name: titleText,
                                            ),
                                      )
                                    : DefaultProfileAvatar(
                                        size: 48,
                                        seed: uid.isNotEmpty ? uid : titleText,
                                        name: titleText,
                                      ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    titleText,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontFamily: 'Pretendard',
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF111111),
                                    ),
                                  ),
                                  if (subtitle.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      subtitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontFamily: 'Pretendard',
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        color: Color(0xFF9CA3AF),
                                      ),
                                    ),
                                  ],
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
