import 'package:flutter/material.dart';

import '../models/community_challenge.dart';
import '../services/admin_service.dart';
import '../services/challenge_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/community_social_cards.dart';

class AdminChallengeComposeScreen extends StatefulWidget {
  const AdminChallengeComposeScreen({super.key});

  @override
  State<AdminChallengeComposeScreen> createState() =>
      _AdminChallengeComposeScreenState();
}

class _AdminChallengeComposeScreenState
    extends State<AdminChallengeComposeScreen> {
  final _title = TextEditingController();
  final _subtitle = TextEditingController();
  final _description = TextEditingController();
  final _tag = TextEditingController();
  final DateTime _startsAt = DateTime.now();
  final DateTime _endsAt = DateTime.now().add(const Duration(days: 7));
  int _required = 1;
  int _goal = 1000;
  ChallengeProofMode _mode = ChallengeProofMode.count;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    AdminService.instance.isAdmin().then((ok) {
      if (!ok && mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _subtitle.dispose();
    _description.dispose();
    _tag.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      await ChallengeService.instance.createOfficialChallenge(
        title: _title.text,
        subtitle: _subtitle.text,
        description: _description.text,
        tag: _tag.text,
        startsAt: _startsAt,
        endsAt: _endsAt,
        requiredProofCount: _required,
        proofMode: _mode,
        goalParticipantCount: _goal,
      );
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
        title: const Text('공식 챌린지'),
        actions: [
          TextButton(
            onPressed: _submitting ? null : _submit,
            child: const Text(
              '만들기',
              style: TextStyle(
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
          TextField(controller: _title, decoration: const InputDecoration(labelText: '제목'), maxLength: 80),
          TextField(controller: _subtitle, decoration: const InputDecoration(labelText: '한줄 소개'), maxLength: 80),
          TextField(controller: _description, decoration: const InputDecoration(labelText: '설명'), maxLines: 4, maxLength: 2000),
          TextField(controller: _tag, decoration: const InputDecoration(labelText: '태그'), maxLength: 20),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('연속 날짜로 인증'),
            value: _mode == ChallengeProofMode.consecutiveDays,
            onChanged: (v) => setState(
              () => _mode = v
                  ? ChallengeProofMode.consecutiveDays
                  : ChallengeProofMode.count,
            ),
          ),
          Row(
            children: [
              const Text('목표 인원'),
              Expanded(
                child: Slider(
                  min: 100,
                  max: 5000,
                  divisions: 49,
                  value: _goal.toDouble().clamp(100, 5000),
                  label: '$_goal',
                  onChanged: (v) => setState(() => _goal = v.round()),
                ),
              ),
              Text('$_goal'),
            ],
          ),
          Row(
            children: [
              const Text('필요 인증'),
              Expanded(
                child: Slider(
                  min: 1,
                  max: 7,
                  divisions: 6,
                  value: _required.toDouble(),
                  onChanged: (v) => setState(() => _required = v.round()),
                ),
              ),
              Text('$_required회'),
            ],
          ),
        ],
      ),
    );
  }
}
