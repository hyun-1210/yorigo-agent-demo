import 'dart:io';

import 'package:cupertino_http/cupertino_http.dart';
import 'package:http/http.dart' as http;

/// 파싱 전용 HTTP 클라이언트 (실질적으로 iOS 전용).
///
/// iOS: `CupertinoClient`(URLSession). Happy Eyeballs 로 AAAA 실패 시
/// 빠르게 IPv4 로 넘어가며 TLS/SNI 가 네이티브 스택에서 정상 동작한다.
/// (dart:io IPv4 `connectionFactory` 는 Cloudflare HTML 400 을 유발했음)
///
/// Android 는 [ApiService._openParsingClient] 에서 이 함수를 호출하지 않고
/// 기본 `http.Client()` 를 쓴다. 여기의 non-iOS 분기는 안전망이다.
http.Client createParsingHttpClient({required String preferIpv4Host}) {
  if (Platform.isIOS) {
    return CupertinoClient.defaultSessionConfiguration();
  }
  // preferIpv4Host 는 iOS 경로에서만 의미가 있음 (API 호환용으로 유지).
  return http.Client();
}
