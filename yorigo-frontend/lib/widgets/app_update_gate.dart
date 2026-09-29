import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_store_update_service.dart';
import '../services/play_store_update_service.dart';

class AppUpdateGate extends StatefulWidget {
  const AppUpdateGate({
    super.key,
    required this.child,
    AppStoreUpdateService? appStoreUpdateService,
    PlayStoreUpdateService? playStoreUpdateService,
  }) : _appStoreUpdateService = appStoreUpdateService,
       _playStoreUpdateService = playStoreUpdateService;

  final Widget child;
  final AppStoreUpdateService? _appStoreUpdateService;
  final PlayStoreUpdateService? _playStoreUpdateService;

  @override
  State<AppUpdateGate> createState() => _AppUpdateGateState();
}

class _AppUpdateGateState extends State<AppUpdateGate> {
  late final AppStoreUpdateService _appStoreUpdateService =
      widget._appStoreUpdateService ?? AppStoreUpdateService();
  late final PlayStoreUpdateService _playStoreUpdateService =
      widget._playStoreUpdateService ?? PlayStoreUpdateService();
  bool _didCheck = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_checkForUpdate());
    });
  }

  Future<void> _checkForUpdate() async {
    if (_didCheck) return;
    _didCheck = true;

    try {
      final playUpdate = await _playStoreUpdateService.checkForUpdate();
      if (!mounted) return;
      if (playUpdate.updateAvailable) {
        if (playUpdate.immediateUpdateAllowed) {
          final completed = await _playStoreUpdateService
              .performImmediateUpdate();
          if (!mounted || completed) return;
          final launchedManualStore = await _openStore(
            _androidPlayStoreUpdateInfo.storeUrl,
          );
          if (!mounted || launchedManualStore) return;
        }
        await _showForcedUpdateDialog(_androidPlayStoreUpdateInfo);
        return;
      }

      final appStoreUpdate = await _appStoreUpdateService.checkForUpdate();
      if (!mounted) return;
      if (appStoreUpdate.updateAvailable) {
        await _showForcedUpdateDialog(
          _iosAppStoreUpdateInfo(appStoreUpdate.storeUrl),
        );
        return;
      }
    } catch (e, st) {
      if (kDebugMode) {
        print('[AppUpdateGate] update check failed: $e');
        print('$st');
      }
    }
  }

  static const _ForcedUpdateInfo _androidPlayStoreUpdateInfo =
      _ForcedUpdateInfo(
        title: '업데이트가 필요해요',
        message: '최신 버전으로 업데이트해야 요리고를 계속 사용할 수 있어요.',
        storeUrl:
            'https://play.google.com/store/apps/details?id=com.yorigo.mobile',
      );

  static _ForcedUpdateInfo _iosAppStoreUpdateInfo(String? dynamicStoreUrl) =>
      _ForcedUpdateInfo(
        title: '업데이트가 필요해요',
        message: '최신 버전으로 업데이트해야 요리고를 계속 사용할 수 있어요.',
        storeUrl:
            dynamicStoreUrl ??
            'https://apps.apple.com/kr/search?term=%EC%9A%94%EB%A6%AC%EA%B3%A0',
      );

  Future<void> _showForcedUpdateDialog(_ForcedUpdateInfo update) {
    return showGeneralDialog<void>(
      context: context,
      barrierLabel: update.title,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.42),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (ctx, _, _) => const SizedBox.shrink(),
      transitionBuilder: (ctx, anim, _, _) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return PopScope(
          canPop: false,
          child: Opacity(
            opacity: curved.value,
            child: Transform.scale(
              scale: 0.96 + 0.04 * curved.value,
              child: _ForcedUpdateDialog(
                title: update.title,
                message: update.message,
                onUpdate: () => unawaited(_openStore(update.storeUrl)),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<bool> _openStore(String storeUrl) async {
    final uri = Uri.tryParse(storeUrl);
    if (uri == null) return false;

    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('스토어를 열 수 없습니다. 잠시 후 다시 시도해 주세요.')),
      );
    }
    return launched;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ForcedUpdateInfo {
  const _ForcedUpdateInfo({
    required this.title,
    required this.message,
    required this.storeUrl,
  });

  final String title;
  final String message;
  final String storeUrl;
}

class _ForcedUpdateDialog extends StatelessWidget {
  const _ForcedUpdateDialog({
    required this.title,
    required this.message,
    required this.onUpdate,
  });

  final String title;
  final String message;
  final VoidCallback onUpdate;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.10),
                    blurRadius: 30,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF111111),
                              letterSpacing: -0.43,
                              height: 1.35,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            message,
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF6B7280),
                              letterSpacing: -0.35,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: onUpdate,
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: const Color(0xFFFF6B00),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text(
                            '업데이트',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                              letterSpacing: -0.375,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
