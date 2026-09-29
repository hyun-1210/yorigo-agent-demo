import 'dart:async';
import 'dart:io' show ProcessInfo;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// 앱 성능 계측용 경량 모니터.
///
/// 모든 로그는 `[PERF]` 접두사를 붙여 출력하므로
/// `adb logcat | findstr PERF` 또는 `flutter run` 콘솔에서 필터링하기 쉽다.
///
/// 수집 항목:
/// - 프레임 jank (build+raster 가 프레임 예산 초과)
/// - 화면/탭 전환 이벤트 시각 + 그 순간 RSS 메모리
/// - 주기적 메모리(RSS)·이미지 캐시 스냅샷 + 직전 구간 jank 비율
/// - 임의 구간 측정(measure / event)
class PerfMonitor {
  PerfMonitor._();
  static final PerfMonitor instance = PerfMonitor._();

  /// 릴리스 빌드에서는 계측을 끈다. (프로파일/디버그에서만 동작)
  static const bool _enabled = !kReleaseMode;

  bool _started = false;
  Timer? _snapshotTimer;

  /// 60Hz 기준 한 프레임 예산은 ~16.7ms. 두 배(=1프레임 드랍) 넘으면 jank 로 본다.
  static const double _jankThresholdMs = 32.0;

  int _framesInWindow = 0;
  int _jankFramesInWindow = 0;
  double _worstFrameMsInWindow = 0.0;

  /// 마지막 이벤트 라벨(현재 사용자가 어느 화면/동작 중인지 상관관계 파악용)
  String _lastEvent = 'startup';
  final Stopwatch _sinceLastEvent = Stopwatch()..start();

  void start() {
    if (!_enabled || _started) return;
    _started = true;

    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);

    _snapshotTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _logSnapshot(),
    );

    // dart:io Platform is unsupported on web.
    final device = kIsWeb ? 'web' : defaultTargetPlatform.name;
    _log('MONITOR STARTED (device=$device)');
  }

  void stop() {
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
    _started = false;
  }

  void _onFrameTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final totalMs = t.totalSpan.inMicroseconds / 1000.0;
      final buildMs = t.buildDuration.inMicroseconds / 1000.0;
      final rasterMs = t.rasterDuration.inMicroseconds / 1000.0;
      _framesInWindow++;
      if (totalMs > _worstFrameMsInWindow) _worstFrameMsInWindow = totalMs;
      if (totalMs > _jankThresholdMs) {
        _jankFramesInWindow++;
        // 심한 jank(3프레임 이상 드랍)는 즉시 어떤 동작 중인지와 함께 남긴다.
        if (totalMs > 50.0) {
          _log(
            'JANK ${totalMs.toStringAsFixed(1)}ms '
            '(build=${buildMs.toStringAsFixed(1)} '
            'raster=${rasterMs.toStringAsFixed(1)}) '
            'during="$_lastEvent" +${_sinceLastEvent.elapsedMilliseconds}ms',
          );
        }
      }
    }
  }

  int _currentRssBytes() {
    if (kIsWeb) return 0;
    try {
      return ProcessInfo.currentRss;
    } catch (_) {
      return 0;
    }
  }

  double _mb(int bytes) => bytes / (1024 * 1024);

  void _logSnapshot() {
    if (!_enabled) return;
    final rss = _currentRssBytes();
    final imgCache = PaintingBinding.instance.imageCache;
    final jankPct = _framesInWindow == 0
        ? 0.0
        : (_jankFramesInWindow * 100.0 / _framesInWindow);

    _log(
      'SNAPSHOT rss=${_mb(rss).toStringAsFixed(1)}MB '
      'imgCache=${_mb(imgCache.currentSizeBytes).toStringAsFixed(1)}MB'
      '/${imgCache.currentSize}imgs(live=${imgCache.liveImageCount}) '
      'jank=${_jankFramesInWindow}/$_framesInWindow'
      '(${jankPct.toStringAsFixed(0)}%) '
      'worst=${_worstFrameMsInWindow.toStringAsFixed(1)}ms '
      'screen="$_lastEvent"',
    );

    _framesInWindow = 0;
    _jankFramesInWindow = 0;
    _worstFrameMsInWindow = 0.0;
  }

  /// 화면 전환·탭 전환·주요 사용자 동작 시점을 표시한다.
  void event(String label) {
    if (!_enabled) return;
    _lastEvent = label;
    _sinceLastEvent.reset();
    final rss = _currentRssBytes();
    _log('EVENT "$label" rss=${_mb(rss).toStringAsFixed(1)}MB');
  }

  /// 동기/비동기 구간의 소요 시간을 측정한다.
  Future<T> measure<T>(String label, Future<T> Function() action) async {
    if (!_enabled) return action();
    final sw = Stopwatch()..start();
    final rssBefore = _currentRssBytes();
    try {
      return await action();
    } finally {
      sw.stop();
      final rssAfter = _currentRssBytes();
      _log(
        'MEASURE "$label" took=${sw.elapsedMilliseconds}ms '
        'rss ${_mb(rssBefore).toStringAsFixed(1)}->'
        '${_mb(rssAfter).toStringAsFixed(1)}MB',
      );
    }
  }

  void _log(String msg) {
    // debugPrint 는 안드로이드 로그 rate-limit 을 피하기 위해 청크로 출력.
    debugPrint('[PERF] $msg');
  }
}
