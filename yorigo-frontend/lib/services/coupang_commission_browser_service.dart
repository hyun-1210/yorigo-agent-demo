import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Close reason reported by the native iOS Coupang commission browser.
enum CoupangCommissionBrowserCloseReason {
  userDismissed,
  openedNativeApp,
  stayedOnWeb,
  returnedFromExternalApp,
  unknown;

  static CoupangCommissionBrowserCloseReason fromNative(String? raw) {
    return switch (raw) {
      'userDismissed' => CoupangCommissionBrowserCloseReason.userDismissed,
      'openedNativeApp' => CoupangCommissionBrowserCloseReason.openedNativeApp,
      'stayedOnWeb' => CoupangCommissionBrowserCloseReason.stayedOnWeb,
      'returnedFromExternalApp' =>
        CoupangCommissionBrowserCloseReason.returnedFromExternalApp,
      _ => CoupangCommissionBrowserCloseReason.unknown,
    };
  }
}

/// Native iOS in-app browser for Coupang affiliate links with auto-close.
class CoupangCommissionBrowserService {
  CoupangCommissionBrowserService._();

  static const _channel = MethodChannel('yorigo.app/marketplace');

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// Opens [url] in the native browser and completes when it auto-closes or the
  /// user taps Done.
  static Future<CoupangCommissionBrowserCloseReason> openCommissionLink(
    Uri url,
  ) async {
    if (!isSupported) {
      return CoupangCommissionBrowserCloseReason.unknown;
    }

    try {
      final result = await _channel.invokeMethod<Object?>(
        'openCoupangCommissionLink',
        {'url': url.toString()},
      );
      if (result is Map) {
        return CoupangCommissionBrowserCloseReason.fromNative(
          result['reason']?.toString(),
        );
      }
    } on PlatformException {
      // Fall through to unknown.
    } on MissingPluginException {
      // Native channel not registered (e.g. old build).
    }
    return CoupangCommissionBrowserCloseReason.unknown;
  }
}
