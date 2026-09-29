import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

const authWasLoggedInPrefsKey = 'auth_was_logged_in_v1';

/// Tracks whether Firebase Auth has finished its cold-start session restore.
class AuthSessionController {
  AuthSessionController._();

  static final instance = AuthSessionController._();

  bool sessionReady = false;

  void markSessionReady() {
    sessionReady = true;
  }
}

/// Waits for Firebase Auth disk session restore to settle after a cold start.
///
/// [authStateChanges().first] resolves on the first emission, which is often
/// `null` before persistence finishes. This helper debounces auth events and,
/// when the user was previously logged in, waits longer before accepting null.
Future<User?> waitForFirebaseAuthSessionReady({
  Duration debounce = const Duration(milliseconds: 350),
  Duration maxWait = const Duration(seconds: 3),
}) async {
  final auth = FirebaseAuth.instance;

  Future<User?> readStableUser() async {
    final before = auth.currentUser;
    await Future.delayed(debounce);
    final after = auth.currentUser;
    if (before?.uid == after?.uid) {
      return after;
    }
    return null;
  }

  var stable = await readStableUser();
  if (stable != null) {
    await syncAuthLoggedInPreference(stable);
    AuthSessionController.instance.markSessionReady();
    return stable;
  }

  final prefs = await SharedPreferences.getInstance();
  final wasLoggedIn = prefs.getBool(authWasLoggedInPrefsKey) ?? false;
  final deadline = DateTime.now().add(maxWait);

  while (DateTime.now().isBefore(deadline)) {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      break;
    }

    try {
      await auth.authStateChanges().first.timeout(
        remaining > const Duration(milliseconds: 500)
            ? const Duration(milliseconds: 500)
            : remaining,
      );
    } on TimeoutException {
      break;
    }

    stable = await readStableUser();
    if (stable != null) {
      await syncAuthLoggedInPreference(stable);
      AuthSessionController.instance.markSessionReady();
      return stable;
    }

    if (!wasLoggedIn && auth.currentUser == null) {
      break;
    }
  }

  stable = auth.currentUser;
  await syncAuthLoggedInPreference(stable);
  AuthSessionController.instance.markSessionReady();
  return stable;
}

Future<void> syncAuthLoggedInPreference(User? user) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(authWasLoggedInPrefsKey, user != null);
}

/// True while auth may still be restoring and a null user should not be treated
/// as a real sign-out.
bool shouldIgnoreTransientAuthNull() {
  return !AuthSessionController.instance.sessionReady;
}
