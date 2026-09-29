import 'package:flutter/material.dart';

import '../constants/home_section_keys.dart';
import '../services/home_section_curation_service.dart';

/// 레시피 상세에서 관리자가 홈 섹션 pin/block 하는 bottom sheet.
class AdminHomeSectionCurationSheet extends StatefulWidget {
  const AdminHomeSectionCurationSheet({
    super.key,
    required this.recipeId,
  });

  final String recipeId;

  static Future<void> show(BuildContext context, {required String recipeId}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => AdminHomeSectionCurationSheet(recipeId: recipeId),
    );
  }

  @override
  State<AdminHomeSectionCurationSheet> createState() =>
      _AdminHomeSectionCurationSheetState();
}

class _AdminHomeSectionCurationSheetState
    extends State<AdminHomeSectionCurationSheet> {
  final HomeSectionCurationService _service =
      HomeSectionCurationService.instance;

  final Map<String, List<String>> _pinnedBySection = {};
  final Map<String, List<String>> _blockedBySection = {};
  bool _loading = true;
  String? _busyKey;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    setState(() => _loading = true);
    for (final key in HomeSectionKeys.curationKeys) {
      final state = await _service.getSectionState(sectionKey: key);
      if (!mounted) return;
      final overrides = state?['overrides'];
      if (overrides is Map) {
        _pinnedBySection[key] = List<String>.from(
          (overrides['pinnedIds'] as List?)?.map((e) => e.toString()) ?? [],
        );
        _blockedBySection[key] = List<String>.from(
          (overrides['blockedIds'] as List?)?.map((e) => e.toString()) ?? [],
        );
      } else {
        _pinnedBySection[key] = [];
        _blockedBySection[key] = [];
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _runAction(
    String sectionKey,
    Future<bool> Function() action,
  ) async {
    setState(() => _busyKey = sectionKey);
    final ok = await action();
    if (!mounted) return;
    setState(() => _busyKey = null);
    if (ok) {
      await _loadAll();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('홈 섹션 설정이 반영되었습니다. 홈에서 새로고침해 주세요.'),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('처리에 실패했습니다')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.75,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Container(
            width: 48,
            height: 6,
            decoration: BoxDecoration(
              color: const Color(0xFFE5E7EB),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '홈 섹션 관리',
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF111111),
                ),
              ),
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(32),
              child: CircularProgressIndicator(),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.fromLTRB(12, 0, 12, bottom + 16),
                itemCount: HomeSectionKeys.curationKeys.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final key = HomeSectionKeys.curationKeys[index];
                  final label = HomeSectionKeys.labelFor(key);
                  final pinned = _pinnedBySection[key] ?? const [];
                  final blocked = _blockedBySection[key] ?? const [];
                  final status = _service.statusForRecipe(
                    pinnedIds: pinned,
                    blockedIds: blocked,
                    recipeId: widget.recipeId,
                  );
                  final busy = _busyKey == key;
                  return ListTile(
                    title: Text(
                      label,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      _statusLabel(status),
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 12,
                        color: status == HomeSectionCurationStatus.none
                            ? const Color(0xFF8B95A1)
                            : const Color(0xFFFF6B00),
                      ),
                    ),
                    trailing: busy
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : PopupMenuButton<String>(
                            onSelected: (value) {
                              switch (value) {
                                case 'pin':
                                  _runAction(
                                    key,
                                    () => _service.pinRecipe(
                                      sectionKey: key,
                                      recipeId: widget.recipeId,
                                    ),
                                  );
                                case 'unpin':
                                  _runAction(
                                    key,
                                    () => _service.unpinRecipe(
                                      sectionKey: key,
                                      recipeId: widget.recipeId,
                                    ),
                                  );
                                case 'block':
                                  _runAction(
                                    key,
                                    () => _service.blockRecipe(
                                      sectionKey: key,
                                      recipeId: widget.recipeId,
                                    ),
                                  );
                                case 'unblock':
                                  _runAction(
                                    key,
                                    () => _service.unblockRecipe(
                                      sectionKey: key,
                                      recipeId: widget.recipeId,
                                    ),
                                  );
                              }
                            },
                            itemBuilder: (ctx) => [
                              if (status != HomeSectionCurationStatus.pinned)
                                const PopupMenuItem(
                                  value: 'pin',
                                  child: Text('이 섹션에 고정'),
                                ),
                              if (status == HomeSectionCurationStatus.pinned)
                                const PopupMenuItem(
                                  value: 'unpin',
                                  child: Text('고정 해제'),
                                ),
                              if (status != HomeSectionCurationStatus.blocked)
                                const PopupMenuItem(
                                  value: 'block',
                                  child: Text('이 섹션에서 제외'),
                                ),
                              if (status == HomeSectionCurationStatus.blocked)
                                const PopupMenuItem(
                                  value: 'unblock',
                                  child: Text('제외 해제'),
                                ),
                            ],
                          ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  String _statusLabel(HomeSectionCurationStatus status) {
    switch (status) {
      case HomeSectionCurationStatus.pinned:
        return '고정됨';
      case HomeSectionCurationStatus.blocked:
        return '제외됨';
      case HomeSectionCurationStatus.none:
        return '자동 매칭';
    }
  }
}
