import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/environment_config.dart';
import '../services/ingredient_shelf_life_service.dart';

/// Detects ingredients missing shelf-life data and batches them for
/// LLM research via `POST /admin/shelf-life/research-batch`.
///
/// - Collects up to 10 ingredient names at a time.
/// - Flushes immediately when 10 are queued, or after 24 hours for partials.
/// - On failure, retries with exponential backoff (max 3 attempts per batch).
/// - Results are auto-saved to Firestore by the backend, and the local
///   [IngredientShelfLifeService] cache is refreshed.
class ShelfLifeResearchUploader {
  ShelfLifeResearchUploader._();

  static final List<String> _pending = [];
  static final Set<String> _alreadyQueued = {};
  static bool _flushing = false;
  static Timer? _partialFlushDeadline;
  static Timer? _retryTimer;
  static int _consecutiveFailures = 0;

  static const int _batchSize = 3;
  static const int _maxRetries = 3;
  static const Duration _partialFlushAfter = Duration(seconds: 30);

  /// Call this whenever new ingredients appear (e.g., after a recipe is parsed
  /// and its ingredients are stored in the fridge). It will queue any ingredient
  /// names that lack shelf-life data for LLM research.
  static void checkAndQueue(List<String> ingredientNames) {
    final service = IngredientShelfLifeService.instance;
    final missing = service.findMissingIngredients(ingredientNames);
    for (final name in missing) {
      if (_alreadyQueued.contains(name)) continue;
      _alreadyQueued.add(name);
      _pending.add(name);
    }
    if (_pending.length >= _batchSize && _retryTimer == null) {
      _partialFlushDeadline?.cancel();
      _partialFlushDeadline = null;
      unawaited(_flushBatch());
    } else if (_pending.isNotEmpty && _retryTimer == null) {
      _schedulePartialFlushDeadline();
    }
  }

  static void _schedulePartialFlushDeadline() {
    if (_pending.isEmpty || _pending.length >= _batchSize) {
      _partialFlushDeadline?.cancel();
      _partialFlushDeadline = null;
      return;
    }
    if (_partialFlushDeadline?.isActive == true) return;
    _partialFlushDeadline = Timer(_partialFlushAfter, () {
      unawaited(_flushPartial());
    });
  }

  static Future<void> _flushPartial() async {
    if (_flushing || _pending.isEmpty) return;
    await _postAndDrain(_pending.length.clamp(1, _batchSize));
  }

  static Future<void> _flushBatch() async {
    if (_flushing || _pending.length < _batchSize) return;
    await _postAndDrain(_batchSize);
  }

  static void _scheduleRetry() {
    if (_consecutiveFailures >= _maxRetries) {
      if (kDebugMode) {
        debugPrint(
          '[ShelfLifeResearch] giving up after $_maxRetries failures, '
          '${_pending.length} items remain in queue',
        );
      }
      _consecutiveFailures = 0;
      _pending.clear();
      _alreadyQueued.clear();
      return;
    }
    final delaySec = math.min(300, 30 * math.pow(2, _consecutiveFailures).toInt());
    if (kDebugMode) {
      debugPrint(
        '[ShelfLifeResearch] retry #${_consecutiveFailures + 1} in ${delaySec}s',
      );
    }
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(seconds: delaySec), () {
      _retryTimer = null;
      if (_pending.length >= _batchSize) {
        unawaited(_flushBatch());
      } else if (_pending.isNotEmpty) {
        unawaited(_flushPartial());
      }
    });
  }

  static Future<void> _postAndDrain(int take) async {
    if (_flushing || take < 1 || _pending.length < take) return;
    _flushing = true;
    final batch = List<String>.from(_pending.take(take));
    try {
      final user = FirebaseAuth.instance.currentUser;
      final token = user == null ? null : await user.getIdToken();
      if (token == null) return;

      final uri = Uri.parse(
        '${EnvironmentConfig.baseUrl}/admin/shelf-life/research-batch',
      );
      final body = jsonEncode({'ingredient_names': batch});
      final res = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json; charset=utf-8',
        },
        body: body,
      );
      if (res.statusCode == 200) {
        _pending.removeRange(0, take);
        for (final name in batch) {
          _alreadyQueued.remove(name);
        }
        _consecutiveFailures = 0;

        await IngredientShelfLifeService.instance.ensureLoaded();

        if (kDebugMode) {
          debugPrint(
              '[ShelfLifeResearch] batch OK (${batch.length} items)');
        }
        // Process remaining items if any.
        if (_pending.length >= _batchSize) {
          unawaited(_flushBatch());
        } else if (_pending.isNotEmpty) {
          _schedulePartialFlushDeadline();
        }
      } else {
        if (kDebugMode) {
          debugPrint(
            '[ShelfLifeResearch] HTTP ${res.statusCode} '
            '(${batch.length} items deferred)',
          );
        }
        _consecutiveFailures++;
        _scheduleRetry();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[ShelfLifeResearch] error: $e');
      }
      _consecutiveFailures++;
      _scheduleRetry();
    } finally {
      _flushing = false;
    }
  }
}
