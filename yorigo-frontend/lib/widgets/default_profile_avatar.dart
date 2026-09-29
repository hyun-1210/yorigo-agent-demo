import 'package:flutter/material.dart';

import 'user_initial_avatar.dart';

/// Default profile avatar used when a user has not uploaded a profile photo.
///
/// Prefer passing [seed] (e.g. uid) and [name] so the avatar renders the
/// shared pastel `color + first letter` chip that's used everywhere else in
/// the app. The legacy grey asset path is kept as a fallback for the few
/// call sites that don't have user identity handy (e.g. linked account
/// placeholders).
class DefaultProfileAvatar extends StatelessWidget {
  const DefaultProfileAvatar({super.key, this.size = 56, this.seed, this.name});

  final double size;
  final String? seed;
  final String? name;

  static const String _asset = 'assets/default_profile_avatar.png';

  @override
  Widget build(BuildContext context) {
    final hasIdentity =
        (seed?.trim().isNotEmpty ?? false) ||
        (name?.trim().isNotEmpty ?? false);
    if (hasIdentity) {
      return UserInitialAvatar(
        seed: (seed ?? '').trim(),
        name: (name ?? '').trim(),
        size: size,
      );
    }
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Container(width: size, height: size, color: const Color(0xFFE0E0E0)),
        Image.asset(
          _asset,
          fit: BoxFit.cover,
          width: size,
          height: size,
          errorBuilder: (context, error, stackTrace) {
            return Container(
              width: size,
              height: size,
              color: const Color(0xFFBDBDBD),
              alignment: Alignment.center,
              child: Icon(
                Icons.person_rounded,
                size: size * 0.55,
                color: Colors.white,
              ),
            );
          },
        ),
      ],
    );
  }

  /// ImageProvider for use in CircleAvatar.backgroundImage
  static ImageProvider get imageProvider => const AssetImage(_asset);
}
