import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../screens/onboarding_screen.dart';
import '../services/user_service.dart';
import '../utils/auth_session_ready.dart';

/// 로그인된 유저가 아직 온보딩을 끝내지 않았으면 [OnboardingScreen]을 연다.
/// 완료 여부는 메모리·로컬 캐시로 먼저 보고, 없으면 Firestore를 한 번 읽는다.
class OnboardingGate extends StatefulWidget {
  const OnboardingGate({super.key, required this.child});

  final Widget child;

  @override
  State<OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends State<OnboardingGate> {
  final UserService _userService = UserService();
  StreamSubscription<User?>? _authSub;
  bool _busy;
  bool _showOnboarding = false;
  String? _lastUid;
  Map<String, dynamic>? _userData;

  _OnboardingGateState()
      : _busy = !_hasCompletedInMemory(FirebaseAuth.instance.currentUser?.uid);

  static bool _hasCompletedInMemory(String? uid) {
    return uid != null && UserService.isOnboardingCompletedInMemory(uid);
  }

  @override
  void initState() {
    super.initState();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null && UserService.isOnboardingCompletedInMemory(uid)) {
      _lastUid = uid;
    }
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      unawaited(_reload(user?.uid));
    });
    unawaited(_reload(FirebaseAuth.instance.currentUser?.uid));
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  Future<void> _reload(String? uid) async {
    if (shouldIgnoreTransientAuthNull()) return;
    if (uid == null) {
      _lastUid = null;
      _userData = null;
      if (!mounted) return;
      setState(() {
        _showOnboarding = false;
        _busy = false;
      });
      return;
    }
    if (uid == _lastUid && !_busy) return;
    if (UserService.isOnboardingCompletedInMemory(uid)) {
      _lastUid = uid;
      if (!mounted) return;
      setState(() {
        _showOnboarding = false;
        _busy = false;
      });
      return;
    }
    try {
      final needs = await _userService.needsOnboarding(uid);
      _lastUid = uid;
      if (needs) {
        _userData = await _userService.readUserData(uid);
      } else {
        _userData = null;
      }
      if (!mounted) return;
      setState(() {
        _showOnboarding = needs;
        _busy = false;
      });
    } catch (e, st) {
      if (kDebugMode) {
        print('[OnboardingGate] _reload failed: $e');
        print('$st');
      }
      // 완료로 찍지 않는다. 초안이 있으면 이어서 열고, 없으면 이번만 홈.
      // 다음 기동에서 Firestore를 다시 본다.
      var resumeDraft = false;
      try {
        resumeDraft = await _userService.hasOnboardingDraft(uid);
      } catch (_) {
        resumeDraft = false;
      }
      if (!mounted) return;
      setState(() {
        _showOnboarding = resumeDraft;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return const Scaffold(
        body: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_showOnboarding) {
      return OnboardingScreen(initialUserData: _userData);
    }
    return widget.child;
  }
}
