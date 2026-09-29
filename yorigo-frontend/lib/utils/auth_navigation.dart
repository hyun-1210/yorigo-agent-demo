import 'package:flutter/material.dart';

/// After sign-in, always navigate to `/`; [TermsAgreementGate] in [main.dart] shows terms if needed.
class AuthNavigation {
  AuthNavigation._();

  static bool pendingOpenAddRecipe = false;

  static void navigateToAuthenticatedHome(
    BuildContext context, {
    bool openAddRecipe = false,
  }) {
    pendingOpenAddRecipe = openAddRecipe;
    Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
  }

  /// After terms/signup, show onboarding then land on `/`.
  static void navigateToOnboarding(
    BuildContext context, {
    String? continueRouteName,
    Object? continueRouteArguments,
  }) {
    Navigator.of(context).pushNamedAndRemoveUntil(
      '/onboarding',
      (route) => false,
      arguments: {
        if (continueRouteName != null) 'continueRouteName': continueRouteName,
        if (continueRouteArguments != null)
          'continueRouteArguments': continueRouteArguments,
      },
    );
  }
}
