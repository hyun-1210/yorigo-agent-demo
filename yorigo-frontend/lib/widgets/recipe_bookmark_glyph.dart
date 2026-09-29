import 'package:flutter/material.dart';

/// Shared recipe-save glyph.
/// Unsaved: black outline ribbon. Saved: filled orange.
class RecipeBookmarkGlyph extends StatelessWidget {
  const RecipeBookmarkGlyph({
    super.key,
    required this.isBookmarked,
    this.size = defaultSize,
    this.outlineColor = const Color(0xFF1A1A1A),
  });

  final bool isBookmarked;
  final double size;
  final Color outlineColor;

  static const double defaultSize = 28;

  static const LinearGradient savedGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFF9A3D), Color(0xFFFF6B00), Color(0xFFFF4D00)],
    stops: [0.0, 0.55, 1.0],
  );

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        size: Size(size, size),
        painter: _RecipeBookmarkPainter(
          filled: isBookmarked,
          outlineColor: outlineColor,
          gradient: isBookmarked ? savedGradient : null,
        ),
      ),
    );
  }
}

class _RecipeBookmarkPainter extends CustomPainter {
  const _RecipeBookmarkPainter({
    required this.filled,
    required this.outlineColor,
    this.gradient,
  });

  final bool filled;
  final Color outlineColor;
  final Gradient? gradient;

  Path _path(Size size) {
    final w = size.width;
    final h = size.height;
    final left = w * 0.24;
    final right = w * 0.76;
    final top = h * 0.10;
    final bottom = h * 0.90;
    final midX = w * 0.50;
    final notch = h * 0.66;
    final r = w * 0.09;

    return Path()
      ..moveTo(left + r, top)
      ..lineTo(right - r, top)
      ..quadraticBezierTo(right, top, right, top + r)
      ..lineTo(right, bottom)
      ..lineTo(midX, notch)
      ..lineTo(left, bottom)
      ..lineTo(left, top + r)
      ..quadraticBezierTo(left, top, left + r, top)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = _path(size);
    final paint = Paint()
      ..isAntiAlias = true
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    if (filled) {
      paint
        ..style = PaintingStyle.fill
        ..shader = gradient?.createShader(Offset.zero & size);
      canvas.drawPath(path, paint);
      return;
    }

    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = (size.width * 0.085).clamp(1.6, 2.4)
      ..color = outlineColor;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _RecipeBookmarkPainter oldDelegate) {
    return oldDelegate.filled != filled ||
        oldDelegate.outlineColor != outlineColor ||
        oldDelegate.gradient != gradient;
  }
}
