import 'package:flutter/material.dart';

import '../models/community_challenge.dart';
import '../services/admin_service.dart';
import '../services/challenge_service.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/community_social_cards.dart';
import 'admin_challenge_compose_screen.dart';
import 'challenge_detail_screen.dart';
import 'friend_challenge_compose_screen.dart';
import 'join_challenge_code_sheet.dart';

class ChallengeTab extends StatefulWidget {
  const ChallengeTab({super.key, this.scrollController});

  final ScrollController? scrollController;

  @override
  State<ChallengeTab> createState() => _ChallengeTabState();
}

class _ChallengeTabState extends State<ChallengeTab> {
  final _service = ChallengeService.instance;
  bool _loading = true;
  bool _isAdmin = false;
  List<CommunityChallenge> _official = const [];
  List<CommunityChallenge> _mine = const [];

  @override
  void initState() {
    super.initState();
    _service.listRevision.addListener(_onListRevision);
    _load();
  }

  void _onListRevision() {
    _load(force: true);
  }

  @override
  void dispose() {
    _service.listRevision.removeListener(_onListRevision);
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    try {
      final official = await _service.fetchOfficialActive(forceRefresh: force);
      final mine = await _service.fetchMyChallenges(forceRefresh: force);
      final isAdmin = await AdminService.instance.isAdmin();
      if (!mounted) return;
      setState(() {
        _official = official;
        _mine = mine;
        _isAdmin = isAdmin;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _open(CommunityChallenge challenge) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ChallengeDetailScreen(challengeId: challenge.id),
      ),
    );
    if (mounted) await _load(force: true);
  }

  List<CommunityChallenge> get _friends =>
      _mine.where((c) => c.isFriend).toList();

  @override
  Widget build(BuildContext context) {
    return AppRefreshIndicator(
      onRefresh: () => _load(force: true),
      child: ListView(
        controller: widget.scrollController,
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
        children: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(top: 48),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            CommunitySectionHeader(
              title: '이번 주 챌린지',
              description: '같이 도전하고 함께 즐겨요',
              trailing: _isAdmin
                  ? TextButton(
                      onPressed: () async {
                        final created = await Navigator.of(context).push<bool>(
                          MaterialPageRoute(
                            builder: (_) => const AdminChallengeComposeScreen(),
                          ),
                        );
                        if (created == true) await _load(force: true);
                      },
                      child: const Text('공식 만들기'),
                    )
                  : null,
            ),
            const SizedBox(height: 14),
            if (_official.isEmpty)
              const CommunityEmptyState(message: '진행 중인 공식 챌린지가 없어요')
            else
              ..._official.map(
                (c) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: CommunityChallengeCard(
                    tag: c.tag.isEmpty ? '공식' : c.tag,
                    title: c.title,
                    subtitle: c.subtitle,
                    progress: c.progress,
                    progressLabel: '${c.participantCount}명',
                    progressGoal: '목표 ${c.goalParticipantCount}명',
                    onTap: () => _open(c),
                  ),
                ),
              ),
            const SizedBox(height: 22),
            CommunitySectionHeader(
              title: '친구끼리 챌린지',
              description: '가까운 사람과 가볍게 이겨봐요',
              trailing: TextButton(
                onPressed: () async {
                  final id = await showJoinChallengeCodeSheet(context);
                  if (!context.mounted || id == null || id.isEmpty) return;
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ChallengeDetailScreen(challengeId: id),
                    ),
                  );
                  if (mounted) await _load(force: true);
                },
                child: const Text('코드로 참여'),
              ),
            ),
            const SizedBox(height: 14),
            if (_friends.isEmpty)
              CommunityEmptyState(
                message: '참여 중인 친구 챌린지가 없어요',
                actionLabel: '친구 챌린지 만들기',
                onAction: () async {
                  final created = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => const FriendChallengeComposeScreen(),
                    ),
                  );
                  if (created == true) await _load(force: true);
                },
              )
            else
              ..._friends.map(
                (c) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: CommunityChallengeCard(
                    tag: c.tag.isEmpty ? '친구' : c.tag,
                    title: c.title,
                    subtitle: c.subtitle,
                    onTap: () => _open(c),
                  ),
                ),
              ),
            const SizedBox(height: 22),
            const CommunitySectionHeader(
              title: '내 챌린지',
              description: '참여 중인 챌린지를 한눈에 봐요',
            ),
            const SizedBox(height: 14),
            if (_mine.isEmpty)
              const CommunityEmptyState(message: '참여 중인 챌린지가 없어요')
            else
              ..._mine.map(
                (c) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: CommunityChallengeCard(
                    tag: c.isOfficial ? '공식' : '친구',
                    title: c.title,
                    subtitle: c.subtitle,
                    onTap: () => _open(c),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
