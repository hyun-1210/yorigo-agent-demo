import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Thumbnail + minimal center play glyph (white triangle) for inline video heroes.
///
/// No dimming overlay so the still matches full-opacity reference frames.
/// Triangle horizontal span defaults to a small fraction of slot width (~3.8%).
class InlineVideoHeroPoster extends StatelessWidget {
  const InlineVideoHeroPoster({
    super.key,
    required this.thumbnailUrl,
    required this.backgroundColor,
    required this.imageFit,
    /// Horizontal span of the play triangle (left-to-tip). If null, derived from width.
    this.playTriangleWidth,
    this.showCenterPlayGlyph = true,
    this.showInstagramTopTapBlock = false,
    this.imageHttpHeaders,
    this.memCacheWidth,
    this.memCacheHeight,
    this.fadeInDuration,
    this.placeholderColor,
  });

  final String? thumbnailUrl;
  final Color backgroundColor;
  final BoxFit imageFit;

  /// When null, uses [playWidthFraction] of layout width.
  final double? playTriangleWidth;

  /// When false, thumbnail only (e.g. Instagram: WebView replaces hero when ready).
  final bool showCenterPlayGlyph;

  final bool showInstagramTopTapBlock;
  final Map<String, String>? imageHttpHeaders;
  final int? memCacheWidth;
  final int? memCacheHeight;
  final Duration? fadeInDuration;
  final Color? placeholderColor;

  /// Default fraction of hero width used as triangle horizontal span (tip − base).
  static const double playWidthFraction = 0.038;

  /// Same Referer pattern as recipe detail [CachedNetworkImage] for IG CDN.
  static const Map<String, String> instagramThumbnailHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
    'Referer': 'https://www.instagram.com/',
  };

  @override
  Widget build(BuildContext context) {
    final trimmed = thumbnailUrl?.trim() ?? '';
    final hasThumb = trimmed.isNotEmpty;

    return ColoredBox(
      color: backgroundColor,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxW = constraints.maxWidth;
          final span = playTriangleWidth ??
              (maxW.isFinite && maxW > 0
                  ? (maxW * playWidthFraction).clamp(10.0, 22.0)
                  : 16.0);
          final h = span * 2 / math.sqrt(3);
          final cornerR =
              (span * 0.2).clamp(0.55, 1.65); // subtle rounding, scales with glyph

          return Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.hardEdge,
            children: [
              if (hasThumb)
                Positioned.fill(
                  child: CachedNetworkImage(
                    imageUrl: trimmed,
                    fit: imageFit,
                    httpHeaders: imageHttpHeaders,
                    memCacheWidth: memCacheWidth,
                    memCacheHeight: memCacheHeight,
                    maxWidthDiskCache: 1400,
                    maxHeightDiskCache: 1200,
                    fadeInDuration:
                        fadeInDuration ?? const Duration(milliseconds: 500),
                    placeholder: (_, __) => ColoredBox(
                      color: placeholderColor ?? Colors.transparent,
                    ),
                    errorWidget: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              if (showCenterPlayGlyph)
                Center(
                  child: _WhiteRightTriangle(
                    width: span,
                    height: h,
                    cornerRadius: cornerR,
                  ),
                ),
              if (showInstagramTopTapBlock)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: 8,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    child: ColoredBox(color: backgroundColor),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Solid white triangle pointing right with softly rounded vertices.
class _WhiteRightTriangle extends StatelessWidget {
  const _WhiteRightTriangle({
    required this.width,
    required this.height,
    required this.cornerRadius,
  });

  final double width;
  final double height;
  final double cornerRadius;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(width, height),
      painter: _RoundedRightTrianglePainter(
        color: Colors.white,
        cornerRadius: cornerRadius,
      ),
    );
  }
}

class _RoundedRightTrianglePainter extends CustomPainter {
  _RoundedRightTrianglePainter({
    required this.color,
    required this.cornerRadius,
  });

  final Color color;
  final double cornerRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final corners = <Offset>[
      Offset.zero,
      Offset(0, h),
      Offset(w, h / 2),
    ];

    final path = _roundedPolygonPath(corners, cornerRadius);
    canvas.drawPath(path, Paint()..color = color);
  }

  /// Per-vertex quadratic fillet so corners read as slightly rounded.
  Path _roundedPolygonPath(List<Offset> corners, double radius) {
    final path = Path();
    final n = corners.length;
    if (n < 3) return path;

    Offset norm(Offset v) {
      final len = v.distance;
      if (len < 1e-9) return Offset.zero;
      return Offset(v.dx / len, v.dy / len);
    }

    for (var i = 0; i < n; i++) {
      final prev = corners[(i - 1 + n) % n];
      final curr = corners[i];
      final next = corners[(i + 1) % n];

      final vIn = norm(curr - prev);
      final vOut = norm(next - curr);
      final cosAngle =
          (vIn.dx * vOut.dx + vIn.dy * vOut.dy).clamp(-1.0, 1.0);
      final angle = math.acos(cosAngle);
      if (angle < 1e-4) {
        if (i == 0) {
          path.moveTo(curr.dx, curr.dy);
        } else {
          path.lineTo(curr.dx, curr.dy);
        }
        continue;
      }

      final tanHalf = math.tan(angle / 2);
      if (tanHalf < 1e-9) continue;

      final edgeIn = (curr - prev).distance;
      final edgeOut = (next - curr).distance;
      final maxD = math.min(edgeIn, edgeOut) * 0.48;
      final d = (radius / tanHalf).clamp(0.0, maxD);

      final pBefore = curr - vIn * d;
      final pAfter = curr + vOut * d;

      if (i == 0) {
        path.moveTo(pBefore.dx, pBefore.dy);
      } else {
        path.lineTo(pBefore.dx, pBefore.dy);
      }
      path.quadraticBezierTo(curr.dx, curr.dy, pAfter.dx, pAfter.dy);
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(covariant _RoundedRightTrianglePainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.cornerRadius != cornerRadius;
  }
}