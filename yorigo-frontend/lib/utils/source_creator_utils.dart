/// 레시피 source 메타데이터에서 크리에이터 @핸들을 해석한다.
///
/// 플랫폼마다 `uploader_id` 의미가 다르다.
/// - YouTube: 채널 핸들/ID (`jian_home`, `UC...`)
/// - Instagram/TikTok: 내부 숫자 PK — 실제 아이디는 `uploader`에 있음

String _withAtPrefix(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';
  return trimmed.startsWith('@') ? trimmed : '@$trimmed';
}

/// 순수 숫자(또는 @+숫자)면 소셜 플랫폼 내부 PK로 간주한다.
bool isNumericCreatorInternalId(String? raw) {
  if (raw == null || raw.trim().isEmpty) return false;
  final stripped = raw.trim().replaceFirst(RegExp(r'^@'), '');
  return RegExp(r'^\d+$').hasMatch(stripped);
}

bool _isInstagramPlatform(String? platform) {
  final p = (platform ?? '').toLowerCase();
  return p == 'instagram' || p == 'instagramweb';
}

bool _isTikTokPlatform(String? platform) {
  final p = (platform ?? '').toLowerCase();
  return p == 'tiktok' || p == 'tiktokweb';
}

/// source 필드로부터 UI에 표시할 @핸들을 반환한다.
String resolveCreatorHandle({
  String? platform,
  String? uploader,
  String? uploaderId,
  String? channel,
  String fallback = '@Chef',
}) {
  final up = (uploader ?? '').trim();
  final ch = (channel ?? '').trim();
  final id = (uploaderId ?? '').trim();

  // Instagram/TikTok: username은 uploader, uploader_id는 숫자 PK.
  if (_isInstagramPlatform(platform) || _isTikTokPlatform(platform)) {
    if (up.isNotEmpty) return _withAtPrefix(up);
    if (ch.isNotEmpty && !isNumericCreatorInternalId(ch)) {
      return _withAtPrefix(ch);
    }
    return fallback;
  }

  // YouTube 등: uploader_id가 핸들/채널 ID. 순수 숫자면 uploader로 fallback.
  if (id.isNotEmpty && !isNumericCreatorInternalId(id)) {
    return _withAtPrefix(id);
  }
  if (up.isNotEmpty) return _withAtPrefix(up);
  if (ch.isNotEmpty) return _withAtPrefix(ch);
  return fallback;
}
