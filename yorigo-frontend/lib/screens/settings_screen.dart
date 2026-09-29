import 'dart:io';
import 'package:app_settings/app_settings.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import '../widgets/app_toast.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:firebase_auth/firebase_auth.dart';
import '../services/auth_service.dart';
import '../services/user_service.dart';
import '../services/admin_service.dart';
import '../services/notification_service.dart';
import '../theme/app_colors.dart';
import '../widgets/app_network_image.dart';
import '../widgets/environment_switcher.dart';
import '../l10n/app_localizations.dart';
import '../widgets/default_profile_avatar.dart';
import 'profile_edit_screen.dart';
import 'linked_account_screen.dart';
import 'help_screen.dart';
import 'customer_center_screen.dart';
import '../widgets/profile_feedback_sheet.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final bool _isLinking = false;
  final UserService _userService = UserService();
  final ImagePicker _imagePicker = ImagePicker();
  bool _isSchedulingPushTest = false;
  bool _isSchedulingInstagramBroadcast = false;
  bool _isSchedulingAppReinstallBroadcast = false;
  bool _isSchedulingMealReminderTest = false;

  /// null = 아직 모름(첫 진입·캐시 없음), true/false = 표시 확정
  bool? _isAdmin;

  // Figma design tokens (node 269-235)
  static const Color _figmaBorder = Color(0xFFF2F4F6);
  static const Color _figmaShadow = Color(0x05000000);
  static const Color _figmaTextPrimary = Color(0xFF191F28);
  static const Color _figmaTextSecondary = Color(0xFF333D4B);
  static const Color _figmaTextMuted = Color(0xFF8B95A1);
  static const Color _figmaTextDisabled = Color(0xFFB0B8C1);
  static const Color _figmaTextDisabledSub = Color(0xFFD1D6DB);
  static const Color _figmaPillBg = Color(0xFFF2F4F6);
  static const Color _figmaConnectedBg = Color(0xFFE8F5E9);
  static const Color _figmaConnectedText = Color(0xFF15803D);
  static const Color _figmaLogoutRed = Color(0xFFEF4444);

  @override
  void initState() {
    super.initState();
    // 세션 중 이미 조회된 캐시가 있으면 즉시 표시 (깜빡임 방지)
    _isAdmin = AdminService.instance.cachedIsAdminForCurrentUser();
    // 백그라운드에서 최신 권한 재확인 (실패 시 기존 캐시 유지)
    _refreshAdminRole();
  }

  Future<void> _refreshAdminRole() async {
    final isAdmin = await AdminService.instance.refreshIsAdmin();
    if (!mounted) return;
    if (_isAdmin != isAdmin) {
      setState(() => _isAdmin = isAdmin);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authService = AuthService();
    final user = authService.currentUser;
    final l10n = AppLocalizations.of(context);
    final brightness = Theme.of(context).brightness;

    return Scaffold(
      backgroundColor: AppColors.getBackground(brightness),
      appBar: AppBar(
        backgroundColor: AppColors.getBackground(brightness),
        elevation: 0,
        titleSpacing: 0,
        title: const Text(
          '설정',
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        centerTitle: false,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back,
            color: AppColors.getTextPrimary(brightness),
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(left: 20, right: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (user != null) ...[
                _buildFigmaProfileCard(context, user, brightness),
                const SizedBox(height: 12),
                _buildFigmaRowCard(
                  icon: Icons.edit_outlined,
                  title: '프로필 편집',
                  subtitle: '닉네임, 아이디, 프로필 사진 수정',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ProfileEditScreen(
                          user: user,
                          onSaved: () => setState(() {}),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),
                _buildFigmaLinkedAccountsSection(
                  context,
                  authService,
                  brightness,
                ),
                const SizedBox(height: 12),
              ],
              _buildFigmaSettingsCard(context, authService, brightness),
              if (kDebugMode) ...[
                const SizedBox(height: 12),
                const EnvironmentSwitcher(),
              ],
              const SizedBox(height: 12),
              _buildFigmaLogoutCard(context, authService, l10n),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFigmaProfileCard(
    BuildContext context,
    User user,
    Brightness brightness,
  ) {
    return FutureBuilder(
      future: _userService.getUserDocument(user.uid),
      builder: (context, snapshot) {
        final userData = snapshot.data?.data() as Map<String, dynamic>?;
        final displayName = user.displayName ?? userData?['name'] ?? '';
        final handle = userData?['handle'] as String? ?? '';
        final email = user.email ?? '';
        final photoUrl =
            (userData != null ? resolveUserPhotoUrl(userData) : null) ??
            user.photoURL;

        return _figmaCard(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          minHeight: 81.33,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 48,
                height: 48,
                child: ClipOval(
                  child: photoUrl != null && photoUrl.isNotEmpty
                      ? Image.network(
                          photoUrl,
                          fit: BoxFit.cover,
                          width: 48,
                          height: 48,
                          errorBuilder: (_, __, ___) => DefaultProfileAvatar(
                            size: 48,
                            seed: user.uid,
                            name: displayName.isNotEmpty
                                ? displayName.toString()
                                : (handle.isNotEmpty ? handle : '나'),
                          ),
                        )
                      : DefaultProfileAvatar(
                          size: 48,
                          seed: user.uid,
                          name: displayName.isNotEmpty
                              ? displayName.toString()
                              : (handle.isNotEmpty ? handle : '나'),
                        ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            displayName.isNotEmpty
                                ? displayName
                                : (user.email ?? '사용자'),
                            style: const TextStyle(
                              color: _figmaTextPrimary,
                              fontSize: 16,
                              fontFamily: 'Pretendard',
                              fontWeight: FontWeight.w700,
                              height: 1.50,
                              letterSpacing: -0.40,
                            ),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                        if (handle.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Flexible(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: ShapeDecoration(
                                color: _figmaPillBg,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(6),
                                ),
                              ),
                              child: Text(
                                '@$handle',
                                style: const TextStyle(
                                  color: _figmaTextMuted,
                                  fontSize: 11,
                                  fontFamily: 'Pretendard',
                                  fontWeight: FontWeight.w500,
                                  height: 1.50,
                                  letterSpacing: -0.40,
                                ),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      email,
                      style: const TextStyle(
                        color: _figmaTextMuted,
                        fontSize: 13,
                        fontFamily: 'Pretendard',
                        fontWeight: FontWeight.w400,
                        height: 1.50,
                        letterSpacing: -0.32,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFigmaRowCard({
    required IconData icon,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: _figmaCard(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        minHeight: 75.83,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: _figmaTextSecondary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: _figmaTextSecondary,
                      fontSize: 15,
                      fontFamily: 'Pretendard',
                      fontWeight: FontWeight.w700,
                      height: 1.50,
                      letterSpacing: -0.38,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: _figmaTextMuted,
                        fontSize: 12,
                        fontFamily: 'Pretendard',
                        fontWeight: FontWeight.w500,
                        height: 1.50,
                        letterSpacing: -0.30,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: _figmaTextMuted,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFigmaLinkedAccountsSection(
    BuildContext context,
    AuthService authService,
    Brightness brightness,
  ) {
    final linkedProviders = authService.getLinkedProviders();
    final hasPassword = linkedProviders.contains('password');
    final hasGoogle = linkedProviders.contains('google.com');
    final hasApple = linkedProviders.contains('apple.com');
    final canShowApple =
        kIsWeb || (!kIsWeb && (Platform.isIOS || Platform.isMacOS));
    final hasAnyFirebaseProvider = linkedProviders.isNotEmpty;

    return _figmaCard(
      padding: const EdgeInsets.only(
        top: 16.67,
        left: 16.67,
        right: 16.67,
        bottom: 16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '연결된 계정',
            style: const TextStyle(
              color: _figmaTextMuted,
              fontSize: 13,
              fontFamily: 'Pretendard',
              fontWeight: FontWeight.w600,
              height: 1.50,
              letterSpacing: -0.32,
            ),
          ),
          const SizedBox(height: 12),
          if (hasPassword)
            _buildFigmaLinkedRow(
              context: context,
              authService: authService,
              icon: Icons.email_outlined,
              title: '이메일',
              providerId: 'password',
              isLinked: true,
              canUnlink: linkedProviders.length > 1,
            ),
          if (hasPassword) const SizedBox(height: 2),
          _buildFigmaLinkedRow(
            context: context,
            authService: authService,
            icon: Icons.g_mobiledata,
            title: 'Google',
            providerId: 'google.com',
            isLinked: hasGoogle,
            canUnlink: linkedProviders.length > 1,
            isGoogle: true,
          ),
          if (canShowApple) const SizedBox(height: 2),
          if (canShowApple)
            _buildFigmaLinkedRow(
              context: context,
              authService: authService,
              icon: Icons.apple,
              title: 'Apple',
              providerId: 'apple.com',
              isLinked: hasApple,
              canUnlink: linkedProviders.length > 1,
            ),
          const SizedBox(height: 2),
          FutureBuilder<bool>(
            future: authService.isKakaoLinked(),
            builder: (context, snapshot) {
              final hasKakao = snapshot.data ?? false;
              return _buildFigmaLinkedRow(
                context: context,
                authService: authService,
                icon: Icons.chat_bubble_outline,
                title: '카카오톡',
                providerId: 'kakao',
                isLinked: hasKakao,
                canUnlink: hasAnyFirebaseProvider,
                isKakao: true,
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildFigmaLinkedRow({
    required BuildContext context,
    required AuthService authService,
    required IconData icon,
    required String title,
    required String providerId,
    required bool isLinked,
    required bool canUnlink,
    bool isGoogle = false,
    bool isKakao = false,
  }) {
    return InkWell(
      onTap: _isLinking
          ? null
          : () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => LinkedAccountScreen(
                    providerId: providerId,
                    title: title,
                    isGoogle: isGoogle,
                    isKakao: isKakao,
                    canUnlink: canUnlink,
                  ),
                ),
              ).then((_) => setState(() {}));
            },
      borderRadius: BorderRadius.circular(0),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                if (isGoogle)
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: Center(
                      child: Transform.scale(
                        scale: 1.55,
                        child: Image.asset(
                          'assets/icons/google_g.png',
                          width: 20,
                          height: 20,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  )
                else if (isKakao)
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: Center(
                      child: Transform.scale(
                        scale: 1.15,
                        child: Image.asset(
                          'assets/icons/kakaotalk_icon.png',
                          width: 20,
                          height: 20,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  )
                else
                  Icon(icon, size: 20, color: _figmaTextSecondary),
                const SizedBox(width: 12),
                Text(
                  title,
                  style: const TextStyle(
                    color: _figmaTextSecondary,
                    fontSize: 15,
                    fontFamily: 'Pretendard',
                    fontWeight: FontWeight.w500,
                    height: 1.50,
                    letterSpacing: -0.38,
                  ),
                ),
              ],
            ),
            if (_isLinking)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (isLinked)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3.67,
                ),
                decoration: ShapeDecoration(
                  color: _figmaConnectedBg,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                child: const Text(
                  '연결됨',
                  style: TextStyle(
                    color: _figmaConnectedText,
                    fontSize: 11,
                    fontFamily: 'Pretendard',
                    fontWeight: FontWeight.w700,
                    height: 1.50,
                    letterSpacing: -0.28,
                  ),
                ),
              )
            else
              Container(
                padding: const EdgeInsets.fromLTRB(8, 3.67, 5, 3.67),
                decoration: BoxDecoration(
                  color: const Color(0xFF111111),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '연결',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontFamily: 'Pretendard',
                        fontWeight: FontWeight.w700,
                        height: 1.50,
                        letterSpacing: -0.28,
                      ),
                    ),
                    const SizedBox(width: 1),
                    const Icon(
                      Icons.chevron_right_rounded,
                      size: 11,
                      color: Colors.white,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFigmaSettingsCard(
    BuildContext context,
    AuthService authService,
    Brightness brightness,
  ) {
    return _figmaCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          _buildFigmaSettingsRow(
            icon: Icons.notifications_outlined,
            title: '알림 설정',
            subtitle: '기기 알림 권한과 수신 설정 변경',
            onTap: () => _openNotificationSettings(context),
          ),
          Container(
            height: 1,
            color: _figmaBorder,
            margin: const EdgeInsets.only(left: 16),
          ),
          _buildFigmaSettingsRow(
            icon: Icons.headset_mic_outlined,
            title: '고객센터',
            subtitle: '불편 신고 · FAQ · 카카오톡·메일 문의',
            onTap: () => _openCustomerCenter(context),
          ),
          Container(
            height: 1,
            color: _figmaBorder,
            margin: const EdgeInsets.only(left: 16),
          ),
          _buildFigmaSettingsRow(
            icon: Icons.edit_note_outlined,
            title: '의견 보내기',
            subtitle: '카카오톡·메일 문의 및 앱 피드백',
            onTap: () => ProfileFeedbackSheet.show(context),
          ),
          Container(
            height: 1,
            color: _figmaBorder,
            margin: const EdgeInsets.only(left: 16),
          ),
          _buildFigmaSettingsRow(
            icon: Icons.help_outline_rounded,
            title: '도움말',
            subtitle: '자주 묻는 질문과 사용 안내',
            onTap: () => _openHelpScreen(context),
          ),
          if (_isAdmin == true) ...[
            Container(
              height: 1,
              color: _figmaBorder,
              margin: const EdgeInsets.only(left: 16),
            ),
            _buildFigmaSettingsRow(
              icon: Icons.report_gmailerrorred_rounded,
              title: '신고 관리',
              subtitle: '신고 큐에서 숨김/복구 처리',
              onTap: () => Navigator.pushNamed(context, '/admin-reports'),
            ),
            Container(
              height: 1,
              color: _figmaBorder,
              margin: const EdgeInsets.only(left: 16),
            ),
            _buildFigmaSettingsRow(
              icon: Icons.support_agent_rounded,
              title: '사용자 문의',
              subtitle: '파싱 실패·레시피 문제 신고',
              onTap: () =>
                  Navigator.pushNamed(context, '/admin-user-inquiries'),
            ),
            Container(
              height: 1,
              color: _figmaBorder,
              margin: const EdgeInsets.only(left: 16),
            ),
            _buildFigmaSettingsRow(
              icon: Icons.feedback_outlined,
              title: '앱 피드백',
              subtitle: '의견 보내기 시트 접수 내역',
              onTap: () =>
                  Navigator.pushNamed(context, '/admin-app-feedback'),
            ),
            Container(
              height: 1,
              color: _figmaBorder,
              margin: const EdgeInsets.only(left: 16),
            ),
            _buildFigmaSettingsRow(
              icon: Icons.error_outline_rounded,
              title: '오류 레시피 검수',
              subtitle: '파싱 실패 항목 숨김/복구',
              onTap: () =>
                  Navigator.pushNamed(context, '/admin-error-recipes'),
            ),
            Container(
              height: 1,
              color: _figmaBorder,
              margin: const EdgeInsets.only(left: 16),
            ),
            _buildFigmaSettingsRow(
              icon: Icons.view_carousel_outlined,
              title: '홈 섹션 큐레이션',
              subtitle: '안주·유아식 등 pin/block',
              onTap: () =>
                  Navigator.pushNamed(context, '/admin-home-sections'),
            ),
            Container(
              height: 1,
              color: _figmaBorder,
              margin: const EdgeInsets.only(left: 16),
            ),
            // 모임·챌린지: 배포 전까지 숨김.
            // _buildFigmaSettingsRow(
            //   icon: Icons.emoji_events_outlined,
            //   title: '공식 챌린지',
            //   subtitle: '주간 챌린지 생성',
            //   onTap: () =>
            //       Navigator.pushNamed(context, '/admin-challenge-compose'),
            // ),
            // Container(
            //   height: 1,
            //   color: _figmaBorder,
            //   margin: const EdgeInsets.only(left: 16),
            // ),
            _buildFigmaSettingsRow(
              icon: Icons.refresh_rounded,
              title: '레시피 재파싱 (테스트)',
              subtitle: '새로운 파싱 로직으로 레시피 선택 재파싱',
              onTap: () =>
                  Navigator.pushNamed(context, '/reparse-recipes'),
            ),
            Container(
              height: 1,
              color: _figmaBorder,
              margin: const EdgeInsets.only(left: 16),
            ),
            _buildFigmaSettingsRow(
              icon: Icons.notifications_active_outlined,
              title: '푸시 알림 테스트 (30초 지연)',
              subtitle: _isSchedulingPushTest
                  ? '예약 중...'
                  : '버튼 탭 후 앱을 끄고 푸시 수신 확인',
              onTap: () => _scheduleAdminPushDebugTest(context),
              disabled: _isSchedulingPushTest,
            ),
            Container(
              height: 1,
              color: _figmaBorder,
              margin: const EdgeInsets.only(left: 16),
            ),
            _buildFigmaSettingsRow(
              icon: Icons.restaurant_menu_outlined,
              title: '식사 알림 테스트 (아침/점심/저녁)',
              subtitle: _isSchedulingMealReminderTest
                  ? '테스트 요청 중...'
                  : '오늘 일정에 랜덤 레시피 추가 후 알림 즉시 발송',
              onTap: () => _scheduleAdminMealReminderTest(context),
              disabled: _isSchedulingMealReminderTest,
            ),
            Container(
              height: 1,
              color: _figmaBorder,
              margin: const EdgeInsets.only(left: 16),
            ),
            _buildFigmaSettingsRow(
              icon: Icons.campaign_outlined,
              title: '인스타그램 점검 공지 (전체 1회)',
              subtitle: _isSchedulingInstagramBroadcast
                  ? '발송 요청 중...'
                  : '전체 사용자에게 푸시 + 인앱 알림 1회 발송',
              onTap: () => _scheduleInstagramMaintenanceBroadcast(context),
              disabled: _isSchedulingInstagramBroadcast,
            ),
            Container(
              height: 1,
              color: _figmaBorder,
              margin: const EdgeInsets.only(left: 16),
            ),
            _buildFigmaSettingsRow(
              icon: Icons.system_update_alt_outlined,
              title: '앱 재설치 안내 (전체 1회)',
              subtitle: _isSchedulingAppReinstallBroadcast
                  ? '발송 요청 중...'
                  : '앱 실행 오류 시 재설치 안내 — 푸시 + 인앱 1회',
              onTap: () => _scheduleAppReinstallBroadcast(context),
              disabled: _isSchedulingAppReinstallBroadcast,
            ),
          ],
          Container(
            height: 1,
            color: _figmaBorder,
            margin: const EdgeInsets.only(left: 16),
          ),
          _buildFigmaSettingsRow(
            icon: Icons.gavel_rounded,
            title: '이용약관',
            onTap: () => Navigator.pushNamed(context, '/terms-of-service'),
          ),
          Container(
            height: 1,
            color: _figmaBorder,
            margin: const EdgeInsets.only(left: 16),
          ),
          _buildFigmaSettingsRow(
            icon: Icons.shield_outlined,
            title: '개인정보 처리방침',
            onTap: () => Navigator.pushNamed(context, '/privacy-policy'),
          ),
          Container(
            height: 1,
            color: _figmaBorder,
            margin: const EdgeInsets.only(left: 16),
          ),
          _buildFigmaSettingsRow(
            icon: Icons.delete_forever_rounded,
            title: '계정 삭제',
            subtitle: '계정 및 모든 데이터를 영구적으로 삭제합니다',
            onTap: () => _handleDeleteAccount(context, authService, brightness),
            isDestructive: true,
          ),
        ],
      ),
    );
  }

  Widget _buildFigmaSettingsRow({
    required IconData icon,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
    bool disabled = false,
    bool isDestructive = false,
  }) {
    return InkWell(
      onTap: disabled ? null : onTap,
      child: Opacity(
        opacity: disabled ? 0.7 : 1.0,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 18,
                color: isDestructive
                    ? _figmaLogoutRed
                    : (disabled ? _figmaTextDisabled : _figmaTextSecondary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: isDestructive
                            ? _figmaLogoutRed
                            : (disabled
                                  ? _figmaTextDisabled
                                  : _figmaTextSecondary),
                        fontSize: 15,
                        fontFamily: 'Pretendard',
                        fontWeight: FontWeight.w500,
                        height: 1.50,
                        letterSpacing: -0.38,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: disabled
                              ? _figmaTextDisabledSub
                              : _figmaTextMuted,
                          fontSize: 12,
                          fontFamily: 'Pretendard',
                          fontWeight: FontWeight.w500,
                          height: 1.50,
                          letterSpacing: -0.30,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: _figmaTextMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFigmaLogoutCard(
    BuildContext context,
    AuthService authService,
    AppLocalizations? l10n,
  ) {
    return InkWell(
      onTap: () => _handleLogout(context, authService, l10n),
      borderRadius: BorderRadius.circular(20),
      child: _figmaCard(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        minHeight: 55.83,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(Icons.logout_rounded, size: 18, color: _figmaLogoutRed),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n?.logout ?? '로그아웃',
                style: const TextStyle(
                  color: _figmaLogoutRed,
                  fontSize: 15,
                  fontFamily: 'Pretendard',
                  fontWeight: FontWeight.w700,
                  height: 1.50,
                  letterSpacing: -0.38,
                ),
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: _figmaTextMuted,
            ),
          ],
        ),
      ),
    );
  }

  Widget _figmaCard({
    required EdgeInsets padding,
    double? minHeight,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      constraints: minHeight != null
          ? BoxConstraints(minHeight: minHeight)
          : null,
      padding: padding,
      decoration: ShapeDecoration(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          side: const BorderSide(width: 0.67, color: _figmaBorder),
          borderRadius: BorderRadius.circular(20),
        ),
        shadows: const [
          BoxShadow(
            color: _figmaShadow,
            blurRadius: 12,
            offset: Offset(0, 2),
            spreadRadius: 0,
          ),
        ],
      ),
      child: child,
    );
  }

  Future<void> _openNotificationSettings(BuildContext context) async {
    if (kIsWeb) {
      if (!context.mounted) return;
      showAppSnackBar(context, 
        const SnackBar(content: Text('알림 설정은 모바일 기기에서 변경할 수 있어요.')),
      );
      return;
    }
    try {
      await AppSettings.openAppSettings(type: AppSettingsType.notification);
    } catch (_) {
      await AppSettings.openAppSettings();
    }
  }

  void _openHelpScreen(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (context) => const HelpScreen()));
  }

  void _openCustomerCenter(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => const CustomerCenterScreen(),
      ),
    );
  }

  Future<void> _scheduleAdminPushDebugTest(BuildContext context) async {
    if (_isSchedulingPushTest) return;
    setState(() => _isSchedulingPushTest = true);
    try {
      await NotificationService.instance.scheduleAdminPushDebugTest(
        delaySeconds: 30,
      );
      if (!context.mounted) return;
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('푸시 테스트 예약 완료: 약 30초 후 알림이 도착합니다.'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      showAppSnackBar(context, 
        SnackBar(
          content: Text('푸시 테스트 예약 실패: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isSchedulingPushTest = false);
      }
    }
  }

  Future<void> _scheduleAdminMealReminderTest(BuildContext context) async {
    if (_isSchedulingMealReminderTest) return;

    final mealType = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('식사 알림 테스트'),
          content: const Text(
            '선택한 식사 시간에 랜덤 레시피를 오늘 일정에 추가하고, '
            '실제 식사 알림과 동일한 푸시·인앱 알림을 즉시 보냅니다.\n\n'
            '해당 식사 슬롯의 기존 일정은 테스트용 레시피 1개로 교체됩니다.',
            style: TextStyle(fontSize: 14, height: 1.45),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'breakfast'),
              child: const Text('아침'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'lunch'),
              child: const Text('점심'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'dinner'),
              child: const Text('저녁'),
            ),
          ],
        );
      },
    );
    if (mealType == null || !context.mounted) return;

    const mealLabels = {
      'breakfast': '아침',
      'lunch': '점심',
      'dinner': '저녁',
    };
    final mealLabel = mealLabels[mealType] ?? mealType;

    setState(() => _isSchedulingMealReminderTest = true);
    try {
      await NotificationService.instance.scheduleAdminMealReminderTest(
        mealType: mealType,
      );
      if (!context.mounted) return;
      showAppSnackBar(context, 
        SnackBar(
          content: Text('$mealLabel 식사 알림 테스트를 요청했습니다. 곧 알림이 도착합니다.'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      showAppSnackBar(context, 
        SnackBar(
          content: Text('식사 알림 테스트 실패: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isSchedulingMealReminderTest = false);
      }
    }
  }

  Future<void> _scheduleInstagramMaintenanceBroadcast(
    BuildContext context,
  ) async {
    if (_isSchedulingInstagramBroadcast) return;

    const title = '인스타그램 링크 분석 점검 알림';
    const body =
        '서버 점검으로 인해 인스타그램 링크 분석이 일시적으로 불안정할 수 있습니다. '
        '1-2일 내 복구 예정이오니 불편하시더라도 조금만 기다려 주시면 감사하겠습니다. '
        '유튜브, 틱톡은 정상적으로 이용하실 수 있습니다!';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('전체 공지 발송'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '아래 내용을 모든 사용자에게 푸시 알림과 인앱 알림함으로 1회만 발송합니다.',
                  style: TextStyle(fontSize: 14, height: 1.45),
                ),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(body, style: const TextStyle(fontSize: 14, height: 1.5)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('발송'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !context.mounted) return;

    setState(() => _isSchedulingInstagramBroadcast = true);
    try {
      await NotificationService.instance.scheduleInstagramMaintenanceBroadcast();
      if (!context.mounted) return;
      showAppSnackBar(context, 
        const SnackBar(
          content: Text('전체 공지 발송이 시작되었습니다. 완료까지 몇 분 걸릴 수 있습니다.'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      final message = e.toString().contains('already exists')
          ? '이미 발송된 공지입니다. (1회만 발송 가능)'
          : '전체 공지 발송 실패: $e';
      showAppSnackBar(context, 
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) {
        setState(() => _isSchedulingInstagramBroadcast = false);
      }
    }
  }

  Future<void> _scheduleAppReinstallBroadcast(BuildContext context) async {
    if (_isSchedulingAppReinstallBroadcast) return;

    const title = '요리고 앱 이용 안내';
    const body =
        '앱이 열리지 않으면 삭제 후 스토어에서 다시 설치해 주세요. '
        '최신 버전에서 안정성이 개선되었습니다.';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('앱 재설치 안내 발송'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '아래 내용을 모든 사용자에게 푸시 알림과 인앱 알림함으로 1회만 발송합니다.',
                  style: TextStyle(fontSize: 14, height: 1.45),
                ),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(body, style: const TextStyle(fontSize: 14, height: 1.5)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('발송'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !context.mounted) return;

    setState(() => _isSchedulingAppReinstallBroadcast = true);
    try {
      await NotificationService.instance.scheduleAppReinstallBroadcast();
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        const SnackBar(
          content: Text('전체 공지 발송이 시작되었습니다. 완료까지 몇 분 걸릴 수 있습니다.'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      final message = e.toString().contains('already_exists')
          ? '이미 발송된 공지입니다. (1회만 발송 가능)'
          : '전체 공지 발송 실패: $e';
      showAppSnackBar(
        context,
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) {
        setState(() => _isSchedulingAppReinstallBroadcast = false);
      }
    }
  }

  Future<void> _handleDeleteAccount(
    BuildContext context,
    AuthService authService,
    Brightness brightness,
  ) async {
    const deleteConfirmationPhrase = '계정을 삭제하고 요리GO를 떠나기';
    final confirmationController = TextEditingController();
    // Show warning dialog
    final shouldDelete = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final canDelete =
              confirmationController.text.trim() == deleteConfirmationPhrase;
          return Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 27),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: const [
              BoxShadow(
                color: Color(0x1F000000),
                blurRadius: 30,
                offset: Offset(0, 8),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '계정 삭제',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          color: Color(0xFFEF4444),
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                          height: 1.5,
                          letterSpacing: -0.45,
                        ),
                      ),
                      SizedBox(height: 12),
                      Text(
                        '계정을 삭제하면 다음 데이터가 영구적으로 삭제됩니다:',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF191F28),
                        ),
                      ),
                      SizedBox(height: 12),
                      Text(
                        '• 프로필 정보 (이름, 핸들, 프로필 사진)',
                        style: TextStyle(fontFamily: 'Pretendard'),
                      ),
                      Text(
                        '• 저장된 레시피',
                        style: TextStyle(fontFamily: 'Pretendard'),
                      ),
                      Text(
                        '• 작성한 리뷰 및 댓글',
                        style: TextStyle(fontFamily: 'Pretendard'),
                      ),
                      Text(
                        '• 식사 계획',
                        style: TextStyle(fontFamily: 'Pretendard'),
                      ),
                      Text(
                        '• 장바구니 정보',
                        style: TextStyle(fontFamily: 'Pretendard'),
                      ),
                      SizedBox(height: 12),
                      Text(
                        '이 작업은 되돌릴 수 없습니다. 정말 계정을 삭제하시겠습니까?',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFEF4444),
                        ),
                      ),
                      SizedBox(height: 18),
                      Text(
                        '계속하려면 아래에 "$deleteConfirmationPhrase"를 입력해주세요.',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF4B5563),
                          height: 1.45,
                        ),
                      ),
                      SizedBox(height: 10),
                      TextField(
                        controller: confirmationController,
                        autofocus: true,
                        onChanged: (_) => setDialogState(() {}),
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF191F28),
                        ),
                        decoration: InputDecoration(
                          hintText: deleteConfirmationPhrase,
                          hintStyle: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFB0B8C1),
                          ),
                          filled: true,
                          fillColor: Color(0xFFF9FAFB),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 13,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(12)),
                            borderSide: BorderSide(
                              color: Color(0xFFE5E7EB),
                              width: 1,
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(12)),
                            borderSide: BorderSide(
                              color: Color(0xFFEF4444),
                              width: 1.2,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Container(
                height: 55.167,
                decoration: const BoxDecoration(
                  border: Border(
                    top: BorderSide(color: Color(0xFFF2F4F6), width: 0.667),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => Navigator.of(dialogContext).pop(false),
                        child: Container(
                          height: double.infinity,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                            border: Border(
                              right: BorderSide(
                                color: Color(0xFFF2F4F6),
                                width: 0.667,
                              ),
                            ),
                          ),
                          child: Text(
                            '취소',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              height: 1.5,
                              color: AppColors.getTextSecondary(brightness),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: InkWell(
                        onTap: canDelete
                            ? () => Navigator.of(dialogContext).pop(true)
                            : null,
                        child: Container(
                          height: double.infinity,
                          alignment: Alignment.center,
                          child: Text(
                            '삭제',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              height: 1.5,
                              color: canDelete
                                  ? const Color(0xFFEF4444)
                                  : _figmaTextDisabled,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
        },
      ),
    );
    confirmationController.dispose();

    if (shouldDelete != true) return;

    // Show loading dialog
    if (!context.mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      await authService.deleteAccount();

      if (context.mounted) {
        Navigator.of(context).pop(); // Close loading dialog
        Navigator.of(context).popUntil((route) => route.isFirst);

        showAppSnackBar(context, 
          const SnackBar(
            content: Text('계정이 성공적으로 삭제되었습니다'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context).pop(); // Close loading dialog

        final raw = e.toString();
        final message = raw.startsWith('Exception: ')
            ? raw.substring('Exception: '.length)
            : raw;

        showAppSnackBar(context, 
          SnackBar(
            content: Text('계정 삭제 중 오류가 발생했습니다: $message'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  Future<void> _handleLogout(
    BuildContext context,
    AuthService authService,
    AppLocalizations? l10n,
  ) async {
    // Show confirmation dialog
    final shouldLogout = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 27),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: const [
              BoxShadow(
                color: Color(0x1F000000),
                blurRadius: 30,
                offset: Offset(0, 8),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n?.logoutConfirm ?? '로그아웃 하시겠습니까?',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        height: 1.5,
                        letterSpacing: -0.45,
                        color: Color(0xFF191F28),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                height: 55.167,
                decoration: const BoxDecoration(
                  border: Border(
                    top: BorderSide(color: Color(0xFFF2F4F6), width: 0.667),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => Navigator.of(dialogContext).pop(false),
                        child: Container(
                          height: double.infinity,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                            border: Border(
                              right: BorderSide(
                                color: Color(0xFFF2F4F6),
                                width: 0.667,
                              ),
                            ),
                          ),
                          child: Text(
                            l10n?.cancel ?? '취소',
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              height: 1.5,
                              color: Color(0xFF4E5968),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: InkWell(
                        onTap: () => Navigator.of(dialogContext).pop(true),
                        child: Container(
                          height: double.infinity,
                          alignment: Alignment.center,
                          child: Text(
                            l10n?.logout ?? '로그아웃',
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              height: 1.5,
                              color: Color(0xFFEF4444),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (shouldLogout == true && context.mounted) {
      try {
        await authService.signOut();
        if (context.mounted) {
          // Navigate back to home
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      } catch (e) {
        if (context.mounted) {
          showAppSnackBar(context, 
            SnackBar(
              content: Text(
                l10n?.logoutError(e.toString()) ?? '로그아웃 중 오류가 발생했습니다: $e',
              ),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  // ignore: unused_element
  Future<void> _showEditProfileDialog(
    BuildContext context,
    User user,
    Brightness brightness,
  ) async {
    final userDoc = await _userService.getUserDocument(user.uid);
    final userData = userDoc.data() as Map<String, dynamic>?;

    final nameController = TextEditingController(
      text: user.displayName ?? userData?['name'] ?? '',
    );
    final handleController = TextEditingController(
      text: userData?['handle'] ?? '',
    );

    String? photoUrl = userData != null ? resolveUserPhotoUrl(userData) : null;
    File? selectedImage;
    bool isUploading = false;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('프로필 편집'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Profile Picture
                GestureDetector(
                  onTap: () async {
                    final image = await _imagePicker.pickImage(
                      source: ImageSource.gallery,
                      imageQuality: 85,
                      maxWidth: 800,
                      maxHeight: 800,
                    );
                    if (image != null) {
                      setDialogState(() {
                        selectedImage = File(image.path);
                      });
                    }
                  },
                  child: Stack(
                    children: [
                      CircleAvatar(
                        radius: 50,
                        backgroundColor: AppColors.primary.withValues(
                          alpha: 0.1,
                        ),
                        backgroundImage: selectedImage != null
                            ? FileImage(selectedImage!)
                            : (photoUrl != null && photoUrl.isNotEmpty
                                  ? AppNetworkImage.imageProviderForAvatar(
                                      photoUrl,
                                    )
                                  : null),
                        child:
                            (selectedImage == null &&
                                (photoUrl == null || photoUrl.isEmpty))
                            ? Icon(
                                Icons.person,
                                size: 50,
                                color: AppColors.primary,
                              )
                            : null,
                      ),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.camera_alt,
                            size: 20,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                // Name field
                TextField(
                  controller: nameController,
                  decoration: InputDecoration(
                    labelText: '이름',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Handle field
                TextField(
                  controller: handleController,
                  decoration: InputDecoration(
                    labelText: '핸들',
                    hintText: 'your_handle',
                    prefixText: '@',
                    prefixStyle: TextStyle(
                      color: AppColors.getTextPrimary(brightness),
                      fontSize: 16,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    helperText: '고유한 핸들을 입력하세요 (영문, 숫자, 언더스코어만 사용 가능)',
                  ),
                ),
                if (isUploading) ...[
                  const SizedBox(height: 16),
                  const CircularProgressIndicator(),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: isUploading
                  ? null
                  : () async {
                      setDialogState(() {
                        isUploading = true;
                      });

                      try {
                        String? newPhotoUrl = photoUrl;
                        String? oldPhotoUrl = photoUrl;

                        // Upload image if selected
                        if (selectedImage != null) {
                          newPhotoUrl = await _uploadProfileImage(
                            user.uid,
                            selectedImage!,
                            oldPhotoUrl: oldPhotoUrl,
                          );
                        }

                        // Validate and update handle
                        var newHandle = handleController.text
                            .trim()
                            .toLowerCase();
                        // Remove @ if user typed it
                        if (newHandle.startsWith('@')) {
                          newHandle = newHandle.substring(1);
                        }

                        if (newHandle.isNotEmpty) {
                          // Validate handle format
                          if (newHandle.length < 3 || newHandle.length > 20) {
                            if (context.mounted) {
                              showAppSnackBar(context, 
                                const SnackBar(
                                  content: Text('핸들은 3-20자 사이여야 합니다'),
                                  backgroundColor: Colors.red,
                                ),
                              );
                            }
                            setDialogState(() {
                              isUploading = false;
                            });
                            return;
                          }

                          if (!RegExp(r'^[a-z0-9_]+$').hasMatch(newHandle)) {
                            if (context.mounted) {
                              showAppSnackBar(context, 
                                const SnackBar(
                                  content: Text(
                                    '핸들은 영문, 숫자, 언더스코어(_)만 사용할 수 있습니다',
                                  ),
                                  backgroundColor: Colors.red,
                                ),
                              );
                            }
                            setDialogState(() {
                              isUploading = false;
                            });
                            return;
                          }

                          final isAvailable = await _userService
                              .isHandleAvailable(newHandle);
                          if (!isAvailable &&
                              newHandle != userData?['handle']) {
                            if (context.mounted) {
                              showAppSnackBar(context, 
                                const SnackBar(
                                  content: Text('이미 사용 중인 핸들입니다'),
                                  backgroundColor: Colors.red,
                                ),
                              );
                            }
                            setDialogState(() {
                              isUploading = false;
                            });
                            return;
                          }
                        }

                        // Update profile
                        final newName = nameController.text.trim();
                        await _userService.updateUserProfile(
                          uid: user.uid,
                          name: newName.isNotEmpty ? newName : null,
                          handle: newHandle.isNotEmpty ? newHandle : null,
                          photoUrl: newPhotoUrl,
                        );

                        // Update Firebase Auth display name
                        if (newName.isNotEmpty && newName != user.displayName) {
                          await user.updateDisplayName(newName);
                          await user.reload();
                        }

                        if (context.mounted) {
                          Navigator.pop(context);
                          showAppSnackBar(context, 
                            const SnackBar(
                              content: Text('프로필이 업데이트되었습니다'),
                              backgroundColor: Colors.green,
                            ),
                          );
                        }
                      } catch (e) {
                        if (context.mounted) {
                          showAppSnackBar(context, 
                            SnackBar(
                              content: Text('오류: $e'),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                        setDialogState(() {
                          isUploading = false;
                        });
                      }
                    },
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );
  }

  Future<String> _uploadProfileImage(
    String uid,
    File imageFile, {
    String? oldPhotoUrl,
  }) async {
    try {
      final storageRef = FirebaseStorage.instance
          .ref()
          .child('profile_images')
          .child('$uid.jpg');

      // Upload new image
      await storageRef.putFile(imageFile);
      final downloadUrl = await storageRef.getDownloadURL();

      // Delete old image if it exists and is different from new one
      if (oldPhotoUrl != null &&
          oldPhotoUrl.isNotEmpty &&
          oldPhotoUrl != downloadUrl) {
        try {
          // Extract the path from the old URL
          final oldRef = FirebaseStorage.instance.refFromURL(oldPhotoUrl);
          await oldRef.delete();
          print('[SettingsScreen] Deleted old profile image');
        } catch (deleteError) {
          // Log but don't fail - old image might not exist or already deleted
          print(
            '[SettingsScreen] Could not delete old profile image: $deleteError',
          );
        }
      }

      return downloadUrl;
    } catch (e) {
      print('[SettingsScreen] Error uploading profile image: $e');
      rethrow;
    }
  }
}
