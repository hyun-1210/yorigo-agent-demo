import 'dart:async';

import 'package:flutter/material.dart';

/// Renders an animated "..." (1 → 2 → 3 dots) cycling on a fixed tick,
/// used as a live indicator after the parsing-stage text so the card
/// looks like the step is actively progressing.
///
/// - Reserves fixed width for "..." so surrounding text never shifts.
/// - Inherits [TextStyle] from the caller so it visually matches the
///   stage text (size, weight, color, height).
class ParsingAnimatedDots extends StatefulWidget {
  const ParsingAnimatedDots({
    super.key,
    this.style,
    this.interval = const Duration(milliseconds: 380),
    this.maxDots = 3,
  });

  final TextStyle? style;
  final Duration interval;
  final int maxDots;

  @override
  State<ParsingAnimatedDots> createState() => _ParsingAnimatedDotsState();
}

class _ParsingAnimatedDotsState extends State<ParsingAnimatedDots> {
  Timer? _timer;
  int _count = 1;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.interval, (_) {
      if (!mounted) return;
      setState(() {
        _count = _count >= widget.maxDots ? 1 : _count + 1;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dots = '.' * _count;
    // Reserve the full width of "maxDots" dots so the text doesn't
    // dance around as the count changes.
    return Stack(
      alignment: Alignment.centerLeft,
      children: [
        Opacity(
          opacity: 0,
          child: Text('.' * widget.maxDots, style: widget.style),
        ),
        Text(dots, style: widget.style),
      ],
    );
  }
}
