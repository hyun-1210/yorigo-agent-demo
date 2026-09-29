import 'package:flutter/material.dart';

import '../models/meetup.dart';
import '../services/meetup_service.dart';
import '../theme/app_colors.dart';
import '../widgets/app_toast.dart';
import '../widgets/community_social_cards.dart';

class MeetupComposeScreen extends StatefulWidget {
  const MeetupComposeScreen({super.key, this.existing});

  final Meetup? existing;

  @override
  State<MeetupComposeScreen> createState() => _MeetupComposeScreenState();
}

class _MeetupComposeScreenState extends State<MeetupComposeScreen> {
  final _title = TextEditingController();
  final _subtitle = TextEditingController();
  final _description = TextEditingController();
  final _tag = TextEditingController();
  final _place = TextEditingController();
  final _recurrence = TextEditingController();
  final _price = TextEditingController();
  MeetupKind _kind = MeetupKind.smallGroup;
  MeetupMeetingFormat _format = MeetupMeetingFormat.offline;
  DateTime _startsAt = DateTime.now().add(const Duration(days: 2, hours: 2));
  int _capacity = 8;
  int _priceKrw = 0;
  String _iconKey = 'restaurant_menu';
  bool _submitting = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing != null) {
      _kind = existing.kind;
      _title.text = existing.title;
      _subtitle.text = existing.subtitle;
      _description.text = existing.description;
      _tag.text = existing.tag;
      _place.text = existing.placeText;
      _recurrence.text = existing.recurrenceNote ?? '';
      _startsAt = existing.startsAt;
      _capacity = existing.capacity;
      _priceKrw = existing.priceKrw;
      _price.text = existing.priceKrw == 0 ? '' : '${existing.priceKrw}';
      _format = existing.meetingFormat;
      _iconKey = existing.iconKey;
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _subtitle.dispose();
    _description.dispose();
    _tag.dispose();
    _place.dispose();
    _recurrence.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _pickDateTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _startsAt,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_startsAt),
    );
    if (time == null || !mounted) return;
    setState(() {
      _startsAt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      if (_isEdit) {
        await MeetupService.instance.updateMeetup(
          widget.existing!.id,
          title: _title.text,
          subtitle: _subtitle.text,
          description: _description.text,
          tag: _tag.text,
          placeText: _place.text,
          startsAt: _startsAt,
          capacity: _capacity,
          meetingFormat: _format == MeetupMeetingFormat.live ? 'live' : 'offline',
          iconKey: _iconKey,
          recurrenceNote: _recurrence.text,
        );
      } else {
        await MeetupService.instance.createMeetup(
          kind: _kind,
          title: _title.text,
          subtitle: _subtitle.text,
          description: _description.text,
          tag: _tag.text,
          placeText: _place.text,
          startsAt: _startsAt,
          capacity: _capacity,
          meetingFormat: _format == MeetupMeetingFormat.live ? 'live' : 'offline',
          priceKrw: _kind == MeetupKind.openClass ? _priceKrw : 0,
          iconKey: _iconKey,
          recurrenceNote: _recurrence.text,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      AppToast.error(context, e.toString().replaceFirst('Bad state: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(_isEdit ? '모임 수정' : '모임 만들기'),
        actions: [
          TextButton(
            onPressed: _submitting ? null : _submit,
            child: Text(
              _isEdit ? '저장' : '올리기',
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontWeight: FontWeight.w800,
                color: kCommunityOrange,
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          if (!_isEdit)
            SegmentedButton<MeetupKind>(
              segments: const [
                ButtonSegment(value: MeetupKind.smallGroup, label: Text('소모임')),
                ButtonSegment(value: MeetupKind.openClass, label: Text('오픈 클래스')),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() => _kind = s.first),
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _title,
            maxLength: 80,
            decoration: const InputDecoration(labelText: '제목'),
          ),
          TextField(
            controller: _subtitle,
            maxLength: 80,
            decoration: const InputDecoration(labelText: '한줄 소개'),
          ),
          TextField(
            controller: _description,
            maxLength: 2000,
            maxLines: 4,
            decoration: const InputDecoration(labelText: '설명'),
          ),
          TextField(
            controller: _tag,
            maxLength: 20,
            decoration: const InputDecoration(labelText: '태그'),
          ),
          TextField(
            controller: _place,
            maxLength: 80,
            decoration: const InputDecoration(labelText: '장소'),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('날짜 · 시간'),
            subtitle: Text(
              '${_startsAt.month}.${_startsAt.day} ${_startsAt.hour.toString().padLeft(2, '0')}:${_startsAt.minute.toString().padLeft(2, '0')}',
            ),
            onTap: _pickDateTime,
          ),
          Row(
            children: [
              const Text('정원'),
              Expanded(
                child: Slider(
                  min: 2,
                  max: 30,
                  divisions: 28,
                  label: '$_capacity',
                  value: _capacity.toDouble(),
                  activeColor: AppColors.primary,
                  onChanged: (v) => setState(() => _capacity = v.round()),
                ),
              ),
              Text('$_capacity명'),
            ],
          ),
          if (_kind == MeetupKind.openClass) ...[
            TextField(
              controller: _price,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '가격(원, 0이면 무료)'),
              onChanged: (v) => _priceKrw = int.tryParse(v) ?? 0,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('라이브 클래스'),
              value: _format == MeetupMeetingFormat.live,
              onChanged: (v) => setState(
                () => _format = v
                    ? MeetupMeetingFormat.live
                    : MeetupMeetingFormat.offline,
              ),
            ),
          ],
          TextField(
            controller: _recurrence,
            decoration: const InputDecoration(labelText: '반복 메모 (선택)'),
          ),
        ],
      ),
    );
  }
}
