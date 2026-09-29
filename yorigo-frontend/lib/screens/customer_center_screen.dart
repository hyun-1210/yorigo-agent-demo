import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/auth_service.dart';
import '../services/user_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/ios_liquid_glass_tab_bar.dart';
import '../widgets/profile_feedback_sheet.dart';
import 'help_screen.dart';
import 'privacy_policy_screen.dart';
import 'terms_of_service_screen.dart';

/// 프로필·설정에서 진입하는 고객센터 허브.
///
/// 목표: 앱스토어/플레이스토어 악플로 새기 전에, 앱 안에서
/// FAQ → 불편 신고 → 카카오/메일로 불만을 흡수한다.
class CustomerCenterScreen extends StatefulWidget {
  const CustomerCenterScreen({super.key});

  @override
  State<CustomerCenterScreen> createState() => _CustomerCenterScreenState();
}

class _CustomerCenterScreenState extends State<CustomerCenterScreen>
    with SingleTickerProviderStateMixin {
  /// 강조용 선명한 오렌지 (연한 살구 톤 배경 없이 아이콘/뱃지 텍스트만).
  static const Color _accent = Color(0xFFFF4D00);

  final UserService _userService = UserService();
  String? _displayName;
  late final AnimationController _nameShimmerController;

  static const List<_CsTopic> _topics = [
    _CsTopic(
      label: '분석 실패·지연',
      question: '레시피 분석이 오래 걸리거나 실패했어요',
      answer:
          '분석은 백그라운드로 진행되니 다른 화면을 봐도 괜찮아요. 너무 오래 걸리거나 실패하면 홈·분석 기록에서 다시 시도할 수 있어요. 비공개·삭제된 링크나 레시피가 거의 없는 영상은 분석이 어려울 수 있어요.\n\n같은 링크가 반복해서 실패하면 아래에 ‘아직 불편해요’로 알려주세요. 원인 파악에 큰 도움이 돼요.',
      feedbackCategories: ['레시피 분석', '버그'],
    ),
    _CsTopic(
      label: '재료·순서 오류',
      question: '재료나 조리 순서가 이상해요',
      answer:
          '원본 영상·글과 다르게 정리됐다면 레시피 상세에서 직접 수정할 수 있어요. 잘못된 분석이 반복되면 해당 레시피 URL과 함께 알려주시면 파싱을 개선하는 데 반영할게요.',
      feedbackCategories: ['레시피 분석'],
    ),
    _CsTopic(
      label: '장바구니·가격',
      question: '장바구니나 가격이 이상해요',
      answer:
          '쿠팡·마켓컬리 등 제휴 마켓 상품을 재료별로 추천하고 필요한 양에 맞춰 비교해 줘요. 실제 결제·배송·환불은 해당 마켓에서 이뤄져요.\n\n추천 상품이나 수량 계산이 어색하다면 어떤 재료인지와 함께 알려주세요.',
      feedbackCategories: ['장바구니 탭'],
    ),
    _CsTopic(
      label: '냉장고',
      question: '냉장고 재료가 안 맞아요',
      answer:
          '장바구니에서 구매 완료하면 재료가 냉장고로 들어와요. 수량·유통기한이 다르면 냉장고에서 직접 수정할 수 있어요. 들어오지 않거나 중복으로 쌓이면 말씀해 주세요.',
      feedbackCategories: ['냉장고 탭'],
    ),
    _CsTopic(
      label: '버그·오류',
      question: '앱이 끊기거나 이상하게 동작해요',
      answer:
          '어떤 화면에서, 어떤 동작을 하다가 문제가 생겼는지 알려주시면 가장 빨리 고칠 수 있어요. 가능하면 기기·OS 버전도 함께 적어 주세요.\n\n같은 문제가 반복되면 아래에 ‘아직 불편해요’로 상황을 남겨 주세요. 확인하고 바로 도와드릴게요.',
      feedbackCategories: ['버그', '속도 · 성능'],
    ),
    _CsTopic(
      label: '계정·로그인',
      question: '로그인·계정에 문제가 있어요',
      answer:
          '로그인 연동·알림·계정 삭제는 설정에서 관리할 수 있어요. 로그인이 안 되거나 계정이 사라졌다면 사용 중이던 로그인 방법(카카오·구글·애플·이메일)과 함께 문의해 주세요.',
      feedbackCategories: ['프로필 탭', '기타'],
    ),
    _CsTopic(
      label: '기능 제안',
      question: '이런 기능이 있으면 좋겠어요',
      answer:
          '바라는 기능이나 개선 아이디어를 자유롭게 보내 주세요. 작은 제안도 다음 업데이트 우선순위를 정하는 데 큰 도움이 돼요.',
      feedbackCategories: ['앱 전반'],
    ),
  ];

  @override
  void initState() {
    super.initState();
    _nameShimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1900),
    )..repeat();
    _loadDisplayName();
  }

  @override
  void dispose() {
    _nameShimmerController.dispose();
    super.dispose();
  }

  Future<void> _loadDisplayName() async {
    final user = AuthService().currentUser;
    if (user == null) return;
    var name = user.displayName?.trim() ?? '';
    if (name.isEmpty) {
      try {
        final doc = await _userService.getUserDocument(user.uid);
        final data = doc.data() as Map<String, dynamic>?;
        name = (data?['name'] as String?)?.trim() ?? '';
      } catch (_) {
        // ignore — greeting falls back without name
      }
    }
    if (!mounted) return;
    if (name.isNotEmpty) setState(() => _displayName = name);
  }

  bool _isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  Color _canvas(BuildContext context) =>
      _isDark(context) ? const Color(0xFF111317) : const Color(0xFFF2F4F6);

  Color _surface(BuildContext context) =>
      _isDark(context) ? const Color(0xFF1B1E24) : Colors.white;

  Color _textPrimary(BuildContext context) =>
      _isDark(context) ? Colors.white : const Color(0xFF191F28);

  Color _textSecondary(BuildContext context) =>
      _isDark(context) ? const Color(0xFFC2C7CF) : const Color(0xFF4E5968);

  Color _textMuted(BuildContext context) => const Color(0xFF8B95A1);

  Color _divider(BuildContext context) =>
      _isDark(context) ? const Color(0xFF2A2E36) : const Color(0xFFF2F4F6);

  Color _chipBorder(BuildContext context) =>
      _isDark(context) ? const Color(0xFF2A2E36) : const Color(0xFFE5E8EB);

  Future<void> _launchKakao() async {
    final uri = Uri.parse(ProfileFeedbackSheet.kKakaoInquiryUrl);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        const SnackBar(content: Text('카카오톡을 열 수 없어요.')),
      );
    }
  }

  Future<void> _launchMail() async {
    final uri = Uri.parse(
      'mailto:${ProfileFeedbackSheet.kSupportEmail}'
      '?subject=${Uri.encodeComponent('[요리GO] 문의')}',
    );
    try {
      await launchUrl(uri);
    } catch (_) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        const SnackBar(content: Text('메일 앱을 열 수 없어요.')),
      );
    }
  }

  Future<void> _openFeedback({
    List<String>? categories,
    String? initialDetail,
    String? initialDisliked,
  }) {
    return ProfileFeedbackSheet.show(
      context,
      initialCategories: categories,
      initialDetail: initialDetail,
      initialDisliked: initialDisliked,
    );
  }

  void _openTopic(_CsTopic topic) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return _TopicDetailSheet(
          topic: topic,
          surface: _surface(context),
          textPrimary: _textPrimary(context),
          textSecondary: _textSecondary(context),
          textMuted: _textMuted(context),
          onResolved: () => Navigator.of(sheetContext).pop(),
          onStillUnhappy: () {
            Navigator.of(sheetContext).pop();
            _openFeedback(
              categories: topic.feedbackCategories,
              initialDisliked: topic.question,
            );
          },
        );
      },
    );
  }

  Widget _buildGreeting(BuildContext context) {
    final titleStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 24,
      fontWeight: FontWeight.w800,
      height: 1.35,
      letterSpacing: -0.6,
      color: _textPrimary(context),
    );
    final nickname = _displayName?.trim() ?? '';
    if (nickname.isEmpty) {
      return Text('무엇이 불편하셨나요?', style: titleStyle);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            AnimatedBuilder(
              animation: _nameShimmerController,
              builder: (context, child) {
                return ShaderMask(
                  blendMode: BlendMode.srcIn,
                  shaderCallback: (bounds) {
                    return LinearGradient(
                      colors: const [
                        Color(0xFFFF6B00),
                        Color(0xFFFF9A3D),
                        Color(0xFFFFC078),
                        Color(0xFFFF6B00),
                      ],
                      stops: const [0.0, 0.34, 0.58, 1.0],
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      transform: _NameShimmerTransform(
                        progress: _nameShimmerController.value,
                      ),
                    ).createShader(bounds);
                  },
                  child: child,
                );
              },
              child: Text(
                nickname,
                style: titleStyle.copyWith(
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                ),
              ),
            ),
            Text('님,', style: titleStyle),
          ],
        ),
        Text('무엇이 불편하셨나요?', style: titleStyle),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _canvas(context),
      appBar: AppBar(
        backgroundColor: _canvas(context),
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: _textPrimary(context)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          '고객센터',
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: _textPrimary(context),
            letterSpacing: -0.3,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        // iPhone: 푸시 화면이라 탭 바가 없는데 하단 SafeArea가
        // 리스트 아래에 막힌 띠만 만든다. 콘텐츠를 바닥까지 그린다.
        bottom: !IosLiquidGlassTabBar.shouldUse(context),
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            20,
            8,
            20,
            IosLiquidGlassTabBar.shouldUse(context)
                ? MediaQuery.paddingOf(context).bottom + 16
                : 40,
          ),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildGreeting(context),
                  const SizedBox(height: 10),
                  Text(
                    '불편하거나 기대와 달랐던 점이 있다면 먼저 말씀해 주세요.\n놓치지 않고 확인하고, 필요할 때 바로 도와드릴게요.',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      height: 1.55,
                      letterSpacing: -0.3,
                      color: _textMuted(context),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            _sectionHeader(
              context,
              title: '자주 묻는 불편 · 질문',
              actionLabel: '전체 도움말',
              onAction: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const HelpScreen(),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            _buildTopicGrid(context),
            const SizedBox(height: 28),
            _groupLabel(context, '바로 도움받기'),
            const SizedBox(height: 10),
            _card(
              context,
              child: Column(
                children: [
                  _contactRow(
                    context,
                    icon: Icons.edit_note_rounded,
                    title: '불편·오류 신고하기',
                    subtitle: '앱 안에서 바로 남기면 팀이 확인해요',
                    badge: '추천',
                    emphasize: true,
                    showDivider: true,
                    onTap: () => _openFeedback(),
                  ),
                  _contactRow(
                    context,
                    icon: Icons.chat_bubble_outline_rounded,
                    title: '카카오톡 1:1 문의',
                    subtitle: '급하거나 자세한 상담이 필요할 때',
                    iconColor: const Color(0xFFFFCD00),
                    showDivider: true,
                    onTap: _launchKakao,
                  ),
                  _contactRow(
                    context,
                    icon: Icons.mail_outline_rounded,
                    title: '메일로 문의하기',
                    subtitle: ProfileFeedbackSheet.kSupportEmail,
                    showDivider: true,
                    onTap: _launchMail,
                  ),
                  _contactRow(
                    context,
                    icon: Icons.menu_book_outlined,
                    title: '도움말 보기',
                    subtitle: '사용 방법과 FAQ 전체',
                    showDivider: true,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const HelpScreen(),
                        ),
                      );
                    },
                  ),
                  _contactRow(
                    context,
                    icon: Icons.description_outlined,
                    title: '약관 및 정책',
                    subtitle: '이용약관 · 개인정보 처리방침',
                    showDivider: false,
                    onTap: () => _showPolicyPicker(context),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  '보내주신 내용은 서비스 개선에만 사용되며, 최대한 빠르게 살펴볼게요.',
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    height: 1.2,
                    letterSpacing: -0.35,
                    color: _textMuted(context),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showPolicyPicker(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _surface(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(
                    '이용약관',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontWeight: FontWeight.w600,
                      color: _textPrimary(context),
                    ),
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const TermsOfServiceScreen(),
                      ),
                    );
                  },
                ),
                ListTile(
                  title: Text(
                    '개인정보 처리방침',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontWeight: FontWeight.w600,
                      color: _textPrimary(context),
                    ),
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const PrivacyPolicyScreen(),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopicGrid(BuildContext context) {
    const gap = 8.0;
    final rows = <Widget>[];
    for (var i = 0; i < _topics.length; i += 2) {
      final left = _topics[i];
      final hasRight = i + 1 < _topics.length;
      if (!hasRight) {
        rows.add(
          _TopicChip(
            label: left.label,
            borderColor: _chipBorder(context),
            textColor: _textPrimary(context),
            surfaceColor: _surface(context),
            onTap: () => _openTopic(left),
            expand: true,
          ),
        );
      } else {
        final right = _topics[i + 1];
        rows.add(
          Row(
            children: [
              Expanded(
                child: _TopicChip(
                  label: left.label,
                  borderColor: _chipBorder(context),
                  textColor: _textPrimary(context),
                  surfaceColor: _surface(context),
                  onTap: () => _openTopic(left),
                  expand: true,
                ),
              ),
              const SizedBox(width: gap),
              Expanded(
                child: _TopicChip(
                  label: right.label,
                  borderColor: _chipBorder(context),
                  textColor: _textPrimary(context),
                  surfaceColor: _surface(context),
                  onTap: () => _openTopic(right),
                  expand: true,
                ),
              ),
            ],
          ),
        );
      }
    }

    return Column(
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: gap),
          rows[i],
        ],
      ],
    );
  }

  Widget _sectionHeader(
    BuildContext context, {
    required String title,
    required String actionLabel,
    required VoidCallback onAction,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: _textMuted(context),
                letterSpacing: -0.2,
              ),
            ),
          ),
          InkWell(
            onTap: onAction,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    actionLabel,
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _textSecondary(context),
                      letterSpacing: -0.2,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: _textMuted(context),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _groupLabel(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: _textMuted(context),
          letterSpacing: -0.2,
        ),
      ),
    );
  }

  Widget _card(BuildContext context, {required Widget child}) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: _surface(context),
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  Widget _contactRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    required bool showDivider,
    String? badge,
    Color? iconColor,
    bool emphasize = false,
  }) {
    final resolvedIconColor =
        iconColor ?? (emphasize ? _accent : _textPrimary(context));
    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: _isDark(context)
                          ? const Color(0xFF1B1E24)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _isDark(context)
                            ? const Color(0xFF2A2E36)
                            : const Color(0xFFE5E8EB),
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      icon,
                      size: 20,
                      color: resolvedIconColor,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                title,
                                style: TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: _textPrimary(context),
                                  letterSpacing: -0.3,
                                ),
                              ),
                            ),
                            if (badge != null) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: _isDark(context)
                                      ? const Color(0xFF1B1E24)
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: _accent.withValues(alpha: 0.55),
                                  ),
                                ),
                                child: Text(
                                  badge,
                                  style: const TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: _accent,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                            color: _textMuted(context),
                            letterSpacing: -0.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: _textMuted(context),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (showDivider)
          Divider(
            height: 1,
            thickness: 1,
            indent: 70,
            endIndent: 16,
            color: _divider(context),
          ),
      ],
    );
  }
}

class _NameShimmerTransform extends GradientTransform {
  const _NameShimmerTransform({required this.progress});

  final double progress;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(bounds.width * (progress * 2 - 1), 0, 0);
  }
}

class _CsTopic {
  const _CsTopic({
    required this.label,
    required this.question,
    required this.answer,
    required this.feedbackCategories,
  });

  final String label;
  final String question;
  final String answer;
  final List<String> feedbackCategories;
}

class _TopicChip extends StatelessWidget {
  const _TopicChip({
    required this.label,
    required this.borderColor,
    required this.textColor,
    required this.surfaceColor,
    required this.onTap,
    this.expand = false,
  });

  final String label;
  final Color borderColor;
  final Color textColor;
  final Color surfaceColor;
  final VoidCallback onTap;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: surfaceColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(999),
        side: BorderSide(color: borderColor),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          width: expand ? double.infinity : null,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: textColor,
              letterSpacing: -0.3,
            ),
          ),
        ),
      ),
    );
  }
}

class _TopicDetailSheet extends StatelessWidget {
  const _TopicDetailSheet({
    required this.topic,
    required this.surface,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.onResolved,
    required this.onStillUnhappy,
  });

  final _CsTopic topic;
  final Color surface;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final VoidCallback onResolved;
  final VoidCallback onStillUnhappy;

  static const Color _accent = Color(0xFFFF4D00);

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.78,
      ),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 12, 20, 12 + bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 3.5,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE5E7EB),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                topic.question,
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  height: 1.35,
                  letterSpacing: -0.4,
                  color: textPrimary,
                ),
              ),
              const SizedBox(height: 14),
              Flexible(
                child: SingleChildScrollView(
                  child: Text(
                    topic.answer,
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      height: 1.6,
                      letterSpacing: -0.2,
                      color: textSecondary,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: onResolved,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: textPrimary,
                        side: BorderSide(color: textMuted.withValues(alpha: 0.45)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text(
                        '해결됐어요',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontWeight: FontWeight.w700,
                          fontSize: 14.5,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: onStillUnhappy,
                      style: FilledButton.styleFrom(
                        backgroundColor: _accent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text(
                        '아직 불편해요',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontWeight: FontWeight.w700,
                          fontSize: 14.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
