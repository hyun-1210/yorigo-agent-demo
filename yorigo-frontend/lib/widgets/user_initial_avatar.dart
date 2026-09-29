import 'package:flutter/material.dart';

/// Gray "letter" avatar used everywhere the user has not uploaded a photo.
/// The shade is deterministic per [seed] so the same user stays the same.
///
/// Use this widget (or the static [colorFor] / [initialFor] helpers) for every
/// fallback avatar in the app so they look consistent.
class UserInitialAvatar extends StatelessWidget {
  const UserInitialAvatar({
    super.key,
    required this.seed,
    required this.name,
    this.size = 40,
    this.fontSize,
  });

  /// Stable identifier used to pick the color (e.g. user uid). If empty, we
  /// fall back to [name] so the color still doesn't change between rebuilds.
  final String seed;

  /// Display name; only the first non-empty character is rendered.
  final String name;

  final double size;
  final double? fontSize;

  static const List<Color> _palette = <Color>[
    Color(0xFFF3F4F6),
    Color(0xFFE8EAED),
    Color(0xFFE5E7EB),
    Color(0xFFDDE1E6),
  ];

  /// Pick a stable background color for a given [seed].
  static Color colorFor(String seed) {
    final source = seed.isEmpty ? '_' : seed;
    // FNV-1a 32-bit gives much better dispersion across short uids than a
    // rolling `value * 31 + rune` hash.
    int hash = 0x811C9DC5;
    for (final rune in source.runes) {
      hash ^= rune;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return _palette[hash % _palette.length];
  }

  /// First displayable character for [name]. Strips a leading `@`, falls back
  /// to `요` if nothing usable remains. Original case is preserved so
  /// `skyland` stays `s`, not `S`.
  static String initialFor(String name) {
    final normalized = name.startsWith('@') ? name.substring(1) : name;
    final trimmed = normalized.trim();
    if (trimmed.isEmpty) return '요';
    return String.fromCharCode(trimmed.runes.first);
  }

  static const Color _foregroundColor = Color(0xFF6B7280);

  @override
  Widget build(BuildContext context) {
    final color = colorFor(seed.isNotEmpty ? seed : name);
    final initial = initialFor(name);
    final letterSize = fontSize ?? (size * 0.44);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          fontFamily: 'Pretendard',
          fontSize: letterSize,
          fontWeight: FontWeight.w800,
          color: _foregroundColor,
          height: 1,
        ),
      ),
    );
  }
}
