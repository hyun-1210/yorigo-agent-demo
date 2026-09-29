import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/environment_config.dart';
import '../services/admin_service.dart';
import 'ingredient_conversion_gap_ledger.dart';

/// Batches [IngredientConversionGap] reports to
/// `POST /admin/conversion-gaps/research-batch` (1–3 items per call, one Gemini run).
///
/// - **Immediate:** when **3** unique gaps are queued, flushes right away (admin + token).
/// - **24h fallback:** if **1–2** gaps sit in the queue for **24 hours** without a third,
///   sends that partial batch so late-arriving data still gets researched.
///
/// Enable with `--dart-define=ENABLE_CONVERSION_GAP_RESEARCH_BATCH=true`.
class IngredientConversionGapResearchUploader {
  IngredientConversionGapResearchUploader._();

  static final List<IngredientConversionGap> _pending = [];
  static final Set<String> _fingerprintsInQueue = {};
  static bool _flushing = false;
  static void Function(IngredientConversionGap)? _previousOnGap;
  static Timer? _partialFlushDeadline;

  static const Duration _partialFlushAfter = Duration(hours: 24);

  static String _fingerprint(IngredientConversionGap g) =>
      '${g.kind.name}|${g.ingredientName}|${g.recipeUnit ?? ''}|${g.shoppingUnit ?? ''}|${g.detail ?? ''}';

  /// Chain into [IngredientConversionGapLedger.onGap]. Safe to call once at startup.
  static void install() {
    if (!EnvironmentConfig.enableConversionGapResearchBatch) return;
    _previousOnGap = IngredientConversionGapLedger.onGap;
    IngredientConversionGapLedger.onGap = (gap) {
      _previousOnGap?.call(gap);
      _onGap(gap);
    };
  }

  static void _schedulePartialFlushDeadline() {
    if (_pending.isEmpty || _pending.length >= 3) {
      _partialFlushDeadline?.cancel();
      _partialFlushDeadline = null;
      return;
    }
    if (_partialFlushDeadline?.isActive == true) return;
    _partialFlushDeadline = Timer(_partialFlushAfter, () {
      unawaited(_flushPartialDueToDeadline());
    });
  }

  static void _onGap(IngredientConversionGap gap) {
    final fp = _fingerprint(gap);
    if (_fingerprintsInQueue.contains(fp)) return;
    _fingerprintsInQueue.add(fp);
    _pending.add(gap);
    if (_pending.length >= 3) {
      _partialFlushDeadline?.cancel();
      _partialFlushDeadline = null;
      unawaited(_flushBatch());
    } else {
      _schedulePartialFlushDeadline();
    }
  }

  static Future<void> _flushPartialDueToDeadline() async {
    if (_flushing || _pending.isEmpty) return;
    if (_pending.length >= 3) {
      unawaited(_flushBatch());
      return;
    }
    await _postAndDrain(_pending.length);
  }

  static Future<void> _flushBatch() async {
    if (_flushing || _pending.length < 3) return;
    await _postAndDrain(3);
  }

  static Future<void> _postAndDrain(int take) async {
    if (_flushing || take < 1 || take > 3 || _pending.length < take) return;
    _flushing = true;
    final batch = List<IngredientConversionGap>.from(_pending.take(take));
    try {
      if (!await AdminService.instance.isAdmin()) {
        return;
      }
      final user = FirebaseAuth.instance.currentUser;
      final token = user == null ? null : await user.getIdToken();
      if (token == null) {
        return;
      }

      final uri = Uri.parse(
        '${EnvironmentConfig.baseUrl}/admin/conversion-gaps/research-batch',
      );
      final body = jsonEncode({
        'gaps': batch.map((e) => e.toJson()).toList(),
      });
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
        for (final g in batch) {
          _fingerprintsInQueue.remove(_fingerprint(g));
        }
        if (kDebugMode) {
          debugPrint('[ConversionGapResearch] batch OK (${batch.length} items)');
        }
      } else {
        if (kDebugMode) {
          debugPrint(
            '[ConversionGapResearch] HTTP ${res.statusCode} ${res.body}',
          );
        }
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[ConversionGapResearch] error: $e\n$st');
      }
    } finally {
      _flushing = false;
      _partialFlushDeadline?.cancel();
      _partialFlushDeadline = null;
      if (_pending.length >= 3) {
        unawaited(_flushBatch());
      } else if (_pending.isNotEmpty) {
        _schedulePartialFlushDeadline();
      }
    }
  }
}
