import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../theme/app_colors.dart';

class BottomNav extends StatelessWidget {
  final int currentIndex;
  final Function(int) onTap;
  final int? cartBadgeCount;

  const BottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.cartBadgeCount,
  });

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.getBackground(brightness),
        border: Border(
          top: BorderSide(color: AppColors.getBorder(brightness), width: 1),
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildNavItem(
                context,
                iconAsset: 'assets/icons/nav_recipebook.svg',
                label: '레시피북',
                index: 0,
              ),
              _buildNavItem(
                context,
                icon: Icons.restaurant_outlined,
                label: '레시피',
                index: 1,
              ),
              _buildNavItem(
                context,
                icon: Icons.people_outline,
                label: '커뮤니티',
                index: 2,
              ),
              _buildNavItem(
                context,
                icon: Icons.shopping_cart_outlined,
                label: '장바구니',
                index: 3,
                badgeCount: cartBadgeCount,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(
    BuildContext context, {
    IconData? icon,
    String? iconAsset,
    required String label,
    required int index,
    int? badgeCount,
  }) {
    assert(
      icon != null || iconAsset != null,
      'BottomNav item requires either an icon or an iconAsset',
    );
    final isActive = currentIndex == index;
    final brightness = Theme.of(context).brightness;
    final color = isActive
        ? AppColors.primary
        : AppColors.getTextTertiary(brightness);

    final iconWidget = iconAsset != null
        ? SvgPicture.asset(
            iconAsset,
            width: 22,
            height: 22,
            colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
          )
        : Icon(icon, size: 24, color: color);

    return Expanded(
      child: GestureDetector(
        onTap: () => onTap(index),
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 24,
                    width: 24,
                    child: Center(child: iconWidget),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      color: color,
                      fontWeight: isActive
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ],
              ),
              if (badgeCount != null && badgeCount > 0)
                Positioned(
                  top: -4,
                  right: 20,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    constraints: const BoxConstraints(
                      minWidth: 20,
                      minHeight: 20,
                    ),
                    decoration: const BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        badgeCount.toString(),
                        style: TextStyle(
                          color: AppColors.getBackground(brightness),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
