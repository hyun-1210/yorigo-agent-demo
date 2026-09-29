import 'package:flutter/material.dart';

import '../services/grocery_agent_service.dart';
import '../theme/app_colors.dart';

/// 홈에서 여는 장보기 지휘자 시트. 사용자가 묻고, 에이전트가 답한다.
class GroceryAgentSheet extends StatefulWidget {
  const GroceryAgentSheet({super.key});

  static Future<void> open(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const GroceryAgentSheet(),
    );
  }

  @override
  State<GroceryAgentSheet> createState() => _GroceryAgentSheetState();
}

class _GroceryAgentSheetState extends State<GroceryAgentSheet> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();
  final List<_Bubble> _bubbles = [];
  GroceryAgentTurnResult? _latest;
  bool _busy = false;
  ScrollController? _sheetScroll;

  static const _starters = [
    '냉장고에 뭐 있어?',
    '이번 주에 뭐 해먹지?',
    '장바구니에 뭐 있어?',
  ];

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _jumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = _sheetScroll;
      if (controller == null || !controller.hasClients) return;
      controller.animateTo(
        controller.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send({String? message, String? chipId, String? chipLabel}) async {
    final text = (message ?? _input.text).trim();
    if ((text.isEmpty && (chipId == null || chipId.isEmpty)) || _busy) return;
    setState(() {
      _busy = true;
      _bubbles.add(_Bubble(text.isEmpty ? (chipLabel ?? chipId ?? '') : text, true));
      _input.clear();
    });
    _jumpToEnd();
    try {
      final result = await GroceryAgentService.instance.turn(
        message: text.isEmpty ? chipLabel : text,
        chipId: chipId,
      );
      if (!mounted) return;
      setState(() {
        _latest = result;
        _bubbles.add(_Bubble(result.reply, false));
      });
    } on GroceryAgentException catch (error) {
      if (!mounted) return;
      setState(() {
        _bubbles.add(_Bubble('연결하지 못했어요 (${error.message})', false));
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _jumpToEnd();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final latest = _latest;
    final background = AppColors.getBackground(brightness);
    final textPrimary = AppColors.getTextPrimary(brightness);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.88,
      minChildSize: 0.45,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        _sheetScroll = scrollController;
        return Container(
          decoration: BoxDecoration(
            color: background,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.getBorderSecondary(brightness),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppColors.primaryLight,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.auto_awesome, size: 18, color: AppColors.primary),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '장보기 에이전트',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: textPrimary,
                            ),
                          ),
                          Text(
                            '냉장고, 레시피, 장바구니를 보고 답해요',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 12,
                              color: AppColors.getTextSecondary(brightness),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (latest != null && latest.skillsLoaded.isNotEmpty)
                SizedBox(
                  height: 32,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      for (final skill in latest.skillsLoaded)
                        Container(
                          margin: const EdgeInsets.only(right: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.getBackgroundSecondary(brightness),
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Text(
                            skill.replaceAll('yorigo-', ''),
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.getTextSecondary(brightness),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  children: [
                    if (_bubbles.isEmpty) _emptyState(brightness),
                    for (final bubble in _bubbles) _bubbleView(bubble, brightness),
                    if (_busy) _typing(brightness),
                    if (latest != null && !_busy) ...[
                      if (latest.meals.isNotEmpty) _meals(latest, brightness),
                      if (latest.gap.isNotEmpty) _gap(latest, brightness),
                      if (latest.basket.isNotEmpty) _basket(latest, brightness),
                    ],
                  ],
                ),
              ),
              if (latest != null && latest.chips.isNotEmpty)
                SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                    children: [
                      for (final chip in latest.chips)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ActionChip(
                            label: Text(chip, style: const TextStyle(fontFamily: 'Pretendard')),
                            backgroundColor: AppColors.primaryLight,
                            side: const BorderSide(color: Color(0xFFFFD7B8)),
                            onPressed: _busy
                                ? null
                                : () => _send(
                                      message: chip,
                                      chipId: _chipId(chip),
                                      chipLabel: chip,
                                    ),
                          ),
                        ),
                    ],
                  ),
                ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _input,
                          focusNode: _focus,
                          autofocus: true,
                          enabled: !_busy,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          style: TextStyle(fontFamily: 'Pretendard', color: textPrimary),
                          decoration: InputDecoration(
                            hintText: '물어보세요',
                            hintStyle: TextStyle(
                              fontFamily: 'Pretendard',
                              color: AppColors.getTextTertiary(brightness),
                            ),
                            filled: true,
                            fillColor: AppColors.getBackgroundSecondary(brightness),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(22),
                              borderSide: BorderSide.none,
                            ),
                          ),
                          onSubmitted: (_) => _send(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Material(
                        color: _busy ? AppColors.getBorderSecondary(brightness) : AppColors.primary,
                        borderRadius: BorderRadius.circular(22),
                        child: InkWell(
                          onTap: _busy ? null : () => _send(),
                          borderRadius: BorderRadius.circular(22),
                          child: SizedBox(
                            width: 44,
                            height: 44,
                            child: _busy
                                ? const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.arrow_upward_rounded, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _emptyState(Brightness brightness) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 36, 8, 8),
      child: Column(
        children: [
          const Icon(Icons.chat_bubble_outline_rounded, color: AppColors.primary, size: 28),
          const SizedBox(height: 12),
          Text(
            '궁금한 걸 입력하면 답할게요.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.getTextPrimary(brightness),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '아래를 눌러도 되고, 직접 적어도 돼요.',
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 13,
              color: AppColors.getTextSecondary(brightness),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              for (final starter in _starters)
                ActionChip(
                  label: Text(starter, style: const TextStyle(fontFamily: 'Pretendard', fontSize: 13)),
                  onPressed: _busy ? null : () => _send(message: starter),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _typing(Brightness brightness) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.getBackgroundSecondary(brightness),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomRight: Radius.circular(16),
            bottomLeft: Radius.circular(4),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
            ),
            const SizedBox(width: 8),
            Text(
              '답하는 중이에요',
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 13,
                color: AppColors.getTextSecondary(brightness),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String? _chipId(String label) {
    switch (label) {
      case '이대로 장보기':
        return 'accept_plan';
      case '하루 빼기':
        return 'drop_friday';
      case '장바구니에 담기':
        return 'accept_cart';
      case '예산 초과 허용':
        return 'allow_over_budget';
      default:
        return null;
    }
  }

  Widget _bubbleView(_Bubble bubble, Brightness brightness) {
    final mine = bubble.mine;
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(16),
      topRight: const Radius.circular(16),
      bottomLeft: Radius.circular(mine ? 16 : 4),
      bottomRight: Radius.circular(mine ? 4 : 16),
    );
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 300),
        decoration: BoxDecoration(
          color: mine ? AppColors.primary : AppColors.getBackgroundSecondary(brightness),
          borderRadius: radius,
        ),
        child: Text(
          bubble.text,
          style: TextStyle(
            fontFamily: 'Pretendard',
            color: mine ? Colors.white : AppColors.getTextPrimary(brightness),
            fontSize: 14,
            height: 1.35,
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String text, Brightness brightness) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: 'Pretendard',
          fontWeight: FontWeight.w700,
          fontSize: 14,
          color: AppColors.getTextPrimary(brightness),
        ),
      ),
    );
  }

  Widget _meals(GroceryAgentTurnResult latest, Brightness brightness) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('이번 주 저녁', brightness),
        for (final meal in latest.meals)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.getBackground(brightness),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.getBorderSecondary(brightness)),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.primaryLight,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    meal.day,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: AppColors.primaryDark,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        meal.recipeName,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppColors.getTextPrimary(brightness),
                        ),
                      ),
                      Text(
                        '${meal.servings}인분${meal.note.isEmpty ? '' : ' · ${meal.note}'}',
                        style: TextStyle(fontSize: 12, color: AppColors.getTextSecondary(brightness)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _gap(GroceryAgentTurnResult latest, Brightness brightness) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('냉장고와 차이', brightness),
        for (final item in latest.gap)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: item.action == 'skip' ? const Color(0xFFDCFCE7) : const Color(0xFFFFEDD5),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    item.action == 'skip' ? '있음' : '구매',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${item.name} ${item.needed} · ${item.note}',
                    style: TextStyle(color: AppColors.getTextPrimary(brightness)),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _basket(GroceryAgentTurnResult latest, Brightness brightness) {
    final recommending = latest.phase != 'basket' && latest.phase != 'committed';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(
          recommending ? '추천 상품' : '장바구니 ${_won(latest.totalPrice)} / 예산 ${_won(latest.budget)}',
          brightness,
        ),
        for (final line in latest.basket)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.getBackground(brightness),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.getBorderSecondary(brightness)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: line.image.startsWith('http')
                      ? Image.network(
                          line.image,
                          width: 64,
                          height: 64,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _imageFallback(),
                        )
                      : _imageFallback(),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        line.channel.isEmpty ? line.name : '${line.channel} · ${line.name}',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.getTextSecondary(brightness),
                        ),
                      ),
                      Text(
                        line.productName.isEmpty ? line.name : line.productName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppColors.getTextPrimary(brightness),
                        ),
                      ),
                      Text(
                        line.rating > 0
                            ? '별점 ${line.rating.toStringAsFixed(1)} · 리뷰 ${line.reviews} · ${_won(line.price)}'
                            : _won(line.price),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primaryDark,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _imageFallback() {
    return Container(
      width: 64,
      height: 64,
      color: const Color(0xFFF4F4F5),
      child: const Icon(Icons.image_outlined, color: Color(0xFFA1A1AA)),
    );
  }

  String _won(int value) {
    final raw = value.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < raw.length; i++) {
      if (i > 0 && (raw.length - i) % 3 == 0) buffer.write(',');
      buffer.write(raw[i]);
    }
    return '$buffer원';
  }
}

/// 홈 오른쪽 아래. 탭하면 장보기 에이전트 시트가 열리고, 질문은 사용자가 입력한다.
class GroceryAgentFab extends StatelessWidget {
  const GroceryAgentFab({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 64),
      child: Material(
        color: const Color(0xFF18181B),
        elevation: 8,
        shadowColor: const Color(0x6618181B),
        borderRadius: BorderRadius.circular(28),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(28),
          child: const Padding(
            padding: EdgeInsets.fromLTRB(14, 12, 16, 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.auto_awesome, color: Colors.white, size: 18),
                SizedBox(width: 8),
                Text(
                  '에이전트',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Bubble {
  _Bubble(this.text, this.mine);
  final String text;
  final bool mine;
}
