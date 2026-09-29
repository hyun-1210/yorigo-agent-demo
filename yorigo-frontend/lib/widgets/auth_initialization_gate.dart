import 'package:flutter/material.dart';

import '../utils/auth_session_ready.dart';

/// Blocks the main UI until Firebase Auth session restore has settled.
class AuthInitializationGate extends StatelessWidget {
  const AuthInitializationGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (AuthSessionController.instance.sessionReady) {
      return child;
    }

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
}
