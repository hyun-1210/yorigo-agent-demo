import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/recipe_models.dart' as models;
import '../utils/haptics.dart';
import '../utils/recipe_wait_timer.dart';

enum _Phase { idle, running, paused, done }

class MethodStepTimerBlock extends StatefulWidget {
  const MethodStepTimerBlock({
    super.key,
    required this.step,
    required this.sentences,
    required this.style,
  });

  final models.Step step;
  final List<String> sentences;
  final TextStyle style;

  @override
  State<MethodStepTimerBlock> createState() => _MethodStepTimerBlockState();
}

class _MethodStepTimerBlockState extends State<MethodStepTimerBlock> {
  Timer? _ticker;
  late final TapGestureRecognizer _phraseTap;
  _Phase _phase = _Phase.idle;
  int? _totalSec;
  int _leftSec = 0;
  DateTime? _endsAt;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _phraseTap = TapGestureRecognizer()..onTap = _onPhraseTap;
  }

  ({int seconds, String phrase})? get _suggestion =>
      RecipeWaitTimer.suggestionFor(widget.step);

  @override
  void dispose() {
    _ticker?.cancel();
    _phraseTap.dispose();
    super.dispose();
  }

  void _start(int seconds) {
    final safe = seconds.clamp(1, RecipeWaitTimer.maxSeconds);
    _ticker?.cancel();
    setState(() {
      _totalSec = safe;
      _endsAt = DateTime.now().add(Duration(seconds: safe));
      _phase = _Phase.running;
      _leftSec = safe;
      _expanded = true;
    });
    _armTicker();
  }

  void _pause() {
    if (_phase != _Phase.running) return;
    _ticker?.cancel();
    _ticker = null;
    setState(() {
      _endsAt = null;
      _phase = _Phase.paused;
    });
  }

  void _resume() {
    if (_phase != _Phase.paused || _leftSec <= 0) return;
    setState(() {
      _endsAt = DateTime.now().add(Duration(seconds: _leftSec));
      _phase = _Phase.running;
    });
    _armTicker();
  }

  void _reset() {
    final total = _totalSec;
    if (total == null) return;
    _ticker?.cancel();
    _ticker = null;
    setState(() {
      _endsAt = null;
      _phase = _Phase.paused;
      _leftSec = total;
    });
  }

  void _dismiss() {
    _ticker?.cancel();
    _ticker = null;
    setState(() {
      _totalSec = null;
      _leftSec = 0;
      _endsAt = null;
      _phase = _Phase.idle;
      _expanded = false;
    });
  }

  int _liveLeft() {
    if (_phase == _Phase.done) return 0;
    if (_phase == _Phase.paused) return _leftSec;
    final endsAt = _endsAt;
    if (endsAt == null) return _leftSec;
    return endsAt
        .difference(DateTime.now())
        .inSeconds
        .clamp(0, RecipeWaitTimer.maxSeconds);
  }

  void _armTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted || _phase != _Phase.running) return;
      final left = _liveLeft();
      if (left <= 0) {
        _ticker?.cancel();
        _ticker = null;
        setState(() {
          _endsAt = null;
          _phase = _Phase.done;
          _leftSec = 0;
        });
        return;
      }
      if (left != _leftSec) {
        setState(() => _leftSec = left);
      }
    });
  }

  void _onPhraseTap() {
    Haptics.selection();
    final suggestion = _suggestion;
    if (suggestion == null) return;
    if (_phase == _Phase.idle || _phase == _Phase.done) {
      _start(suggestion.seconds);
      return;
    }
    if (_phase == _Phase.paused) {
      _resume();
      setState(() => _expanded = true);
      return;
    }
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final suggestion = _suggestion;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildInstruction(suggestion),
        if (_expanded && suggestion != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _buildBar(suggestion),
          ),
      ],
    );
  }

  Widget _buildInstruction(({int seconds, String phrase})? suggestion) {
    final sentences = widget.sentences;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (sentences.isEmpty)
          _richLine(widget.step.instruction, suggestion)
        else
          for (var i = 0; i < sentences.length; i++) ...[
            if (i > 0) const SizedBox(height: 2),
            _richLine(sentences[i], suggestion),
          ],
      ],
    );
  }

  Widget _richLine(String text, ({int seconds, String phrase})? suggestion) {
    final phrase = suggestion?.phrase;
    final index = phrase == null ? -1 : text.indexOf(phrase);
    if (suggestion == null || phrase == null || index < 0) {
      return Text(text, style: widget.style);
    }
    return Text.rich(
      TextSpan(
        style: widget.style,
        children: [
          TextSpan(text: text.substring(0, index)),
          TextSpan(
            text: phrase,
            style: widget.style.copyWith(
              color: const Color(0xFFEA580C),
              decoration: TextDecoration.underline,
              decorationColor: const Color(0xFFEA580C),
              decorationThickness: 1.4,
            ),
            recognizer: _phraseTap,
          ),
          TextSpan(text: text.substring(index + phrase.length)),
        ],
      ),
    );
  }

  Widget _buildBar(({int seconds, String phrase}) suggestion) {
    final idle = _phase == _Phase.idle;
    final done = _phase == _Phase.done;
    final paused = _phase == _Phase.paused;
    final running = _phase == _Phase.running;
    final message = idle
        ? '${RecipeWaitTimer.formatLabel(suggestion.seconds)} 타이머를 시작할까요?'
        : (done
            ? '시간이 끝났어요'
            : RecipeWaitTimer.formatClock(_leftSec));

    return Container(
      height: 40,
      padding: const EdgeInsets.fromLTRB(8, 0, 6, 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFFD7B8), width: 0.8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x07000000),
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: paused
                ? Row(
                    children: [
                      Text(
                        RecipeWaitTimer.formatClock(_leftSec),
                        maxLines: 1,
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFEA580C),
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          '일시정지',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF9C9389),
                            letterSpacing: -0.15,
                          ),
                        ),
                      ),
                    ],
                  )
                : Text(
                    message,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: done || !idle
                          ? const Color(0xFFEA580C)
                          : const Color(0xFF4B5563),
                      letterSpacing: -0.2,
                    ),
                  ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (idle)
                    _chip(
                      '시작',
                      filled: true,
                      onTap: () {
                        Haptics.selection();
                        _start(suggestion.seconds);
                      },
                    )
                  else if (done) ...[
                    _chip(
                      '다시',
                      filled: true,
                      onTap: () {
                        Haptics.selection();
                        _start(_totalSec ?? suggestion.seconds);
                      },
                    ),
                    const SizedBox(width: 4),
                    _chip('닫기', onTap: _dismiss),
                  ] else ...[
                    _chip(
                      running ? '멈춤' : '계속',
                      filled: true,
                      onTap: () {
                        Haptics.selection();
                        if (running) {
                          _pause();
                        } else {
                          _resume();
                        }
                      },
                    ),
                    const SizedBox(width: 4),
                    _chip(
                      '초기화',
                      onTap: () {
                        Haptics.selection();
                        _reset();
                      },
                    ),
                    const SizedBox(width: 4),
                    _chip('끄기', onTap: _dismiss),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, {bool filled = false, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled ? const Color(0xFFEA580C) : const Color(0xFFF4F5F7),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: filled ? Colors.white : const Color(0xFF4B5563),
            height: 1,
          ),
        ),
      ),
    );
  }
}
