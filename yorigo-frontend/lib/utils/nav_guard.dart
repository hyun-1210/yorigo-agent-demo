import 'package:flutter/material.dart';

/// Prevents duplicate navigation when users double-tap recipe cards or other
/// navigable elements.
///
/// Important: this guard is **global** and only stays locked for the duration
/// of the awaited [action] body. Callers that `await` a pushed route / modal
/// until it is popped will lock the entire app navigation for that lifetime
/// and silently swallow other [NavGuard.once] taps (e.g. recipe cards inside).
/// Prefer starting navigation without awaiting pop — same pattern as home /
/// category explore.
class NavGuard {
  static bool _active = false;

  /// Wraps [action] so it only runs once at a time. Subsequent calls while
  /// the first is still in progress are silently ignored.
  static VoidCallback once(Future<void> Function() action) {
    return () async {
      if (_active) return;
      _active = true;
      try {
        await action();
      } finally {
        _active = false;
      }
    };
  }

  /// 테스트에서 가드 상태를 초기화한다.
  static void debugReset() {
    _active = false;
  }
}
