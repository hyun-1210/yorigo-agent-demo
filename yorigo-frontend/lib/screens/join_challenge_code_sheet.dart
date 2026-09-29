import 'package:flutter/material.dart';

import '../models/community_challenge.dart';
import '../services/challenge_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/community_social_cards.dart';

Future<String?> showJoinChallengeCodeSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => const _JoinChallengeCodeSheet(),
  );
}

class _JoinChallengeCodeSheet extends StatefulWidget {
  const _JoinChallengeCodeSheet();

  @override
  State<_JoinChallengeCodeSheet> createState() => _JoinChallengeCodeSheetState();
}

class _JoinChallengeCodeSheetState extends State<_JoinChallengeCodeSheet> {
  final _controller = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final code = normalizeInviteCode(_controller.text);
    if (code.length != 6) {
      AppToast.error(context, '6자리 코드를 입력해 주세요');
      return;
    }
    setState(() => _busy = true);
    try {
      final id = await ChallengeService.instance.joinChallenge(inviteCode: code);
      if (!mounted) return;
      Navigator.pop(context, id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppToast.error(context, e.toString().replaceFirst('Bad state: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: 20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '초대코드로 참여',
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: kCommunityInk,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            textCapitalization: TextCapitalization.characters,
            maxLength: 8,
            decoration: const InputDecoration(hintText: '예: AB3K7P'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : _join,
            style: FilledButton.styleFrom(backgroundColor: kCommunityOrange),
            child: const Text('참여하기'),
          ),
        ],
      ),
    );
  }
}
