import 'package:flutter/material.dart';

/// In-app help for the profile tab — Toss-style clean layout.
///
/// Structure: intro → quick start → feature guides → FAQ → support.
/// Visual language: light gray canvas, white grouped cards with hairline
/// dividers, restrained accent color, calm typography.
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  static const Color _accent = Color(0xFFFF6B00);

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

  Color _textMuted(BuildContext context) =>
      _isDark(context) ? const Color(0xFF8B95A1) : const Color(0xFF8B95A1);

  Color _divider(BuildContext context) =>
      _isDark(context) ? const Color(0xFF2A2E36) : const Color(0xFFF2F4F6);

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
          '도움말',
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
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
          children: [
            _buildIntro(context),
            const SizedBox(height: 28),
            _groupLabel(context, '빠른 시작'),
            const SizedBox(height: 10),
            _buildQuickStartCard(context),
            const SizedBox(height: 28),
            _groupLabel(context, '기능 안내'),
            const SizedBox(height: 10),
            _buildFeatureGroupCard(context),
            const SizedBox(height: 28),
            _groupLabel(context, '자주 묻는 질문'),
            const SizedBox(height: 10),
            _buildFaqGroupCard(context),
            const SizedBox(height: 28),
            _buildSupportCard(context),
          ],
        ),
      ),
    );
  }

  // ── Intro ────────────────────────────────────────────────────────────────
  Widget _buildIntro(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Transform.translate(
                offset: const Offset(-3, 0),
                child: Image.asset(
                  'assets/yorigo_help_logo.png',
                  height: 33,
                  fit: BoxFit.contain,
                ),
              ),
              Text(
                ', 이렇게 써요',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  height: 1.35,
                  letterSpacing: -0.6,
                  color: _textPrimary(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '영상 속 레시피를 저장하고, 필요한 재료를 사고,\n냉장고로 관리하고, 요리 기록까지 한 곳에서 이어져요.',
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
    );
  }

  // ── Quick start ────────────────────────────────────────────────────────
  Widget _buildQuickStartCard(BuildContext context) {
    const steps = [
      (
        '레시피 가져오기',
        '유튜브·인스타그램·틱톡·네이버 블로그 링크는 물론, 레시피 스크린샷이나 직접 적은 글까지 붙여 넣으면 재료와 순서가 자동으로 정리돼요.',
      ),
      (
        '재료 담기',
        '집에 없는 재료만 골라 담고, 몇 인분 만들지와 요리할 날짜·끼니를 정해요.',
      ),
      (
        '사고 · 요리하기',
        '쿠팡·마켓컬리에서 가격을 비교해 사고, 구매한 재료는 냉장고에서 관리해요.',
      ),
    ];
    return _card(
      context,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
      child: Column(
        children: [
          for (var i = 0; i < steps.length; i++)
            _buildStepRow(
              context,
              number: i + 1,
              title: steps[i].$1,
              description: steps[i].$2,
              isLast: i == steps.length - 1,
            ),
        ],
      ),
    );
  }

  Widget _buildStepRow(
    BuildContext context, {
    required int number,
    required String title,
    required String description,
    required bool isLast,
  }) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: _surface(context),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _isDark(context)
                        ? const Color(0xFF2A2E36)
                        : const Color(0xFFEDEFF3),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: Text(
                  '$number',
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: _accent,
                  ),
                ),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    color: _divider(context),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 14 : 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: _textPrimary(context),
                      height: 1.3,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: _textSecondary(context),
                      height: 1.55,
                      letterSpacing: -0.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Feature guides (grouped list) ────────────────────────────────────────
  Widget _buildFeatureGroupCard(BuildContext context) {
    const guides = [
      (
        Icons.add_link_rounded,
        '레시피 추가 · 분석',
        '링크 공유, 직접 작성, 스크린샷으로 추가해요. 분석은 백그라운드로 진행되고, 실패한 항목은 분석 기록에서 다시 시도할 수 있어요.',
      ),
      (
        Icons.menu_book_rounded,
        '레시피북',
        '저장한 레시피를 카테고리로 정리하고, 재료·조리 순서 확인과 나만의 메모를 더할 수 있어요.',
      ),
      (
        Icons.shopping_cart_rounded,
        '장바구니 · 쇼핑',
        '레시피별 재료를 인분에 맞게 계산하고, 쿠팡·마켓컬리에서 가격을 비교해 구매해요.',
      ),
      (
        Icons.kitchen_rounded,
        '냉장고',
        '구매한 재료가 냉장고로 들어오고, 유통기한 임박·지남을 한눈에 관리해요.',
      ),
      (
        Icons.ramen_dining_rounded,
        '요리 · 기록',
        '조리 모드로 단계별로 따라 만들고, 완료 후 요리 기록을 남겨 피드에서 나눠요.',
      ),
      (
        Icons.person_rounded,
        '프로필 · 계정',
        '팔로우, 받은 좋아요, 요리 기록을 확인하고, 로그인 연동·계정 관리는 설정에서 해요.',
      ),
    ];
    return _card(
      context,
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < guides.length; i++) ...[
            if (i > 0) _hairline(context),
            _buildFeatureRow(
              context,
              icon: guides[i].$1,
              title: guides[i].$2,
              description: guides[i].$3,
            ),
          ],
        ],
      ),
    );
  }

  Widget _liftedIconBox(BuildContext context, IconData icon) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: _surface(context),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: _isDark(context)
              ? const Color(0xFF2A2E36)
              : const Color(0xFFEDEFF3),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 14, color: _accent),
    );
  }

  Widget _buildFeatureRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String description,
  }) {
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _liftedIconBox(context, icon),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: _textPrimary(context),
                    height: 1.3,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: _textSecondary(context),
                    height: 1.55,
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── FAQ (grouped list) ───────────────────────────────────────────────────
  Widget _buildFaqGroupCard(BuildContext context) {
    const faqs = [
      (
        '어떤 링크를 분석할 수 있나요?',
        '유튜브, 인스타그램, 틱톡, 네이버 블로그 링크를 지원해요. 공유하기로 요리GO를 선택하거나, 링크를 복사해 추가 화면에 붙여 넣으면 돼요.',
      ),
      (
        '분석이 오래 걸리거나 실패했어요.',
        '분석은 백그라운드로 진행되니 다른 화면을 봐도 괜찮아요. 너무 오래 걸리거나 실패하면 분석 기록에서 다시 시도할 수 있어요. 비공개·삭제된 링크는 분석이 어려울 수 있어요.',
      ),
      (
        '네이버 블로그 본문이 안 보여요.',
        '네이버 블로그 본문은 저작권 보호를 위해 본인이 직접 분석한 기기에만 저장돼요. 원본 블로그를 보거나, 직접 분석해서 레시피북에 추가할 수 있어요.',
      ),
      (
        '장바구니 가격은 어떻게 정해지나요?',
        '쿠팡·마켓컬리 등 제휴 마켓 상품을 재료별로 추천하고 필요한 양에 맞춰 비교해 줘요. 실제 결제는 해당 마켓에서 진행돼요.',
      ),
      (
        '구매한 재료는 어떻게 냉장고로 가나요?',
        '장바구니에서 구매를 완료하면 재료가 냉장고로 자동으로 들어와요. 냉장고에서 유통기한 임박·지남을 관리할 수 있어요.',
      ),
      (
        '로그인 없이도 쓸 수 있나요?',
        '레시피 탐색 등 일부는 둘러볼 수 있지만, 저장·장바구니·냉장고·요리 기록처럼 내 데이터가 필요한 기능은 로그인 후 이용할 수 있어요.',
      ),
      (
        '계정을 삭제하면 어떻게 되나요?',
        '프로필, 저장한 레시피, 리뷰·댓글, 식사 계획, 장바구니 정보가 영구적으로 삭제되며 되돌릴 수 없어요. 설정 > 계정 삭제에서 확인 문구를 입력해야 진행돼요.',
      ),
    ];
    return _card(
      context,
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < faqs.length; i++) ...[
            if (i > 0) _hairline(context),
            _buildFaqTile(context, question: faqs[i].$1, answer: faqs[i].$2),
          ],
        ],
      ),
    );
  }

  Widget _buildFaqTile(
    BuildContext context, {
    required String question,
    required String answer,
  }) {
    return Theme(
      data: Theme.of(context).copyWith(
        dividerColor: Colors.transparent,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        listTileTheme: const ListTileThemeData(minLeadingWidth: 0),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
        childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        iconColor: _accent,
        collapsedIconColor: _textMuted(context),
        title: Text(
          question,
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 14.5,
            fontWeight: FontWeight.w700,
            color: _textPrimary(context),
            height: 1.4,
            letterSpacing: -0.3,
          ),
        ),
        children: [
          Text(
            answer,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: _textSecondary(context),
              height: 1.6,
              letterSpacing: -0.2,
            ),
          ),
        ],
      ),
    );
  }

  // ── Support ──────────────────────────────────────────────────────────────
  Widget _buildSupportCard(BuildContext context) {
    return _card(
      context,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
                  '더 궁금한 점이 있나요?',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: _textPrimary(context),
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '불편하셨던 점이나 바라는 기능이 있다면 편하게 말씀해 주세요. 보내주신 의견은 꼼꼼히 살펴보고 다음 업데이트에 반영하겠습니다.',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: _textSecondary(context),
                    height: 1.6,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 14),
                _supportLine(context, '앱', '프로필·설정 > 고객센터'),
                const SizedBox(height: 8),
                _supportLine(
                  context,
                  '1:1 카카오톡 문의',
                  "'요리GO 고객센터' 검색",
                ),
                const SizedBox(height: 8),
                _supportLine(context, '고객문의 메일', 'yorigoadm@gmail.com'),
        ],
      ),
    );
  }

  Widget _supportLine(BuildContext context, String label, String value) {
    return RichText(
      text: TextSpan(
        style: TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 13,
          height: 1.5,
          letterSpacing: -0.2,
          color: _textSecondary(context),
        ),
        children: [
          TextSpan(
            text: '$label  ',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: _textPrimary(context),
            ),
          ),
          TextSpan(
            text: value,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  // ── Shared building blocks ───────────────────────────────────────────────
  Widget _card(
    BuildContext context, {
    required Widget child,
    required EdgeInsets padding,
  }) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: _surface(context),
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  Widget _hairline(BuildContext context) => Divider(
        height: 1,
        thickness: 1,
        indent: 18,
        endIndent: 18,
        color: _divider(context),
      );

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
}
