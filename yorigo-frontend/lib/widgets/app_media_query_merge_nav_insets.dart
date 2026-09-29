import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Bottom inset for system nav / home gesture (use in [showModalBottomSheet] with
/// [useSafeArea: false], or any overlay that does not inherit merged padding).
double appSystemNavBottomInset(BuildContext context) {
  final mq = MediaQuery.of(context);
  if (mq.viewInsets.bottom > 0) {
    return mq.padding.bottom;
  }
  final g = mq.systemGestureInsets;
  return math.max(
    math.max(mq.padding.bottom, mq.viewPadding.bottom),
    g.bottom,
  );
}

/// Merges [MediaQuery.viewPadding] and [MediaQuery.systemGestureInsets] into
/// [MediaQuery.padding] when the OS uses edge-to-edge mode so [padding.bottom]
/// can be 0 while [viewPadding.bottom] still reflects the system nav / gesture
/// bar. Descendants that call [MediaQuery.paddingOf] (including [SafeArea])
/// then see the real insets.
///
/// While the keyboard is open ([viewInsets.bottom] > 0), bottom padding is
/// left as Flutter provides so [resizeToAvoidBottomInset] behavior stays intact.
class AppMediaQueryMergeNavInsets extends StatelessWidget {
  const AppMediaQueryMergeNavInsets({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final g = mq.systemGestureInsets;
    final left = math.max(
      math.max(mq.padding.left, mq.viewPadding.left),
      g.left,
    );
    final right = math.max(
      math.max(mq.padding.right, mq.viewPadding.right),
      g.right,
    );
    final top = math.max(
      math.max(mq.padding.top, mq.viewPadding.top),
      g.top,
    );
    final double bottom;
    if (mq.viewInsets.bottom > 0) {
      bottom = mq.padding.bottom;
    } else {
      bottom = math.max(
        math.max(mq.padding.bottom, mq.viewPadding.bottom),
        g.bottom,
      );
    }
    return MediaQuery(
      data: mq.copyWith(
        padding: EdgeInsets.only(
          left: left,
          right: right,
          top: top,
          bottom: bottom,
        ),
      ),
      child: child,
    );
  }
}

/// Root wrapper for every [MaterialApp] route: merges OS / gesture insets, then
/// reserves the bottom system navigation / home-indicator strip consistently
/// (same behavior as recipe detail footers).
class AppRootNavigationSafeArea extends StatelessWidget {
  const AppRootNavigationSafeArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Root-level SafeArea(bottom) can create an extra blank strip under the
    // app's own bottom navigation. Keep inset merge only; each screen/sheet
    // handles its own safe area requirements.
    return AppMediaQueryMergeNavInsets(child: child);
  }
}
