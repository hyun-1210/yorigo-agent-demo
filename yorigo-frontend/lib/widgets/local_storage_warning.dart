import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Warning banner that shows when user is not logged in
/// Informs them that recipes are stored locally and will be lost if app is deleted
class LocalStorageWarning extends StatelessWidget {
  final bool showMigrationButton;
  final VoidCallback? onMigrate;

  const LocalStorageWarning({
    super.key,
    this.showMigrationButton = false,
    this.onMigrate,
  });

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    // Don't show warning if user is logged in
    if (user != null) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        border: Border(
          bottom: BorderSide(color: Colors.orange.shade200, width: 1),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: Colors.orange.shade700,
            size: 24,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '임시 저장 모드',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.orange.shade900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '로그인하지 않고 앱을 삭제하면 모든 데이터가 사라집니다.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.orange.shade800,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 8),
                if (showMigrationButton && onMigrate != null)
                  TextButton.icon(
                    onPressed: onMigrate,
                    icon: const Icon(Icons.login, size: 16),
                    label: const Text(
                      '로그인하여 영구 저장',
                      style: TextStyle(fontSize: 12),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.orange.shade900,
                      backgroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact version for smaller spaces
class CompactLocalStorageWarning extends StatelessWidget {
  const CompactLocalStorageWarning({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    // Don't show warning if user is logged in
    if (user != null) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        border: Border(
          bottom: BorderSide(color: Colors.orange.shade200, width: 1),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: Colors.orange.shade700, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '로그인하지 않으면 앱 삭제 시 데이터가 사라집니다',
              style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
            ),
          ),
        ],
      ),
    );
  }
}

/// Dialog that explains local storage and encourages sign-up
class LocalStorageExplainerDialog extends StatelessWidget {
  const LocalStorageExplainerDialog({super.key});

  static const _orange = Color(0xFFFF6B00);
  static const _orangeSoft = Color(0xFFFFF1E6);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.10),
                    blurRadius: 30,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: _orangeSoft,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.storage_rounded,
                            color: _orange,
                            size: 22,
                          ),
                        ),
                        const SizedBox(height: 14),
                        const Text(
                          '지금은 임시 저장 모드예요',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF111111),
                            letterSpacing: -0.43,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          '로그인하지 않으면 데이터가 기기에만 저장돼요.',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF6B7280),
                            letterSpacing: -0.35,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8F9FA),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _ExplainerRow(
                            iconData: Icons.check_rounded,
                            iconColor: Color(0xFF16A34A),
                            text: '레시피가 기기에 저장돼요',
                          ),
                          SizedBox(height: 8),
                          _ExplainerRow(
                            iconData: Icons.check_rounded,
                            iconColor: Color(0xFF16A34A),
                            text: '인터넷 없이 볼 수 있어요',
                          ),
                          SizedBox(height: 8),
                          _ExplainerRow(
                            iconData: Icons.warning_amber_rounded,
                            iconColor: _orange,
                            text: '앱을 삭제하면 데이터가 사라져요',
                          ),
                          SizedBox(height: 8),
                          _ExplainerRow(
                            iconData: Icons.warning_amber_rounded,
                            iconColor: _orange,
                            text: '다른 기기에서는 볼 수 없어요',
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: _orangeSoft,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Row(
                        children: [
                          Icon(
                            Icons.cloud_upload_rounded,
                            color: _orange,
                            size: 18,
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '로그인하면 클라우드에 영구 저장돼요!',
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFFB04500),
                                height: 1.4,
                                letterSpacing: -0.325,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: _ExplainerButton(
                            label: '나중에',
                            onTap: () => Navigator.pop(context),
                            background: const Color(0xFFF4F5F7),
                            foreground: const Color(0xFF4B5563),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _ExplainerButton(
                            label: '로그인하기',
                            onTap: () {
                              Navigator.pop(context);
                              Navigator.pushNamed(context, '/login');
                            },
                            background: _orange,
                            foreground: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static void show(BuildContext context) {
    showGeneralDialog(
      context: context,
      barrierLabel: '임시 저장 모드 안내',
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.42),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (ctx, _, _) => const SizedBox.shrink(),
      transitionBuilder: (ctx, anim, _, _) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return Opacity(
          opacity: curved.value,
          child: Transform.scale(
            scale: 0.96 + 0.04 * curved.value,
            child: const LocalStorageExplainerDialog(),
          ),
        );
      },
    );
  }
}

class _ExplainerRow extends StatelessWidget {
  const _ExplainerRow({
    required this.iconData,
    required this.iconColor,
    required this.text,
  });

  final IconData iconData;
  final Color iconColor;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(iconData, size: 16, color: iconColor),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
              color: Color(0xFF374151),
              height: 1.45,
              letterSpacing: -0.34,
            ),
          ),
        ),
      ],
    );
  }
}

class _ExplainerButton extends StatelessWidget {
  const _ExplainerButton({
    required this.label,
    required this.onTap,
    required this.background,
    required this.foreground,
  });

  final String label;
  final VoidCallback onTap;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: foreground,
              letterSpacing: -0.375,
            ),
          ),
        ),
      ),
    );
  }
}
