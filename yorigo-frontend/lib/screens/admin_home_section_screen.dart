import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../constants/home_section_keys.dart';
import '../services/admin_service.dart';
import '../services/home_section_curation_service.dart';
import '../services/recipe_service.dart';
import '../widgets/app_refresh_indicator.dart';

/// 관리자용 홈 섹션 큐레이션 — pin/block 목록 및 재빌드.
class AdminHomeSectionScreen extends StatefulWidget {
  const AdminHomeSectionScreen({super.key});

  @override
  State<AdminHomeSectionScreen> createState() => _AdminHomeSectionScreenState();
}

class _AdminHomeSectionScreenState extends State<AdminHomeSectionScreen> {
  final HomeSectionCurationService _curation =
      HomeSectionCurationService.instance;
  final RecipeService _recipeService = RecipeService.shared;
  final TextEditingController _searchController = TextEditingController();

  late final Future<bool> _adminFuture = AdminService.instance.isAdmin();

  String _sectionKey = HomeSectionKeys.curationKeys.first;
  bool _loading = true;
  bool _rebuilding = false;
  List<String> _pinnedIds = [];
  List<String> _blockedIds = [];
  List<String> _indexIds = [];
  Map<String, String> _titlesById = {};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _adminFuture.then((isAdmin) {
      if (isAdmin && mounted) _loadSection();
    });
  }

  Future<void> _loadSection() async {
    setState(() => _loading = true);
    final state = await _curation.getSectionState(sectionKey: _sectionKey);
    if (!mounted) return;
    final overrides = state?['overrides'];
    _pinnedIds = [];
    _blockedIds = [];
    if (overrides is Map) {
      _pinnedIds = List<String>.from(
        (overrides['pinnedIds'] as List?)?.map((e) => e.toString()) ?? [],
      );
      _blockedIds = List<String>.from(
        (overrides['blockedIds'] as List?)?.map((e) => e.toString()) ?? [],
      );
    }
    _indexIds = List<String>.from(
      (state?['recipeIds'] as List?)?.map((e) => e.toString()) ?? [],
    );
    final allIds = {..._pinnedIds, ..._blockedIds, ..._indexIds}.toList();
    _titlesById = {};
    if (allIds.isNotEmpty) {
      final recipes = await _recipeService.getExploreRecipesByIds(
        allIds,
        limit: allIds.length,
      );
      for (final r in recipes) {
        final id = r['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        final nested = r['recipe'] as Map<String, dynamic>? ?? {};
        _titlesById[id] =
            (r['title']?.toString().isNotEmpty == true
                    ? r['title']?.toString()
                    : nested['name']?.toString()) ??
                id;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _rebuild() async {
    setState(() => _rebuilding = true);
    final counts = await _curation.rebuildSection(sectionKey: _sectionKey);
    if (!mounted) return;
    setState(() => _rebuilding = false);
    if (counts != null) {
      await _loadSection();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '재빌드 완료 (${counts[_sectionKey] ?? 0}개)',
          ),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('재빌드 실패')),
      );
    }
  }

  Future<void> _searchAndPin() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;
    String? recipeId;
    if (query.length >= 16 && !query.contains(' ')) {
      final snap = await FirebaseFirestore.instance
          .collection('recipes')
          .doc(query)
          .get();
      if (snap.exists) recipeId = snap.id;
    }
    if (recipeId == null) {
      final snap = await FirebaseFirestore.instance
          .collection('recipes')
          .where('status', isEqualTo: 'completed')
          .limit(20)
          .get();
      for (final doc in snap.docs) {
        final data = doc.data();
        final nested = data['recipe'] as Map<String, dynamic>? ?? {};
        final title =
            (data['title']?.toString() ?? nested['name']?.toString() ?? '')
                .toLowerCase();
        if (title.contains(query.toLowerCase())) {
          recipeId = doc.id;
          break;
        }
      }
    }
    if (recipeId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('레시피를 찾지 못했습니다')),
      );
      return;
    }
    final ok = await _curation.pinRecipe(
      sectionKey: _sectionKey,
      recipeId: recipeId,
    );
    if (!mounted) return;
    if (ok) {
      _searchController.clear();
      await _loadSection();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('고정되었습니다'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> _unpin(String id) async {
    final ok = await _curation.unpinRecipe(sectionKey: _sectionKey, recipeId: id);
    if (ok) await _loadSection();
  }

  Future<void> _unblock(String id) async {
    final ok =
        await _curation.unblockRecipe(sectionKey: _sectionKey, recipeId: id);
    if (ok) await _loadSection();
  }

  Future<void> _blockFromIndex(String id) async {
    final ok =
        await _curation.blockRecipe(sectionKey: _sectionKey, recipeId: id);
    if (ok) await _loadSection();
  }

  Widget _idTile({
    required String id,
    required String subtitle,
    VoidCallback? onRemove,
    VoidCallback? onBlock,
    String removeLabel = '제거',
  }) {
    return ListTile(
      dense: true,
      title: Text(
        _titlesById[id] ?? id,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontFamily: 'Pretendard', fontSize: 14),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontFamily: 'Pretendard', fontSize: 11),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onBlock != null)
            IconButton(
              icon: const Icon(Icons.block, size: 20),
              tooltip: '제외',
              onPressed: onBlock,
            ),
          if (onRemove != null)
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              tooltip: removeLabel,
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _adminFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.data != true) {
          return const Scaffold(
            body: Center(child: Text('관리자 권한이 필요합니다')),
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('홈 섹션 큐레이션'),
            actions: [
              if (_rebuilding)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: '섹션 재빌드',
                  onPressed: _rebuild,
                ),
            ],
          ),
          body: AppRefreshIndicator(
            onRefresh: _loadSection,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                DropdownButtonFormField<String>(
                  value: _sectionKey,
                  decoration: const InputDecoration(
                    labelText: '섹션',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final key in HomeSectionKeys.curationKeys)
                      DropdownMenuItem(
                        value: key,
                        child: Text(HomeSectionKeys.labelFor(key)),
                      ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _sectionKey = v);
                    _loadSection();
                  },
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        decoration: const InputDecoration(
                          labelText: '레시피 ID 또는 제목 검색',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _searchAndPin,
                      child: const Text('고정'),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Text(
                  '고정 목록 (${_pinnedIds.length})',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (_pinnedIds.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('없음'),
                  )
                else
                  ..._pinnedIds.map(
                    (id) => _idTile(
                      id: id,
                      subtitle: 'pinned · $id',
                      onRemove: () => _unpin(id),
                      removeLabel: '고정 해제',
                    ),
                  ),
                const SizedBox(height: 16),
                Text(
                  '현재 인덱스 (${_indexIds.length})',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_indexIds.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('없음'),
                  )
                else
                  ..._indexIds.map(
                    (id) => _idTile(
                      id: id,
                      subtitle: 'index · $id',
                      onBlock: _pinnedIds.contains(id) || _blockedIds.contains(id)
                          ? null
                          : () => _blockFromIndex(id),
                    ),
                  ),
                const SizedBox(height: 16),
                Text(
                  '제외 목록 (${_blockedIds.length})',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (_blockedIds.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('없음'),
                  )
                else
                  ..._blockedIds.map(
                    (id) => _idTile(
                      id: id,
                      subtitle: 'blocked · $id',
                      onRemove: () => _unblock(id),
                      removeLabel: '제외 해제',
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
