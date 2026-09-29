import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class IosActionSheetAction {
  const IosActionSheetAction({
    required this.id,
    required this.title,
    this.destructive = false,
  });

  final String id;
  final String title;
  final bool destructive;
}

/// iPhone-only official `UIAlertController` action sheet.
///
/// Returns `null` when the user cancels. Throws [MissingPluginException]
/// when the native plugin is not available so callers can fall back.
class IosActionSheet {
  IosActionSheet._();

  static const _channel = MethodChannel('yorigo.app/ios_action_sheet');

  static bool shouldUse(BuildContext context) {
    if (kIsWeb) return false;
    if (defaultTargetPlatform != TargetPlatform.iOS) return false;
    return MediaQuery.sizeOf(context).shortestSide < 600;
  }

  /// Centered confirm/cancel alert (`UIAlertController` `.alert`).
  static Future<bool?> showConfirm({
    required BuildContext context,
    required String title,
    String? message,
    String confirmLabel = '확인',
    String cancelLabel = '취소',
    bool destructive = false,
  }) async {
    final value = await _channel.invokeMethod<bool>('showConfirm', <String, dynamic>{
      'title': title,
      'message': message,
      'confirmLabel': confirmLabel,
      'cancelLabel': cancelLabel,
      'destructive': destructive,
    });
    return value;
  }

  static Future<String?> show({
    required BuildContext context,
    String? title,
    String? message,
    required List<IosActionSheetAction> actions,
    String cancelLabel = '취소',
  }) {
    return _channel.invokeMethod<String>('show', <String, dynamic>{
      'title': title,
      'message': message,
      'cancelLabel': cancelLabel,
      'actions': [
        for (final action in actions)
          <String, dynamic>{
            'id': action.id,
            'title': action.title,
            'destructive': action.destructive,
          },
      ],
    });
  }
}
