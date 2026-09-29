import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/analytics_service.dart';
import '../services/recipe_agent_service.dart';
import '../theme/app_colors.dart';
import '../utils/haptics.dart';
import '../utils/recipe_agent_confirm.dart';
import '../utils/recipe_overlay.dart';
import 'app_toast.dart';

Future<void> showRecipeAgentSheet({
  required BuildContext context,
  required String recipeTitle,
  required bool hasOverlay,
  required List<String> ingredientNames,
  required int portionCount,
  required ValueChanged<int> onPortionChanged,
  required String? recipeId,
  required bool isSaved,
  required Map<String, dynamic> overlay,
  required Map<String, dynamic> clientSnapshot,
  required Future<bool> Function() ensureSaved,
  required Future<void> Function(List<RecipeAgentPatch> patches) onApplied,
}) {
  if (!RecipeAgentService.enabled) {
    return Future.value();
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _RecipeAgentSheet(
      recipeTitle: recipeTitle,
      hasOverlay: hasOverlay,
      ingredientNames: ingredientNames,
      portionCount: portionCount,
      onPortionChanged: onPortionChanged,
      recipeId: recipeId,
      isSaved: isSaved,
      overlay: overlay,
      clientSnapshot: clientSnapshot,
      ensureSaved: ensureSaved,
      onApplied: onApplied,
    ),
  );
}

class _ChatLine {
  _ChatLine({
    required this.isUser,
    required this.text,
    this.patches = const [],
    this.warnings = const [],
    this.pending = false,
  });

  final bool isUser;
  final String text;
  final List<RecipeAgentPatch> patches;
  final List<String> warnings;
  final bool pending;
}

class _RecipeAgentSheet extends StatefulWidget {
  const _RecipeAgentSheet({
    required this.recipeTitle,
    required this.hasOverlay,
    required this.ingredientNames,
    required this.portionCount,
    required this.onPortionChanged,
    required this.recipeId,
    required this.isSaved,
    required this.overlay,
    required this.clientSnapshot,
    required this.ensureSaved,
    required this.onApplied,
  });

  final String recipeTitle;
  final bool hasOverlay;
  final List<String> ingredientNames;
  final int portionCount;
  final ValueChanged<int> onPortionChanged;
  final String? recipeId;
  final bool isSaved;
  final Map<String, dynamic> overlay;
  final Map<String, dynamic> clientSnapshot;
  final Future<bool> Function() ensureSaved;
  final Future<void> Function(List<RecipeAgentPatch> patches) onApplied;

  @override
  State<_RecipeAgentSheet> createState() => _RecipeAgentSheetState();
}

class _RecipeAgentSheetState extends State<_RecipeAgentSheet> {
  final _input = TextEditingController();
  final _lines = <_ChatLine>[];
  final _history = <Map<String, String>>[];
  bool _busy = false;
  bool _showPortion = false;
  late int _portion;
  late Map<String, dynamic> _overlay;
  bool _hasOverlay = false;

  bool get _awaitingConfirm =>
      _lines.any((l) => l.pending && l.patches.isNotEmpty);

  int get _pendingIndex =>
      _lines.lastIndexWhere((l) => l.pending && l.patches.isNotEmpty);

  bool get _locked => _busy;

  bool get _changeChipsLocked => _busy || _awaitingConfirm;

  @override
  void initState() {
    super.initState();
    _portion = widget.portionCount;
    _overlay = Map<String, dynamic>.from(widget.overlay);
    _hasOverlay = widget.hasOverlay;
    AnalyticsService().trackRecipeAgentOpened(recipeId: widget.recipeId);
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<bool> _requireLogin() async {
    if (FirebaseAuth.instance.currentUser != null) return true;
    if (!mounted) return false;
    await Navigator.pushNamed(context, '/login');
    return FirebaseAuth.instance.currentUser != null;
  }

  String _userLabel({
    String? chipId,
    required String text,
    String? focusIngredient,
  }) {
    if (chipId == 'missing_ingredient') {
      return '${focusIngredient ?? ''} 없으면';
    }
    if (chipId == 'less_spicy') return '덜 맵게';
    if (chipId == 'air_fryer') return '에어프라이어로';
    if (chipId == 'easier_step') return '이 단계 쉽게';
    if (chipId == 'confirm') return '네';
    if (chipId == 'decline') return '아니오';
    return text;
  }

  Future<void> _send({
    String? chipId,
    String? message,
    String? focusIngredient,
  }) async {
    if (_busy) return;
    if (!await _requireLogin()) return;
    final text = (message ?? _input.text).trim();
    if (chipId == null && text.isEmpty) return;
    _input.clear();
    final userLabel = _userLabel(
      chipId: chipId,
      text: text,
      focusIngredient: focusIngredient,
    );
    final pendingIndex = _pendingIndex;
    if (pendingIndex >= 0) {
      final pending = _lines[pendingIndex];
      if (isRecipeAgentConfirmYes(text, chipId: chipId)) {
        setState(() {
          _lines.add(_ChatLine(isUser: true, text: userLabel));
        });
        await _apply(pending, pendingIndex);
        return;
      }
      if (isRecipeAgentConfirmNo(text, chipId: chipId)) {
        setState(() {
          _lines.add(_ChatLine(isUser: true, text: userLabel));
        });
        await _dismiss(pending, pendingIndex);
        return;
      }
      await _dismiss(pending, pendingIndex, announce: false);
    }
    setState(() {
      _busy = true;
      _lines.add(_ChatLine(isUser: true, text: userLabel));
    });
    final started = DateTime.now();
    try {
      final result = await RecipeAgentService.instance.turn(
        recipeId: widget.recipeId,
        chipId: chipId,
        message: text.isEmpty ? null : text,
        focusIngredient: focusIngredient,
        overlay: _overlay,
        clientSnapshot: widget.clientSnapshot,
        history: List<Map<String, String>>.from(_history),
      );
      _history.add({'role': 'user', 'text': userLabel});
      _history.add({'role': 'assistant', 'text': result.reply});
      if (_history.length > 8) {
        _history.removeRange(0, _history.length - 8);
      }
      if (!mounted) return;
      final awaiting = result.awaitingConfirm && result.patches.isNotEmpty;
      setState(() {
        _busy = false;
        _lines.add(
          _ChatLine(
            isUser: false,
            text: result.reply,
            patches: result.patches,
            warnings: result.warnings,
            pending: awaiting,
          ),
        );
      });
      if (!awaiting && result.patches.isNotEmpty) {
        await _apply(_lines.last, _lines.length - 1);
      }
      await AnalyticsService().trackRecipeAgentTurn(
        recipeId: widget.recipeId,
        chipId: chipId,
        onTopic: result.onTopic,
        patchCount: result.patches.length,
        latencyMs: DateTime.now().difference(started).inMilliseconds,
        engine: result.engine,
      );
    } on RecipeAgentException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      await AnalyticsService().trackRecipeAgentTurnFailed(
        recipeId: widget.recipeId,
        chipId: chipId,
        statusCode: e.statusCode,
      );
      if (e.statusCode == 401) {
        await _requireLogin();
        return;
      }
      final msg = e.statusCode == 429
          ? '조금 뒤에 다시 시도해 주세요.'
          : '지금은 답할 수 없어요. 잠시 후 다시 시도해 주세요.';
      setState(() {
        _lines.add(_ChatLine(isUser: false, text: msg));
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _lines.add(
          _ChatLine(
            isUser: false,
            text: '지금은 답할 수 없어요. 잠시 후 다시 시도해 주세요.',
          ),
        );
      });
      await AnalyticsService().trackRecipeAgentTurnFailed(
        recipeId: widget.recipeId,
        chipId: chipId,
      );
    }
  }

  Future<void> _apply(_ChatLine line, int index) async {
    if (line.patches.isEmpty) return;
    final id = widget.recipeId?.trim() ?? '';
    if (id.isEmpty) {
      AppToast.info(context, '레시피를 저장한 뒤 내 버전에 반영할 수 있어요');
      return;
    }
    if (!widget.isSaved) {
      final ok = await widget.ensureSaved();
      if (!ok) return;
    }
    try {
      await widget.onApplied(line.patches);
      _overlay = applyPatchesToOverlay(
        _overlay,
        line.patches.map((p) => p.toOverlayMap()).toList(),
      );
      _hasOverlay = true;
    } catch (_) {
      if (mounted) AppToast.error(context, '반영에 실패했어요');
      return;
    }
    if (!mounted) return;
    setState(() {
      _lines[index] = _ChatLine(
        isUser: false,
        text: line.text,
        patches: line.patches,
        warnings: line.warnings,
        pending: false,
      );
      if (line.text != kRecipeAgentConfirmedReply) {
        _lines.add(
          _ChatLine(isUser: false, text: kRecipeAgentConfirmedReply),
        );
      }
    });
    AppToast.success(
      context,
      '내 버전에 반영됨. 장바구니는 \'재료 구매하기\'로 담으면 이 재료가 들어갑니다.',
    );
    await AnalyticsService().trackRecipeAgentPatchApplied(
      recipeId: widget.recipeId,
      patchCount: line.patches.length,
    );
  }

  Future<void> _dismiss(
    _ChatLine line,
    int index, {
    bool announce = true,
  }) async {
    setState(() {
      _lines[index] = _ChatLine(
        isUser: false,
        text: line.text,
        patches: const [],
        warnings: line.warnings,
        pending: false,
      );
      if (announce && line.text != kRecipeAgentDeclinedReply) {
        _lines.add(
          _ChatLine(isUser: false, text: kRecipeAgentDeclinedReply),
        );
      }
    });
    await AnalyticsService().trackRecipeAgentPatchDismissed(
      recipeId: widget.recipeId,
    );
  }

  Future<void> _onMissingIngredient() async {
    if (_changeChipsLocked || widget.ingredientNames.isEmpty) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text(
                  '없는 재료를 고르세요',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
              ...widget.ingredientNames.map(
                (name) => ListTile(
                  title: Text(name, style: const TextStyle(fontFamily: 'Pretendard')),
                  onTap: () => Navigator.pop(ctx, name),
                ),
              ),
            ],
          ),
        );
      },
    );
    if (picked == null || picked.isEmpty) return;
    await _send(chipId: 'missing_ingredient', focusIngredient: picked);
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.9;
    final brightness = Theme.of(context).brightness;
    return SizedBox(
      height: height,
      child: Material(
        color: AppColors.getBackground(brightness),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.getBorder(brightness),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.recipeTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                        color: AppColors.getTextPrimary(brightness),
                      ),
                    ),
                  ),
                  if (_hasOverlay)
                    Container(
                      margin: const EdgeInsets.only(left: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primaryLight,
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: const Text(
                        '내 버전',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primaryDark,
                        ),
                      ),
                    ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  _chip(
                    '이 재료 없으면',
                    _changeChipsLocked ? null : _onMissingIngredient,
                  ),
                  _chip(
                    '인분 바꾸기',
                    _changeChipsLocked
                        ? null
                        : () => setState(() => _showPortion = !_showPortion),
                  ),
                  _chip(
                    '덜 맵게',
                    _changeChipsLocked
                        ? null
                        : () => _send(chipId: 'less_spicy'),
                  ),
                  _chip(
                    '에어프라이어로',
                    _changeChipsLocked
                        ? null
                        : () => _send(chipId: 'air_fryer'),
                  ),
                  _chip(
                    '이 단계 쉽게',
                    _changeChipsLocked
                        ? null
                        : () => _send(chipId: 'easier_step'),
                  ),
                ],
              ),
            ),
            if (_showPortion)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                child: Row(
                  children: [
                    const Text('인분', style: TextStyle(fontFamily: 'Pretendard')),
                    const Spacer(),
                    IconButton(
                      onPressed: _portion <= 1
                          ? null
                          : () {
                              Haptics.selection();
                              setState(() => _portion -= 1);
                              widget.onPortionChanged(_portion);
                            },
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                    Text(
                      '$_portion',
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    IconButton(
                      onPressed: () {
                        Haptics.selection();
                        setState(() => _portion += 1);
                        widget.onPortionChanged(_portion);
                      },
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                itemCount: _lines.length + (_busy ? 1 : 0),
                itemBuilder: (context, i) {
                  if (_busy && i == _lines.length) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    );
                  }
                  final line = _lines[i];
                  return _bubble(line, i, brightness);
                },
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        enabled: !_locked,
                        minLines: 1,
                        maxLines: 4,
                        decoration: InputDecoration(
                          hintText: _awaitingConfirm
                              ? '네 또는 아니오로 답해 주세요'
                              : '이 레시피에 대해 물어보세요',
                          hintStyle: TextStyle(
                            fontFamily: 'Pretendard',
                            color: AppColors.getTextTertiary(brightness),
                          ),
                          filled: true,
                          fillColor: AppColors.getBackgroundSecondary(brightness),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                        ),
                        onSubmitted: (_) => _send(message: _input.text),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: _locked ? null : () => _send(message: _input.text),
                      style: IconButton.styleFrom(
                        backgroundColor: AppColors.primary,
                      ),
                      icon: const Icon(Icons.arrow_upward, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, VoidCallback? onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ActionChip(
        label: Text(
          label,
          style: const TextStyle(fontFamily: 'Pretendard', fontSize: 13),
        ),
        onPressed: onTap,
      ),
    );
  }

  Widget _bubble(_ChatLine line, int index, Brightness brightness) {
    final align = line.isUser ? Alignment.centerRight : Alignment.centerLeft;
    return Align(
      alignment: align,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        decoration: BoxDecoration(
          color: line.isUser
              ? AppColors.primaryLight
              : AppColors.getBackgroundSecondary(brightness),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              line.text,
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 14,
                height: 1.4,
                color: AppColors.getTextPrimary(brightness),
              ),
            ),
            if (line.warnings.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                line.warnings.join('\n'),
                style: const TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 12,
                  color: Color(0xFFB45309),
                ),
              ),
            ],
            if (line.pending && line.patches.isNotEmpty) ...[
              const SizedBox(height: 8),
              ...line.patches.map(
                (p) => Text(
                  '· ${p.diffLabel}',
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton(
                    onPressed: () => _send(chipId: 'confirm'),
                    child: const Text('네'),
                  ),
                  TextButton(
                    onPressed: () => _send(chipId: 'decline'),
                    child: const Text('아니오'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
