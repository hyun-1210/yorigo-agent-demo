import 'package:flutter/material.dart';

/// Firestore `home_cms/bundle` 스냅샷.
class HomeCmsBundle {
  const HomeCmsBundle({
    required this.schemaVersion,
    required this.updatedAt,
    required this.posters,
    required this.sections,
  });

  final int schemaVersion;
  final String updatedAt;
  final List<HomeCmsPoster> posters;
  final List<HomeCmsSection> sections;

  factory HomeCmsBundle.fromJson(Map<String, dynamic> json) {
    final postersRaw = json['posters'];
    final sectionsRaw = json['sections'];
    return HomeCmsBundle(
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 1,
      updatedAt: json['updatedAt']?.toString() ?? '',
      posters: [
        if (postersRaw is List)
          for (final item in postersRaw)
            if (item is Map)
              HomeCmsPoster.fromJson(Map<String, dynamic>.from(item)),
      ],
      sections: [
        if (sectionsRaw is List)
          for (final item in sectionsRaw)
            if (item is Map)
              HomeCmsSection.fromJson(Map<String, dynamic>.from(item)),
      ],
    );
  }

  List<HomeCmsPoster> get enabledPosters {
    final list = posters.where((p) => p.enabled).toList();
    list.sort((a, b) => a.order.compareTo(b.order));
    return list;
  }

  List<HomeCmsSection> get enabledSections {
    final list = sections.where((s) => s.enabled).toList();
    list.sort((a, b) => a.order.compareTo(b.order));
    return list;
  }

  List<HomeCmsSection> get enabledPrograms => enabledSections
      .where((s) => s.kind == 'program')
      .toList(growable: false);
}

class HomeCmsPoster {
  const HomeCmsPoster({
    required this.id,
    required this.order,
    required this.enabled,
    required this.data,
  });

  final String id;
  final int order;
  final bool enabled;
  final Map<String, dynamic> data;

  factory HomeCmsPoster.fromJson(Map<String, dynamic> json) {
    return HomeCmsPoster(
      id: json['id']?.toString() ?? '',
      order: (json['order'] as num?)?.toInt() ?? 0,
      enabled: json['enabled'] != false,
      data: json,
    );
  }
}

class HomeCmsSection {
  const HomeCmsSection({
    required this.sectionKey,
    required this.label,
    required this.kind,
    required this.order,
    required this.enabled,
    required this.membersOnly,
  });

  final String sectionKey;
  final String label;
  final String kind;
  final int order;
  final bool enabled;
  final bool membersOnly;

  factory HomeCmsSection.fromJson(Map<String, dynamic> json) {
    return HomeCmsSection(
      sectionKey: (json['sectionKey'] ?? json['id'])?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      kind: json['kind']?.toString() ?? 'trend',
      order: (json['order'] as num?)?.toInt() ?? 0,
      enabled: json['enabled'] != false,
      membersOnly: json['membersOnly'] == true,
    );
  }
}

Alignment homeCmsAlignment(String? raw) {
  switch ((raw ?? '').trim()) {
    case 'center':
      return Alignment.center;
    case 'centerLeft':
      return Alignment.centerLeft;
    case 'topCenter':
      return Alignment.topCenter;
    case 'bottomCenter':
      return Alignment.bottomCenter;
    default:
      return Alignment.centerRight;
  }
}

IconData homeCmsTipIcon(String? raw) {
  switch ((raw ?? '').trim()) {
    case 'science_outlined':
      return Icons.science_outlined;
    case 'swap_horiz_rounded':
      return Icons.swap_horiz_rounded;
    case 'restaurant_outlined':
      return Icons.restaurant_outlined;
    case 'shopping_basket_outlined':
      return Icons.shopping_basket_outlined;
    case 'soup_kitchen_outlined':
      return Icons.soup_kitchen_outlined;
    case 'scale_outlined':
      return Icons.scale_outlined;
    case 'lightbulb_outline':
      return Icons.lightbulb_outline;
    default:
      return Icons.info_outline;
  }
}
