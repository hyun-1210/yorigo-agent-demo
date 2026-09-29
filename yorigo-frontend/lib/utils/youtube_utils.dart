/// YouTube URL에서 video ID를 추출하는 유틸리티 함수들
library;

/// YouTube URL에서 video ID를 추출합니다.
/// 
/// 지원하는 URL 형식:
/// - https://www.youtube.com/watch?v=VIDEO_ID
/// - https://youtu.be/VIDEO_ID
/// - https://www.youtube.com/embed/VIDEO_ID
/// - https://www.youtube.com/v/VIDEO_ID
/// - https://www.youtube.com/shorts/VIDEO_ID
/// 
/// Returns null if video ID를 찾을 수 없는 경우
String? extractYouTubeVideoId(String url) {
  if (url.isEmpty) return null;

  // 정규식 패턴으로 YouTube video ID 추출
  final patterns = [
    // youtube.com/watch?v=VIDEO_ID
    RegExp(r'(?:youtube\.com\/watch\?v=|youtube\.com\/embed\/|youtube\.com\/v\/)([a-zA-Z0-9_-]{11})'),
    // youtu.be/VIDEO_ID
    RegExp(r'youtu\.be\/([a-zA-Z0-9_-]{11})'),
    // youtube.com/shorts/VIDEO_ID
    RegExp(r'youtube\.com\/shorts\/([a-zA-Z0-9_-]{11})'),
    // URL에 직접 포함된 11자리 ID (마지막 fallback)
    RegExp(r'([a-zA-Z0-9_-]{11})(?:\?|&|$|#)'),
  ];

  for (final pattern in patterns) {
    final match = pattern.firstMatch(url);
    if (match != null && match.groupCount >= 1) {
      final videoId = match.group(1);
      if (videoId != null && videoId.length == 11) {
        return videoId;
      }
    }
  }

  return null;
}

/// URL이 YouTube URL인지 확인합니다.
bool isYouTubeUrl(String url) {
  if (url.isEmpty) return false;
  
  final lowerUrl = url.toLowerCase();
  return lowerUrl.contains('youtube.com') || 
         lowerUrl.contains('youtu.be') ||
         lowerUrl.contains('youtube.com/shorts');
}

/// URL이 명시적인 YouTube Shorts URL인지 확인합니다.
///
/// 주의: `youtu.be/VIDEO_ID` 같은 단축 공유 URL은 Shorts/일반 영상 둘 다
/// 동일한 포맷이라 URL만으로 구분이 불가능하므로 false를 반환합니다.
/// 정확한 판별이 필요하면 backend에서 oEmbed API 등으로 미리 판단해
/// 메타데이터로 내려주거나, 등록 시 URL을 `youtube.com/shorts/...` 형태로
/// 정규화해 저장하는 것을 권장합니다.
bool isYouTubeShortUrl(String url) {
  if (url.isEmpty) return false;
  final lowerUrl = url.toLowerCase();
  return lowerUrl.contains('youtube.com/shorts/') ||
      lowerUrl.contains('m.youtube.com/shorts/');
}

double? _asPositiveDouble(Object? raw) {
  if (raw is num) {
    final value = raw.toDouble();
    return value > 0 ? value : null;
  }
  if (raw is String) {
    final trimmed = raw.trim();
    final value = double.tryParse(trimmed);
    if (value != null && value > 0) return value;
    return _iso8601DurationSeconds(trimmed);
  }
  return null;
}

double? _iso8601DurationSeconds(String raw) {
  final match = RegExp(
    r'^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?$',
    caseSensitive: false,
  ).firstMatch(raw.trim());
  if (match == null) return null;
  final hours = int.tryParse(match.group(1) ?? '') ?? 0;
  final minutes = int.tryParse(match.group(2) ?? '') ?? 0;
  final seconds = double.tryParse(match.group(3) ?? '') ?? 0;
  final total = hours * 3600 + minutes * 60 + seconds;
  return total > 0 ? total : null;
}

String youtubeSourceUrlOf(Map<String, dynamic> source) {
  final url = source['url'];
  if (url is String && url.trim().isNotEmpty) return url.trim();
  final alt = source['sourceUrl'];
  if (alt is String && alt.trim().isNotEmpty) return alt.trim();
  if (url != null) {
    final text = url.toString().trim();
    if (text.isNotEmpty && text != 'null') return text;
  }
  return '';
}

double? youtubeDurationSecFromSource(Map<String, dynamic> source) {
  const keys = <String>[
    'duration_sec',
    'durationSec',
    'duration_seconds',
    'lengthSeconds',
    'length_seconds',
  ];
  for (final key in keys) {
    final value = _asPositiveDouble(source[key]);
    if (value != null) return value;
  }
  return null;
}

/// YouTube IFrame 이 알려 준 실제 재생 길이. 저장된 `is_short`/해상도보다 우선.
final Map<String, double> _playbackDurationSecByVideoId = <String, double>{};

/// 재생 길이를 기억한다. 값이 바뀌었으면 true.
bool rememberYouTubePlaybackDuration(String videoId, double seconds) {
  if (videoId.isEmpty || seconds <= 0.5) return false;
  final previous = _playbackDurationSecByVideoId[videoId];
  if (previous != null && (previous - seconds).abs() < 0.5) return false;
  _playbackDurationSecByVideoId[videoId] = seconds;
  return true;
}

/// 인라인 플레이어를 가로 롱폼(16:9) 박스로 둘지 여부.
///
/// 9:16 숏폼은 1:1 박스 안에 세로 플레이어, 가로 롱폼만 시네마 박스.
/// `youtu.be` 는 숏폼·롱폼이 같은 포맷이라 URL만으로 구분할 수 없다.
/// `/shorts/`·`is_short==true`·세로 픽셀은 숏폼.
/// 짧아도 가로 해상도면 시네마(16:9)를 쓴다. 길이만으로 가로 영상을
/// 숏폼 박스에 넣지 않는다.
///
/// YouTube Shorts 최대 길이는 3분(180초). 길이를 모르면 숏폼 플레이어.
const double youtubeShortsMaxDurationSec = 180;

bool isLandscapeYouTubeSource(Map<String, dynamic> source) {
  final url = youtubeSourceUrlOf(source);
  if (isYouTubeShortUrl(url)) return false;

  final width = _asPositiveDouble(source['width']);
  final height = _asPositiveDouble(source['height']);
  final isPortrait = width != null && height != null && height > width * 1.05;
  final isLandscape = width != null && height != null && width > height * 1.05;
  if (isPortrait) return false;
  // 확실한 가로는 시네마. 예전 duration≤180 오기록(is_short=true)도 덮지 않는다.
  if (isLandscape) return true;

  final isShort = source['is_short'];
  if (isShort == true) return false;

  final videoId = extractYouTubeVideoId(url);
  final duration = (videoId != null
          ? _playbackDurationSecByVideoId[videoId]
          : null) ??
      youtubeDurationSecFromSource(source);

  if (duration != null && duration > youtubeShortsMaxDurationSec) {
    return true;
  }

  return false;
}

/// nocookie WebView 최상위 이동만 허용. intent:// · youtube: · market: 는 앱을 나간다.
bool isYouTubeEmbedNavigationAllowed(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'about' || scheme == 'data' || scheme == 'blob') return true;
  if (scheme != 'https' && scheme != 'http') return false;
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return false;
  return host.endsWith('youtube.com') ||
      host.endsWith('youtube-nocookie.com') ||
      host.endsWith('youtu.be') ||
      host.endsWith('ytimg.com') ||
      host.endsWith('googlevideo.com') ||
      host.endsWith('gstatic.com') ||
      host.endsWith('google.com') ||
      host.endsWith('googleapis.com') ||
      host.endsWith('ggpht.com') ||
      host.endsWith('googleusercontent.com') ||
      host.endsWith('doubleclick.net') ||
      host.endsWith('googlesyndication.com');
}


