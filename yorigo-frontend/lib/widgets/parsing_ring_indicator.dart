import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/app_colors.dart';

// -----------------------------------------------------------------------------
// Parsing thumbnail ring: one stroke only (no second “head” color).
// Target % comes from [RecipeService.parsingProgressCache] only; internal lerp
// gives App Store–style smooth rotation without coarse jumps.
// -----------------------------------------------------------------------------

/// Softer orange than [AppColors.primary] — single uniform arc.
final Color _kParsingRingOrange =
    Color.lerp(AppColors.primary, Colors.white, 0.28)!;

/// Determinate ring for parsing thumbnails — one arc, frosted track.
class ParsingRingIndicator extends StatefulWidget {
  const ParsingRingIndicator({
    super.key,
    required this.progressPercent,
    this.size = 48,
    this.strokeWidth = 4.2,
  });

  /// 0–100 from [RecipeService.parsingProgressCache].
  final double progressPercent;
  final double size;
  final double strokeWidth;

  @override
  State<ParsingRingIndicator> createState() => _ParsingRingIndicatorState();
}

class _ParsingRingIndicatorState extends State<ParsingRingIndicator>
    with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  double _displayPercent = 0;

  /// Lower = smoother, more “liquid” catch-up (closer to iOS install ring).
  static const double _lerp = 0.11;

  @override
  void initState() {
    super.initState();
    _displayPercent = widget.progressPercent.clamp(0.0, 100.0);
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void didUpdateWidget(covariant ParsingRingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.progressPercent - widget.progressPercent).abs() > 40 &&
        widget.progressPercent < 5) {
      _displayPercent = widget.progressPercent.clamp(0.0, 100.0);
    }
  }

  void _onTick(Duration _) {
    final target = widget.progressPercent.clamp(0.0, 100.0);
    final next = _displayPercent + (target - _displayPercent) * _lerp;
    if (!mounted) return;
    if ((target - next).abs() < 0.015 && (next - _displayPercent).abs() < 0.003) {
      if (_displayPercent != target) {
        setState(() => _displayPercent = target);
      }
      return;
    }
    setState(() => _displayPercent = next);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = (_displayPercent / 100).clamp(0.0, 1.0);
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: CustomPaint(
        painter: _ParsingRingPainter(
          progress: t,
          ringColor: _kParsingRingOrange,
          track: Colors.white.withValues(alpha: 0.78),
          strokeWidth: widget.strokeWidth,
        ),
      ),
    );
  }
}

class _ParsingRingPainter extends CustomPainter {
  _ParsingRingPainter({
    required this.progress,
    required this.ringColor,
    required this.track,
    required this.strokeWidth,
  });

  final double progress;
  final Color ringColor;
  final Color track;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = (size.shortestSide - strokeWidth) / 2;
    final rect = Rect.fromCircle(center: c, radius: r);

    final trackPaint = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    final arcPaint = Paint()
      ..color = ringColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    canvas.drawCircle(c, r, trackPaint);

    final sweep = 2 * math.pi * progress;
    if (sweep <= 0.001) return;

    const start = -math.pi / 2;
    canvas.drawArc(rect, start, sweep, false, arcPaint);
  }

  @override
  bool shouldRepaint(covariant _ParsingRingPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.ringColor != ringColor ||
        oldDelegate.track != track ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}
