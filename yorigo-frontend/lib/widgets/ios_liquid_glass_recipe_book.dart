import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ios_liquid_glass_tab_bar.dart';

/// iPhone-only host for the official UIKit glass recipe-book dock.
///
/// Collapsed / mini chrome is a native `UIButton.Configuration.glass()`
/// overlay (iOS 26 Liquid Glass). Flutter must not paint a glass lookalike.
class IosLiquidGlassRecipeBook {
  IosLiquidGlassRecipeBook._();

  static const _channel = MethodChannel(
    'yorigo.app/ios_liquid_glass_recipe_book',
  );

  static final ValueNotifier<bool> overlayActive = ValueNotifier<bool>(false);

  static bool _handlersBound = false;
  static bool _lastVisible = false;
  static bool _lastMini = false;
  static double _lastTabBarHeight = -1;
  static double _lastHeight = -1;
  static double _lastBottomGap = -1;
  static int _lastSavedCount = -1;

  static bool shouldUse(BuildContext context) {
    return IosLiquidGlassTabBar.shouldUse(context);
  }

  static void bindHandlers({
    required VoidCallback onTap,
    required VoidCallback onDragStart,
    required ValueChanged<double> onDragUpdate,
    required ValueChanged<double> onDragEnd,
    required VoidCallback onDragCancel,
  }) {
    _handlersBound = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onTap':
          onTap();
        case 'onDragStart':
          onDragStart();
        case 'onDragUpdate':
          final delta = call.arguments;
          if (delta is num) onDragUpdate(delta.toDouble());
        case 'onDragEnd':
          final velocity = call.arguments;
          if (velocity is num) onDragEnd(velocity.toDouble());
        case 'onDragCancel':
          onDragCancel();
      }
      return null;
    });
  }

  static void unbindHandlers() {
    if (!_handlersBound) return;
    _handlersBound = false;
    _channel.setMethodCallHandler(null);
  }

  static Future<void> sync({
    required bool visible,
    required bool mini,
    required double tabBarHeight,
    double sideInset = IosLiquidGlassTabBar.hostHorizontalInset,
    double height = 50,
    double miniSize = 54,
    double bottomGap = 2,
    int savedCount = 0,
  }) async {
    if (!visible) {
      if (_lastVisible) {
        _lastVisible = false;
        overlayActive.value = false;
        try {
          await _channel.invokeMethod('hide');
        } catch (_) {}
      }
      return;
    }
    if (_lastVisible &&
        _lastMini == mini &&
        (_lastTabBarHeight - tabBarHeight).abs() < 0.5 &&
        (_lastHeight - height).abs() < 0.5 &&
        (_lastBottomGap - bottomGap).abs() < 0.5 &&
        _lastSavedCount == savedCount) {
      return;
    }
    _lastVisible = true;
    _lastMini = mini;
    _lastTabBarHeight = tabBarHeight;
    _lastHeight = height;
    _lastBottomGap = bottomGap;
    _lastSavedCount = savedCount;
    try {
      final raw = await _channel.invokeMethod<dynamic>('show', <String, dynamic>{
        'mini': mini,
        'tabBarHeight': tabBarHeight,
        'sideInset': sideInset,
        'height': height,
        'miniSize': miniSize,
        'bottomGap': bottomGap,
        'savedCount': savedCount,
      });
      final supported = raw is Map && raw['supported'] == true;
      overlayActive.value = supported;
      if (!supported) {
        _lastVisible = false;
      }
    } catch (_) {
      overlayActive.value = false;
      _lastVisible = false;
    }
  }
}
