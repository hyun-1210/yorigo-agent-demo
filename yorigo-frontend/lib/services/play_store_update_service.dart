import 'package:flutter/foundation.dart';
import 'package:in_app_update/in_app_update.dart';

class PlayStoreUpdateInfo {
  const PlayStoreUpdateInfo({
    required this.updateAvailable,
    required this.immediateUpdateAllowed,
  });

  final bool updateAvailable;
  final bool immediateUpdateAllowed;
}

class PlayStoreUpdateService {
  Future<PlayStoreUpdateInfo> checkForUpdate() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const PlayStoreUpdateInfo(
        updateAvailable: false,
        immediateUpdateAllowed: false,
      );
    }

    final updateInfo = await InAppUpdate.checkForUpdate();
    return PlayStoreUpdateInfo(
      updateAvailable:
          updateInfo.updateAvailability == UpdateAvailability.updateAvailable,
      immediateUpdateAllowed: updateInfo.immediateUpdateAllowed,
    );
  }

  Future<bool> performImmediateUpdate() async {
    final result = await InAppUpdate.performImmediateUpdate();
    return result == AppUpdateResult.success;
  }
}
