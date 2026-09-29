import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/auth_session_ready.dart';

/// 한 건의 "레시피 분석 시도" 기록.
///
/// 사용자가 링크/글/스크린샷을 분석하려고 시도할 때마다 로컬에 남겨서,
/// 분석이 실패하거나 오래 걸려도 "놓친 링크"가 사라지지 않도록 안전망 역할을 한다.
/// (홈 카드는 성공 시 일반 레시피로 바뀌고, 실패 카드는 사용자가 삭제하면
///  흔적이 남지 않기 때문에 별도의 영속 기록이 필요하다.)
class ParseAttempt {
  ParseAttempt({
    required this.id,
    required this.kind, // 'link' | 'text' | 'image'
    this.url,
    this.title,
    this.platform,
    this.thumbnailUrl,
    this.status = 'parsing', // 'parsing' | 'completed' | 'error'
    this.errorType,
    this.error,
    this.manualText,
    this.savedImageCount = 0,
    this.isNaverDedup = false,
    required this.createdAt,
    required this.updatedAt,
    this.reported = false,
  });

  String id;
  final String kind;
  String? url;
  String? title;
  String? platform;
  String? thumbnailUrl;
  String status;
  String? errorType;
  String? error;
  /// 글/스크린샷 재시도용 원본 텍스트(로컬에만 저장).
  String? manualText;
  /// [saveAttemptImages]로 디스크에 저장된 스크린샷 장수.
  int savedImageCount;
  /// 다른 사용자의 공용 네이버 메타 id 로 dedup 파싱한 경우(재시도 경로 분기).
  bool isNaverDedup;
  final int createdAt;
  int updatedAt;
  bool reported;

  bool get isParsing => status == 'parsing';
  bool get isCompleted => status == 'completed';
  bool get isError => status == 'error';

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'url': url,
        'title': title,
        'platform': platform,
        'thumbnailUrl': thumbnailUrl,
        'status': status,
        'errorType': errorType,
        'error': error,
        'manualText': manualText,
        'savedImageCount': savedImageCount,
        'isNaverDedup': isNaverDedup,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'reported': reported,
      };

  factory ParseAttempt.fromJson(Map<String, dynamic> json) => ParseAttempt(
        id: json['id'] as String? ?? '',
        kind: json['kind'] as String? ?? 'link',
        url: json['url'] as String?,
        title: json['title'] as String?,
        platform: json['platform'] as String?,
        thumbnailUrl: json['thumbnailUrl'] as String?,
        status: json['status'] as String? ?? 'parsing',
        errorType: json['errorType'] as String?,
        error: json['error'] as String?,
        manualText: json['manualText'] as String?,
        savedImageCount: (json['savedImageCount'] as num?)?.toInt() ?? 0,
        isNaverDedup: json['isNaverDedup'] as bool? ?? false,
        createdAt: (json['createdAt'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
        updatedAt: (json['updatedAt'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
        reported: json['reported'] as bool? ?? false,
      );
}

/// 분석 시도 히스토리 로컬 저장소.
///
/// 기록은 **로그인 계정(uid)별로 분리**되어 저장된다. 로그아웃 상태에서 쌓인
/// 기록은 익명(anon) 버킷에 보관되고, 로그인하면 해당 계정 버킷으로 전환된다.
/// (auth 상태 변화를 구독해 자동 전환 + UI 갱신)
class ParseHistoryService {
  ParseHistoryService._();
  static final ParseHistoryService instance = ParseHistoryService._();

  /// 키 prefix. 실제 저장 키는 `${_prefsKeyBase}_<uid|anon>`.
  static const String _prefsKeyBase = 'parse_attempt_history_v1';

  /// 계정 분리 도입 전(단일 키) 데이터 → 익명 버킷으로 1회 이전하기 위한 레거시 키.
  static const String _legacyPrefsKey = 'parse_attempt_history_v1';
  static const int _maxEntries = 80;
  static const int _maxManualTextChars = 8000;
  static const int _maxSavedImages = 5;

  final List<ParseAttempt> _items = <ParseAttempt>[];
  bool _loaded = false;
  Future<void>? _loading;

  /// 현재 기록이 속한 계정 uid (null = 로그아웃/익명).
  String? _uid;
  StreamSubscription<User?>? _authSub;
  Timer? _switchUserDebounceTimer;

  /// 현재 계정 버킷의 저장 키.
  String get _prefsKey => '${_prefsKeyBase}_${_uid ?? 'anon'}';

  /// UI가 구독해 목록 변경을 감지하는 리비전 카운터.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  Future<void> _ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _load();
  }

  Future<void> init() async {
    _uid = FirebaseAuth.instance.currentUser?.uid;
    // 로그인/로그아웃 시 계정 버킷으로 자동 전환.
    _authSub ??= FirebaseAuth.instance.authStateChanges().listen((user) {
      _switchUser(user?.uid);
    });
    await _ensureLoaded();
  }

  /// 계정이 바뀌면 메모리를 비우고 해당 계정 버킷을 다시 로드한다.
  void _switchUser(String? newUid) {
    _switchUserDebounceTimer?.cancel();
    if (newUid == null) {
      _switchUserDebounceTimer = Timer(const Duration(milliseconds: 800), () {
        if (FirebaseAuth.instance.currentUser != null) return;
        _applyUserSwitch(null);
      });
      return;
    }
    _applyUserSwitch(newUid);
  }

  void _applyUserSwitch(String? newUid) {
    if (newUid == _uid) return;
    _uid = newUid;
    _items.clear();
    _loaded = false;
    _loading = null;
    revision.value++; // 화면을 즉시 비워 이전 계정 기록 노출 방지.
    unawaited(_ensureLoaded());
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var raw = prefs.getString(_prefsKey);
      // 레거시(단일 키) 데이터는 익명 버킷으로 1회 이전.
      if ((raw == null || raw.isEmpty) && _uid == null) {
        final legacy = prefs.getString(_legacyPrefsKey);
        if (legacy != null &&
            legacy.isNotEmpty &&
            _legacyPrefsKey != _prefsKey) {
          await prefs.setString(_prefsKey, legacy);
          await prefs.remove(_legacyPrefsKey);
          raw = legacy;
        }
      }
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _items
            ..clear()
            ..addAll(decoded
                .whereType<Map>()
                .map((e) =>
                    ParseAttempt.fromJson(Map<String, dynamic>.from(e)))
                .where((a) => a.id.isNotEmpty));
        }
      }
    } catch (_) {
      // Corrupt cache → start clean.
    } finally {
      _loaded = true;
      revision.value++;
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      if (_items.length > _maxEntries) {
        _items.removeRange(_maxEntries, _items.length);
      }
      final encoded =
          jsonEncode(_items.map((e) => e.toJson()).toList(growable: false));
      await prefs.setString(_prefsKey, encoded);
    } catch (_) {
      // Best-effort persistence.
    } finally {
      revision.value++;
    }
  }

  ParseAttempt? _findById(String id) {
    for (final a in _items) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// 현재까지 로드된 기록(최신순). 호출 전 [init]/[ensureLoaded]가 끝나 있어야 정확하다.
  List<ParseAttempt> get items {
    final copy = List<ParseAttempt>.from(_items);
    copy.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return copy;
  }

  bool get hasAny => _items.isNotEmpty;
  int get failureCount => _items.where((a) => a.isError).length;

  /// 분석 시도 기록(없으면 생성, 있으면 메타 갱신).
  Future<void> record({
    required String id,
    required String kind,
    String? url,
    String? title,
    String? platform,
    String? thumbnailUrl,
    String? manualText,
  }) async {
    if (id.isEmpty) return;
    await _ensureLoaded();
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = _findById(id);
    if (existing != null) {
      if (url != null && url.isNotEmpty) existing.url = url;
      if (title != null && title.isNotEmpty) existing.title = title;
      if (platform != null && platform.isNotEmpty) existing.platform = platform;
      if (thumbnailUrl != null && thumbnailUrl.isNotEmpty) {
        existing.thumbnailUrl = thumbnailUrl;
      }
      if (manualText != null && manualText.isNotEmpty) {
        existing.manualText = _truncateManualText(manualText);
      }
      existing.updatedAt = now;
    } else {
      _items.insert(
        0,
        ParseAttempt(
          id: id,
          kind: kind,
          url: url,
          title: title,
          platform: platform,
          thumbnailUrl: thumbnailUrl,
          manualText: manualText != null && manualText.isNotEmpty
              ? _truncateManualText(manualText)
              : null,
          status: 'parsing',
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
    await _persist();
  }

  String _truncateManualText(String text) {
    final trimmed = text.trim();
    if (trimmed.length <= _maxManualTextChars) return trimmed;
    return trimmed.substring(0, _maxManualTextChars);
  }

  Directory _imageCacheDir(String attemptId) {
    return Directory(
      '${Directory.systemTemp.path}/parse_history_images/$attemptId',
    );
  }

  /// 스크린샷 재시도를 위해 디스크에 저장(모바일/데스크톱만, Web 제외).
  Future<void> saveAttemptImages(String id, List<Uint8List> images) async {
    if (id.isEmpty || images.isEmpty || kIsWeb) return;
    await _ensureLoaded();
    final attempt = _findById(id);
    if (attempt == null) return;

    try {
      final dir = _imageCacheDir(id);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      await dir.create(recursive: true);
      final capped = images.take(_maxSavedImages).toList();
      for (var i = 0; i < capped.length; i++) {
        await File('${dir.path}/$i.bin').writeAsBytes(capped[i]);
      }
      attempt.savedImageCount = capped.length;
      attempt.updatedAt = DateTime.now().millisecondsSinceEpoch;
      await _persist();
    } catch (_) {
      // Best-effort — 재시도 불가 시 UI에서 안내.
    }
  }

  Future<List<Uint8List>> loadAttemptImages(String id) async {
    if (id.isEmpty || kIsWeb) return const [];
    final attempt = _findById(id);
    if (attempt == null || attempt.savedImageCount <= 0) return const [];
    try {
      final dir = _imageCacheDir(id);
      if (!await dir.exists()) return const [];
      final out = <Uint8List>[];
      for (var i = 0; i < attempt.savedImageCount; i++) {
        final file = File('${dir.path}/$i.bin');
        if (!await file.exists()) break;
        out.add(await file.readAsBytes());
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _deleteAttemptImages(String id) async {
    if (id.isEmpty || kIsWeb) return;
    try {
      final dir = _imageCacheDir(id);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }

  Future<void> _moveAttemptImages(String fromId, String toId) async {
    if (fromId.isEmpty || toId.isEmpty || fromId == toId || kIsWeb) return;
    try {
      final from = _imageCacheDir(fromId);
      if (!await from.exists()) return;
      final to = _imageCacheDir(toId);
      if (await to.exists()) {
        await to.delete(recursive: true);
      }
      await from.rename(to.path);
    } catch (_) {
      // rename 실패 시 load/save 로 복구하지 않음 — 재시도 시 재입력 안내.
    }
  }

  Future<void> markError({
    required String id,
    required String error,
    String? errorType,
    bool isNaverDedup = false,
  }) async {
    if (id.isEmpty) return;
    await _ensureLoaded();
    final a = _findById(id);
    if (a == null) return;
    a.status = 'error';
    a.error = error;
    a.errorType = errorType ?? 'client_error';
    if (isNaverDedup) a.isNaverDedup = true;
    a.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await _persist();
  }

  Future<void> markParsing(String id) async {
    if (id.isEmpty) return;
    await _ensureLoaded();
    final a = _findById(id);
    if (a == null) return;
    a.status = 'parsing';
    a.error = null;
    a.errorType = null;
    a.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await _persist();
  }

  /// 낙관적 id(opt_/임시) → 최종 recipeId 로 키 변경.
  Future<void> remap(String oldId, String newId) async {
    if (oldId.isEmpty || newId.isEmpty || oldId == newId) return;
    await _ensureLoaded();
    final old = _findById(oldId);
    if (old == null) return;
    final dest = _findById(newId);
    if (dest != null) {
      // 최종 id로 만들어진 항목이 이미 있으면 메타만 병합하고 옛 항목 제거.
      dest.url ??= old.url;
      dest.title ??= old.title;
      dest.platform ??= old.platform;
      dest.thumbnailUrl ??= old.thumbnailUrl;
      dest.manualText ??= old.manualText;
      if (dest.savedImageCount == 0 && old.savedImageCount > 0) {
        dest.savedImageCount = old.savedImageCount;
        await _moveAttemptImages(oldId, newId);
      }
      _items.remove(old);
    } else {
      old.id = newId;
      if (old.savedImageCount > 0) {
        await _moveAttemptImages(oldId, newId);
      }
      old.updatedAt = DateTime.now().millisecondsSinceEpoch;
    }
    await _persist();
  }

  Future<void> markReported(String id) async {
    await _ensureLoaded();
    final a = _findById(id);
    if (a == null) return;
    a.reported = true;
    a.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await _persist();
  }

  Future<void> remove(String id) async {
    await _ensureLoaded();
    _items.removeWhere((a) => a.id == id);
    await _deleteAttemptImages(id);
    await _persist();
  }

  Future<void> clear() async {
    await _ensureLoaded();
    for (final a in _items) {
      await _deleteAttemptImages(a.id);
    }
    _items.clear();
    await _persist();
  }

  /// 홈 화면이 받는 레시피 리스트로 각 기록의 상태를 동기화한다.
  /// (성공/실패/제목/썸네일 등은 분석 서비스가 직접 알려주지 않으므로,
  ///  레시피 스트림을 단일 진실 공급원으로 사용한다.)
  Future<void> syncFromRecipes(List<Map<String, dynamic>> recipes) async {
    if (!_loaded) {
      // 아직 로드 전이면 로드만 트리거하고 이번 동기화는 스킵.
      unawaited(_ensureLoaded());
      return;
    }
    if (_items.isEmpty) return;

    var changed = false;
    final byId = <String, Map<String, dynamic>>{};
    final byUrl = <String, Map<String, dynamic>>{};
    for (final r in recipes) {
      final id = r['id'] as String?;
      if (id != null && id.isNotEmpty) byId[id] = r;
      final source = r['source'] as Map<String, dynamic>?;
      final url = (r['sourceUrl'] as String?) ?? (source?['url'] as String?);
      if (url != null && url.isNotEmpty) byUrl[url] = r;
    }

    for (final attempt in _items) {
      Map<String, dynamic>? r = byId[attempt.id];
      r ??= (attempt.url != null && attempt.url!.isNotEmpty)
          ? byUrl[attempt.url!]
          : null;
      if (r == null) continue;

      final status = (r['status'] as String?) ?? 'completed';
      final recipeData = r['recipe'] as Map<String, dynamic>? ?? const {};
      final title = (r['title'] as String?) ??
          (recipeData['title'] as String?) ??
          (recipeData['name'] as String?);
      final thumb = (r['thumbnailUrl'] as String?) ??
          (r['thumbnailUrlCropped'] as String?);
      final errorType = r['errorType'] as String?;
      final error = r['error'] as String?;

      var localChanged = false;
      // 동기화로 최종 recipeId를 잡아준다(낙관적 id → 실제 id).
      final realId = r['id'] as String?;
      if (realId != null && realId.isNotEmpty && realId != attempt.id) {
        attempt.id = realId;
        localChanged = true;
      }
      if (status != attempt.status) {
        attempt.status = status;
        localChanged = true;
      }
      if (title != null && title.isNotEmpty && title != '분석 중..') {
        if (attempt.title != title) {
          attempt.title = title;
          localChanged = true;
        }
      }
      if (thumb != null && thumb.isNotEmpty && attempt.thumbnailUrl != thumb) {
        attempt.thumbnailUrl = thumb;
        localChanged = true;
      }
      if (errorType != null && attempt.errorType != errorType) {
        attempt.errorType = errorType;
        localChanged = true;
      }
      if (error != null && attempt.error != error) {
        attempt.error = error;
        localChanged = true;
      }
      if (localChanged) {
        attempt.updatedAt = DateTime.now().millisecondsSinceEpoch;
        changed = true;
      }
    }

    if (changed) await _persist();
  }
}
