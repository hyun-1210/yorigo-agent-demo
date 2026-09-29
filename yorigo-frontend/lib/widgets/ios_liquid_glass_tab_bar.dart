import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// iPhone-only host for the real UIKit tab bar (Liquid Glass on iOS 26+).
///
/// The bar is a native overlay on FlutterViewController, not a [UiKitView].
/// This widget only reserves layout height and syncs selection/badge.
class IosLiquidGlassTabBar extends StatefulWidget {
  const IosLiquidGlassTabBar({
    super.key,
    required this.selectedIndex,
    required this.cartBadge,
    required this.onTabSelected,
    this.onNativeUnavailable,
  });

  final int selectedIndex;
  final int cartBadge;
  final ValueChanged<int> onTabSelected;
  final VoidCallback? onNativeUnavailable;

  static const _channel = MethodChannel('yorigo.app/ios_liquid_glass_tab_bar');

  /// True while the native overlay is actually on screen (not Flutter fallback).
  static final ValueNotifier<bool> overlayActive = ValueNotifier<bool>(false);

  /// True when a fullscreen page (not a modal sheet) covers the five tab roots.
  static final ValueNotifier<bool> coveredByPushedRoute =
      ValueNotifier<bool>(false);

  /// Real native tab bar only on iPhone. iPad / Android / web keep Flutter nav.
  static bool shouldUse(BuildContext context) {
    if (kIsWeb) return false;
    if (defaultTargetPlatform != TargetPlatform.iOS) return false;
    return MediaQuery.sizeOf(context).shortestSide < 600;
  }

  /// Apple UI kit chrome height for current iPhones (402×95 on 16 Pro).
  static double hostHeight(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return bottom > 0 ? 95 : 64;
  }

  /// Side inset for the collapsed recipe-book pill only. The navbar is full width.
  static const double hostHorizontalInset = 16;

  /// Native overlay height when the iOS tab bar is actually showing.
  ///
  /// 0 when the Flutter nav owns the scaffold slot (Android / iPad / fallback).
  /// Use this for docks, FABs, and sheets that must sit flush above the bar.
  static double overlayChromeInset(BuildContext context) {
    if (coveredByPushedRoute.value) return 0;
    final scope = context
        .dependOnInheritedWidgetOfExactType<IosLiquidGlassTabBarScope>();
    if (scope != null) return scope.overlayHeight;
    if (!overlayActive.value) return 0;
    return hostHeight(context);
  }

  static Future<void> syncHomeScroll({
    required double offset,
    required double maxExtent,
  }) async {
    if (!overlayActive.value) return;
    try {
      await _channel.invokeMethod('setHomeScrollOffset', <String, dynamic>{
        'offset': offset,
        'maxExtent': maxExtent,
      });
    } catch (_) {}
  }

  /// 네이티브 크롬은 그대로 두고 히트만 끈다. 모달 시트 제스처가 홈 스크롤에 먹히지 않게.
  static Future<void> setChromeHitsEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod('setHitsEnabled', enabled);
    } catch (_) {}
  }

  static ValueChanged<double>? _homeScrollHandler;

  /// 네이티브 UIScrollView → Flutter 홈 리스트 오프셋 동기화.
  static void bindHomeScrollHandler(ValueChanged<double> onOffset) {
    _homeScrollHandler = onOffset;
  }

  static void unbindHomeScrollHandler() {
    _homeScrollHandler = null;
  }

  @override
  State<IosLiquidGlassTabBar> createState() => _IosLiquidGlassTabBarState();
}

/// Tells tab bodies how tall the native overlay is so chrome can sit above it.
class IosLiquidGlassTabBarScope extends InheritedWidget {
  const IosLiquidGlassTabBarScope({
    super.key,
    required this.overlayHeight,
    required super.child,
  });

  final double overlayHeight;

  @override
  bool updateShouldNotify(IosLiquidGlassTabBarScope oldWidget) =>
      overlayHeight != oldWidget.overlayHeight;
}

/// Hides the native overlay on fullscreen pages. Modal sheets stay on the
/// tab shell, so they keep the bar.
class IosLiquidGlassTabBarRouteObserver extends NavigatorObserver {
  int _covering = 0;

  static bool coversTabShell(Route<dynamic> route) {
    if (route is PopupRoute) return false;
    if (route is PageRoute) return !route.isFirst;
    return false;
  }

  void _setCovering(int next) {
    _covering = next < 0 ? 0 : next;
    final covered = _covering > 0;
    if (IosLiquidGlassTabBar.coveredByPushedRoute.value != covered) {
      IosLiquidGlassTabBar.coveredByPushedRoute.value = covered;
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (coversTabShell(route)) _setCovering(_covering + 1);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (coversTabShell(route)) _setCovering(_covering - 1);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (coversTabShell(route)) _setCovering(_covering - 1);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    var next = _covering;
    if (oldRoute != null && coversTabShell(oldRoute)) next--;
    if (newRoute != null && coversTabShell(newRoute)) next++;
    _setCovering(next);
  }
}

class _IosLiquidGlassTabBarState extends State<IosLiquidGlassTabBar> {
  var _didInitialSync = false;
  var _hasPresentedOverlay = false;

  @override
  void initState() {
    super.initState();
    IosLiquidGlassTabBar._channel.setMethodCallHandler(_onNative);
    IosLiquidGlassTabBar.coveredByPushedRoute.addListener(_onCoveredChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery가 바뀔 때마다 show()하면 접힌 탭바가 다시 펼쳐진다.
    if (_didInitialSync) return;
    _didInitialSync = true;
    unawaited(_syncNativeVisibility());
  }

  @override
  void didUpdateWidget(IosLiquidGlassTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (IosLiquidGlassTabBar.coveredByPushedRoute.value) return;
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      unawaited(_invoke('setSelectedIndex', widget.selectedIndex));
    }
    if (oldWidget.cartBadge != widget.cartBadge) {
      unawaited(_invoke('setCartBadge', widget.cartBadge));
    }
  }

  @override
  void dispose() {
    IosLiquidGlassTabBar.coveredByPushedRoute.removeListener(_onCoveredChanged);
    IosLiquidGlassTabBar.overlayActive.value = false;
    unawaited(_invoke('hide'));
    IosLiquidGlassTabBar._channel.setMethodCallHandler(null);
    super.dispose();
  }

  void _onCoveredChanged() {
    if (!mounted) return;
    unawaited(_syncNativeVisibility());
  }

  Future<void> _invoke(String method, [dynamic arguments]) async {
    try {
      await IosLiquidGlassTabBar._channel.invokeMethod(method, arguments);
    } catch (_) {}
  }

  Future<void> _syncNativeVisibility() async {
    if (IosLiquidGlassTabBar.coveredByPushedRoute.value) {
      IosLiquidGlassTabBar.overlayActive.value = false;
      await _invoke('hide', <String, dynamic>{
        'animated': _hasPresentedOverlay,
      });
      return;
    }
    IosLiquidGlassTabBar.overlayActive.value = true;
    try {
      await IosLiquidGlassTabBar._channel.invokeMethod('show', <String, dynamic>{
        'selectedIndex': widget.selectedIndex,
        'cartBadge': widget.cartBadge,
        'height': IosLiquidGlassTabBar.hostHeight(context),
        'animated': _hasPresentedOverlay,
      });
      _hasPresentedOverlay = true;
    } on MissingPluginException {
      IosLiquidGlassTabBar.overlayActive.value = false;
      widget.onNativeUnavailable?.call();
    } on PlatformException {
      IosLiquidGlassTabBar.overlayActive.value = false;
      widget.onNativeUnavailable?.call();
    }
  }

  Future<dynamic> _onNative(MethodCall call) async {
    if (call.method == 'onTabSelected') {
      final index = call.arguments;
      if (index is int) widget.onTabSelected(index);
    } else if (call.method == 'onHomeScrollOffset') {
      final args = call.arguments;
      if (args is Map) {
        final offset = args['offset'];
        if (offset is num) {
          IosLiquidGlassTabBar._homeScrollHandler?.call(offset.toDouble());
        }
      } else if (args is num) {
        IosLiquidGlassTabBar._homeScrollHandler?.call(args.toDouble());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: IosLiquidGlassTabBar.hostHeight(context),
      width: double.infinity,
    );
  }
}
