import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';
import '../utils/receipt_catalog_matcher.dart';
import '../utils/receipt_scan_item_normalizer.dart';

/// 영수증 분석 결과 1건. 원본 사진은 저장하지 않는다.
class ReceiptScanHistoryEntry {
  const ReceiptScanHistoryEntry({
    required this.id,
    required this.scannedAtMs,
    required this.items,
  });

  final String id;
  final int scannedAtMs;
  final List<FridgeScanItemResult> items;

  DateTime get scannedAt =>
      DateTime.fromMillisecondsSinceEpoch(scannedAtMs);

  /// 냉장고에 담을 수 있는(카탈로그 매칭된) 재료만.
  List<FridgeScanItemResult> get addableItems =>
      items.where((e) => e.canAddToFridge).toList(growable: false);

  int get addableCount => addableItems.length;

  String get summaryNames {
    final matched = addableItems;
    final names =
        matched.map((e) => e.name.trim()).where((e) => e.isNotEmpty);
    final list = names.take(3).toList();
    if (list.isEmpty) return '담을 재료 없음';
    final more = matched.length - list.length;
    if (more > 0) return '${list.join(', ')} 외 $more개';
    return list.join(', ');
  }

  /// 항목별 금액 합. 금액이 하나도 없으면 null.
  int? get totalPrice {
    var sum = 0;
    var hasPrice = false;
    for (final item in items) {
      final p = item.price;
      if (p == null || p <= 0) continue;
      hasPrice = true;
      sum += p;
    }
    return hasPrice ? sum : null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'scannedAtMs': scannedAtMs,
        'items': items.map(_itemToJson).toList(),
      };

  static ReceiptScanHistoryEntry fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final items = <FridgeScanItemResult>[];
    if (rawItems is List) {
      for (final raw in rawItems) {
        if (raw is! Map) continue;
        final map = Map<String, dynamic>.from(raw);
        final name = ReceiptScanItemNormalizer.normalizeName(
          (map['name']?.toString() ?? '').trim(),
          rawLine: map['rawLine']?.toString() ?? map['raw_line']?.toString(),
        );
        if (name.isEmpty) continue;
        final rawLine =
            map['rawLine']?.toString() ?? map['raw_line']?.toString();
        final isFoodRaw = map['isFood'] ?? map['is_food'];
        final heuristicFood = ReceiptScanItemNormalizer.isLikelyFood(
          name,
          rawLine: rawLine,
        );
        final isFood =
            isFoodRaw is bool ? (isFoodRaw && heuristicFood) : heuristicFood;
        final catalogName = ReceiptCatalogMatcher.resolveCatalogName(
          name,
          rawLine: rawLine,
        );
        final inCatalogRaw = map['inCatalog'] ?? map['in_catalog'];
        final inCatalog = catalogName != null ||
            (inCatalogRaw is bool ? inCatalogRaw : false);
        items.add(
          FridgeScanItemResult(
            name: catalogName ?? name,
            category: ReceiptScanItemNormalizer.categoryForNormalizedName(
              catalogName ?? name,
              (map['category']?.toString() ?? '').trim(),
            ),
            qty: _asDouble(map['qty']) ?? 1,
            unit: (map['unit']?.toString() ?? '개').trim().isEmpty
                ? '개'
                : (map['unit']?.toString() ?? '개').trim(),
            confidence: (_asDouble(map['confidence']) ?? 0.7).clamp(0.0, 1.0),
            rawLine: rawLine,
            isFood: isFood,
            inCatalog: inCatalog && isFood,
            price: _asInt(map['price']),
          ),
        );
      }
    }
    return ReceiptScanHistoryEntry(
      id: (json['id']?.toString() ?? '').trim().isEmpty
          ? 'scan_${json['scannedAtMs'] ?? 0}'
          : json['id'].toString(),
      scannedAtMs: _asInt(json['scannedAtMs']) ?? 0,
      items: items,
    );
  }

  static Map<String, dynamic> _itemToJson(FridgeScanItemResult item) => {
        'name': item.name,
        'category': item.category,
        'qty': item.qty,
        'unit': item.unit,
        'confidence': item.confidence,
        'isFood': item.isFood,
        'inCatalog': item.inCatalog,
        if (item.price != null) 'price': item.price,
        if (item.rawLine != null && item.rawLine!.trim().isNotEmpty)
          'rawLine': item.rawLine,
      };

  static double? _asDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  static int? _asInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }
}

/// SharedPreferences 기반 영수증 분석 히스토리 (로컬 전용).
class ReceiptScanHistoryStore {
  ReceiptScanHistoryStore._();

  static const String _prefsKey = 'fridge_receipt_scan_history_v1';
  static const int maxEntries = 15;

  static Future<List<ReceiptScanHistoryEntry>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.trim().isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final entries = <ReceiptScanHistoryEntry>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final entry = ReceiptScanHistoryEntry.fromJson(
          Map<String, dynamic>.from(item),
        );
        if (entry.items.isEmpty) continue;
        entries.add(entry);
      }
      entries.sort((a, b) => b.scannedAtMs.compareTo(a.scannedAtMs));
      if (entries.length > maxEntries) {
        return entries.take(maxEntries).toList();
      }
      return entries;
    } catch (_) {
      return const [];
    }
  }

  static List<FridgeScanItemResult> _enrichCatalog(
    List<FridgeScanItemResult> items,
  ) {
    final out = <FridgeScanItemResult>[];
    for (final it in items) {
      final normalizedName = ReceiptScanItemNormalizer.normalizeName(
        it.name,
        rawLine: it.rawLine,
      );
      if (normalizedName.isEmpty) continue;
      final isFood = it.isFood &&
          ReceiptScanItemNormalizer.isLikelyFood(
            normalizedName,
            rawLine: it.rawLine,
          );
      final catalogName = ReceiptCatalogMatcher.resolveCatalogName(
        normalizedName,
        rawLine: it.rawLine,
      );
      final name = catalogName ?? normalizedName;
      out.add(
        it.copyWith(
          name: name,
          category: ReceiptScanItemNormalizer.categoryForNormalizedName(
            name,
            it.category,
          ),
          isFood: isFood,
          inCatalog: catalogName != null && isFood,
        ),
      );
    }
    return out;
  }

  static Future<List<ReceiptScanHistoryEntry>> addFromScan({
    required List<FridgeScanItemResult> items,
    DateTime? scannedAt,
  }) async {
    final cleaned = _enrichCatalog(items);
    if (cleaned.isEmpty) return load();

    final now = scannedAt ?? DateTime.now();
    final entry = ReceiptScanHistoryEntry(
      id: 'scan_${now.millisecondsSinceEpoch}',
      scannedAtMs: now.millisecondsSinceEpoch,
      items: cleaned,
    );
    final current = await load();
    final next = <ReceiptScanHistoryEntry>[
      entry,
      ...current.where((e) => e.id != entry.id),
    ];
    final trimmed = next.take(maxEntries).toList();
    await _persist(trimmed);
    return trimmed;
  }

  static Future<List<ReceiptScanHistoryEntry>> remove(String id) async {
    final current = await load();
    final next = current.where((e) => e.id != id).toList();
    await _persist(next);
    return next;
  }

  static Future<void> _persist(List<ReceiptScanHistoryEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = jsonEncode(entries.map((e) => e.toJson()).toList());
    await prefs.setString(_prefsKey, payload);
  }
}
