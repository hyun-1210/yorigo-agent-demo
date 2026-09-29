import 'package:http/http.dart' as http;

/// Web/stub: 기본 HTTP 클라이언트 (IPv4 강제 불가).
http.Client createParsingHttpClient({required String preferIpv4Host}) {
  return http.Client();
}
