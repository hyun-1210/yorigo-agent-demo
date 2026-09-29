import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/meetup.dart';
import '../services/meetup_service.dart';
import '../widgets/app_confirm_dialog.dart';
import '../widgets/app_toast.dart';
import '../widgets/community_social_cards.dart';
import '../widgets/review_post_action_sheets.dart';
import 'meetup_compose_screen.dart';
import 'meetup_tab.dart';

class MeetupDetailScreen extends StatefulWidget {
  const MeetupDetailScreen({super.key, required this.meetupId});

  final String meetupId;

  @override
  State<MeetupDetailScreen> createState() => _MeetupDetailScreenState();
}

class _MeetupDetailScreenState extends State<MeetupDetailScreen> {
  final _service = MeetupService.instance;
  bool _loading = true;
  bool _busy = false;
  Meetup? _meetup;
  List<MeetupAttendee> _attendees = const [];
  MeetupAttendee? _mine;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;
  bool get _isHost => _meetup != null && _meetup!.hostId == _uid;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final meetup = await _service.getMeetup(widget.meetupId);
      final attendees = meetup == null
          ? const <MeetupAttendee>[]
          : await _service.fetchAttendees(widget.meetupId);
      final mine = attendees.where((a) => a.uid == _uid).firstOrNull;
      if (!mounted) return;
      setState(() {
        _meetup = meetup;
        _attendees = attendees;
        _mine = mine;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      AppToast.error(context, '모임을 불러오지 못했어요');
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _load();
    } catch (e) {
      if (mounted) {
        AppToast.error(context, e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _joinOrApply() async {
    final meetup = _meetup;
    if (meetup == null) return;
    if (meetup.isPaid) {
      await _run(() => _service.applyOpenClass(meetup.id));
      if (mounted) AppToast.success(context, '신청했어요. 호스트 수락을 기다려 주세요');
    } else {
      await _run(() => _service.joinMeetup(meetup.id));
      if (mounted) AppToast.success(context, '참여했어요');
    }
  }

  Future<void> _leave() async {
    final meetup = _meetup;
    if (meetup == null) return;
    if (_mine?.isApplied == true) {
      await _run(() => _service.withdrawApplication(meetup.id));
      return;
    }
    await _run(() => _service.leaveMeetup(meetup.id));
  }

  Future<void> _cancel() async {
    final ok = await AppConfirmDialog.show(
      context: context,
      title: '모임을 취소할까요?',
      description: '참가자에게는 다음 조회 때 취소로 보여요.',
      confirmLabel: '취소하기',
      destructive: true,
    );
    if (ok != true) return;
    await _run(() => _service.cancelMeetup(widget.meetupId));
  }

  @override
  Widget build(BuildContext context) {
    final meetup = _meetup;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('모임'),
        actions: [
          if (meetup != null)
            IconButton(
              icon: const Icon(Icons.more_horiz),
              onPressed: () {
                showReviewPostMenuBottomSheet(
                  context,
                  isOwnPost: _isHost,
                  shareText: '${meetup.title} · ${meetup.placeText}',
                  onEdit: _isHost
                      ? () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  MeetupComposeScreen(existing: meetup),
                            ),
                          ).then((_) => _load());
                        }
                      : null,
                  onDelete: _isHost ? _cancel : null,
                  onOpenReport: _isHost
                      ? null
                      : () {
                          showReviewReportBottomSheet(
                            context,
                            type: 'meetup',
                            targetId: meetup.id,
                          );
                        },
                );
              },
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : meetup == null
              ? const Center(child: Text('모임을 찾을 수 없어요'))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                  children: [
                    CommunitySoftChip(
                      label: meetup.kind == MeetupKind.openClass
                          ? '오픈 클래스'
                          : '소모임',
                    ),
                    const SizedBox(height: 12),
                    Text(
                      meetup.cancelled ? '${meetup.title} (취소됨)' : meetup.title,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: kCommunityInk,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      meetup.subtitle,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 15,
                        color: kCommunityInkSub,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '${meetup.placeText} · ${formatMeetupWhen(meetup.startsAt)}',
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: kCommunityMuted,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${meetup.memberCount}/${meetup.capacity}명'
                      '${meetup.isPaid ? ' · ${formatKrw(meetup.priceKrw)}' : ''}',
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: kCommunityInkSub,
                      ),
                    ),
                    if (meetup.description.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      Text(
                        meetup.description,
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 15,
                          height: 1.5,
                          color: kCommunityInk,
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    const Text(
                      '참가자',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ..._attendees.where((a) => a.isJoined).map(
                          (a) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              a.isHost ? '${a.name} · 호스트' : a.name,
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                    if (_isHost) ...[
                      const SizedBox(height: 12),
                      const Text(
                        '신청',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      ..._attendees.where((a) => a.isApplied).map(
                            (a) => ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(a.name),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _run(
                                              () => _service.confirmOpenClass(
                                                meetupId: meetup.id,
                                                targetUid: a.uid,
                                              ),
                                            ),
                                    child: const Text('수락'),
                                  ),
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _run(
                                              () => _service.rejectApplication(
                                                meetupId: meetup.id,
                                                targetUid: a.uid,
                                              ),
                                            ),
                                    child: const Text('거절'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                    ],
                    const SizedBox(height: 24),
                    if (!meetup.cancelled && !_isHost)
                      FilledButton(
                        onPressed: _busy || meetup.isPast
                            ? null
                            : (_mine == null
                                ? (meetup.isFull && !meetup.isPaid
                                    ? null
                                    : _joinOrApply)
                                : _leave),
                        style: FilledButton.styleFrom(
                          backgroundColor: kCommunityOrange,
                          minimumSize: const Size.fromHeight(48),
                        ),
                        child: Text(
                          _mine == null
                              ? (meetup.isPaid ? '신청하기' : '참여하기')
                              : (_mine!.isApplied ? '신청 취소' : '나가기'),
                        ),
                      ),
                  ],
                ),
    );
  }
}
