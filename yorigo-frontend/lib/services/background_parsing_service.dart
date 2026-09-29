import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'api_service.dart';
import '../main.dart' show mainNavigatorKey;
import '../models/recipe_models.dart' as models;
import '../utils/naver_blog_utils.dart';
import '../utils/recipe_social_counts.dart';
import '../utils/recipe_source_lookup.dart';
import '../widgets/similar_recipes_bottom_sheet.dart';
import 'analytics_service.dart';
import 'guest_parse_quota_service.dart';
import 'local_storage_service.dart';
import 'parse_history_service.dart';
import 'recipe_service.dart';
import '../utils/parse_error_type.dart';
import 'user_service.dart';

/// 게스트 무료 분석(성공 기준 [GuestParseQuotaService.freeParseLimit]회)을
/// 모두 쓴 뒤 다시 분석을 시도했을 때 던진다. UI는 이 예외를 받아 로그인을 유도한다.
class GuestParseLimitException implements Exception {
  const GuestParseLimitException();

  @override
  String toString() => '두 번째 분석부터는 로그인이 필요합니다';
}

class ExistingRecipeException implements Exception {
  final String recipeId;

  ExistingRecipeException(this.recipeId);

  @override
  String toString() => 'ExistingRecipeException:$recipeId';
}

class BackgroundParsingService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final LocalStorageService _localStorage = LocalStorageService();

  /// 네이버 블로그: 다른 사용자가 이미 만든 공용 `recipes/{id}` 메타에 dedup
  /// 으로 본인의 본문만 로컬에 추가하는 케이스에서, 메타 쓰기를 스킵해야 하는
  /// recipeId 집합. parseInBackground 진입 시 결정되고 _completeNaverParsing
  /// 에서 소비된다.
  final Set<String> _naverDedupSkipMetaIds = <String>{};
  final RecipeService _recipeService = RecipeService();
  final AnalyticsService _analyticsService = AnalyticsService();
  final UserService _userService = UserService();

  /// In-flight local parses cancelled before SSE completion (guard recreate).
  final Set<String> _cancelledLocalIds = {};

  /// parsingGeneration captured when a client-side parse job starts (SSE path).
  final Map<String, int> _parsingGenerationAtStart = {};
  // Currently active parsing jobs
  final Map<String, StreamSubscription> _activeParsing = {};
  /// async HTTP 실패 후 SSE 폴백 중인 recipeId. 실패 이벤트 parse_path 구분용.
  final Set<String> _sseFallbackIds = {};
  
  /// 로컬(비로그인) 파싱 완료/에러 시 UI가 Firestore 구독 없이도 반응할 수 있도록 브로드캐스트
  final StreamController<Map<String, dynamic>> _completionController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onParsingComplete => _completionController.stream;
  
  // Retry-related constants
  static const int _maxRetries = 3;
  static const int _maxConcurrentParsingPerUser = 5;
  
  /// Find and resume parsing recipes when app starts
  /// 맥미니 등 서버 비동기 파싱이 끝날 때까지 클라이언트가 SSE 재시도하지 않는 구간.
  /// 이 창 안에서는 Firestore status=parsing 을 그대로 두고 폴링/FCM 만 기다린다.
  /// 워커 크래시로 서버 메모리 레지스트리가 사라진 잡의 클라 안전망이기도 하다.
  static const Duration _serverAsyncParseTrustWindow = Duration(minutes: 15);

  Future<void> resumeIncompleteParsing() async {
    final user = _auth.currentUser;
    if (user == null) {
      return;
    }
    
    try {
      // Find user's parsing recipes
      final querySnapshot = await _firestore
          .collection('recipes')
          .where('userId', isEqualTo: user.uid)
          .where('status', isEqualTo: 'parsing')
          .get();
      
      for (final doc in querySnapshot.docs) {
        final data = doc.data();
        final sourceUrl = data['sourceUrl'] as String?;
        final recipeId = doc.id;
        
        if (sourceUrl == null || sourceUrl.isEmpty) {
          await _handleParsingError(
            recipeId: recipeId,
            error: '소스 URL이 없어 파싱을 재개할 수 없습니다',
            sourceUrl: null,
          );
          continue;
        }

        // 네이버·게스트는 클라이언트 SSE 가 본문 저장 경로이므로 기존 재개 로직 유지.
        final bool serverAsyncCandidate =
            !recipeId.startsWith('local_') && !isNaverBlogUrl(sourceUrl);
        
        final parsingStartedAt = (data['parsingStartedAt'] as Timestamp?)?.toDate();
        if (parsingStartedAt != null) {
          final now = DateTime.now();
          final age = now.difference(parsingStartedAt);
          // 신뢰 창이 지난 parsing 문서는 서버 유실로 보고 timeout.
          // (창을 먼저 두면 15분 컷이 45분 신뢰 창에 가려진다.)
          if (age >= _serverAsyncParseTrustWindow) {
            if (serverAsyncCandidate) {
              // 로그인 영상 파싱은 서버 job 이 실패를 남긴다. 클라 timeout 은
              // 가짜 recipe_parsing_failed + Firestore error 를 만든다.
              continue;
            }
            await _handleParsingError(
              recipeId: recipeId,
              error: '파싱 시간이 너무 오래 걸려 중단되었습니다',
              sourceUrl: sourceUrl,
              errorType: 'timeout',
            );
            continue;
          }
          if (serverAsyncCandidate) {
            // 맥미니 /parse_recipe_async 가 이미 처리 중 — SSE 재시도 시 오탐 error 가 난다.
            continue;
          }
        }
        
        _parseInBackgroundWithRetry(
          recipeId: recipeId,
          url: sourceUrl,
          preferLang: 'ko',
        );
        RecipeService.parsingProgressCache.startProgressSimulation(recipeId);
      }
    } catch (e) {
      // Error resuming incomplete parsing - silently continue
    }
  }
  
  /// 백그라운드에서 레시피 파싱 시작
  Future<String> startBackgroundParsing({
    required String url,
    String preferLang = 'ko',
    String? preAllocatedRecipeId,
  }) async {
    final user = _auth.currentUser;
    final now = DateTime.now();
    final canonical = _recipeService.buildCanonicalSourceInfo(url);
    final normalizedUrl = canonical.normalizedUrl;
    final sourceKey = canonical.sourceKey;

    void clearOptimisticIfNeeded() {
      final id = preAllocatedRecipeId;
      if (id == null || id.isEmpty) return;
      RecipeService.removeOptimisticParsingRecipe(id);
      RecipeService.parsingProgressCache.remove(id);
      RecipeService.notifyRecipesChanged();
    }

    Future<void> _replaceOptimisticWithExisting(
      String? optId, String existingRecipeId,
    ) async {
      try {
        final doc = await _firestore.collection('recipes').doc(existingRecipeId).get();
        final data = doc.data();
        if (doc.exists && data != null && optId != null && optId.isNotEmpty) {
          final cardData = <String, dynamic>{
            'id': existingRecipeId,
            ...data,
            'status': data['status'] ?? 'completed',
          };
          RecipeService.replaceOptimisticWithExistingRecipe(optId, cardData);
          final uid = user?.uid;
          if (uid != null) {
            unawaited(
              _userService.remapRecipebookCategoryRecipeId(
                uid: uid,
                fromRecipeId: optId,
                toRecipeId: existingRecipeId,
              ),
            );
          }
          unawaited(_recipeService.bumpSavedRecipeTimestamp(existingRecipeId));
          unawaited(_recipeService.reloadSavedRecipesFromNetwork());
          return;
        }
      } catch (_) {}
      clearOptimisticIfNeeded();
    }
    
    // Fire-and-forget analytics — don't block the UI
    _analyticsService.trackParsingRequested(
      platform: _extractPlatform(url),
      isAuthenticated: user != null,
      parsePath: (user != null &&
              !(preAllocatedRecipeId ?? '').startsWith('local_') &&
              !isNaverBlogUrl(normalizedUrl))
          ? 'async'
          : 'sse',
    );

    final bool isNaver = isNaverBlogUrl(normalizedUrl);
    String? naverDedupRecipeId;

    if (user != null) {
      // 로그인 사용자는 파싱 시작 전에 DB 중복 여부를 한 번 더 강하게 확인한다.
      // (UI 선행 체크가 실패해도 서비스 레벨에서 중복 파싱 방지)
      final existingOwnedOrSavedId = await _recipeService
          .getUserSavedOrOwnedRecipeIdBySourceUrl(normalizedUrl);
      if (existingOwnedOrSavedId != null && existingOwnedOrSavedId.isNotEmpty) {
        // 네이버 블로그는 owner/saved 매칭이어도 throw 하지 않고 아래 dedup
        // 분기로 흘려보낸다. 본인이 이전에 분석했더라도 본문은 로컬에만 보관
        // 되므로(저작권 §30), 북마크 해제·앱 재설치 등으로 로컬 본문이 사라
        // 진 경우 같은 메타 recipeId 를 재사용하면서 본문만 재추출 + saved
        // Recipes 재attach 가 필요하다. _completeNaverParsing 의
        // skipMetaWrite==true 분기가 이 attach 를 처리한다.
        if (!isNaver) {
          await _replaceOptimisticWithExisting(
            preAllocatedRecipeId, existingOwnedOrSavedId,
          );
          _analyticsService.trackRecipeDedupFound(
            platform: _extractPlatform(normalizedUrl),
            isAuthenticated: true,
          );
          throw ExistingRecipeException(existingOwnedOrSavedId);
        }
      }

      // 비네이버: 완료본뿐 아니라 parsing 중 문서도 찾는다. 숨김 껍데기는
      // 쿼리에서 제외되므로, 남의 duplicate_of 사본이 있어도 원본을 받을 수 있다.
      final existingAny = isNaver
          ? await _recipeService.getNaverBlogMetaForDedup(normalizedUrl)
          : await _recipeService.getAnyRecipeBySourceUrl(normalizedUrl);
      final existingAnyId = existingAny?['id'] as String?;
      if (existingAnyId != null && existingAnyId.isNotEmpty) {
        if (isNaver) {
          // 네이버 블로그(B): URL당 meta 1건. hidden 포함 sourceKey lookup.
          // 타 사용자 메타 → skipMetaWrite + SSE 재파싱 + 로컬 본문.
          // 본인 메타 재파싱 → owner update + SSE + _writeNaverMeta.
          naverDedupRecipeId = existingAnyId;
          final ownerId = existingAny?['userId'] as String?;
          final isSharedMeta =
              ownerId != null && ownerId.isNotEmpty && ownerId != user.uid;
          if (isSharedMeta) {
            _naverDedupSkipMetaIds.add(existingAnyId);
            try {
              await _firestore.collection('users').doc(user.uid).set({
                'savedRecipes': FieldValue.arrayUnion([existingAnyId]),
                'savedAt.$existingAnyId': FieldValue.serverTimestamp(),
                'lastUpdated': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));
            } catch (e) {
              print(
                '[BackgroundParsing] Naver dedup: early savedRecipes attach failed: $e',
              );
            }
          }
        } else {
          // 비-네이버: 공용 본문이 있으면 attach 만 하고 새 문서를 만들지 않는다.
          try {
            await _firestore.collection('users').doc(user.uid).set({
              'savedRecipes': FieldValue.arrayUnion([existingAnyId]),
              'lastUpdated': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
          } catch (e) {
            print('[BackgroundParsing] Failed to attach existing recipe: $e');
          }
          await _replaceOptimisticWithExisting(
            preAllocatedRecipeId, existingAnyId,
          );
          _analyticsService.trackRecipeDedupFound(
            platform: _extractPlatform(normalizedUrl),
            isAuthenticated: true,
          );
          if (isInProgressSourceDoc(existingAny!)) {
            // 다른 파싱이 진행 중 — 새 id 를 만들지 않고 기존 문서를 기다린다.
            return existingAnyId;
          }
          throw ExistingRecipeException(existingAnyId);
        }
      }

      await _assertUserParsingLimit(
        userId: user.uid,
        preAllocatedRecipeId: preAllocatedRecipeId,
      );
      _analyticsService.trackParseAttemptForUser(user.uid);
    }

    final String? reusableRetryId = user != null && !isNaver
        ? await _recipeService.findReusableCancelledRecipeId(normalizedUrl) ??
            await _recipeService.findReusableFailedRecipeId(
              normalizedUrl,
              userId: user.uid,
            )
        : null;

    if (user == null) {
      final existingLocalId =
          await _localStorage.getLocalRecipeIdBySourceUrl(normalizedUrl);
      if (existingLocalId != null) {
        final local = await _localStorage.getLocalRecipe(existingLocalId);
        final localStatus = (local?['status'] as String?)?.toLowerCase();
        if (local != null && localStatus == 'completed') {
          clearOptimisticIfNeeded();
          throw Exception('이미 저장된 레시피입니다');
        }
        // 취소·실패분 재시도도 남은 무료 횟수가 있어야 한다.
        if (!await GuestParseQuotaService.instance.canParseAsGuest()) {
          clearOptimisticIfNeeded();
          throw const GuestParseLimitException();
        }
        if (local != null &&
            (RecipeService.isReusableCancelledRecipeData(local) ||
                localStatus == 'error' ||
                localStatus == 'failed')) {
          await _localStorage.reviveLocalParsingRecipe(
            recipeId: existingLocalId,
            sourceUrl: normalizedUrl,
          );
          _cancelledLocalIds.remove(existingLocalId);
          final gen = (local['parsingGeneration'] as num?)?.toInt() ?? 1;
          _parsingGenerationAtStart[existingLocalId] = gen + 1;
          if (preAllocatedRecipeId != null) {
            RecipeService.replaceOptimisticRecipeId(
              preAllocatedRecipeId,
              existingLocalId,
            );
          } else {
            RecipeService.addOptimisticParsingRecipe(
              recipeId: existingLocalId,
              sourceUrl: normalizedUrl,
            );
          }
          RecipeService.parsingProgressCache.startProgressSimulation(
            existingLocalId,
          );
          RecipeService.notifyRecipesChanged();
          _parseInBackgroundWithRetry(
            recipeId: existingLocalId,
            url: normalizedUrl,
            preferLang: preferLang,
          );
          return existingLocalId;
        }
        if (local != null && localStatus == 'parsing') {
          clearOptimisticIfNeeded();
          throw Exception('이미 분석 중인 레시피입니다');
        }
      }

      // 무료 분석을 이미 성공시킨 게스트는 여기서 막는다 (2번째부터 로그인 필요).
      if (!await GuestParseQuotaService.instance.canParseAsGuest()) {
        clearOptimisticIfNeeded();
        throw const GuestParseLimitException();
      }

      final tempRecipeId = 'local_${DateTime.now().millisecondsSinceEpoch}';
      if (preAllocatedRecipeId != null) {
        RecipeService.replaceOptimisticRecipeId(preAllocatedRecipeId, tempRecipeId);
        RecipeService.parsingProgressCache.startProgressSimulation(tempRecipeId);
        RecipeService.notifyRecipesChanged();
      } else {
        RecipeService.addOptimisticParsingRecipe(recipeId: tempRecipeId, sourceUrl: normalizedUrl);
        RecipeService.parsingProgressCache.startProgressSimulation(tempRecipeId);
        RecipeService.notifyRecipesChanged();
      }

      _localStorage.createLocalParsingRecipe(
        recipeId: tempRecipeId,
        sourceUrl: normalizedUrl,
      );
      _parsingGenerationAtStart[tempRecipeId] = 1;
      
      _parseInBackgroundWithRetry(
        recipeId: tempRecipeId,
        url: normalizedUrl,
        preferLang: preferLang,
      );
      return tempRecipeId;
    }
    
    // Logged-in: reuse pre-allocated ID, Naver meta, reusable cancelled/error slot,
    // or generate new one.
    final tempRecipeId = preAllocatedRecipeId
        ?? naverDedupRecipeId
        ?? reusableRetryId
        ?? _firestore.collection('recipes').doc().id;
    final reviveCancelled = reusableRetryId != null &&
        tempRecipeId == reusableRetryId &&
        naverDedupRecipeId == null;
    if (preAllocatedRecipeId == null) {
      RecipeService.addOptimisticParsingRecipe(recipeId: tempRecipeId, sourceUrl: normalizedUrl);
      RecipeService.parsingProgressCache.startProgressSimulation(tempRecipeId);
      RecipeService.notifyRecipesChanged();
    } else if (preAllocatedRecipeId.startsWith('opt_')) {
      // Pre-allocated with a temp ID — replace with a real Firestore ID
      // (Naver dedup case uses existing meta id, so no opt_ replacement needed)
      final realId = naverDedupRecipeId
          ?? reusableRetryId
          ?? _firestore.collection('recipes').doc().id;
      final realRevive = reusableRetryId != null &&
          realId == reusableRetryId &&
          naverDedupRecipeId == null;
      RecipeService.replaceOptimisticRecipeId(preAllocatedRecipeId, realId);
      RecipeService.parsingProgressCache.startProgressSimulation(realId);
      RecipeService.notifyRecipesChanged();
      if (isNaver) {
        await _beginNaverParsingDoc(
          recipeId: realId,
          userId: user.uid,
          normalizedUrl: normalizedUrl,
          sourceKey: sourceKey,
          now: now,
          sharedMetaDedup: _naverDedupSkipMetaIds.contains(realId),
          ownerReuseMeta: naverDedupRecipeId != null &&
              !_naverDedupSkipMetaIds.contains(realId),
          reviveCancelled: realRevive,
        );
      } else if (naverDedupRecipeId == null) {
        await _beginParsingDoc(
          recipeId: realId,
          userId: user.uid,
          normalizedUrl: normalizedUrl,
          sourceKey: sourceKey,
          now: now,
          reviveCancelled: realRevive,
        );
      } else {
        await _recordParsingGenerationAtStart(realId);
      }
      _parseInBackgroundWithRetry(
        recipeId: realId,
        url: normalizedUrl,
        preferLang: preferLang,
      );
      return realId;
    }

    // 네이버 shared dedup: 타 사용자 meta → Firestore doc 스킵(skipMetaWrite).
    // owner reuse: 본인 meta → parsing 상태로 update.
    if (isNaver) {
      await _beginNaverParsingDoc(
        recipeId: tempRecipeId,
        userId: user.uid,
        normalizedUrl: normalizedUrl,
        sourceKey: sourceKey,
        now: now,
        sharedMetaDedup: _naverDedupSkipMetaIds.contains(tempRecipeId),
        ownerReuseMeta: naverDedupRecipeId != null &&
            !_naverDedupSkipMetaIds.contains(tempRecipeId),
        reviveCancelled: reviveCancelled,
      );
    } else if (naverDedupRecipeId == null) {
      await _beginParsingDoc(
        recipeId: tempRecipeId,
        userId: user.uid,
        normalizedUrl: normalizedUrl,
        sourceKey: sourceKey,
        now: now,
        reviveCancelled: reviveCancelled,
      );
    } else {
      await _recordParsingGenerationAtStart(tempRecipeId);
    }

    _parseInBackgroundWithRetry(
      recipeId: tempRecipeId,
      url: normalizedUrl,
      preferLang: preferLang,
    );
    return tempRecipeId;
  }

  Future<int> _countUserParsingJobs({
    required String userId,
    String? excludingRecipeId,
  }) async {
    final querySnapshot = await _firestore
        .collection('recipes')
        .where('userId', isEqualTo: userId)
        .where('status', isEqualTo: 'parsing')
        .get();

    if (excludingRecipeId == null || excludingRecipeId.isEmpty) {
      return querySnapshot.docs.length;
    }
    return querySnapshot.docs.where((doc) => doc.id != excludingRecipeId).length;
  }

  Future<void> _assertUserParsingLimit({
    required String userId,
    String? excludingRecipeId,
    String? preAllocatedRecipeId,
  }) async {
    final activeJobs = await _countUserParsingJobs(
      userId: userId,
      excludingRecipeId: excludingRecipeId,
    );
    if (activeJobs < _maxConcurrentParsingPerUser) return;

    if (preAllocatedRecipeId != null && preAllocatedRecipeId.isNotEmpty) {
      RecipeService.removeOptimisticParsingRecipe(preAllocatedRecipeId);
      RecipeService.parsingProgressCache.remove(preAllocatedRecipeId);
    }
    throw Exception(
      '동시에 최대 $_maxConcurrentParsingPerUser개의 영상만 분석할 수 있어요. '
      '진행 중인 분석이 끝난 뒤 다시 시도해주세요.',
    );
  }

  /// Write the initial parsing doc + savedRecipes update to Firestore (non-blocking).
  Future<void> _writeParsingDocToFirestore({
    required String recipeId,
    required String userId,
    required String normalizedUrl,
    required String? sourceKey,
    required DateTime now,
  }) async {
    try {
      final platform = _extractPlatform(normalizedUrl);
      await _firestore.collection('recipes').doc(recipeId).set({
        'userId': userId,
        'sourceUrl': normalizedUrl,
        'sourceKey': sourceKey,
        'status': 'parsing',
        'progress': 0.0,
        'stage': '시작 중...',
        'title': '분석 중..',
        'recipe': {
          'title': '분석 중..',
        },
        'source': {
          'url': normalizedUrl,
          'platform': platform,
        },
        // 기기 OS (ios/android) — 에러 레시피 관찰용
        'appPlatform': ApiService.deviceOsTag,
        'createdAt': Timestamp.fromDate(now),
        'parsingStartedAt': Timestamp.fromDate(now),
        'isHidden': platform == 'naver_blog',
        'isTemporary': true,
        'parsingGeneration': 1,
        'saveCount': RecipeSocialCounts.seedSaveCount(recipeId),
        'weeklySaves': 0,
        'monthlySaves': 0,
      });

      await _firestore.collection('users').doc(userId).set({
        'savedRecipes': FieldValue.arrayUnion([recipeId]),
        'savedAt.$recipeId': FieldValue.serverTimestamp(),
        'lastUpdated': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      print('[BackgroundParsing] Firestore write failed: $e');
    }
  }

  Future<void> _reviveCancelledRecipeDoc({
    required String recipeId,
    required String userId,
    required DateTime now,
  }) async {
    try {
      final snap = await _firestore.collection('recipes').doc(recipeId).get();
      final currentGen =
          (snap.data()?['parsingGeneration'] as num?)?.toInt() ?? 1;
      await _firestore.collection('recipes').doc(recipeId).set({
        'userId': userId,
        'status': 'parsing',
        'progress': 0.0,
        'stage': '시작 중...',
        'parsingGeneration': currentGen + 1,
        'parsingStartedAt': Timestamp.fromDate(now),
        'parseCancelledAt': FieldValue.delete(),
        'cancelReason': FieldValue.delete(),
        'error': FieldValue.delete(),
        'errorType': FieldValue.delete(),
        'isTemporary': true,
        'recipe': {'title': '분석 중..'},
        'appPlatform': ApiService.deviceOsTag,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await _firestore.collection('users').doc(userId).set({
        'savedRecipes': FieldValue.arrayUnion([recipeId]),
        'savedAt.$recipeId': FieldValue.serverTimestamp(),
        'lastUpdated': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      print('[BackgroundParsing] Revive cancelled doc failed: $e');
    }
  }

  Future<void> _restartNaverOwnerParsingDoc({
    required String recipeId,
    required String userId,
    required DateTime now,
  }) async {
    try {
      final snap = await _firestore.collection('recipes').doc(recipeId).get();
      final currentGen =
          (snap.data()?['parsingGeneration'] as num?)?.toInt() ?? 1;
      await _firestore.collection('recipes').doc(recipeId).update({
        'status': 'parsing',
        'progress': 0.0,
        'stage': '시작 중...',
        'parsingGeneration': currentGen + 1,
        'parsingStartedAt': Timestamp.fromDate(now),
        'isTemporary': true,
        'error': FieldValue.delete(),
        'errorType': FieldValue.delete(),
        'parseCancelledAt': FieldValue.delete(),
        'cancelReason': FieldValue.delete(),
        'appPlatform': ApiService.deviceOsTag,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      await _firestore.collection('users').doc(userId).set({
        'savedRecipes': FieldValue.arrayUnion([recipeId]),
        'savedAt.$recipeId': FieldValue.serverTimestamp(),
        'lastUpdated': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      print('[BackgroundParsing] Naver owner re-parse doc update failed: $e');
    }
  }

  Future<void> _beginNaverParsingDoc({
    required String recipeId,
    required String userId,
    required String normalizedUrl,
    required String? sourceKey,
    required DateTime now,
    required bool sharedMetaDedup,
    required bool ownerReuseMeta,
    required bool reviveCancelled,
  }) async {
    if (sharedMetaDedup) {
      await _recordParsingGenerationAtStart(recipeId);
      return;
    }
    if (ownerReuseMeta) {
      await _restartNaverOwnerParsingDoc(
        recipeId: recipeId,
        userId: userId,
        now: now,
      );
    } else if (reviveCancelled) {
      await _reviveCancelledRecipeDoc(
        recipeId: recipeId,
        userId: userId,
        now: now,
      );
    } else {
      await _writeParsingDocToFirestore(
        recipeId: recipeId,
        userId: userId,
        normalizedUrl: normalizedUrl,
        sourceKey: sourceKey,
        now: now,
      );
    }
    await _recordParsingGenerationAtStart(recipeId);
  }

  Future<void> _beginParsingDoc({
    required String recipeId,
    required String userId,
    required String normalizedUrl,
    required String? sourceKey,
    required DateTime now,
    required bool reviveCancelled,
  }) async {
    if (reviveCancelled) {
      await _reviveCancelledRecipeDoc(
        recipeId: recipeId,
        userId: userId,
        now: now,
      );
    } else {
      await _writeParsingDocToFirestore(
        recipeId: recipeId,
        userId: userId,
        normalizedUrl: normalizedUrl,
        sourceKey: sourceKey,
        now: now,
      );
    }
    await _recordParsingGenerationAtStart(recipeId);
  }

  Future<void> _recordParsingGenerationAtStart(String recipeId) async {
    if (recipeId.startsWith('opt_') || recipeId.startsWith('local_')) return;
    _parsingGenerationAtStart[recipeId] =
        await _recipeService.readParsingGeneration(recipeId);
  }

  /// 클라가 미리 쓴 `status=parsing` 이 아니라, 서버가 잡을 수락/진행한 신호.
  bool _dataShowsServerAsyncOwnership(Map<String, dynamic>? data) {
    if (data == null) return false;
    if (RecipeService.isCancelledRecipeData(data)) return true;
    final status = (data['status'] as String?)?.toLowerCase();
    if (status == 'completed') return true;
    if (data['asyncParseQueuedAt'] != null) return true;
    final stage = (data['stage'] as String?) ?? '';
    return stage.contains('대기');
  }

  String _analyticsParsePath(String recipeId) {
    if (recipeId.startsWith('local_')) return 'sse';
    if (_sseFallbackIds.contains(recipeId)) return 'sse_fallback';
    if (_activeParsing.containsKey(recipeId)) return 'sse';
    return 'async';
  }

  Future<bool> _shouldSkipClientWrite(String recipeId) async {
    if (recipeId.startsWith('opt_')) return false;
    if (_cancelledLocalIds.contains(recipeId)) return true;

    // 이 클라이언트가 SSE 로 진행 중이면 서버 async 위임으로 오인하지 않는다.
    // (글/사진 수동 파싱은 generation 기록을 안 하던 경로가 있어, 없으면
    //  완료 SSE 가 _completeManualParsing 에 도달하기 전에 여기서 drop 됐다.)
    // async HTTP 실패 후 SSE 폴백은 예외: 서버가 이미 완료했으면 덮어쓰지 않는다.
    final bool sseFallback = _sseFallbackIds.contains(recipeId);
    if (_activeParsing.containsKey(recipeId) && !sseFallback) return false;

    if (recipeId.startsWith('local_')) {
      final local = await _localStorage.getLocalRecipe(recipeId);
      if (local != null && RecipeService.isCancelledRecipeData(local)) {
        return true;
      }
      return false;
    }

    try {
      final snap = await _firestore.collection('recipes').doc(recipeId).get();
      final data = snap.data();
      if (data == null) return false;
      if (RecipeService.isCancelledRecipeData(data)) return true;
      final status = (data['status'] as String?)?.toLowerCase();
      // 서버(맥미니) 비동기 파싱이 이미 완료한 뒤 늦게 도착한 SSE 오류는 무시한다.
      if (status == 'completed') {
        // 클라이언트 SSE 가 늦어도 옵티미스틱/파싱 카드는 정리한다.
        RecipeService.removeOptimisticParsingRecipe(
          recipeId,
          sourceUrl: data['sourceUrl'] as String?,
        );
        RecipeService.parsingProgressCache.remove(recipeId);
        return true;
      }
      final startGen = _parsingGenerationAtStart[recipeId];
      // 이 세션에서 파싱을 시작하지 않았는데 아직 parsing 이면 서버 비동기 처리 중일 수 있다.
      if (status == 'parsing' && startGen == null) {
        final started =
            (data['parsingStartedAt'] as Timestamp?)?.toDate();
        if (started != null &&
            DateTime.now().difference(started) < _serverAsyncParseTrustWindow) {
          return true;
        }
      }
      if (startGen != null) {
        final docGen = (data['parsingGeneration'] as num?)?.toInt() ?? 1;
        if (status == 'parsing' && docGen != startGen) return true;
      }
    } catch (_) {}
    return false;
  }

  /// 로그인 비동기 파싱을 서버가 이미 수락/진행한 경우.
  /// 클라가 쓴 status=parsing 만으로는 구분하지 않는다. 그렇지 않으면
  /// HTTP 타임아웃 시 SSE 폴백이 영구히 막힌다.
  Future<bool> _serverLikelyOwnsParse(String recipeId) async {
    if (recipeId.startsWith('local_') || recipeId.startsWith('opt_')) {
      return false;
    }
    try {
      final snap = await _firestore.collection('recipes').doc(recipeId).get();
      return _dataShowsServerAsyncOwnership(snap.data());
    } catch (_) {
      return false;
    }
  }
  
  /// Fire-and-forget: tell the backend to parse in the background.
  /// Android / iOS 동일: `POST parse.yorigo.kr/parse_recipe_async` (맥미니),
  /// 실패 시에만 클라우드 폴백 → 그래도 실패하면 SSE.
  /// The backend writes results directly to Firestore and sends an FCM
  /// push notification. No SSE connection needed — the user can leave the app.
  Future<void> _parseViaAsyncEndpoint({
    required String recipeId,
    required String url,
    required String preferLang,
  }) async {
    final user = _auth.currentUser;
    if (user == null) return;
    final osTag = ApiService.deviceOsTag;

    try {
      await ApiService.parseRecipeAsync(
        url: url,
        recipeId: recipeId,
        userId: user.uid,
        preferLang: preferLang,
      );
      print(
        '[$osTag] [BackgroundParsing] Async parse job queued for $recipeId',
      );
    } catch (e) {
      // 맥미니가 이미 큐에 넣었을 수 있음 — 완료/진행 중이면 SSE 폴백 금지.
      if (await _shouldSkipClientWrite(recipeId) ||
          await _serverLikelyOwnsParse(recipeId)) {
        print(
          '[$osTag] [BackgroundParsing] Async endpoint failed but server '
          'already owns $recipeId — skip SSE fallback',
        );
        return;
      }
      print(
        '[$osTag] [BackgroundParsing] Async endpoint failed, '
        'falling back to SSE: $e',
      );
      _sseFallbackIds.add(recipeId);
      _parseInBackgroundWithRetry(
        recipeId: recipeId,
        url: url,
        preferLang: preferLang,
        forceSSE: true,
      );
    }
  }

  /// 백그라운드에서 실제 파싱 수행 (재시도 로직 포함)
  void _parseInBackgroundWithRetry({
    required String recipeId,
    required String url,
    required String preferLang,
    int currentRetry = 0,
    bool forceSSE = false,
  }) async {
    // Logged-in users: prefer the async endpoint (no SSE connection needed).
    // Guests (local_* IDs) must use SSE since the backend can't write to
    // their local storage. Naver blog must use SSE because the body is stored
    // locally on the device (copyright §30), not in Firestore.
    if (!forceSSE &&
        currentRetry == 0 &&
        _auth.currentUser != null &&
        !recipeId.startsWith('local_') &&
        !isNaverBlogUrl(url)) {
      await _parseViaAsyncEndpoint(
        recipeId: recipeId,
        url: url,
        preferLang: preferLang,
      );
      return;
    }

    try {
      // SSE 스트림 구독 (guest users + fallback)
      final stream = ApiService.parseRecipeStream(
        url: url,
        preferLang: preferLang,
      );
      
      StreamSubscription? subscription;
      subscription = stream.listen(
        (event) async {
          // 진행 상황 업데이트
          await _updateParsingProgress(
            recipeId: recipeId,
            stage: event['stage'] as String?,
            progress: (event['progress'] as num?)?.toDouble() ?? 0.0,
            subStage: event['sub_stage'] as String?,
            event: event,
          );
          
          // 최종 결과 수신
          // 백엔드는 '완료' stage와 함께 'result' 필드에 데이터를 보냄
          if (event['stage'] == '완료' && event['result'] != null) {
            try {
              final data = event['result'] as Map<String, dynamic>;
              final parseResponse = models.ParseResponse.fromJson(data);
              await _completeParsing(
                recipeId: recipeId,
                parseResponse: parseResponse,
                sourceUrl: url,
              );
            } catch (e) {
              await _handleParsingError(
                recipeId: recipeId,
                error: '결과 변환 실패: $e',
                sourceUrl: url,
              );
            }
            // Keep SSE open briefly for the post-completion "timestamps"
            // event.  A safety timer closes it after 90s regardless.
            Future.delayed(const Duration(seconds: 90), () {
              subscription?.cancel();
              _activeParsing.remove(recipeId);
            });
          }

          // Post-completion step timestamps from the backend.
          if (event['stage'] == 'timestamps' &&
              event['step_timestamps'] != null) {
            try {
              final List<dynamic> raw = event['step_timestamps'] as List<dynamic>;
              final timestamps = raw
                  .map((e) => e is num ? e.toInt() : null)
                  .toList()
                  .cast<int?>();
              await _applyStepTimestamps(recipeId, timestamps);
            } catch (e) {
              debugPrint('[BackgroundParsing] Failed to apply step timestamps: $e');
            }
            subscription?.cancel();
            _activeParsing.remove(recipeId);
          }

          // 이전 형식 호환성 유지 (stage == 'result'일 때)
          if (event['stage'] == 'result' && event['data'] != null) {
            try {
              final data = event['data'] as Map<String, dynamic>;
              final parseResponse = models.ParseResponse.fromJson(data);
              await _completeParsing(
                recipeId: recipeId,
                parseResponse: parseResponse,
                sourceUrl: url,
              );
            } catch (e) {
              await _handleParsingError(
                recipeId: recipeId,
                error: '결과 변환 실패: $e',
                sourceUrl: url,
              );
            }
            Future.delayed(const Duration(seconds: 90), () {
              subscription?.cancel();
              _activeParsing.remove(recipeId);
            });
          }
          
          // 에러 처리
          // 백엔드는 '오류' stage를 보냄
          if (event['stage'] == '오류' || event['stage'] == 'error') {
            final errorType = event['error_type'] as String? ?? 'server_error';
            await _handleParsingError(
              recipeId: recipeId,
              error: event['error'] as String? ?? '알 수 없는 오류',
              sourceUrl: url,
              errorType: errorType,
            );
            
            subscription?.cancel();
            _activeParsing.remove(recipeId);
          }
        },
        onError: (error) async {
          // 재시도 가능한 에러인지 확인
          if (currentRetry < _maxRetries && _isRetryableError(error)) {
            subscription?.cancel();
            _activeParsing.remove(recipeId);
            
            // 지수 백오프: 2^currentRetry 초 대기
            final delaySeconds = math.pow(2, currentRetry).toInt();
            await Future.delayed(Duration(seconds: delaySeconds));
            
            // 재시도
            _parseInBackgroundWithRetry(
              recipeId: recipeId,
              url: url,
              preferLang: preferLang,
              currentRetry: currentRetry + 1,
            );
          } else {
            // 재시도 불가능한 에러 또는 최대 재시도 횟수 초과
            await _handleParsingError(
              recipeId: recipeId,
              error: error.toString(),
              sourceUrl: url,
            );
            _activeParsing.remove(recipeId);
          }
        },
      );
      
      _activeParsing[recipeId] = subscription;
    } catch (e) {
      // 재시도 가능한 에러인지 확인
      if (currentRetry < _maxRetries && _isRetryableError(e)) {
        // 지수 백오프: 2^currentRetry 초 대기
        final delaySeconds = math.pow(2, currentRetry).toInt();
        await Future.delayed(Duration(seconds: delaySeconds));
        
        // 재시도
        _parseInBackgroundWithRetry(
          recipeId: recipeId,
          url: url,
          preferLang: preferLang,
          currentRetry: currentRetry + 1,
        );
      } else {
        // 재시도 불가능한 에러 또는 최대 재시도 횟수 초과
        await _handleParsingError(
          recipeId: recipeId,
          error: e.toString(),
          sourceUrl: url,
        );
      }
    }
  }
  
  /// 재시도 가능한 에러인지 확인
  bool _isRetryableError(dynamic error) {
    // SocketException: 네트워크 연결 문제
    if (error is SocketException) {
      return true;
    }
    
    final errorString = error.toString().toLowerCase();
    
    // 네트워크 관련 에러
    if (errorString.contains('network') || 
        errorString.contains('connection') ||
        errorString.contains('timeout') ||
        errorString.contains('socket') ||
        errorString.contains('failed host lookup')) {
      return true;
    }
    
    // HTTP 5xx 서버 에러 (일시적 서버 문제)
    if (errorString.contains('500') ||
        errorString.contains('502') ||
        errorString.contains('503') ||
        errorString.contains('504')) {
      return true;
    }
    
    return false;
  }
  
  /// 파싱 진행 상황 업데이트
  Future<void> _updateParsingProgress({
    required String recipeId,
    required String? stage,
    required double progress,
    String? subStage,
    Map<String, dynamic>? event,
  }) async {
    final user = _auth.currentUser;

    // Heartbeats only keep the SSE connection alive. They repeat the same
    // stage/progress and must not cause a recipe read + write every few
    // seconds while a long parse is running.
    if (event?['heartbeat'] == true) return;
    
    // Update in-memory optimistic card when video_info arrives
    if (subStage == 'video_info' && event != null) {
      final videoInfo = event['video_info'] as Map<String, dynamic>?;
      if (videoInfo != null) {
        RecipeService.updateOptimisticParsingRecipe(
          recipeId,
          title: videoInfo['title'] as String?,
          thumbnail: videoInfo['thumbnail'] as String?,
          uploader: videoInfo['uploader'] as String?,
          channel: videoInfo['channel'] as String?,
        );
      }
    }

    // 로그인하지 않은 경우 로컬 스토리지에 업데이트
    if (user == null || recipeId.startsWith('local_')) {
      if (await _shouldSkipClientWrite(recipeId)) return;
      String? title;
      String? thumb;
      String? up;
      String? ch;
      
      if (subStage == 'video_info' && event != null) {
        final videoInfo = event['video_info'] as Map<String, dynamic>?;
        if (videoInfo != null) {
          title = videoInfo['title'] as String?;
          thumb = videoInfo['thumbnail'] as String?;
          up = videoInfo['uploader'] as String?;
          ch = videoInfo['channel'] as String?;
        }
      }
      
      try {
        await _localStorage.updateLocalParsingProgress(
          recipeId: recipeId,
          progress: progress,
          stage: stage,
          subStage: subStage,
          title: title,
          thumbnailUrl: thumb,
          uploader: up,
          channel: ch,
        );
      } catch (e) {
        // Error updating local parsing progress - silently continue
      }
      return;
    }
    
    if (await _shouldSkipClientWrite(recipeId)) return;

    try {
      final updates = <String, dynamic>{
        'progress': progress,
        'updatedAt': FieldValue.serverTimestamp(),
      };
      
      if (stage != null) {
        updates['stage'] = stage;
      }
      
      if (subStage != null) {
        updates['sub_stage'] = subStage;
      }
      
      // video_info: 제목·썸네일·업로더 (목록에서 파싱 카드에 썸네일 표시용)
      if (subStage == 'video_info' && event != null) {
        final videoInfo = event['video_info'] as Map<String, dynamic>?;
        if (videoInfo != null) {
          final title = videoInfo['title'] as String?;
          if (title != null && title.isNotEmpty) {
            updates['recipe.title'] = title;
          }
          final thumb = videoInfo['thumbnail'] as String?;
          if (thumb != null && thumb.isNotEmpty) {
            updates['thumbnailUrl'] = thumb;
            updates['recipe.thumbnailUrl'] = thumb;
          }
          final up = videoInfo['uploader'] as String?;
          if (up != null && up.isNotEmpty) {
            updates['uploader'] = up;
            updates['source.uploader'] = up;
          }
          final ch = videoInfo['channel'] as String?;
          if (ch != null && ch.isNotEmpty) {
            updates['channel'] = ch;
            updates['source.channel'] = ch;
          }
        }
      }
      
      await _firestore.collection('recipes').doc(recipeId).update(updates);
    } catch (e) {
      // Error updating parsing progress - silently continue
    }
  }
  
  /// 파싱 완료 처리
  Future<void> _completeParsing({
    required String recipeId,
    required models.ParseResponse parseResponse,
    required String sourceUrl,
  }) async {
    if (await _shouldSkipClientWrite(recipeId)) {
      _parsingGenerationAtStart.remove(recipeId);
      _sseFallbackIds.remove(recipeId);
      return;
    }

    // Naver blog: 본문(재료/단계)은 공용 recipes 컬렉션에 저장하면 안 됨.
    // 메타와 본문을 분리 저장하는 별도 경로로 라우팅.
    final platform = (parseResponse.source['platform'] as String?) ?? '';
    if (platform == 'naver_blog') {
      await _completeNaverParsing(
        recipeId: recipeId,
        parseResponse: parseResponse,
        sourceUrl: sourceUrl,
      );
      return;
    }

    // Manual paste: dedicated completion path that uses the content-based
    // sourceKey (from backend), then post-save triggers the similar-recipes
    // bottom sheet.
    if (platform == 'manual') {
      await _completeManualParsing(
        recipeId: recipeId,
        parseResponse: parseResponse,
      );
      return;
    }

    // Fill the ring to 100% before Firestore/local flips to completed — otherwise
    // fast parses replace the parsing card while the ring is still mid‑curve.
    await RecipeService.parsingProgressCache.animateCompletionRing(recipeId);

    final user = _auth.currentUser;
    final canonical = _recipeService.buildCanonicalSourceInfo(sourceUrl);
    
    // 로그인하지 않은 경우 로컬 스토리지에 업데이트 후 완료 스트림으로 UI에 알림 (Firestore 미사용)
    if (user == null || recipeId.startsWith('local_')) {
      try {
        await _localStorage.updateLocalRecipeWithResult(
          recipeId: recipeId,
          parseResponse: parseResponse,
          sourceUrl: sourceUrl,
        );
        print('[BackgroundParsing] Recipe updated locally: $recipeId');
      } catch (e) {
        print('[BackgroundParsing] Error updating recipe locally: $e');
      }
      if (user == null) {
        await GuestParseQuotaService.instance.markGuestParseSucceeded();
      }
      await _analyticsService.trackParsingCompleted(
        platform: _extractPlatform(sourceUrl),
        ingredientCount: parseResponse.recipe.ingredients.length,
        stepCount: parseResponse.recipe.steps.length,
        savedToCloud: false,
        recipeId: recipeId,
        parsePath: _analyticsParsePath(recipeId),
      );
      RecipeService.removeOptimisticParsingRecipe(
        recipeId,
        sourceUrl: sourceUrl,
      );
      RecipeService.parsingProgressCache.remove(recipeId);
      RecipeService.notifyRecipesChanged();
      try {
        _completionController.add({'recipeId': recipeId, 'status': 'completed'});
      } catch (_) {}
      _parsingGenerationAtStart.remove(recipeId);
      _sseFallbackIds.remove(recipeId);
      return;
    }
    
    // 로그인한 경우 Firestore에 저장
    try {
      int? durationMs;
      try {
        final existingDoc = await _firestore.collection('recipes').doc(recipeId).get();
        final parsingStartedAt = (existingDoc.data()?['parsingStartedAt'] as Timestamp?)
            ?.toDate();
        if (parsingStartedAt != null) {
          final measured = DateTime.now().difference(parsingStartedAt).inMilliseconds;
          if (measured >= 0) {
            durationMs = measured;
          }
        }
      } catch (e) {
        print('[BackgroundParsing] Failed to measure parse duration: $e');
      }

      final recipe = parseResponse.recipe;
      final nutrition = parseResponse.nutrition;
      
      // 실제 레시피 데이터로 업데이트 (RecipeService의 saveRecipe와 동일한 구조)
      final recipeData = {
        'status': 'completed',
        'isHidden': false,
        'progress': 100.0,
        'stage': '완료',
        'isTemporary': false,
        'title': recipe.name ?? parseResponse.source['title'] ?? '레시피',
        'sourceUrl': canonical.normalizedUrl,
        'sourceKey': canonical.sourceKey,
        'recipe': {
          'name': recipe.name,
          'servings': recipe.servings,
          'ingredients':
              recipe.ingredients.map((ing) => ing.toRecipeStorageMap()).toList(),
          'steps': recipe.steps.map((step) => step.toStorageMap()).toList(),
          'equipment': recipe.equipment,
          'notes': recipe.notes,
        },
        'source': parseResponse.source,
        'nutrition': {
          'per_serving': nutrition.perServing,
          'assumptions': nutrition.assumptions,
          'llm_estimate': nutrition.llmEstimate != null
              ? {
                  'calories_per_serving': nutrition.llmEstimate!.caloriesPerServing,
                  'protein_g': nutrition.llmEstimate!.proteinG,
                  'fat_g': nutrition.llmEstimate!.fatG,
                  'carbs_g': nutrition.llmEstimate!.carbsG,
                  'sodium_mg': nutrition.llmEstimate!.sodiumMg,
                  'sugar_g': nutrition.llmEstimate!.sugarG,
                  'cholesterol_mg': nutrition.llmEstimate!.cholesterolMg,
                  'fiber_g': nutrition.llmEstimate!.fiberG,
                }
              : null,
        },
        'thumbnailUrl': parseResponse.source['thumbnail'] ?? '',
        'categories': parseResponse.source['categories'] ?? {},
        'tags': parseResponse.source['tags'] ?? [],
        'nutrition_rating': parseResponse.source['nutrition_rating'] ?? 'A',
        'calories': nutrition.llmEstimate?.caloriesPerServing ?? 0,
        'usedOcr': parseResponse.debug['used_ocr'] == true,
        'purchaseOccasionCount': 0,
        'completedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };
      
      await _firestore.collection('recipes').doc(recipeId).update(recipeData);

      // 레시피북 빠른 경로(mini doc) 동기화 — 없으면 parsing 스텁(0재료)이 남거나
      // 폴링이 completed 로 올릴 때 hollow 카드가 잠깐/영구 노출될 수 있다.
      try {
        await _recipeService.updateSavedRecipeMiniDoc(
          user.uid,
          recipeId,
          recipeData,
        );
      } catch (e) {
        print('[BackgroundParsing] URL mini-doc sync failed: $e');
      }

      RecipeService.removeOptimisticParsingRecipe(recipeId);
      RecipeService.parsingProgressCache.remove(recipeId);
      RecipeService.notifyRecipesChanged();
      try {
        _completionController.add({'recipeId': recipeId, 'status': 'completed'});
      } catch (_) {}

      // Storage 이중 썸네일 (카드 200x200 / 상세 원본) — saveRecipe와 동일
      final extThumb = parseResponse.source['thumbnail'] as String? ?? '';
      if (extThumb.isNotEmpty) {
        await RecipeService().uploadAndApplyRecipeThumbnails(
          recipeId,
          extThumb,
          sourceUrl: canonical.normalizedUrl,
          platform: _extractPlatform(canonical.normalizedUrl),
        );
      }

      // 미니 doc 동기화 + 옵티미스틱 카드 제거 (빈 카드 잔류 방지)
      try {
        final userId = user.uid;
        await _recipeService.updateSavedRecipeMiniDoc(
          userId,
          recipeId,
          recipeData,
        );
      } catch (e) {
        print('[BackgroundParsing] mini-doc sync failed: $e');
      }
      RecipeService.removeOptimisticParsingRecipe(
        recipeId,
        sourceUrl: canonical.normalizedUrl,
      );
      RecipeService.parsingProgressCache.remove(recipeId);
      RecipeService.notifyRecipesChanged();

      await _analyticsService.trackParsingCompleted(
        platform: _extractPlatform(sourceUrl),
        ingredientCount: parseResponse.recipe.ingredients.length,
        stepCount: parseResponse.recipe.steps.length,
        savedToCloud: true,
        durationMs: durationMs,
        recipeId: recipeId,
        parsePath: _analyticsParsePath(recipeId),
      );
      _sseFallbackIds.remove(recipeId);
      _parsingGenerationAtStart.remove(recipeId);
    } catch (e) {
      await _handleParsingError(
        recipeId: recipeId,
        error: '저장 중 오류 발생: $e',
        sourceUrl: sourceUrl,
      );
    }
  }

  /// 네이버 블로그 파싱 완료 처리.
  ///
  /// 다른 플랫폼과 다르게 저장 모델이 split:
  /// - **메타**(`recipes/{recipeId}`, Firestore): 작성자, URL, og_image, 카테고리/태그 등 카드 표시용
  /// - **본문**(`LocalStorageService.setNaverBody`, **본인 디바이스 로컬**): 재료/단계/영양
  ///
  /// 본문이 우리 서버(Firestore) 어디에도 가지 않도록 분리하는 것이 이 메서드의 핵심 책임.
  /// 저작권법 §30 사적 복제 안전성을 위해 본문은 사용자 본인 디바이스에만 보관한다.
  /// 다른 사용자가 같은 블로그 글을 파싱할 때는 메타는 dedup(sourceKey)되고
  /// 본문은 각자 자기 디바이스에서 새로 추출해 로컬에 저장한다.
  Future<void> _completeNaverParsing({
    required String recipeId,
    required models.ParseResponse parseResponse,
    required String sourceUrl,
  }) async {
    await RecipeService.parsingProgressCache.animateCompletionRing(recipeId);

    final user = _auth.currentUser;
    final canonical = _recipeService.buildCanonicalSourceInfo(sourceUrl);

    // 비로그인: 기존 로컬 스토리지 흐름과 동일. 본인 디바이스에만 저장되므로 split 불필요.
    if (user == null || recipeId.startsWith('local_')) {
      try {
        await _localStorage.updateLocalRecipeWithResult(
          recipeId: recipeId,
          parseResponse: parseResponse,
          sourceUrl: sourceUrl,
        );
        print('[BackgroundParsing] Naver recipe updated locally: $recipeId');
      } catch (e) {
        print('[BackgroundParsing] Error updating local naver recipe: $e');
      }
      if (user == null) {
        await GuestParseQuotaService.instance.markGuestParseSucceeded();
      }
      await _analyticsService.trackParsingCompleted(
        platform: 'naver_blog',
        ingredientCount: parseResponse.recipe.ingredients.length,
        stepCount: parseResponse.recipe.steps.length,
        savedToCloud: false,
        recipeId: recipeId,
      );
      await _finalizeNaverParsingUi(recipeId: recipeId);
      return;
    }

    // 네이버 dedup 케이스: 다른 사용자(A)가 이미 공용 메타를 만들어 둔 상태.
    // 우리(B)는 메타를 새로 쓰지 않고, 본인 본문만 로컬에 저장하고 savedRecipes
    // 에만 attach 한다.
    final bool skipMetaWrite = _naverDedupSkipMetaIds.remove(recipeId);

    int? durationMs;
    if (!skipMetaWrite) {
      try {
        final existingDoc =
            await _firestore.collection('recipes').doc(recipeId).get();
        final parsingStartedAt =
            (existingDoc.data()?['parsingStartedAt'] as Timestamp?)?.toDate();
        if (parsingStartedAt != null) {
          final measured =
              DateTime.now().difference(parsingStartedAt).inMilliseconds;
          if (measured >= 0) durationMs = measured;
        }
      } catch (e) {
        print('[BackgroundParsing] Naver: parse duration measure failed: $e');
      }

      try {
        await _writeNaverMeta(
          recipeId: recipeId,
          userId: user.uid,
          parseResponse: parseResponse,
          canonicalUrl: canonical.normalizedUrl,
          sourceKey: canonical.sourceKey,
        );
      } catch (e) {
        await _handleParsingError(
          recipeId: recipeId,
          error: '저장 중 오류 발생: $e',
          sourceUrl: sourceUrl,
        );
        return;
      }
    } else {
      // dedup 케이스: 본인 savedRecipes 에 attach (mini doc 는 아래 parseResponse 기준).
      try {
        await _firestore.collection('users').doc(user.uid).set({
          'savedRecipes': FieldValue.arrayUnion([recipeId]),
          'lastUpdated': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (e) {
        print('[BackgroundParsing] Naver dedup: savedRecipes attach failed: $e');
      }
    }

    try {
      await _localStorage.setNaverBody(
        recipeId: recipeId,
        parseResponse: parseResponse,
        sourceUrl: canonical.normalizedUrl,
      );
    } catch (e) {
      // 메타는 이미 저장됨. 본문 저장 실패는 사용자가 본문 다시 파싱하면 복구 가능.
      // 메타 카드는 정상 표시되므로 fatal 처리하지 않고 로그만.
      print('[BackgroundParsing] Naver: local body write failed: $e');
    }

    await _analyticsService.trackParsingCompleted(
      platform: 'naver_blog',
      ingredientCount: parseResponse.recipe.ingredients.length,
      stepCount: parseResponse.recipe.steps.length,
      savedToCloud: !skipMetaWrite,
      durationMs: durationMs,
      recipeId: recipeId,
    );

    try {
      final mainDoc =
          await _firestore.collection('recipes').doc(recipeId).get();
      final mainData = mainDoc.data();
      if (mainDoc.exists && mainData != null) {
        await _recipeService.updateNaverSavedRecipeMiniDoc(
          user.uid,
          recipeId,
          mainData,
          parseResponse,
        );
      } else {
        await _recipeService.updateNaverSavedRecipeMiniDoc(
          user.uid,
          recipeId,
          <String, dynamic>{
            'title': parseResponse.recipe.name ?? '레시피',
            'status': 'completed',
            'isHidden': true,
            'sourceUrl': canonical.normalizedUrl,
            'sourceKey': canonical.sourceKey,
            'source': parseResponse.source,
            'tags': parseResponse.source['tags'] ?? [],
            'categories': parseResponse.source['categories'] ?? {},
          },
          parseResponse,
        );
      }
    } catch (e) {
      print('[BackgroundParsing] Naver: mini doc sync failed: $e');
    }

    await _finalizeNaverParsingUi(
      recipeId: recipeId,
      naverDedup: skipMetaWrite,
    );
  }

  /// 네이버 파싱 완료 후 optimistic → Firestore completed 카드 전환.
  Future<void> _finalizeNaverParsingUi({
    required String recipeId,
    bool naverDedup = false,
  }) async {
    RecipeService.removeOptimisticParsingRecipe(recipeId);
    RecipeService.parsingProgressCache.remove(recipeId);
    try {
      _completionController.add({
        'recipeId': recipeId,
        'status': 'completed',
        if (naverDedup) 'naverDedup': true,
      });
    } catch (_) {}
    await _recipeService.reloadSavedRecipesFromNetwork();
  }

  /// 네이버 블로그: 공용 recipes 메타 문서. 본문(재료/단계/영양)은 절대 포함하지 않는다.
  Future<void> _writeNaverMeta({
    required String recipeId,
    required String userId,
    required models.ParseResponse parseResponse,
    required String canonicalUrl,
    required String? sourceKey,
  }) async {
    final source = parseResponse.source;
    final title = (parseResponse.recipe.name?.isNotEmpty ?? false)
        ? parseResponse.recipe.name!
        : (source['title'] as String? ?? '레시피');

    // 메타에 들어가는 source 는 og:image / thumbnail 키를 제거한 sanitized 사본만
    // 사용한다. 원본 이미지 URL 을 다른 사용자에게 hot-link 노출하면 §30 사적복제
    // 안전구간을 벗어나므로, og:image 는 사용자 본인 디바이스 (LocalStorageService
    // .setNaverBody) 에만 저장한다.
    final sanitizedSource = <String, dynamic>{
      for (final entry in source.entries)
        if (entry.key != 'og_image_url' &&
            entry.key != 'og_image' &&
            entry.key != 'thumbnail')
          entry.key: entry.value,
    };

    final meta = <String, dynamic>{
      'userId': userId,
      'status': 'completed',
      'isHidden': true,
      'progress': 100.0,
      'stage': '완료',
      'isTemporary': false,
      'title': title,
      'sourceUrl': canonicalUrl,
      'sourceKey': sourceKey,
      'recipe': {
        'name': parseResponse.recipe.name,
        'servings': parseResponse.recipe.servings,
      },
      'source': sanitizedSource,
      // 카드 썸네일은 클라이언트가 RecipeThumbnailResolver 에서 네이버 블로그
      // 플레이스홀더 asset 으로 fallback 한다.
      'thumbnailUrl': '',
      'categories': source['categories'] ?? {},
      'tags': source['tags'] ?? [],
      'nutrition_rating': source['nutrition_rating'] ?? 'A',
      'usedOcr': false,
      'purchaseOccasionCount': 0,
      'completedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };

    await _firestore.collection('recipes').doc(recipeId).update(meta);
  }

  /// 파싱 에러 처리
  Future<void> _handleParsingError({
    required String recipeId,
    required String error,
    String? sourceUrl,
    String? errorType,
  }) async {
    final resolvedType = resolvePersistedParseErrorType(
      error,
      providedType: errorType,
    );
    RecipeService.parsingProgressCache.stopProgressSimulation(recipeId);
    if (await _shouldSkipClientWrite(recipeId)) {
      _parsingGenerationAtStart.remove(recipeId);
      _sseFallbackIds.remove(recipeId);
      return;
    }
    // SSE 폴백 중 서버가 이미 잡을 수락했으면 클라 timeout 을 실패로 남기지 않는다.
    if (_sseFallbackIds.contains(recipeId) &&
        await _serverLikelyOwnsParse(recipeId)) {
      _parsingGenerationAtStart.remove(recipeId);
      _sseFallbackIds.remove(recipeId);
      return;
    }
    final user = _auth.currentUser;
    final String platform = sourceUrl != null && sourceUrl.isNotEmpty
        ? _extractPlatform(sourceUrl)
        : 'unknown';

    // dedup: 다른 사용자(A)의 공용 메타 id 를 재사용 중이면 Firestore 에 error 를
    // 쓸 수 없다. 이 경우 클라이언트(optimistic + 분석 기록)만 갱신한다.
    final bool wasNaverDedup = _naverDedupSkipMetaIds.remove(recipeId);

    Future<void> emitFailureAnalytics() async {
      final bool savedToCloud = user != null &&
          !recipeId.startsWith('local_') &&
          !wasNaverDedup;
      await _analyticsService.trackParsingFailed(
        platform: platform,
        savedToCloud: savedToCloud,
        errorMessage: error,
        errorType: resolvedType,
        parsePath: _analyticsParsePath(recipeId),
      );
      _sseFallbackIds.remove(recipeId);
    }

    // 로그인하지 않은 경우 로컬 스토리지에 에러 상태 저장 후 스트림으로 UI에 알림
    if (user == null || recipeId.startsWith('local_')) {
      try {
        await _localStorage.markLocalRecipeError(
          recipeId: recipeId,
          error: error,
        );
        print('[BackgroundParsing] Parsing error (not logged in): $error');
      } catch (e) {
        print('[BackgroundParsing] Error marking local recipe error: $e');
      }
      await emitFailureAnalytics();
      try {
        _completionController.add({
          'recipeId': recipeId,
          'status': 'error',
          'error': error,
          'errorType': resolvedType,
        });
      } catch (_) {}
      return;
    }

    if (wasNaverDedup) {
      await _finalizeNaverDedupParsingFailure(
        recipeId: recipeId,
        error: error,
        errorType: resolvedType,
        sourceUrl: sourceUrl,
      );
      await emitFailureAnalytics();
      return;
    }

    try {
      await _firestore.collection('recipes').doc(recipeId).update({
        'status': 'error',
        'error': error,
        'errorType': resolvedType,
        'appPlatform': ApiService.deviceOsTag,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      // Error handling parsing error - silently continue
    }
    // 실패 문서는 Firestore 에 남기되 레시피북·식단에는 붙이지 않는다.
    if (user != null &&
        !recipeId.startsWith('local_') &&
        !wasNaverDedup) {
      try {
        await _recipeService.cleanupDedupTempSavedRecipe(user.uid, recipeId);
      } catch (e) {
        print('[BackgroundParsing] Detach failed parse from library: $e');
      }
      RecipeService.removeOptimisticParsingRecipe(recipeId);
      RecipeService.parsingProgressCache.remove(recipeId);
      RecipeService.notifyRecipesChanged();
      await ParseHistoryService.instance.markError(
        id: recipeId,
        error: error,
        errorType: resolvedType,
      );
      try {
        _completionController.add({
          'recipeId': recipeId,
          'status': 'error',
          'error': error,
          'errorType': resolvedType,
          if (sourceUrl != null && sourceUrl.isNotEmpty) 'sourceUrl': sourceUrl,
        });
      } catch (_) {}
    }
    await emitFailureAnalytics();
  }

  /// 네이버 dedup 파싱 실패: 공용 recipes doc 는 건드리지 않고 B 사용자 UI 만 정리.
  Future<void> _finalizeNaverDedupParsingFailure({
    required String recipeId,
    required String error,
    required String errorType,
    String? sourceUrl,
  }) async {
    RecipeService.removeOptimisticParsingRecipe(recipeId);
    RecipeService.parsingProgressCache.remove(recipeId);
    RecipeService.notifyRecipesChanged();

    await ParseHistoryService.instance.markError(
      id: recipeId,
      error: error,
      errorType: errorType,
      isNaverDedup: true,
    );

    try {
      _completionController.add({
        'recipeId': recipeId,
        'status': 'error',
        'error': error,
        'errorType': errorType,
        if (sourceUrl != null && sourceUrl.isNotEmpty) 'sourceUrl': sourceUrl,
        'naverDedup': true,
      });
    } catch (_) {}
  }

  // ────────────────────────────────────────────────────────────────────
  // Manual paste (text + screenshots) parsing
  // ────────────────────────────────────────────────────────────────────

  /// Start parsing a manual recipe input (pasted text + screenshots).
  ///
  /// Mirrors [startBackgroundParsing] but uses the content-based parsing API
  /// instead of URL-based parsing. No URL-based dedup is performed up front —
  /// the backend returns a `source.source_key = "content:<sha256>"` that the
  /// completion handler uses to detect already-saved identical content
  /// (only matching `status == 'completed'` recipes — failed parses can be retried).
  ///
  /// At least one of [text] / [images] must be non-empty.
  Future<String> startContentParsing({
    String? text,
    List<Uint8List>? images,
    String preferLang = 'ko',
    String? preAllocatedRecipeId,
  }) async {
    final bool hasText = text != null && text.trim().isNotEmpty;
    final List<Uint8List> imageList = images ?? const <Uint8List>[];
    if (!hasText && imageList.isEmpty) {
      throw Exception('텍스트 또는 사진 중 하나는 입력해주세요.');
    }

    final user = _auth.currentUser;
    final now = DateTime.now();

    _analyticsService.trackParsingRequested(
      platform: 'manual',
      isAuthenticated: user != null,
      parsePath: 'sse',
    );

    if (user != null) {
      await _assertUserParsingLimit(
        userId: user.uid,
        preAllocatedRecipeId: preAllocatedRecipeId,
      );
      _analyticsService.trackParseAttemptForUser(user.uid);
    }

    // 비로그인 경로
    if (user == null) {
      if (!await GuestParseQuotaService.instance.canParseAsGuest()) {
        final optId = preAllocatedRecipeId;
        if (optId != null && optId.isNotEmpty) {
          RecipeService.removeOptimisticParsingRecipe(optId);
          RecipeService.parsingProgressCache.remove(optId);
          RecipeService.notifyRecipesChanged();
        }
        throw const GuestParseLimitException();
      }
      final tempRecipeId = 'local_${DateTime.now().millisecondsSinceEpoch}';
      if (preAllocatedRecipeId != null) {
        RecipeService.replaceOptimisticRecipeId(preAllocatedRecipeId, tempRecipeId);
        RecipeService.parsingProgressCache.startProgressSimulation(tempRecipeId);
        RecipeService.notifyRecipesChanged();
      } else {
        RecipeService.addOptimisticParsingRecipe(
          recipeId: tempRecipeId,
          sourceUrl: '',
        );
        RecipeService.parsingProgressCache.startProgressSimulation(tempRecipeId);
        RecipeService.notifyRecipesChanged();
      }
      _localStorage.createLocalParsingRecipe(
        recipeId: tempRecipeId,
        sourceUrl: '',
      );
      _parseContentInBackgroundWithRetry(
        recipeId: tempRecipeId,
        text: text,
        images: imageList,
        preferLang: preferLang,
      );
      return tempRecipeId;
    }

    // 로그인 경로: 미리할당된 ID 재사용 또는 신규 Firestore ID 생성
    final tempRecipeId = preAllocatedRecipeId ??
        _firestore.collection('recipes').doc().id;
    if (preAllocatedRecipeId == null) {
      RecipeService.addOptimisticParsingRecipe(
        recipeId: tempRecipeId,
        sourceUrl: '',
      );
      RecipeService.parsingProgressCache.startProgressSimulation(tempRecipeId);
      RecipeService.notifyRecipesChanged();
    } else if (preAllocatedRecipeId.startsWith('opt_')) {
      final realId = _firestore.collection('recipes').doc().id;
      RecipeService.replaceOptimisticRecipeId(preAllocatedRecipeId, realId);
      RecipeService.parsingProgressCache.startProgressSimulation(realId);
      RecipeService.notifyRecipesChanged();
      await _writeParsingDocToFirestore(
        recipeId: realId,
        userId: user.uid,
        normalizedUrl: '',
        sourceKey: null,
        now: now,
      );
      // URL 파싱과 동일: 이 세션이 owner 임을 기록해야 완료 SSE 가
      // _shouldSkipClientWrite 에 막히지 않는다.
      await _recordParsingGenerationAtStart(realId);
      _parseContentInBackgroundWithRetry(
        recipeId: realId,
        text: text,
        images: imageList,
        preferLang: preferLang,
      );
      return realId;
    }

    await _writeParsingDocToFirestore(
      recipeId: tempRecipeId,
      userId: user.uid,
      normalizedUrl: '',
      sourceKey: null,
      now: now,
    );
    await _recordParsingGenerationAtStart(tempRecipeId);
    _parseContentInBackgroundWithRetry(
      recipeId: tempRecipeId,
      text: text,
      images: imageList,
      preferLang: preferLang,
    );
    return tempRecipeId;
  }

  /// SSE consumer for manual content parsing. Subset of
  /// [_parseInBackgroundWithRetry] — no resumable retries (manual parses are
  /// short and image payloads aren't preserved client-side after submit).
  void _parseContentInBackgroundWithRetry({
    required String recipeId,
    required String? text,
    required List<Uint8List> images,
    required String preferLang,
    int currentRetry = 0,
  }) async {
    try {
      final stream = ApiService.parseRecipeContentStream(
        text: text,
        images: images,
        preferLang: preferLang,
      );
      StreamSubscription? subscription;
      subscription = stream.listen(
        (event) async {
          await _updateParsingProgress(
            recipeId: recipeId,
            stage: event['stage'] as String?,
            progress: (event['progress'] as num?)?.toDouble() ?? 0.0,
            subStage: event['sub_stage'] as String?,
            event: event,
          );

          if (event['stage'] == '완료' && event['result'] != null) {
            try {
              final data = event['result'] as Map<String, dynamic>;
              final parseResponse = models.ParseResponse.fromJson(data);
              await _completeParsing(
                recipeId: recipeId,
                parseResponse: parseResponse,
                sourceUrl: '',
              );
            } catch (e) {
              await _handleParsingError(
                recipeId: recipeId,
                error: '결과 변환 실패: $e',
                sourceUrl: '',
              );
            }
            subscription?.cancel();
            _activeParsing.remove(recipeId);
          }

          if (event['stage'] == '오류' || event['stage'] == 'error') {
            final errorType = event['error_type'] as String? ?? 'server_error';
            await _handleParsingError(
              recipeId: recipeId,
              error: event['error'] as String? ?? '알 수 없는 오류',
              sourceUrl: '',
              errorType: errorType,
            );
            subscription?.cancel();
            _activeParsing.remove(recipeId);
          }
        },
        onError: (error) async {
          if (currentRetry < _maxRetries && _isRetryableError(error)) {
            subscription?.cancel();
            _activeParsing.remove(recipeId);
            final delaySeconds = math.pow(2, currentRetry).toInt();
            await Future.delayed(Duration(seconds: delaySeconds));
            _parseContentInBackgroundWithRetry(
              recipeId: recipeId,
              text: text,
              images: images,
              preferLang: preferLang,
              currentRetry: currentRetry + 1,
            );
          } else {
            await _handleParsingError(
              recipeId: recipeId,
              error: error.toString(),
              sourceUrl: '',
            );
            _activeParsing.remove(recipeId);
          }
        },
      );
      _activeParsing[recipeId] = subscription;
    } catch (e) {
      if (currentRetry < _maxRetries && _isRetryableError(e)) {
        final delaySeconds = math.pow(2, currentRetry).toInt();
        await Future.delayed(Duration(seconds: delaySeconds));
        _parseContentInBackgroundWithRetry(
          recipeId: recipeId,
          text: text,
          images: images,
          preferLang: preferLang,
          currentRetry: currentRetry + 1,
        );
      } else {
        await _handleParsingError(
          recipeId: recipeId,
          error: e.toString(),
          sourceUrl: '',
        );
      }
    }
  }

  /// Manual paste completion path.
  ///
  /// Differs from the standard video flow on three points:
  ///  1. Uses `source.source_key` (content sha256) from the backend response
  ///     instead of computing a URL-based sourceKey on the client.
  ///  2. Before saving, checks for an already-completed identical-content
  ///     recipe (any user) — if found, redirects to it instead of saving a
  ///     duplicate. Failed parses are NOT considered, so users can retry.
  ///  3. After saving, triggers [SimilarRecipesBottomSheet] for canonical-dish
  ///     recommendations (unless dismissed via SharedPreferences).
  Future<void> _completeManualParsing({
    required String recipeId,
    required models.ParseResponse parseResponse,
  }) async {
    await RecipeService.parsingProgressCache.animateCompletionRing(recipeId);

    final user = _auth.currentUser;
    final source = parseResponse.source;
    final contentSourceKey = (source['source_key'] as String?) ?? '';
    final canonicalDishSeed =
        (source['canonical_dish_seed'] as String?)?.trim() ?? '';

    // 비로그인: 기존 로컬 스토리지 흐름 그대로
    if (user == null || recipeId.startsWith('local_')) {
      try {
        await _localStorage.updateLocalRecipeWithResult(
          recipeId: recipeId,
          parseResponse: parseResponse,
          sourceUrl: '',
        );
      } catch (e) {
        print('[BackgroundParsing] Error updating local manual recipe: $e');
      }
      if (user == null) {
        await GuestParseQuotaService.instance.markGuestParseSucceeded();
      }
      await _analyticsService.trackParsingCompleted(
        platform: 'manual',
        ingredientCount: parseResponse.recipe.ingredients.length,
        stepCount: parseResponse.recipe.steps.length,
        savedToCloud: false,
        recipeId: recipeId,
      );
      RecipeService.removeOptimisticParsingRecipe(recipeId);
      RecipeService.parsingProgressCache.remove(recipeId);
      RecipeService.notifyRecipesChanged();
      try {
        _completionController.add({'recipeId': recipeId, 'status': 'completed'});
      } catch (_) {}
      _maybeShowSimilarRecipesSheet(
        recipeId: recipeId,
        canonicalDishSeed: canonicalDishSeed,
      );
      return;
    }

    // 로그인: 동일 콘텐츠가 이미 저장돼 있으면 redirect
    if (contentSourceKey.isNotEmpty) {
      try {
        final existing = await _recipeService
            .fetchCompletedRecipeBySourceKey(contentSourceKey);
        final existingId = existing?['id'] as String?;
        if (existing != null &&
            existingId != null &&
            existingId.isNotEmpty &&
            existingId != recipeId) {
          try {
            await _firestore.collection('recipes').doc(recipeId).delete();
          } catch (_) {}
          try {
            await _firestore.collection('users').doc(user.uid).set({
              'savedRecipes': FieldValue.arrayUnion([existingId]),
              'lastUpdated': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
          } catch (_) {}
          unawaited(
            _userService.remapRecipebookCategoryRecipeId(
              uid: user.uid,
              fromRecipeId: recipeId,
              toRecipeId: existingId,
            ),
          );
          RecipeService.removeOptimisticParsingRecipe(recipeId);
          RecipeService.parsingProgressCache.remove(recipeId);
          RecipeService.notifyRecipesChanged();
          try {
            _completionController.add({
              'recipeId': existingId,
              'status': 'completed',
              'redirectedFrom': recipeId,
            });
          } catch (_) {}
          await _analyticsService.trackParsingCompleted(
            platform: 'manual',
            ingredientCount: parseResponse.recipe.ingredients.length,
            stepCount: parseResponse.recipe.steps.length,
            savedToCloud: true,
            recipeId: recipeId,
          );
          return;
        }
      } catch (e) {
        print('[BackgroundParsing] Manual sourceKey dedup lookup failed: $e');
      }
    }

    // 정상 저장 경로
    try {
      int? durationMs;
      try {
        final existingDoc =
            await _firestore.collection('recipes').doc(recipeId).get();
        final parsingStartedAt =
            (existingDoc.data()?['parsingStartedAt'] as Timestamp?)?.toDate();
        if (parsingStartedAt != null) {
          final measured =
              DateTime.now().difference(parsingStartedAt).inMilliseconds;
          if (measured >= 0) durationMs = measured;
        }
      } catch (e) {
        print('[BackgroundParsing] Manual: parse duration measure failed: $e');
      }

      final recipe = parseResponse.recipe;
      final nutrition = parseResponse.nutrition;

      final recipeData = <String, dynamic>{
        'status': 'completed',
        'isHidden': true,
        'progress': 100.0,
        'stage': '완료',
        'isTemporary': false,
        'title': recipe.name ?? '내가 입력한 레시피',
        'sourceUrl': '',
        'sourceKey': contentSourceKey,
        if (canonicalDishSeed.isNotEmpty) 'canonicalDish': canonicalDishSeed,
        'recipe': {
          'name': recipe.name,
          'servings': recipe.servings,
          'ingredients':
              recipe.ingredients.map((ing) => ing.toRecipeStorageMap()).toList(),
          'steps': recipe.steps.map((step) => step.toStorageMap()).toList(),
          'equipment': recipe.equipment,
          'notes': recipe.notes,
        },
        'source': source,
        'nutrition': {
          'per_serving': nutrition.perServing,
          'assumptions': nutrition.assumptions,
          'llm_estimate': nutrition.llmEstimate != null
              ? {
                  'calories_per_serving':
                      nutrition.llmEstimate!.caloriesPerServing,
                  'protein_g': nutrition.llmEstimate!.proteinG,
                  'fat_g': nutrition.llmEstimate!.fatG,
                  'carbs_g': nutrition.llmEstimate!.carbsG,
                  'sodium_mg': nutrition.llmEstimate!.sodiumMg,
                  'sugar_g': nutrition.llmEstimate!.sugarG,
                  'cholesterol_mg': nutrition.llmEstimate!.cholesterolMg,
                  'fiber_g': nutrition.llmEstimate!.fiberG,
                }
              : null,
        },
        'thumbnailUrl': '',
        'categories': source['categories'] ?? {},
        'tags': source['tags'] ?? [],
        'nutrition_rating': source['nutrition_rating'] ?? 'A',
        'calories': nutrition.llmEstimate?.caloriesPerServing ?? 0,
        'usedOcr': parseResponse.debug['used_ocr'] == true,
        'purchaseOccasionCount': 0,
        'completedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      await _firestore.collection('recipes').doc(recipeId).update(recipeData);

      // 레시피북 카드 UI 는 users/{uid}/savedRecipes/{id} 미니 doc 의 status 로
      // 파싱 완료를 감지한다. 본체 doc 만 completed 로 바꾸면 미니 doc 이 parsing
      // 으로 남아 카드가 "파싱 중" 에 고착되므로, 여기서 미니 doc 을 동기화한다.
      // (URL 비동기 파싱은 백엔드가 미니 doc 을 sync 하지만, 수동 파싱은 SSE 경로라
      //  클라이언트가 직접 동기화해야 한다.)
      try {
        await _recipeService.updateSavedRecipeMiniDoc(
          user.uid,
          recipeId,
          recipeData,
        );
      } catch (e) {
        print('[BackgroundParsing] Manual mini-doc sync failed: $e');
      }

      // 옵티미스틱 파싱 카드 제거 + 완료 카드로 즉시 전환.
      RecipeService.removeOptimisticParsingRecipe(recipeId);
      RecipeService.parsingProgressCache.remove(recipeId);
      RecipeService.notifyRecipesChanged();
      try {
        _completionController.add({'recipeId': recipeId, 'status': 'completed'});
      } catch (_) {}

      await _analyticsService.trackParsingCompleted(
        platform: 'manual',
        ingredientCount: parseResponse.recipe.ingredients.length,
        stepCount: parseResponse.recipe.steps.length,
        savedToCloud: true,
        durationMs: durationMs,
        recipeId: recipeId,
      );

      _parsingGenerationAtStart.remove(recipeId);

      _maybeShowSimilarRecipesSheet(
        recipeId: recipeId,
        canonicalDishSeed: canonicalDishSeed,
      );
    } catch (e) {
      await _handleParsingError(
        recipeId: recipeId,
        error: '저장 중 오류 발생: $e',
        sourceUrl: '',
      );
    }
  }

  /// Post-save hook: fetch up to 3 similar recipes by canonicalDish and show
  /// a non-blocking bottom sheet, unless the user dismissed it permanently.
  void _maybeShowSimilarRecipesSheet({
    required String recipeId,
    required String canonicalDishSeed,
  }) {
    if (canonicalDishSeed.isEmpty) return;
    Future<void>(() async {
      try {
        final dismissed =
            await _recipeService.isSimilarRecipesSheetDismissed();
        if (dismissed) return;
        final similar = await _recipeService
            .fetchSimilarRecipesByCanonicalDish(
          canonicalDishSeed,
          limit: 3,
          excludeRecipeId: recipeId,
        );
        if (similar.isEmpty) return;
        // 띄우는 시점에 디테일 화면으로의 navigation 이 먼저 일어날 수 있으므로
        // navigator-root context 를 사용한다. 약간의 delay 로 detail 화면이 push
        // 된 후에 그 위에 sheet 가 올라오게 한다.
        await Future.delayed(const Duration(milliseconds: 400));
        final ctx = mainNavigatorKey.currentContext;
        if (ctx == null) return;
        await SimilarRecipesBottomSheet.show(ctx, similarRecipes: similar);
      } catch (e) {
        debugPrint('[BackgroundParsing] Similar recipes sheet failed: $e');
      }
    });
  }

  /// 플랫폼 추출
  String _extractPlatform(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('youtube.com') || lower.contains('youtu.be')) {
      return 'youtube';
    } else if (lower.contains('instagram.com')) {
      return 'instagram';
    } else if (lower.contains('tiktok.com')) {
      return 'tiktok';
    } else if (lower.contains('blog.naver.com') ||
        lower.contains('m.blog.naver.com') ||
        lower.contains('naver.me') ||
        lower.contains('link.naver.com')) {
      return 'naver_blog';
    }
    return 'unknown';
  }
  
  /// 파싱 취소
  Future<void> cancelParsing(String recipeId) async {
    _activeParsing[recipeId]?.cancel();
    _activeParsing.remove(recipeId);
    RecipeService.parsingProgressCache.remove(recipeId);
    _parsingGenerationAtStart.remove(recipeId);

    if (recipeId.startsWith('opt_')) {
      RecipeService.removeOptimisticParsingRecipe(recipeId);
      return;
    }

    if (recipeId.startsWith('local_')) {
      _cancelledLocalIds.add(recipeId);
      await _localStorage.markLocalRecipeCancelled(recipeId);
      RecipeService.removeOptimisticParsingRecipe(recipeId);
      RecipeService.notifyRecipesChanged();
      return;
    }

    final user = _auth.currentUser;
    if (user == null) {
      RecipeService.removeOptimisticParsingRecipe(recipeId);
      return;
    }

    try {
      await _firestore.collection('recipes').doc(recipeId).set({
        'status': 'cancelled',
        'cancelReason': 'user',
        'parseCancelledAt': FieldValue.serverTimestamp(),
        'stage': '취소됨',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}

    try {
      await _userService.removeSavedRecipe(user.uid, recipeId);
    } catch (_) {}

    RecipeService.removeOptimisticParsingRecipe(recipeId);
    RecipeService.notifyRecipesChanged();
  }
  
  /// 에러 상태 레시피 재시도 (기존 레시피 ID 재사용)
  Future<void> retryParsing({
    required String recipeId,
    required String url,
    String preferLang = 'ko',
    bool naverSharedMetaDedup = false,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('로그인이 필요합니다');
    }

    final canonical = _recipeService.buildCanonicalSourceInfo(url);
    final normalizedUrl = canonical.normalizedUrl;
    if (naverSharedMetaDedup ||
        (isNaverBlogUrl(normalizedUrl) && await _isNaverSharedMetaDedup(
          recipeId: recipeId,
          normalizedUrl: normalizedUrl,
          userId: user.uid,
        ))) {
      await retryNaverDedupParsing(
        recipeId: recipeId,
        url: normalizedUrl,
        preferLang: preferLang,
      );
      return;
    }

    await _assertUserParsingLimit(
      userId: user.uid,
      excludingRecipeId: recipeId,
    );
    
    final now = DateTime.now();

    await _analyticsService.trackParsingRequested(
      platform: _extractPlatform(url),
      isAuthenticated: true,
      isRetry: true,
      parsePath: isNaverBlogUrl(normalizedUrl) ? 'sse' : 'async',
    );
    await _analyticsService.trackParseAttemptForUser(user.uid);
    // 기존 레시피 문서를 파싱 중 상태로 초기화
    await _firestore.collection('recipes').doc(recipeId).update({
      'status': 'parsing',
      'progress': 0.0,
      'stage': '시작 중...',
      'recipe': {
        'title': '분석 중..',
      },
      'parsingStartedAt': Timestamp.fromDate(now),
      'isTemporary': true,
      'error': FieldValue.delete(),
      'errorType': FieldValue.delete(),
      'parseCancelledAt': FieldValue.delete(),
      'cancelReason': FieldValue.delete(),
      'appPlatform': ApiService.deviceOsTag,
      'retryCount': FieldValue.increment(1),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    
    await _recordParsingGenerationAtStart(recipeId);
    // 백그라운드에서 파싱 시작 (재시도 로직 포함)
    _parseInBackgroundWithRetry(
      recipeId: recipeId,
      url: normalizedUrl,
      preferLang: preferLang,
    );
    RecipeService.parsingProgressCache.update(recipeId, 0.0, '시작 중...');
    RecipeService.parsingProgressCache.startProgressSimulation(recipeId);
    // 레시피북 스트림은 파싱 중일 때만 폴링하므로, 재시도(error→parsing)를
    // 알려 즉시 리로드/폴링을 깨운다. (이게 없으면 재시도 카드가 안 뜸)
    RecipeService.notifyRecipesChanged();
  }

  /// 공용 네이버 메타 id 재사용(dedup) 재시도. Firestore recipes doc 는 수정하지 않는다.
  Future<void> retryNaverDedupParsing({
    required String recipeId,
    required String url,
    String preferLang = 'ko',
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('로그인이 필요합니다');
    }
    if (!isNaverBlogUrl(url)) {
      throw Exception('네이버 블로그 링크만 이 방식으로 다시 시도할 수 있어요.');
    }

    await _assertUserParsingLimit(userId: user.uid);

    _activeParsing[recipeId]?.cancel();
    _activeParsing.remove(recipeId);

    _naverDedupSkipMetaIds.add(recipeId);

    try {
      await _firestore.collection('users').doc(user.uid).set({
        'savedRecipes': FieldValue.arrayUnion([recipeId]),
        'savedAt.$recipeId': FieldValue.serverTimestamp(),
        'lastUpdated': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      print('[BackgroundParsing] Naver dedup retry: savedRecipes attach failed: $e');
    }

    await _analyticsService.trackParsingRequested(
      platform: 'naver_blog',
      isAuthenticated: true,
      isRetry: true,
      parsePath: 'sse',
    );
    await _analyticsService.trackParseAttemptForUser(user.uid);

    RecipeService.addOptimisticParsingRecipe(
      recipeId: recipeId,
      sourceUrl: url,
    );
    RecipeService.parsingProgressCache.startProgressSimulation(recipeId);
    RecipeService.notifyRecipesChanged();

    _parseInBackgroundWithRetry(
      recipeId: recipeId,
      url: url,
      preferLang: preferLang,
    );
  }

  /// recipeId 가 현재 사용자 소유가 아닌 공용 네이버 메타인지(읽기 가능할 때만).
  Future<bool> _isNaverSharedMetaDedup({
    required String recipeId,
    required String normalizedUrl,
    required String userId,
  }) async {
    if (!isNaverBlogUrl(normalizedUrl)) return false;
    try {
      final doc = await _firestore.collection('recipes').doc(recipeId).get();
      if (!doc.exists) return false;
      final data = doc.data();
      if (data == null) return false;
      final ownerId = data['userId'] as String?;
      if (ownerId == null || ownerId.isEmpty) return false;
      return ownerId != userId;
    } catch (_) {
      // hidden doc 등 읽기 불가 → dedup 재시도 경로로 보내 Firestore update 를 피한다.
      return true;
    }
  }

  /// 글/스크린샷 분석 재시도 (기존 recipeId 재사용).
  Future<void> retryContentParsing({
    required String recipeId,
    String? text,
    List<Uint8List>? images,
    String preferLang = 'ko',
  }) async {
    final imageList = images ?? const <Uint8List>[];
    final hasText = text != null && text.trim().isNotEmpty;
    if (!hasText && imageList.isEmpty) {
      throw Exception('저장된 입력이 없어요. 레시피 추가 화면에서 다시 입력해 주세요.');
    }

    final user = _auth.currentUser;
    final isLocal = recipeId.startsWith('local_');
    final isOptimistic = recipeId.startsWith('opt_');

    if (user != null && !isLocal) {
      await _assertUserParsingLimit(
        userId: user.uid,
        excludingRecipeId: isOptimistic ? null : recipeId,
      );
    }

    await _analyticsService.trackParsingRequested(
      platform: 'manual',
      isAuthenticated: user != null,
      isRetry: true,
      parsePath: 'sse',
    );
    if (user != null) {
      await _analyticsService.trackParseAttemptForUser(user.uid);
    }

    // Firestore doc 가 없는 선행 실패(opt_ 등) → 새 파싱 시작.
    if (user != null && !isLocal && !isOptimistic) {
      final doc = await _firestore.collection('recipes').doc(recipeId).get();
      if (!doc.exists) {
        await startContentParsing(
          text: text,
          images: imageList,
          preferLang: preferLang,
          preAllocatedRecipeId: recipeId,
        );
        return;
      }
    }

    if (user == null || isLocal) {
      if (!isLocal && !isOptimistic) {
        throw Exception('로그인이 필요합니다');
      }
      if (isOptimistic) {
        await startContentParsing(
          text: text,
          images: imageList,
          preferLang: preferLang,
          preAllocatedRecipeId: recipeId,
        );
        return;
      }
      if (user == null &&
          !await GuestParseQuotaService.instance.canParseAsGuest()) {
        throw const GuestParseLimitException();
      }
      await _localStorage.resetLocalRecipeForRetry(recipeId: recipeId);
      RecipeService.parsingProgressCache.update(recipeId, 0.0, '시작 중...');
      RecipeService.parsingProgressCache.startProgressSimulation(recipeId);
      RecipeService.notifyRecipesChanged();
      _parseContentInBackgroundWithRetry(
        recipeId: recipeId,
        text: text,
        images: imageList,
        preferLang: preferLang,
      );
      return;
    }

    if (isOptimistic) {
      await startContentParsing(
        text: text,
        images: imageList,
        preferLang: preferLang,
        preAllocatedRecipeId: recipeId,
      );
      return;
    }

    final now = DateTime.now();
    await _firestore.collection('recipes').doc(recipeId).update({
      'status': 'parsing',
      'progress': 0.0,
      'stage': '시작 중...',
      'recipe': {
        'title': '분석 중..',
      },
      'parsingStartedAt': Timestamp.fromDate(now),
      'isTemporary': true,
      'error': FieldValue.delete(),
      'errorType': FieldValue.delete(),
      'appPlatform': ApiService.deviceOsTag,
      'retryCount': FieldValue.increment(1),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    _parseContentInBackgroundWithRetry(
      recipeId: recipeId,
      text: text,
      images: imageList,
      preferLang: preferLang,
    );
    RecipeService.parsingProgressCache.update(recipeId, 0.0, '시작 중...');
    RecipeService.parsingProgressCache.startProgressSimulation(recipeId);
    RecipeService.notifyRecipesChanged();
  }

  /// Merge step timestamps into an already-saved recipe (Firestore or local).
  Future<void> _applyStepTimestamps(
    String recipeId,
    List<int?> timestamps,
  ) async {
    final user = _auth.currentUser;

    if (user == null || recipeId.startsWith('local_')) {
      // Local storage path — update steps array in the cached recipe.
      try {
        await _localStorage.mergeStepTimestamps(recipeId, timestamps);
        debugPrint('[BackgroundParsing] Applied ${timestamps.length} step timestamps (local)');
      } catch (e) {
        debugPrint('[BackgroundParsing] Failed to apply local step timestamps: $e');
      }
      _completionController.add({
        'recipeId': recipeId,
        'status': 'timestamps_updated',
        'step_timestamps': timestamps,
      });
      return;
    }

    // Firestore path — read current steps, patch start_sec, write back.
    try {
      final doc = await _firestore.collection('recipes').doc(recipeId).get();
      final data = doc.data();
      if (data == null) return;
      final recipeMap = data['recipe'] as Map<String, dynamic>?;
      if (recipeMap == null) return;
      final steps = (recipeMap['steps'] as List<dynamic>?) ?? [];
      bool changed = false;
      for (int i = 0; i < timestamps.length && i < steps.length; i++) {
        if (timestamps[i] != null && steps[i] is Map) {
          (steps[i] as Map<String, dynamic>)['start_sec'] = timestamps[i];
          changed = true;
        }
      }
      if (changed) {
        await _firestore.collection('recipes').doc(recipeId).update({
          'recipe.steps': steps,
        });
        debugPrint('[BackgroundParsing] Applied ${timestamps.length} step timestamps (Firestore)');
      }
    } catch (e) {
      debugPrint('[BackgroundParsing] Failed to apply Firestore step timestamps: $e');
    }

    _completionController.add({
      'recipeId': recipeId,
      'status': 'timestamps_updated',
      'step_timestamps': timestamps,
    });
  }
}

