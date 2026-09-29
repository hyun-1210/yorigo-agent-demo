import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../theme/app_colors.dart';
import '../services/auth_service.dart';
import '../utils/auth_session_ready.dart';
import '../services/notification_service.dart';
import '../services/analytics_service.dart';
import '../utils/meal_calendar_launcher.dart';
import '../screens/notifications_screen.dart';
// [임시 비활성] 리워드 뱃지
// import 'rewards_balance_badge.dart';
import 'yorigo_header_logo.dart';

class AppHeader extends StatelessWidget {
  final VoidCallback? onLoginPressed;
  final bool showProfileIcon;
  final bool showLoginButton;
  /// Customer center (headset) to the left of settings — Profile tab.
  final bool showCustomerCenterIcon;
  /// Bell + unread badge when signed in; hidden when logged out. Omit on Profile tab.
  final bool showNotificationIcon;
  /// Calendar shortcut icon placed before the notification bell.
  final bool showCalendarIcon;
  final VoidCallback? onCalendarPressed;
  /// Search shortcut icon placed before the calendar icon (e.g. Home only).
  final bool showSearchIcon;
  final VoidCallback? onSearchPressed;
  /// Hide the bottom border line (e.g. when header merges visually with a card below).
  final bool hideBottomBorder;
  /// 헤더 리워드 뱃지 탭 시 (기본: /profile 라우트).
  final VoidCallback? onRewardsPressed;
  /// 로그인 시 로고 옆 포인트/경험치 뱃지 표시.
  final bool showRewardsBadge;

  const AppHeader({
    super.key,
    this.onLoginPressed,
    this.showProfileIcon = false,
    this.showLoginButton = false,
    this.showCustomerCenterIcon = false,
    this.showNotificationIcon = false,
    this.showCalendarIcon = false,
    this.onCalendarPressed,
    this.showSearchIcon = false,
    this.onSearchPressed,
    this.hideBottomBorder = false,
    this.onRewardsPressed,
    this.showRewardsBadge = true,
  });

  @override
  Widget build(BuildContext context) {
    final authService = AuthService();

    final brightness = Theme.of(context).brightness;
    final showTrailing =
        showSearchIcon ||
        showCalendarIcon ||
        showNotificationIcon ||
        showCustomerCenterIcon ||
        showProfileIcon ||
        showLoginButton;

    Widget buildTrailing(BuildContext context, User? user) {
      final loggedIn = user != null;
      // 검색은 로그인 여부와 무관하게 노출.
      final showSearch = showSearchIcon;
      final showCalendar = showCalendarIcon && loggedIn;
      final showBell = showNotificationIcon && loggedIn;
      final showCs = showCustomerCenterIcon && loggedIn;
      final showProfileOrLogin =
          (loggedIn && showProfileIcon) || (!loggedIn && showLoginButton);
      final afterSearch = showCalendar || showBell || showCs || showProfileOrLogin;
      final afterCalendar = showBell || showCs || showProfileOrLogin;
      final afterBell = showCs || showProfileOrLogin;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showSearch) _buildSearchShortcut(context),
          if (showSearch && afterSearch) const SizedBox(width: 4),
          if (showCalendar) _buildCalendarShortcut(context),
          if (showCalendar && afterCalendar) const SizedBox(width: 4),
          if (showBell) _buildNotificationBell(context),
          if (showBell && afterBell) const SizedBox(width: 4),
          if (showCs) _buildCustomerCenterShortcut(context),
          if (showCs && showProfileOrLogin) const SizedBox(width: 4),
          if (showProfileOrLogin) _profileOrLogin(context, loggedIn),
        ],
      );
    }

    return Container(
      height: 52,
      padding: const EdgeInsets.only(left: 20, right: 16),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: AppColors.getBackground(brightness),
        border: hideBottomBorder
            ? null
            : Border(
                bottom: BorderSide(color: AppColors.getBorder(brightness), width: 1),
              ),
      ),
      child: StreamBuilder<User?>(
        stream: authService.authStateChanges,
        initialData: authService.currentUser,
        builder: (context, snapshot) {
          User? user = snapshot.data;
          if (user == null &&
              (snapshot.connectionState == ConnectionState.waiting ||
                  shouldIgnoreTransientAuthNull())) {
            user = authService.currentUser;
          }
          return Row(
            children: [
              const YorigoHeaderLogo(height: 24, maxWidth: 160),
              // [임시 비활성] 홈 상단 포인트/경험치 뱃지
              // final loggedIn = user != null;
              // if (loggedIn && showRewardsBadge) ...[
              //   const SizedBox(width: 8),
              //   RewardsBalanceBadge(
              //     onTap: onRewardsPressed ??
              //         () => Navigator.pushNamed(context, '/profile'),
              //   ),
              // ],
              const Spacer(),
              if (showTrailing) buildTrailing(context, user),
            ],
          );
        },
      ),
    );
  }

  Widget _buildCustomerCenterShortcut(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 36,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => Navigator.pushNamed(context, '/customer-center'),
          child: const Center(
            child: Icon(
              Icons.headset_mic_outlined,
              size: 23,
              color: Color(0xFF1E2939),
            ),
          ),
        ),
      ),
    );
  }

  Widget _profileOrLogin(BuildContext context, bool loggedIn) {
    if (loggedIn && showProfileIcon) {
      return SizedBox(
        width: 36,
        height: 36,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => Navigator.pushNamed(context, '/settings'),
            child: const Center(
              child: Icon(
                Icons.settings_outlined,
                size: 24,
                color: Color(0xFF1E2939),
              ),
            ),
          ),
        ),
      );
    }
    if (!loggedIn && showLoginButton) {
      return GestureDetector(
        onTap: () {
          if (onLoginPressed != null) {
            onLoginPressed!();
          } else {
            Navigator.pushNamed(context, '/login');
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 6,
          ),
          decoration: BoxDecoration(
            color: const Color(0xFFFF7518),
            borderRadius: BorderRadius.circular(33554400),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFF7518).withValues(alpha: 0.2),
                blurRadius: 3,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: const Text(
            '로그인',
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 13,
              fontWeight: FontWeight.w700,
              height: 19.5 / 13,
              color: Colors.white,
            ),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildNotificationBell(BuildContext context) {
    return StreamBuilder<int>(
      stream: NotificationService.instance.unreadCountStream(),
      builder: (context, snapshot) {
        final unread = snapshot.data ?? 0;
        return SizedBox(
          width: 36,
          height: 36,
          // Badge lives in this OUTER stack (not inside the circular Material),
          // so it is never clipped by the bell's CircleBorder clip. Position
          // and style stay exactly as before.
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: Material(
                  color: Colors.transparent,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () async {
                      unawaited(AnalyticsService().trackNotificationsOpened());
                      final result = await Navigator.push<AppNotificationAction>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const NotificationsScreen(),
                        ),
                      );
                      if (!context.mounted) return;
                      if (result == null) return;
                      NotificationService.instance.notificationUiActionDelegate
                          ?.call(result);
                    },
                    child: const Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          left: 6,
                          top: 6,
                          child: Icon(
                            Icons.notifications_none_rounded,
                            size: 24,
                            color: Color(0xFF1E2939),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (unread > 0)
                Positioned(
                  left: 18,
                  top: 3,
                  child: IgnorePointer(
                    child: Container(
                      height: 16,
                      constraints: const BoxConstraints(minWidth: 16),
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF6B00),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        unread > 99 ? '99+' : '$unread',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          height: 1.0,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSearchShortcut(BuildContext context) {
    return SizedBox(
      width: 34,
      height: 36,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onSearchPressed,
          child: const Center(
            child: Icon(
              Icons.search_rounded,
              size: 24,
              color: Color(0xFF1E2939),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCalendarShortcut(BuildContext context) {
    return SizedBox(
      width: 34,
      height: 36,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap:
              onCalendarPressed ??
              () => openMealCalendar(context),
          child: const Center(
            child: Icon(
              Icons.calendar_month_rounded,
              size: 23,
              color: Color(0xFF1E2939),
            ),
          ),
        ),
      ),
    );
  }
}
