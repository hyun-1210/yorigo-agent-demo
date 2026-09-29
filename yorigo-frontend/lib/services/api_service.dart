import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kDebugMode, kIsWeb;
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import '../config/environment_config.dart';
import '../utils/instagram_utils.dart';
import '../utils/parsing_http_client.dart';
import '../utils/receipt_scan_item_normalizer.dart';
import '../utils/tiktok_utils.dart';
import '../utils/youtube_utils.dart';
import '../utils/naver_blog_utils.dart';

class ApiService {
  // Backend URL is automatically determined based on environment
  static String get baseUrl => EnvironmentConfig.baseUrl;
  /// 파싱 API 전용 URL (맥미니 파싱 워커 또는 baseUrl 폴백)
  static String get parsingBaseUrl => EnvironmentConfig.parsingBaseUrl;

  /// 디바이스 OS 태그 — 로그/서버 식별용 (`ios` / `android` / …).
  static String get deviceOsTag {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      default:
        return defaultTargetPlatform.name.toLowerCase();
    }
  }

  static bool get _isIosDevice => deviceOsTag == 'ios';

  static void _debugLog(String message) {
    if (kDebugMode) {
      print('[${deviceOsTag}] $message');
    }
  }

  /// 파싱 라우팅 결정은 릴리즈에서도 로그 (TestFlight에서 맥미니 vs Railway 확인용).
  /// 모든 줄 앞에 `[ios]` / `[android]` 를 붙여 플랫폼을 즉시 구분한다.
  static void _logParsingRoute(String message) {
    print('[${deviceOsTag}] $message');
  }

  /// iOS 는 Cloudflare tunnel + 셀룰러에서 연결이 더 자주 흔들려 여유 있게.
  static Duration get _parseConnectTimeout =>
      _isIosDevice ? const Duration(seconds: 30) : const Duration(seconds: 20);

  /// 맥미니 호스트(IPv4 강제 대상). Railway 폴백에는 적용하지 않는다.
  static String get _macMiniHost {
    try {
      return Uri.parse(EnvironmentConfig.parsingBaseUrl).host;
    } catch (_) {
      return 'parse.yorigo.kr';
    }
  }

  static Map<String, String> _parsingHeaders() => <String, String>{
        'Content-Type': 'application/json',
        'X-Client-Platform': deviceOsTag,
      };

  /// 파싱 전용 클라이언트.
  /// iOS=URLSession(Cupertino) / Android=기본 http.Client (원본 로직).
  /// Android 에는 IPv4 Socket 강제를 쓰지 않는다 (Cloudflare HTML 400 이슈).
  static http.Client _openParsingClient() {
    if (_isIosDevice) {
      return createParsingHttpClient(preferIpv4Host: _macMiniHost);
    }
    return http.Client();
  }

  /// 디버깅 로그용 레시피 소스 플랫폼 라벨 (youtube/instagram/…).
  static String _detectPlatformLabel(String url) {
    if (isYouTubeUrl(url)) return 'youtube';
    if (isInstagramUrl(url)) return 'instagram';
    if (isTikTokUrl(url)) return 'tiktok';
    if (isNaverBlogUrl(url)) return 'naver_blog';
    return 'unknown';
  }

  // ──────────────────────────────────────────────────────────────────────
  //  파싱 Failover: 맥미니(주) → 클라우드(AWS/Railway) 자동 폴백
  //  맥미니가 다운/멈춤이면 클라우드가 파싱을 대신 처리한다. 클라우드는 항상
  //  살아있고 파싱 엔드포인트가 마운트돼 있으므로 안전망이 된다.
  // ──────────────────────────────────────────────────────────────────────

  /// 파싱 요청을 시도할 base URL 목록을 우선순위 순으로 반환한다.
  ///
  /// 1) 맥미니(parse.yorigo.kr) — iOS 3회 / Android 2회
  /// 2) 클라우드(Railway/AWS) 폴백
  ///
  /// 전송 클라이언트는 플랫폼별로 다름: iOS=Cupertino URLSession,
  /// Android=기본 http.Client ([_openParsingClient]).
  static Future<List<String>> _resolveParsingBases() async {
    final candidates = EnvironmentConfig.parsingBaseUrlCandidates;
    if (candidates.length <= 1) {
      _logParsingRoute(
        '[ApiService] parse route (single host): ${candidates.join(' → ')}',
      );
      return candidates;
    }
    final primary = candidates.first; // 맥미니
    final fallback = candidates.last; // 클라우드
    // iOS: 일시 tunnel/DNS 실패에 Railway로 바로 튀지 않도록 맥미니 3회.
    final macMiniAttempts = _isIosDevice ? 3 : 2;
    final bases = <String>[
      for (var i = 0; i < macMiniAttempts; i++) primary,
      fallback,
    ];
    final clientLabel =
        _isIosDevice ? 'ios=CupertinoClient' : 'android=default http.Client';
    _logParsingRoute(
      '[ApiService] parse route: ${bases.join(' → ')} ($clientLabel)',
    );
    return bases;
  }

  /// [bases] 순회 중 다음 후보가 아직 맥미니인지(재시도) / 클라우드인지(폴백).
  static String _nextHostActionLabel(List<String> bases, int currentIndex) {
    if (currentIndex + 1 >= bases.length) return 'give up';
    final next = bases[currentIndex + 1];
    final current = bases[currentIndex];
    if (next == current && next == parsingBaseUrl) {
      return 'retry Mac mini';
    }
    if (next != parsingBaseUrl) {
      return 'cloud fallback';
    }
    return 'next host';
  }

  /// 연결 단계(요청 전송/응답코드)에서 폴백해야 하는 에러인지 판단.
  /// 연결 거부·호스트 조회 실패·타임아웃·5xx/게이트웨이 오류면 다음 후보로 폴백.
  static bool _shouldFailover(Object error) {
    if (error is http.ClientException) return true;
    final s = error.toString().toLowerCase();
    return s.contains('socketexception') ||
        s.contains('connection refused') ||
        s.contains('connection closed') ||
        s.contains('connection reset') ||
        s.contains('failed host lookup') ||
        s.contains('network is unreachable') ||
        s.contains('timed out') ||
        s.contains('timeout') ||
        s.contains('handshake');
  }

  /// 5xx/게이트웨이 상태코드(맥미니 멈춤·재시작 등)면 폴백 대상.
  ///
  /// 또한 Cloudflare/nginx 가 TLS 없이 443 으로 받은 요청에 주는
  /// HTML `400 The plain HTTP request was sent to HTTPS port` 는
  /// 레시피 API 의 JSON 400 과 구분되며 전송 실패로 취급한다.
  /// (JSON `{"detail":...}` 형태 400 은 폴백하지 않음 — not_cooking 등)
  static bool _isFailoverStatus(int statusCode, {String? body}) {
    if (statusCode == 502 ||
        statusCode == 503 ||
        statusCode == 504 ||
        statusCode == 520 ||
        statusCode == 521 ||
        statusCode == 522 ||
        statusCode == 523 ||
        statusCode == 524 ||
        statusCode == 525 ||
        statusCode == 526 ||
        statusCode == 530) {
      return true;
    }
    if (statusCode != 400) return false;
    final b = body ?? '';
    if (b.isEmpty) return false;
    final lower = b.toLowerCase();
    return lower.contains('plain http') ||
        lower.contains('<html') ||
        lower.contains('<!doctype');
  }

  static Future<Map<String, dynamic>> parseRecipe({
    required String url,
    String? preferLang,
  }) async {
    final bases = await _resolveParsingBases();
    Object? lastError;
    for (var i = 0; i < bases.length; i++) {
      final base = bases[i];
      final isLast = i == bases.length - 1;
      final client = _openParsingClient();
      try {
        final response = await client
            .post(
              Uri.parse('$base/parse_recipe'),
              headers: _parsingHeaders(),
              body: jsonEncode({
                'url': url,
                if (preferLang != null) 'prefer_lang': preferLang,
              }),
            )
            .timeout(_parseConnectTimeout);

        if (response.statusCode == 200) {
          if (base != parsingBaseUrl) {
            _logParsingRoute(
              '[ApiService] parseRecipe handled via cloud fallback: $base',
            );
          } else {
            _logParsingRoute(
              '[ApiService] parseRecipe handled via Mac mini: $base',
            );
          }
          return jsonDecode(response.body) as Map<String, dynamic>;
        }
        // 5xx/게이트웨이·전송계층 400(HTML)이면 다음 후보로
        if (!isLast &&
            _isFailoverStatus(response.statusCode, body: response.body)) {
          final action = _nextHostActionLabel(bases, i);
          _logParsingRoute(
            '[ApiService] parseRecipe $base HTTP ${response.statusCode} → $action',
          );
          lastError = Exception('HTTP ${response.statusCode} from $base');
          if (base == parsingBaseUrl) {
            await Future<void>.delayed(const Duration(milliseconds: 400));
          }
          continue;
        }
        throw Exception('Failed to parse recipe: ${response.statusCode}');
      } catch (e) {
        lastError = e;
        if (!isLast && _shouldFailover(e)) {
          final action = _nextHostActionLabel(bases, i);
          _logParsingRoute(
            '[ApiService] parseRecipe $base connect failed → $action: $e',
          );
          if (base == parsingBaseUrl) {
            await Future<void>.delayed(const Duration(milliseconds: 400));
          }
          continue;
        }
        throw Exception('Error calling API: $e');
      } finally {
        client.close();
      }
    }
    throw Exception('Error calling API: $lastError');
  }

  /// Fire-and-forget parse request. The backend processes the recipe in a
  /// background thread, writes the result directly to Firestore, and sends
  /// an FCM push notification when done. The client monitors progress via
  /// Firestore snapshots on recipes/{recipeId}.
  static Future<void> parseRecipeAsync({
    required String url,
    required String recipeId,
    required String userId,
    String? preferLang,
  }) async {
    final bases = await _resolveParsingBases();
    Object? lastError;
    for (var i = 0; i < bases.length; i++) {
      final base = bases[i];
      final isLast = i == bases.length - 1;
      final client = _openParsingClient();
      try {
        _logParsingRoute(
          '[ApiService] parseRecipeAsync try #$i → $base '
          '(recipeId=$recipeId)',
        );
        final response = await client
            .post(
              Uri.parse('$base/parse_recipe_async'),
              headers: _parsingHeaders(),
              body: jsonEncode({
                'url': url,
                'recipe_id': recipeId,
                'user_id': userId,
                if (preferLang != null) 'prefer_lang': preferLang,
              }),
            )
            .timeout(_parseConnectTimeout);

        if (response.statusCode == 200) {
          if (base != parsingBaseUrl) {
            _logParsingRoute(
              '[ApiService] parseRecipeAsync handled via cloud fallback: $base',
            );
          } else {
            _logParsingRoute(
              '[ApiService] parseRecipeAsync queued on Mac mini: $base',
            );
          }
          return;
        }
        if (!isLast &&
            _isFailoverStatus(response.statusCode, body: response.body)) {
          final action = _nextHostActionLabel(bases, i);
          _logParsingRoute(
            '[ApiService] parseRecipeAsync $base HTTP ${response.statusCode} → $action',
          );
          lastError = Exception('HTTP ${response.statusCode} from $base');
          if (base == parsingBaseUrl) {
            await Future<void>.delayed(const Duration(milliseconds: 400));
          }
          continue;
        }
        throw Exception('Failed to queue parse job: ${response.statusCode}');
      } catch (e) {
        lastError = e;
        if (!isLast && _shouldFailover(e)) {
          final action = _nextHostActionLabel(bases, i);
          _logParsingRoute(
            '[ApiService] parseRecipeAsync $base connect failed → $action: $e',
          );
          if (base == parsingBaseUrl) {
            await Future<void>.delayed(const Duration(milliseconds: 400));
          }
          continue;
        }
        throw Exception('Error calling async parse API: $e');
      } finally {
        client.close();
      }
    }
    throw Exception('Error calling async parse API: $lastError');
  }

  static Stream<Map<String, dynamic>> parseRecipeStream({
    required String url,
    String? preferLang,
  }) async* {
    _debugLog('=' * 60);
    _debugLog('[ApiService] ===== 파싱 요청 시작 =====');
    _debugLog('[ApiService] Environment: ${EnvironmentConfig.currentEnvironment}');
    _debugLog('[ApiService] Recipe URL: $url');
    _debugLog('[ApiService] Detected platform: ${_detectPlatformLabel(url)}');
    _debugLog('[ApiService] Language: ${preferLang ?? "ko"}');
    _debugLog('=' * 60);

    final bases = await _resolveParsingBases();
    _logParsingRoute('[ApiService] parseRecipeStream route: ${bases.join(' → ')}');
    Object? lastError;

    for (var i = 0; i < bases.length; i++) {
      final base = bases[i];
      final isLast = i == bases.length - 1;
      http.Client? client;
      // 스트리밍이 시작된(첫 청크 수신) 이후에는 폴백 금지 — 중복 파싱 방지.
      bool streamingStarted = false;
      try {
        _debugLog('[ApiService] Connecting SSE to $base/parse_recipe_stream');
        if (base != parsingBaseUrl) {
          _logParsingRoute('[ApiService] parseRecipeStream using cloud host: $base');
        }
        final request = http.Request(
          'POST',
          Uri.parse('$base/parse_recipe_stream'),
        );
        request.headers.addAll(_parsingHeaders());
        request.body = jsonEncode({
          'url': url,
          if (preferLang != null) 'prefer_lang': preferLang,
        });

        client = _openParsingClient();

        http.StreamedResponse response;
        try {
          response = await client.send(request).timeout(_parseConnectTimeout);
        } catch (e) {
          // 연결 실패 → 맥미니 재시도 또는 클라우드 폴백
          if (!isLast && _shouldFailover(e)) {
            final action = _nextHostActionLabel(bases, i);
            _logParsingRoute(
              '[ApiService] SSE connect failed ($base) → $action: $e',
            );
            client.close();
            lastError = e;
            continue;
          }
          rethrow;
        }

        if (response.statusCode != 200) {
          String? errorBody;
          try {
            errorBody = await response.stream.bytesToString();
          } catch (_) {}
          if (!isLast &&
              _isFailoverStatus(response.statusCode, body: errorBody)) {
            final action = _nextHostActionLabel(bases, i);
            _logParsingRoute(
              '[ApiService] SSE $base HTTP ${response.statusCode} → $action',
            );
            client.close();
            lastError = Exception('HTTP ${response.statusCode} from $base');
            continue;
          }
          throw Exception(
            '서버에서 오류가 발생했습니다.\n'
            '상태 코드: ${response.statusCode}\n'
            '서버 주소: $base\n'
            '${errorBody != null ? "응답: $errorBody" : ""}',
          );
        }

        _debugLog('[ApiService] Connected to $base, listening for SSE events...');
        String buffer = '';
        int eventCount = 0;

        await for (var chunk in response.stream.transform(utf8.decoder)) {
          streamingStarted = true;
          buffer += chunk;
          final parts = buffer.split('\n\n');
          buffer = parts.last;
          for (var part in parts) {
            if (part.isEmpty) continue;
            final lines = part.split('\n');
            for (var line in lines) {
              if (line.startsWith('data: ')) {
                final data = line.substring(6);
                if (data.trim().isNotEmpty) {
                  try {
                    final parsed = jsonDecode(data) as Map<String, dynamic>;
                    eventCount++;
                    _debugLog('[ApiService] Event #$eventCount: ${parsed['stage']}');
                    yield parsed;
                  } catch (e) {
                    _debugLog('[ApiService] Error parsing SSE data: $e');
                  }
                }
              }
            }
          }
        }

        if (buffer.isNotEmpty) {
          final lines = buffer.split('\n');
          for (var line in lines) {
            if (line.startsWith('data: ')) {
              final data = line.substring(6);
              if (data.trim().isNotEmpty) {
                try {
                  final parsed = jsonDecode(data) as Map<String, dynamic>;
                  eventCount++;
                  yield parsed;
                } catch (e) {
                  _debugLog('[ApiService] Error parsing final SSE data: $e');
                }
              }
            }
          }
        }

        _debugLog('[ApiService] Stream completed ($base), received $eventCount events');
        return; // 성공 — 폴백 루프 종료
      } catch (e) {
        lastError = e;
        // 연결 전 실패면 폴백, 스트리밍 시작 후면 전파.
        if (!isLast && !streamingStarted && _shouldFailover(e)) {
          _debugLog('[ApiService] SSE $base 폴백: $e');
          continue;
        }
        _debugLog('[ApiService] Stream error ($base): $e');
        if (e is Exception) rethrow;
        throw Exception('API 호출 중 오류가 발생했습니다: $e');
      } finally {
        try {
          client?.close();
        } catch (_) {}
      }
    }

    throw Exception(
      '서버에 연결할 수 없습니다. 맥미니와 클라우드 모두 응답하지 않습니다.\n'
      '마지막 에러: $lastError',
    );
  }

  /// Manual paste 파싱 SSE — 텍스트와/또는 스크린샷에서 레시피를 추출한다.
  ///
  /// [text] 와 [images] 중 최소 하나는 비어있지 않아야 한다. 이미지는 호출자가
  /// 미리 [Uint8List]로 디코드해 전달한다 (라우터에서 base64 검증/디코드).
  ///
  /// 이벤트 형식은 [parseRecipeStream] 과 동일하다 (stage / progress /
  /// sub_stage / video_info / result / error / error_type), 따라서 기존
  /// SSE consumer 로직을 그대로 재사용할 수 있다.
  static Stream<Map<String, dynamic>> parseRecipeContentStream({
    String? text,
    List<Uint8List>? images,
    String? preferLang,
  }) async* {
    final bool hasText = text != null && text.trim().isNotEmpty;
    final List<Uint8List> imageList = images ?? const <Uint8List>[];
    if (!hasText && imageList.isEmpty) {
      throw Exception('텍스트 또는 이미지 중 최소 하나는 있어야 합니다.');
    }

    _debugLog('=' * 60);
    _debugLog('[ApiService] ===== 콘텐츠 파싱 요청 시작 =====');
    _debugLog(
      '[ApiService] text=${hasText ? text.trim().length : 0}chars, '
      'images=${imageList.length}',
    );
    _debugLog('[ApiService] Language: ${preferLang ?? "ko"}');
    _debugLog('=' * 60);

    final List<String> base64Images = imageList
        .map((bytes) => base64Encode(bytes))
        .toList(growable: false);

    final bases = await _resolveParsingBases();
    Object? lastError;

    for (var i = 0; i < bases.length; i++) {
      final base = bases[i];
      final isLast = i == bases.length - 1;
      http.Client? client;
      bool streamingStarted = false;
      try {
        final request = http.Request(
          'POST',
          Uri.parse('$base/parse_recipe_content_stream'),
        );
        request.headers.addAll(_parsingHeaders());
        request.body = jsonEncode({
          if (hasText) 'text': text.trim(),
          if (base64Images.isNotEmpty) 'images': base64Images,
          if (preferLang != null) 'prefer_lang': preferLang,
        });

        client = _openParsingClient();
        http.StreamedResponse response;
        try {
          response = await client.send(request).timeout(_parseConnectTimeout);
        } catch (e) {
          if (!isLast && _shouldFailover(e)) {
            final action = _nextHostActionLabel(bases, i);
            _logParsingRoute(
              '[ApiService] content SSE connect failed ($base) → $action: $e',
            );
            client.close();
            lastError = e;
            continue;
          }
          rethrow;
        }

        if (response.statusCode != 200) {
          String? errorBody;
          try {
            errorBody = await response.stream.bytesToString();
          } catch (_) {}
          if (!isLast &&
              _isFailoverStatus(response.statusCode, body: errorBody)) {
            final action = _nextHostActionLabel(bases, i);
            _logParsingRoute(
              '[ApiService] content SSE $base HTTP ${response.statusCode} → $action',
            );
            client.close();
            lastError = Exception('HTTP ${response.statusCode} from $base');
            continue;
          }
          throw Exception(
            '서버에서 오류가 발생했습니다.\n'
            '상태 코드: ${response.statusCode}\n'
            '${errorBody != null ? "응답: $errorBody" : ""}',
          );
        }

        String buffer = '';
        int eventCount = 0;
        await for (var chunk in response.stream.transform(utf8.decoder)) {
          streamingStarted = true;
          buffer += chunk;
          final parts = buffer.split('\n\n');
          buffer = parts.last;
          for (var part in parts) {
            if (part.isEmpty) continue;
            final lines = part.split('\n');
            for (var line in lines) {
              if (line.startsWith('data: ')) {
                final data = line.substring(6);
                if (data.trim().isNotEmpty) {
                  try {
                    final parsed = jsonDecode(data) as Map<String, dynamic>;
                    eventCount++;
                    _debugLog('[ApiService] ContentEvent #$eventCount: ${parsed['stage']}');
                    yield parsed;
                  } catch (e) {
                    _debugLog('[ApiService] Error parsing SSE data (content): $e');
                  }
                }
              }
            }
          }
        }

        if (buffer.isNotEmpty) {
          final lines = buffer.split('\n');
          for (var line in lines) {
            if (line.startsWith('data: ')) {
              final data = line.substring(6);
              if (data.trim().isNotEmpty) {
                try {
                  final parsed = jsonDecode(data) as Map<String, dynamic>;
                  eventCount++;
                  yield parsed;
                } catch (_) {}
              }
            }
          }
        }

        _debugLog('[ApiService] Content stream completed ($base), received $eventCount events');
        return;
      } catch (e) {
        lastError = e;
        if (!isLast && !streamingStarted && _shouldFailover(e)) {
          _debugLog('[ApiService] content SSE $base 폴백: $e');
          continue;
        }
        _debugLog('[ApiService] Content stream error ($base): $e');
        if (e is Exception) rethrow;
        throw Exception('콘텐츠 파싱 호출 중 오류가 발생했습니다: $e');
      } finally {
        try {
          client?.close();
        } catch (_) {}
      }
    }

    throw Exception(
      '서버에 연결할 수 없습니다. 맥미니와 클라우드 모두 응답하지 않습니다.\n'
      '마지막 에러: $lastError',
    );
  }

  static Future<String> categorizeIngredient({
    required String ingredientName,
    String? category,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/categorize_ingredient'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'ingredient_name': ingredientName,
          if (category != null) 'category': category,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data['category'] as String;
      } else {
        throw Exception(
          'Failed to categorize ingredient: ${response.statusCode}',
        );
      }
    } catch (e) {
      _debugLog('[ApiService] Error categorizing ingredient: $e');
      // Fallback to default category
      return '양념/소스';
    }
  }

  static Future<String> reclassifyIngredient({
    required String ingredientName,
    String? oldCategory,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/reclassify_ingredient'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'ingredient_name': ingredientName,
          if (oldCategory != null) 'old_category': oldCategory,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data['category'] as String;
      } else {
        throw Exception(
          'Failed to reclassify ingredient: ${response.statusCode}',
        );
      }
    } catch (e) {
      _debugLog('[ApiService] Error reclassifying ingredient: $e');
      // Fallback based on old category
      if (oldCategory == 'main') {
        return 'protein';
      } else if (oldCategory == 'sauce_msg') {
        return 'seasonings';
      } else if (oldCategory == 'sub') {
        return 'vegetables_fruits';
      }
      return 'seasonings';
    }
  }

  /// ingredient_unit_prices에 없는 재료명을 백엔드 큐에 보고 (로그인 시에만).
  /// 성공 시 true.
  /// 재료 단가가 부정확해 보일 때 보고 → 서버가 재조사 큐에 넣고 주기적으로 LLM 재추정.
  static Future<bool> reportIngredientPriceIssue({
    required List<String> ingredientNames,
    String? message,
    String? recipeId,
    String? recipeTitle,
  }) async {
    if (ingredientNames.isEmpty) return false;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    try {
      final token = await user.getIdToken();
      if (token == null || token.isEmpty) return false;
      final body = <String, dynamic>{
        'ingredient_names': ingredientNames,
        if (message != null && message.trim().isNotEmpty) 'message': message.trim(),
        if (recipeId != null && recipeId.isNotEmpty) 'recipe_id': recipeId,
        if (recipeTitle != null && recipeTitle.isNotEmpty) 'recipe_title': recipeTitle,
      };
      final response = await http.post(
        Uri.parse('$baseUrl/ingredient_prices/report_price_issue'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode(body),
      );
      if (response.statusCode == 200) {
        return true;
      }
      _debugLog(
        '[ApiService] reportIngredientPriceIssue ${response.statusCode}: ${response.body}',
      );
      return false;
    } catch (e) {
      _debugLog('[ApiService] reportIngredientPriceIssue error: $e');
      return false;
    }
  }

  static Future<bool> reportMissingIngredientPrices(List<String> names) async {
    if (names.isEmpty) return true;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    try {
      final token = await user.getIdToken();
      if (token == null || token.isEmpty) return false;
      final response = await http.post(
        Uri.parse('$baseUrl/ingredient_prices/report_missing'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({'names': names}),
      );
      if (response.statusCode == 200) {
        return true;
      }
      _debugLog(
        '[ApiService] reportMissingIngredientPrices ${response.statusCode}: ${response.body}',
      );
      return false;
    } catch (e) {
      _debugLog('[ApiService] reportMissingIngredientPrices error: $e');
      return false;
    }
  }

  /// 요청된 baseUnit에 대한 단위 가격을 백엔드에 on-demand로 요청합니다.
  /// 성공 시 unitPrice를 반환합니다.
  static Future<double?> requestIngredientUnitPrice({
    required String ingredientName,
    required String requestedBaseUnit,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;

    try {
      final token = await user.getIdToken();
      if (token == null || token.isEmpty) return null;

      final response = await http.post(
        Uri.parse('$baseUrl/ingredient_prices/request_unit_price'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'ingredient_name': ingredientName,
          'requested_base_unit': requestedBaseUnit,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final unitPriceNum = data['unitPrice'] as num?;
        return unitPriceNum?.toDouble();
      }

      _debugLog(
        '[ApiService] requestIngredientUnitPrice ${response.statusCode}: ${response.body}',
      );
      return null;
    } catch (e) {
      _debugLog('[ApiService] requestIngredientUnitPrice error: $e');
      return null;
    }
  }

  /// 냉장고 사진 스캔 결과 재료 1건 (POST /fridge/scan_photo 응답 items[]).
  ///
  /// [confidence]가 낮을수록 인식이 불확실하다는 뜻이며, 프론트는 이를 이용해
  /// "즉시 보정 UX"(기본 체크 해제 + 확인 필요 배지)를 구현한다.
  /// [rawLine]은 영수증 스캔일 때 원문 라인(사용자 대조용)이다.
  static FridgeScanItemResult? _parseFridgeScanItem(dynamic raw) {
    if (raw is! Map) return null;
    final rawName = raw['name']?.toString().trim() ?? '';
    if (rawName.isEmpty) return null;
    final rawLine = raw['raw_line']?.toString();
    final name = ReceiptScanItemNormalizer.normalizeName(
      rawName,
      rawLine: rawLine,
    );
    final qtyNum = raw['qty'];
    final qty = qtyNum is num ? qtyNum.toDouble() : (double.tryParse('$qtyNum') ?? 1.0);
    final confidenceNum = raw['confidence'];
    final confidence = confidenceNum is num
        ? confidenceNum.toDouble().clamp(0.0, 1.0)
        : 0.5;
    final category = ReceiptScanItemNormalizer.categoryForNormalizedName(
      name,
      raw['category']?.toString() ?? 'seasonings_sauces',
    );
    final isFoodRaw = raw['is_food'];
    final heuristicFood = ReceiptScanItemNormalizer.isLikelyFood(
      name,
      rawLine: rawLine,
    );
    final isFood = isFoodRaw is bool ? (isFoodRaw && heuristicFood) : heuristicFood;
    int? price;
    final priceRaw = raw['price'];
    if (priceRaw is num) {
      final p = priceRaw.round();
      if (p > 0 && p <= 10000000) price = p;
    } else if (priceRaw != null) {
      final p = int.tryParse(priceRaw.toString());
      if (p != null && p > 0 && p <= 10000000) price = p;
    }
    return FridgeScanItemResult(
      name: name,
      category: category,
      qty: qty <= 0 ? 1.0 : qty,
      unit: (raw['unit']?.toString().trim().isNotEmpty ?? false)
          ? raw['unit'].toString().trim()
          : '개',
      confidence: confidence,
      rawLine: rawLine,
      isFood: isFood,
      price: price,
    );
  }

  /// 영수증/냉장고 사진을 업로드해 Gemini 비전으로 재료를 인식합니다.
  /// [photoType]은 'receipt' 또는 'fridge_interior'. 로그인 상태 필수.
  /// 실패(네트워크 오류, 인증 만료, 서버 오류) 시 null을 반환하며, 백엔드가
  /// 인식에 실패한 경우엔 items가 빈 리스트인 정상 응답(warning 포함)을 반환한다.
  static Future<FridgeScanResult?> scanFridgePhoto({
    required Uint8List imageBytes,
    required String photoType,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    try {
      final token = await user.getIdToken();
      if (token == null || token.isEmpty) return null;

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/fridge/scan_photo'),
      )
        ..headers['Authorization'] = 'Bearer $token'
        ..fields['photo_type'] = photoType
        ..files.add(
          http.MultipartFile.fromBytes(
            'image',
            imageBytes,
            filename: 'scan.jpg',
          ),
        );

      // 백엔드가 실패 시 1회 재시도하므로(각 시도 최대 60초) 넉넉하게 잡는다.
      final streamed = await request.send().timeout(const Duration(seconds: 75));
      final response = await http.Response.fromStream(streamed);

      if (response.statusCode != 200) {
        _debugLog(
          '[ApiService] scanFridgePhoto ${response.statusCode}: ${response.body}',
        );
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final rawItems = data['items'] as List? ?? [];
      final items = rawItems
          .map(_parseFridgeScanItem)
          .whereType<FridgeScanItemResult>()
          .toList();
      return FridgeScanResult(
        photoType: data['photo_type']?.toString() ?? photoType,
        items: items,
        warning: data['warning']?.toString(),
      );
    } catch (e) {
      _debugLog('[ApiService] scanFridgePhoto error: $e');
      return null;
    }
  }
}

/// POST /fridge/scan_photo 응답으로 받은 재료 1건.
class FridgeScanItemResult {
  const FridgeScanItemResult({
    required this.name,
    required this.category,
    required this.qty,
    required this.unit,
    required this.confidence,
    this.rawLine,
    this.isFood = true,
    this.inCatalog = false,
    this.price,
  });

  final String name;
  final String category;
  final double qty;
  final String unit;

  /// 0~1. 낮을수록(< 0.6) 인식이 불확실해 사용자 확인이 필요하다.
  final double confidence;

  /// 영수증 원문 라인 (영수증 스캔일 때만 값이 있음).
  final String? rawLine;

  /// false면 식재료가 아닌 것으로 보고 리뷰 UI에서 회색/비선택 처리.
  final bool isFood;

  /// 재료 시드/DB 카탈로그에 매칭되면 true.
  ///
  /// false여도 냉장고에는 담을 수 있다(식재료로 보이면). 다만 유통기한
  /// 추정치·레시피 추천 매칭에는 쓰이지 않는다 (저장 시 `catalogMatched`
  /// 플래그로 남겨 레시피 추천 입력에서 걸러낸다).
  final bool inCatalog;

  /// 영수증 라인 결제 금액(원). 가계부 연동용으로 보관하며 재고 qty와는 무관.
  final int? price;

  bool get isLowConfidence => confidence < 0.6;

  /// 냉장고에 담을 수 있는 항목 (식재료면 카탈로그 매칭 여부와 무관하게 허용).
  /// 비식품만 막는다.
  bool get canAddToFridge => isFood;

  FridgeScanItemResult copyWith({
    String? name,
    String? category,
    double? qty,
    String? unit,
    double? confidence,
    String? rawLine,
    bool? isFood,
    bool? inCatalog,
    int? price,
  }) {
    return FridgeScanItemResult(
      name: name ?? this.name,
      category: category ?? this.category,
      qty: qty ?? this.qty,
      unit: unit ?? this.unit,
      confidence: confidence ?? this.confidence,
      rawLine: rawLine ?? this.rawLine,
      isFood: isFood ?? this.isFood,
      inCatalog: inCatalog ?? this.inCatalog,
      price: price ?? this.price,
    );
  }
}

/// POST /fridge/scan_photo 전체 응답.
class FridgeScanResult {
  const FridgeScanResult({
    required this.photoType,
    required this.items,
    this.warning,
  });

  final String photoType;
  final List<FridgeScanItemResult> items;
  final String? warning;
}
