import 'package:http/http.dart' as http;

import 'parsing_http_client_stub.dart'
    if (dart.library.io) 'parsing_http_client_io.dart' as impl;

/// 파싱 전용 HTTP 클라이언트.
///
/// iOS: URLSession(`cupertino_http`) — TLS/Happy Eyeballs.
/// Android 외: 기본 `http.Client()` (원본 요청 로직, IPv4 강제 없음).
/// [preferIpv4Host] 는 iOS 쪽 호환 시그니처용이며 Android 에서는 무시된다.
http.Client createParsingHttpClient({required String preferIpv4Host}) {
  return impl.createParsingHttpClient(preferIpv4Host: preferIpv4Host);
}
