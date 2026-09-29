import 'package:flutter/material.dart';

/// Feed like heart with a short pop when it becomes liked.
class FeedLikeHeart extends StatefulWidget {
  const FeedLikeHeart({
    super.key,
    required this.isLiked,
    required this.color,
    this.size = 24,
  });

  final bool isLiked;
  final Color color;
  final double size;

  @override
  State<FeedLikeHeart> createState() => _FeedLikeHeartState();
}

class _FeedLikeHeartState extends State<FeedLikeHeart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _scale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 1.22)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 40,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.22, end: 0.94)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 25,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 0.94, end: 1.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 35,
      ),
    ]).animate(_controller);
  }

  @override
  void didUpdateWidget(covariant FeedLikeHeart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isLiked && widget.isLiked) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scale,
      child: Icon(
        widget.isLiked
            ? Icons.favorite_rounded
            : Icons.favorite_border_rounded,
        size: widget.size,
        color: widget.color,
      ),
    );
  }
}
