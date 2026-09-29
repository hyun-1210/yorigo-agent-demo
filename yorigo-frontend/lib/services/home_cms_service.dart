import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/home_poster_curations.dart';
import '../models/home_cms_models.dart';

/// 홈 CMS 번들 1회 fetch + 디스크/메모리 TTL 캐시.
class HomeCmsService {
  HomeCmsService._();
  static final HomeCmsService instance = HomeCmsService._();

  static const Duration ttl = Duration(hours: 1);
  static const String _prefsKey = 'home_cms_bundle_v1';

  HomeCmsBundle? _bundle;
  DateTime? _fetchedAt;
  Future<HomeCmsBundle?>? _inFlight;

  HomeCmsBundle? get cachedBundle => _bundle;

  /// Mixpanel 시계열을 CMS 번들 버전에 묶을 때 사용. 캐시 없으면 null.
  String? get analyticsUpdatedAt {
    final value = _bundle?.updatedAt.trim();
    if (value == null || value.isEmpty) return null;
    return value;
  }

  List<HomePosterCuration> get postersOrFallback {
    try {
      final enabled = _bundle?.enabledPosters ?? const <HomeCmsPoster>[];
      if (enabled.isEmpty) return HomePosterCurations.all;
      final parsed = <HomePosterCuration>[];
      for (final poster in enabled) {
        if (poster.id.isEmpty) continue;
        try {
          parsed.add(HomePosterCuration.fromCms(poster.data));
        } catch (e) {
          debugPrint('[HomeCms] skip poster ${poster.id}: $e');
        }
      }
      return parsed.isEmpty ? HomePosterCurations.all : parsed;
    } catch (e) {
      debugPrint('[HomeCms] posters fallback: $e');
      return HomePosterCurations.all;
    }
  }

  HomePosterCuration? posterById(String id) {
    final resolved = id == 'fridge_three_ingredients' ? 'mynormal_low_sugar' : id;
    for (final p in postersOrFallback) {
      if (p.id == resolved) return p;
    }
    return HomePosterCurations.byId(resolved);
  }

  List<HomeCmsSection> get enabledHomeSections =>
      _bundle?.enabledSections ?? const <HomeCmsSection>[];

  List<HomeCmsSection> get programsOrFallback =>
      _bundle?.enabledPrograms ?? const <HomeCmsSection>[];

  bool isSectionEnabled(String sectionKey) {
    final bundle = _bundle;
    if (bundle == null) return true;
    for (final s in bundle.sections) {
      if (s.sectionKey == sectionKey) return s.enabled;
    }
    return true;
  }

  Future<HomeCmsBundle?> ensureLoaded({bool force = false}) {
    if (!force &&
        _bundle != null &&
        _fetchedAt != null &&
        DateTime.now().difference(_fetchedAt!) < ttl) {
      return Future<HomeCmsBundle?>.value(_bundle);
    }
    return _inFlight ??= _load(force: force).whenComplete(() => _inFlight = null);
  }

  Future<HomeCmsBundle?> _load({required bool force}) async {
    if (!force) {
      await _readDisk();
    }
    try {
      final snap = await FirebaseFirestore.instance
          .collection('home_cms')
          .doc('bundle')
          .get();
      if (!snap.exists) {
        _fetchedAt = DateTime.now();
        return _bundle;
      }
      final data = snap.data() ?? <String, dynamic>{};
      final parsed = HomeCmsBundle.fromJson(data);
      _bundle = parsed;
      _fetchedAt = DateTime.now();
      await _writeDisk(data);
      return parsed;
    } catch (e) {
      debugPrint('[HomeCms] fetch failed: $e');
      _fetchedAt = DateTime.now();
      return _bundle;
    }
  }

  Future<void> _readDisk() async {
    if (_bundle != null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        _bundle = HomeCmsBundle.fromJson(decoded);
      } else if (decoded is Map) {
        _bundle = HomeCmsBundle.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (e) {
      debugPrint('[HomeCms] disk read failed: $e');
    }
  }

  Future<void> _writeDisk(Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(data));
    } catch (e) {
      debugPrint('[HomeCms] disk write failed: $e');
    }
  }

  @visibleForTesting
  void debugSetBundle(HomeCmsBundle? bundle) {
    _bundle = bundle;
    _fetchedAt = DateTime.now();
  }
}
