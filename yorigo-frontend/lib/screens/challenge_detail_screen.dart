import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/community_challenge.dart';
import '../services/challenge_service.dart';
import '../services/review_service.dart';
import '../widgets/app_confirm_dialog.dart';
import '../widgets/app_toast.dart';
import '../widgets/community_social_cards.dart';
import '../widgets/progressive_recipe_review_sheet.dart';
import '../widgets/review_post_action_sheets.dart';

class ChallengeDetailScreen extends StatefulWidget {
  const ChallengeDetailScreen({super.key, required this.challengeId});

  final String challengeId;

  @override
  State<ChallengeDetailScreen> createState() => _ChallengeDetailScreenState();
}

class _ChallengeDetailScreenState extends State<ChallengeDetailScreen> {
  final _service = ChallengeService.instance;
  bool _loading = true;
  bool _busy = false;
  CommunityChallenge? _challenge;
  ChallengeParticipant? _mine;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;
  bool get _isCreator => _challenge != null && _challenge!.createdBy == _uid;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final challenge = await _service.getChallenge(widget.challengeId);
      final mine = challenge == null
          ? null
          : await _service.getMyParticipant(widget.challengeId);
      if (!mounted) return;
      setState(() {
        _challenge = challenge;
        _mine = mine;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _run(Future<void> Function() action, {String? ok}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _load();
      if (mounted && ok != null) AppToast.success(context, ok);
    } catch (e) {
      if (mounted) {
        AppToast.error(context, e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitReviewId(String reviewId) async {
    final completed = await _service.submitProof(
      challengeId: widget.challengeId,
      reviewId: reviewId,
    );
    await _load();
    if (!mounted) return;
    AppToast.success(context, completed ? '챌린지를 완료했어요' : '인증했어요');
  }

  Future<void> _proveWithNewReview() async {
    String? createdId;
    await showProgressiveRecipeReviewPopup(
      context,
      recipeId: '',
      recipeTitle: '나의 요리',
      creatorUsername: '',
      platform: 'manual',
      servings: 1,
      isFreeform: true,
      fromCookingFlow: false,
      onReviewCreated: (id) => createdId = id,
    );
    if (createdId != null && createdId!.isNotEmpty) {
      await _run(() => _submitReviewId(createdId!));
    }
  }

  Future<void> _proveWithExisting() async {
    final reviews = await ReviewService().getRecentUserReviews(limit: 20);
    if (!mounted) return;
    if (reviews.isEmpty) {
      AppToast.info(context, '최근 요리 기록이 없어요');
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => ListView(
        children: [
          for (final r in reviews)
            ListTile(
              title: Text((r['recipeTitle'] as String?) ?? '나의 요리'),
              subtitle: Text((r['comment'] as String?) ?? ''),
              onTap: () => Navigator.pop(ctx, r['id'] as String?),
            ),
        ],
      ),
    );
    if (picked == null || picked.isEmpty) return;
    await _run(() => _submitReviewId(picked));
  }

  Future<void> _startProof() async {
    if (_mine == null) {
      if (_challenge?.isOfficial == true) {
        await _run(
          () => _service.joinChallenge(challengeId: widget.challengeId),
          ok: '참여했어요',
        );
      }
      return;
    }
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('새 요리 기록으로 인증'),
              onTap: () => Navigator.pop(ctx, 'new'),
            ),
            ListTile(
              title: const Text('기존 기록 선택'),
              onTap: () => Navigator.pop(ctx, 'existing'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'new') await _proveWithNewReview();
    if (choice == 'existing') await _proveWithExisting();
  }

  @override
  Widget build(BuildContext context) {
    final challenge = _challenge;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('챌린지'),
        actions: [
          if (challenge?.inviteCode != null &&
              challenge!.inviteCode!.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.copy_rounded),
              onPressed: () async {
                final code = challenge.inviteCode!;
                await Clipboard.setData(ClipboardData(text: code));
                if (!context.mounted) return;
                AppToast.success(context, '초대코드를 복사했어요');
              },
            ),
          if (challenge != null)
            IconButton(
              icon: const Icon(Icons.more_horiz),
              onPressed: () {
                showReviewPostMenuBottomSheet(
                  context,
                  isOwnPost: _isCreator,
                  shareText: challenge.inviteCode == null
                      ? challenge.title
                      : '${challenge.title} 코드 ${challenge.inviteCode}',
                  onDelete: _isCreator
                      ? () async {
                          final ok = await AppConfirmDialog.show(
                            context: context,
                            title: '챌린지를 취소할까요?',
                            confirmLabel: '취소하기',
                            destructive: true,
                          );
                          if (ok == true) {
                            await _run(
                              () => _service.cancelChallenge(challenge.id),
                            );
                          }
                        }
                      : null,
                  onOpenReport: _isCreator
                      ? null
                      : () => showReviewReportBottomSheet(
                            context,
                            type: 'challenge',
                            targetId: challenge.id,
                          ),
                );
              },
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : challenge == null
              ? const Center(child: Text('챌린지를 찾을 수 없어요'))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                  children: [
                    CommunitySoftChip(
                      label: challenge.tag.isEmpty
                          ? (challenge.isOfficial ? '공식' : '친구')
                          : challenge.tag,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      challenge.title,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: kCommunityInk,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      challenge.subtitle,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 15,
                        color: kCommunityInkSub,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '인증 ${_mine?.proofCount ?? 0}/${challenge.requiredProofCount}'
                      '${challenge.proofMode == ChallengeProofMode.consecutiveDays ? ' · 연속 날짜' : ''}',
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (challenge.isOfficial) ...[
                      const SizedBox(height: 8),
                      Text(
                        '${challenge.participantCount}명 참여 · 목표 ${challenge.goalParticipantCount}명',
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          color: kCommunityMuted,
                        ),
                      ),
                    ],
                    if (challenge.inviteCode != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        '초대코드 ${challenge.inviteCode}',
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ],
                    if (challenge.description.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        challenge.description,
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 15,
                          height: 1.5,
                        ),
                      ),
                    ],
                    const SizedBox(height: 28),
                    if (!challenge.cancelled)
                      FilledButton(
                        onPressed: _busy ? null : _startProof,
                        style: FilledButton.styleFrom(
                          backgroundColor: kCommunityOrange,
                          minimumSize: const Size.fromHeight(48),
                        ),
                        child: Text(
                          _mine == null
                              ? '참여하기'
                              : (_mine!.isCompleted ? '완료됨' : '요리 기록으로 인증'),
                        ),
                      ),
                    if (_mine != null && !_isCreator) ...[
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _run(
                                  () => _service.leaveChallenge(challenge.id),
                                ),
                        child: const Text('나가기'),
                      ),
                    ],
                  ],
                ),
    );
  }
}
