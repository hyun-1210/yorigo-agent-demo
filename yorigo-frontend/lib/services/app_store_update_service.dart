import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

class AppStoreUpdateInfo {
  const AppStoreUpdateInfo({
    required this.updateAvailable,
    required this.storeUrl,
  });

  final bool updateAvailable;
  final String? storeUrl;
}

class AppStoreUpdateService {
  static const String _lookupBaseUrl = 'https://itunes.apple.com/lookup';

  Future<AppStoreUpdateInfo> checkForUpdate({String countryCode = 'kr'}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return const AppStoreUpdateInfo(updateAvailable: false, storeUrl: null);
    }

    final packageInfo = await PackageInfo.fromPlatform();
    final bundleId = packageInfo.packageName.trim();
    final currentVersion = packageInfo.version.trim();
    if (bundleId.isEmpty || currentVersion.isEmpty) {
      return const AppStoreUpdateInfo(updateAvailable: false, storeUrl: null);
    }

    final lookupUri = Uri.parse(
      '$_lookupBaseUrl?bundleId=$bundleId&country=$countryCode',
    );
    final response = await http.get(lookupUri);
    if (response.statusCode != 200) {
      return const AppStoreUpdateInfo(updateAvailable: false, storeUrl: null);
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      return const AppStoreUpdateInfo(updateAvailable: false, storeUrl: null);
    }

    final results = decoded['results'];
    if (results is! List || results.isEmpty || results.first is! Map) {
      return const AppStoreUpdateInfo(updateAvailable: false, storeUrl: null);
    }

    final appInfo = results.first as Map;
    final appStoreVersion = (appInfo['version'] as String?)?.trim();
    final trackViewUrl = (appInfo['trackViewUrl'] as String?)?.trim();
    if (appStoreVersion == null || appStoreVersion.isEmpty) {
      return const AppStoreUpdateInfo(updateAvailable: false, storeUrl: null);
    }

    final updateAvailable = _compareVersion(appStoreVersion, currentVersion) > 0;
    return AppStoreUpdateInfo(
      updateAvailable: updateAvailable,
      storeUrl: trackViewUrl?.isNotEmpty == true ? trackViewUrl : null,
    );
  }

  int _compareVersion(String left, String right) {
    final leftParts = _toVersionParts(left);
    final rightParts = _toVersionParts(right);
    final maxLength = leftParts.length > rightParts.length
        ? leftParts.length
        : rightParts.length;

    for (var i = 0; i < maxLength; i++) {
      final leftValue = i < leftParts.length ? leftParts[i] : 0;
      final rightValue = i < rightParts.length ? rightParts[i] : 0;
      if (leftValue != rightValue) return leftValue.compareTo(rightValue);
    }
    return 0;
  }

  List<int> _toVersionParts(String version) {
    final matches = RegExp(r'\d+').allMatches(version);
    if (matches.isEmpty) return const [0];
    return matches
        .map((match) => int.tryParse(match.group(0) ?? '0') ?? 0)
        .toList();
  }
}
