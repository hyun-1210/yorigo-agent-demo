import 'package:flutter/material.dart';

import '../models/meetup.dart';
import '../services/meetup_service.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/community_social_cards.dart';
import 'meetup_compose_screen.dart';
import 'meetup_detail_screen.dart';

String formatMeetupWhen(DateTime dt) {
  const days = ['월', '화', '수', '목', '금', '토', '일'];
  final w = days[dt.weekday - 1];
  final h = dt.hour;
  final ampm = h < 12 ? '오전' : '오후';
  final hour12 = h % 12 == 0 ? 12 : h % 12;
  return '${dt.month}.${dt.day}($w) $ampm $hour12시';
}

String formatKrw(int krw) {
  if (krw <= 0) return '무료';
  final raw = krw.toString();
  final buf = StringBuffer();
  for (var i = 0; i < raw.length; i++) {
    final left = raw.length - i;
    buf.write(raw[i]);
    if (left > 1 && left % 3 == 1) buf.write(',');
  }
  return '${buf}원';
}

class MeetupTab extends StatefulWidget {
  const MeetupTab({super.key, this.scrollController});

  final ScrollController? scrollController;

  @override
  State<MeetupTab> createState() => _MeetupTabState();
}

class _MeetupTabState extends State<MeetupTab> {
  final _service = MeetupService.instance;
  bool _loading = true;
  String? _error;
  List<Meetup> _meetups = const [];

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
      final list = await _service.fetchUpcoming(forceRefresh: force);
      if (!mounted) return;
      setState(() {
        _meetups = list;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _openCompose() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const MeetupComposeScreen()),
    );
    if (created == true) await _load(force: true);
  }

  Future<void> _openDetail(Meetup meetup) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => MeetupDetailScreen(meetupId: meetup.id)),
    );
    if (mounted) await _load(force: true);
  }

  @override
  Widget build(BuildContext context) {
    final groups = _meetups
        .where((m) => m.kind == MeetupKind.smallGroup)
        .toList();
    final classes = _meetups
        .where((m) => m.kind == MeetupKind.openClass)
        .toList();

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
          else if (_error != null)
            CommunityEmptyState(message: '모임을 불러오지 못했어요')
          else ...[
            CommunitySectionHeader(
              title: '요리 소모임',
              description: '취향 맞는 사람들과 같이 요리해요',
            ),
            const SizedBox(height: 14),
            if (groups.isEmpty)
              CommunityEmptyState(
                message: '열린 소모임이 없어요',
                actionLabel: '모임 만들기',
                onAction: _openCompose,
              )
            else
              ...groups.map((m) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: CommunityMeetupCard(
                      title: m.title,
                      subtitle: m.subtitle,
                      meta: '${m.placeText} · ${formatMeetupWhen(m.startsAt)}',
                      tag: m.tag.isEmpty ? '모임' : m.tag,
                      trailing: '${m.memberCount}/${m.capacity}명',
                      icon: meetupIconFromKey(m.iconKey),
                      cancelled: m.cancelled,
                      onTap: () => _openDetail(m),
                    ),
                  )),
            const SizedBox(height: 22),
            const CommunitySectionHeader(
              title: '오픈 클래스',
              description: '셰프에게 직접 배워보세요',
            ),
            const SizedBox(height: 14),
            if (classes.isEmpty)
              const CommunityEmptyState(message: '예정된 오픈 클래스가 없어요')
            else
              ...classes.map((m) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: CommunityMeetupCard(
                      title: m.title,
                      subtitle: m.subtitle,
                      meta:
                          '${m.meetingFormat == MeetupMeetingFormat.live ? 'LIVE' : '오프라인'} · ${formatMeetupWhen(m.startsAt)}',
                      tag: m.priceKrw > 0 ? formatKrw(m.priceKrw) : '무료',
                      trailing: '${m.memberCount}/${m.capacity}자리',
                      icon: meetupIconFromKey(m.iconKey),
                      cancelled: m.cancelled,
                      onTap: () => _openDetail(m),
                    ),
                  )),
          ],
        ],
      ),
    );
  }
}
