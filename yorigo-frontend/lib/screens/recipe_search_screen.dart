import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../theme/app_colors.dart';
import '../widgets/home_style_recipe_card.dart';
import '../services/analytics_service.dart';
import '../services/home_agent_service.dart';
import '../services/recipe_service.dart';
import '../services/background_parsing_service.dart';
import '../utils/home_agent_intent.dart';
import '../utils/recipe_search_match.dart';

class RecipeSearchScreen extends StatefulWidget {
  const RecipeSearchScreen({super.key});

  @override
  State<RecipeSearchScreen> createState() => _RecipeSearchScreenState();
}

class _RecipeSearchScreenState extends State<RecipeSearchScreen> {
  final RecipeService _recipeService = RecipeService.shared;
  final BackgroundParsingService _backgroundParsingService =
      BackgroundParsingService();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();

  final List<Map<String, dynamic>> _recipes = [];
  DocumentSnapshot? _lastCursor;
  bool _hasMore = true;
  bool _initialLoading = false;
  bool _loadingMore = false;
  bool _hasStartedSearch = false;
  String? _error;
  String _searchQuery = '';
  String? _lastLoggedSearchQuery;
  String? _lastEmptyLoggedQuery;
  Timer? _searchDebounce;
  bool _searchPrefetchRunning = false;
  bool _homeBusy = false;
  bool _pendingSpiceLow = false;
  bool _applyClientSearchFromAgent = false;
  String _homeReply = '';
  final Map<String, String> _homePickReasons = <String, String>{};

  void _trackSearchEmptyIfNeeded({bool force = false}) {
    if (!mounted) return;
    final q = _searchQuery.trim();
    if (q.isEmpty) return;
    if (_matchingRecipes.isNotEmpty) return;
    // `_hasMore` 는 탐색 카탈로그에 다음 페이지가 있다는 뜻일 뿐,
    // 현재 쿼리 매칭이 없다는 판정과 무관하다. 여기 넣으면 빈 검색이
    // 프리패치 예산이 끝난 뒤에도 search_empty 를 안 남긴다.
    if (!force &&
        (_initialLoading || _loadingMore || _searchPrefetchRunning)) {
      return;
    }
    if (_lastEmptyLoggedQuery == q) return;
    _lastEmptyLoggedQuery = q;
    unawaited(AnalyticsService().trackSearchEmpty(query: q));
  }

  // 검색어를 입력한 뒤에는 기존 검색 흐름을 유지한다. 빈 검색 화면에서만
  // Firestore 조회를 생략해 불필요한 읽기를 줄인다.
  static const int _initialGuestLimit = 40;
  static const int _rawBatch = 30;
  static const int _searchPrefetchMaxPages = 4;
  static const int _searchRetryMaxPages = 12;
  static const int _searchEnoughMatches = 8;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    setState(() => _searchQuery = _searchController.text.trim());
    _searchDebounce?.cancel();
    if (_searchQuery.isEmpty) return;
    _searchDebounce = Timer(const Duration(milliseconds: 380), () {
      if (!mounted) return;
      if (_searchQuery != _lastLoggedSearchQuery) {
        _lastLoggedSearchQuery = _searchQuery;
        unawaited(AnalyticsService().trackSearchQuery(query: _searchQuery));
      }
      if (HomeAgentService.enabled && looksLikeHomeAgentIntent(_searchQuery)) {
        if (_applyClientSearchFromAgent) {
          _applyClientSearchFromAgent = false;
        } else {
          unawaited(_runHomeAgent(message: _searchQuery));
          return;
        }
      }
      if (!_hasStartedSearch) {
        _loadInitialForSearch();
      } else {
        _startSearchPrefetchWorker();
        _tryLoadMoreForSearch();
      }
    });
  }

  Future<bool> _requireHomeAgentLogin() async {
    if (FirebaseAuth.instance.currentUser != null) return true;
    if (!mounted) return false;
    await Navigator.pushNamed(context, '/login');
    return FirebaseAuth.instance.currentUser != null;
  }

  Future<void> _runHomeAgent({
    String? chipId,
    String? message,
    String? focusIngredient,
  }) async {
    if (!HomeAgentService.enabled || _homeBusy) return;
    if (!await _requireHomeAgentLogin()) return;
    setState(() {
      _homeBusy = true;
      _homeReply = '';
      _homePickReasons.clear();
    });
    try {
      final result = await HomeAgentService.instance.turn(
        chipId: chipId,
        message: message,
        focusIngredient: focusIngredient,
      );
      if (!mounted) return;
      await _applyHomeAgentResult(result);
    } on HomeAgentException catch (e) {
      if (!mounted) return;
      setState(() {
        _homeBusy = false;
        _homeReply = e.statusCode == 429
            ? '조금 뒤에 다시 시도해 주세요.'
            : '지금은 답할 수 없어요. 잠시 후 다시 시도해 주세요.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _homeBusy = false;
        _homeReply = '지금은 답할 수 없어요. 잠시 후 다시 시도해 주세요.';
      });
    }
  }

  Future<void> _applyHomeAgentResult(HomeAgentTurnResult result) async {
    if (result.recipeIds.isNotEmpty) {
      final recipes = await _recipeService.getExploreRecipesByIds(
        result.recipeIds,
        limit: 8,
      );
      if (!mounted) return;
      var next = recipes;
      if (result.spiceLow && result.retrieve == 'local_filter') {
        next = applySpiceLowFilter(next);
      }
      setState(() {
        _recipes
          ..clear()
          ..addAll(next);
        _hasMore = false;
        _hasStartedSearch = true;
        _homeBusy = false;
        _homeReply = result.reply;
        _pendingSpiceLow = false;
        _homePickReasons
          ..clear()
          ..addEntries(
            result.picks
                .where((p) => p.recipeId.isNotEmpty && p.reason.isNotEmpty)
                .map((p) => MapEntry(p.recipeId, p.reason)),
          );
        if (result.q.isNotEmpty) {
          _searchQuery = result.q;
        } else if (_searchQuery.isEmpty) {
          _searchQuery = result.reply.isNotEmpty ? result.reply : '추천';
        }
      });
      return;
    }
    if (result.retrieve == 'client_search' && result.q.isNotEmpty) {
      _pendingSpiceLow = result.spiceLow;
      _homeBusy = false;
      _applyClientSearchFromAgent = true;
      _homePickReasons.clear();
      if (_searchController.text.trim() != result.q) {
        _searchController.text = result.q;
      } else if (!_hasStartedSearch) {
        await _loadInitialForSearch();
      }
      setState(() => _homeReply = result.reply);
      return;
    }
    if (result.spiceLow) {
      final filtered = applySpiceLowFilter(_recipes);
      setState(() {
        _recipes
          ..clear()
          ..addAll(filtered);
        _homeBusy = false;
        _homeReply = _recipes.isEmpty && result.reply.isNotEmpty
            ? result.reply
            : (result.reply.isNotEmpty
                ? result.reply
                : '지금 목록에서 청양·매운 태그를 뺐어요.');
      });
      return;
    }
    setState(() {
      _homeBusy = false;
      _homeReply = result.reply;
    });
  }

  Future<void> _onIngredientChip() async {
    if (!HomeAgentService.enabled || _homeBusy) return;
    final controller = TextEditingController();
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('재료 이름'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: '예: 닭가슴살'),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('찾기'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (picked == null || picked.isEmpty) return;
    await _runHomeAgent(chipId: 'with_ingredient', focusIngredient: picked);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (_searchQuery.isNotEmpty && pos.pixels >= pos.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  List<Map<String, dynamic>> get _matchingRecipes => _recipes
      .where((recipe) => recipeMatchesSearchQuery(recipe, _searchQuery))
      .toList(growable: false);

  void _appendUnique(List<Map<String, dynamic>> batch) {
    final ids =
        _recipes.map((r) => r['id'] as String?).whereType<String>().toSet();
    for (final r in batch) {
      final id = r['id'] as String? ?? '';
      if (id.isEmpty || ids.contains(id)) continue;
      ids.add(id);
      _recipes.add(r);
    }
  }

  Future<void> _loadInitialForSearch() async {
    if (!mounted || _hasStartedSearch || _searchQuery.isEmpty) return;
    setState(() {
      _initialLoading = true;
      _error = null;
    });
    try {
      _recipes.clear();
      _lastCursor = null;
      _hasMore = true;
      _hasStartedSearch = true;

      final query = _searchQuery;
      final dishHitsFuture = _recipeService.searchRecipesByDishQuery(
        query,
        limit: _searchEnoughMatches,
      );
      final guestListFuture = _recipeService.getExploreRecipesForGuests(
        limit: _initialGuestLimit,
      );
      final dishHits = await dishHitsFuture;
      if (!mounted || _searchQuery != query) return;
      _appendUnique(dishHits);
      if (_recipes.isNotEmpty) setState(() {});

      final guestList = await guestListFuture;
      if (!mounted || _searchQuery != query) return;
      _appendUnique(guestList);
      setState(() {});

      await _seedCursorFromOldestCreatedAt();
      if (!mounted || _searchQuery != query) return;

      if (_matchingRecipes.length < _searchEnoughMatches) {
        var extraPages = 0;
        while (mounted &&
            _hasMore &&
            _searchQuery == query &&
            extraPages < _searchPrefetchMaxPages) {
          if (_matchingRecipes.length >= _searchEnoughMatches) break;
          extraPages += 1;
          final page = await _recipeService.fetchExploreRecipesPage(
            startAfter: _lastCursor,
            rawLimit: _rawBatch,
          );
          if (!mounted || _searchQuery != query) return;
          _lastCursor = page.lastRawDocument;
          _hasMore = page.hasMore;
          _appendUnique(page.recipes);
          if (_pendingSpiceLow) {
            final filtered = applySpiceLowFilter(_recipes);
            _recipes
              ..clear()
              ..addAll(filtered);
          }
          setState(() {});
          if (!_hasMore) break;
          if (page.lastRawDocument == null && page.recipes.isEmpty) break;
          if (_matchingRecipes.isNotEmpty) break;
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
    if (!mounted) return;
    if (_pendingSpiceLow) {
      final filtered = applySpiceLowFilter(_recipes);
      _recipes
        ..clear()
        ..addAll(filtered);
    }
    setState(() => _initialLoading = false);
    if (_searchQuery.isNotEmpty) {
      _startSearchPrefetchWorker();
      unawaited(_tryLoadMoreForSearch());
    }
    _trackSearchEmptyIfNeeded();
  }

  Future<void> _seedCursorFromOldestCreatedAt() async {
    if (_recipes.isEmpty || _lastCursor != null) return;
    Map<String, dynamic>? oldest;
    DateTime? oldestDate;
    for (final recipe in _recipes) {
      final created = recipe['createdAt'];
      DateTime? date;
      if (created is Timestamp) {
        date = created.toDate();
      } else if (created is DateTime) {
        date = created;
      }
      if (date == null) continue;
      if (oldestDate == null || date.isBefore(oldestDate)) {
        oldestDate = date;
        oldest = recipe;
      }
    }
    final lastId = (oldest?['id'] as String?) ??
        (_recipes.last['id'] as String?);
    if (lastId == null || lastId.isEmpty) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('recipes')
          .doc(lastId)
          .get();
      if (snap.exists) _lastCursor = snap;
    } catch (_) {}
  }

  Future<void> _loadMore() async {
    if (!mounted ||
        _searchQuery.isEmpty ||
        _loadingMore ||
        !_hasMore) {
      return;
    }
    setState(() => _loadingMore = true);
    try {
      final page = await _recipeService.fetchExploreRecipesPage(
        startAfter: _lastCursor,
        rawLimit: _rawBatch,
      );
      if (!mounted) return;
      _lastCursor = page.lastRawDocument;
      _hasMore = page.hasMore;
      _appendUnique(page.recipes);
      if (_pendingSpiceLow) {
        final filtered = applySpiceLowFilter(_recipes);
        _recipes
          ..clear()
          ..addAll(filtered);
      }
      setState(() {});
    } catch (_) {}
    if (mounted) setState(() => _loadingMore = false);
    _trackSearchEmptyIfNeeded();
  }

  Future<void> _startSearchPrefetchWorker() async {
    if (!mounted || _searchPrefetchRunning) return;
    _searchPrefetchRunning = true;
    try {
      var fetchedPages = 0;
      while (mounted && _searchQuery.isNotEmpty && _hasMore) {
        final q = _searchQuery;
        final matches = _recipes
            .where((r) => recipeMatchesSearchQuery(r, q))
            .take(_searchEnoughMatches);
        if (matches.length >= _searchEnoughMatches) break;
        if (fetchedPages >= _searchPrefetchMaxPages) break;
        while (mounted && _loadingMore) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        if (!mounted || _searchQuery.isEmpty || !_hasMore) break;
        final before = _recipes.length;
        await _loadMore();
        fetchedPages += 1;
        if (_recipes.length == before) break;
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    } finally {
      _searchPrefetchRunning = false;
    }
    _trackSearchEmptyIfNeeded();
  }

  Future<void> _tryLoadMoreForSearch() async {
    if (!mounted) return;
    final q = _searchQuery;
    if (q.isEmpty) return;
    if (_recipes.any((r) => recipeMatchesSearchQuery(r, q))) return;
    for (var i = 0; i < _searchRetryMaxPages; i++) {
      if (!mounted || _searchQuery != q) return;
      if (_recipes.any((r) => recipeMatchesSearchQuery(r, q))) return;
      if (!_hasMore) {
        _trackSearchEmptyIfNeeded();
        return;
      }
      while (mounted && _loadingMore) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      await _loadMore();
    }
    while (mounted && _searchQuery == q && _searchPrefetchRunning) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    if (!mounted || _searchQuery != q) return;
    if (_recipes.any((r) => recipeMatchesSearchQuery(r, q))) return;
    _trackSearchEmptyIfNeeded(force: true);
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final bg = AppColors.getBackground(brightness);
    final textPrimary = AppColors.getTextPrimary(brightness);
    final secondary = AppColors.getTextSecondary(brightness);

    final filtered =
        _searchQuery.isEmpty ? const <Map<String, dynamic>>[] : _matchingRecipes;

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Container(
                height: 46,
                padding: const EdgeInsets.only(left: 12, right: 21),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(100),
                  border: Border.all(
                    color: const Color(0xFFFF6B00),
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    Material(
                      color: Colors.transparent,
                      shape: const CircleBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => Navigator.pop(context),
                        child: SizedBox(
                          width: 32,
                          height: 32,
                          child: Center(
                            child: Icon(
                              Icons.arrow_back_rounded,
                              size: 20,
                              color: textPrimary,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        focusNode: _searchFocus,
                        textInputAction: TextInputAction.search,
                        decoration: const InputDecoration(
                          hintText: '레시피 또는 재료 입력',
                          hintStyle: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF99A1AF),
                            letterSpacing: -0.375,
                          ),
                          border: InputBorder.none,
                          isCollapsed: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF111111),
                          letterSpacing: -0.375,
                        ),
                      ),
                    ),
                    if (_searchQuery.isNotEmpty)
                      GestureDetector(
                        onTap: () {
                          _searchController.clear();
                        },
                        child: Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Icon(
                            Icons.cancel_rounded,
                            size: 18,
                            color: const Color(0xFF99A1AF),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (HomeAgentService.enabled) _buildHomeAgentChips(),
            if (HomeAgentService.enabled &&
                (_homeReply.isNotEmpty || _homeBusy))
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _homeBusy ? '찾는 중…' : _homeReply,
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 13,
                      color: secondary,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: _buildBody(brightness, secondary, filtered),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHomeAgentChips() {
    Widget chip(String label, VoidCallback? onTap) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ActionChip(
          label: Text(
            label,
            style: const TextStyle(fontFamily: 'Pretendard', fontSize: 13),
          ),
          onPressed: _homeBusy ? null : onTap,
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Row(
        children: [
          chip('뭐 해먹지', () => _runHomeAgent(chipId: 'what_to_eat')),
          chip('이 재료로', _onIngredientChip),
          chip('빨리', () => _runHomeAgent(chipId: 'fast')),
          chip('해장', () => _runHomeAgent(chipId: 'hangover')),
          chip('고단백', () => _runHomeAgent(chipId: 'high_protein')),
          chip('덜 맵게', () => _runHomeAgent(chipId: 'less_spicy')),
        ],
      ),
    );
  }

  Widget _buildBody(
    Brightness brightness,
    Color secondary,
    List<Map<String, dynamic>> filtered,
  ) {
    if (_searchQuery.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.search_rounded,
                size: 34,
                color: secondary.withValues(alpha: 0.75),
              ),
              const SizedBox(height: 12),
              Text(
                '찾고 싶은 레시피나 재료를 검색해 보세요',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.getTextPrimary(brightness),
                  letterSpacing: -0.35,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '예: 김치찌개, 닭가슴살, 10분 요리',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: secondary,
                  letterSpacing: -0.25,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '레시피를 불러올 수 없어요.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: secondary),
          ),
        ),
      );
    }

    if (_initialLoading && filtered.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (filtered.isEmpty) {
      return Center(
        child: Text(
          _searchQuery.isEmpty ? '아직 레시피가 없어요.' : '검색 결과가 없어요.',
          style: TextStyle(fontSize: 15, color: secondary),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      itemCount: filtered.length + (_loadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= filtered.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              HomeStyleRecipeCard.fromRecipeMap(
                context,
                filtered[index],
                recipeService: _recipeService,
                backgroundParsingService: _backgroundParsingService,
                forceHideDate: true,
                onAfterRecipeMutation: () {
                  if (mounted) setState(() {});
                },
                screenName: 'recipe_search',
                sectionId: 'search_results',
                position: index,
              ),
              if (_homePickReasons[(filtered[index]['id'] ?? '').toString()]
                      ?.isNotEmpty ==
                  true)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 6, 4, 2),
                  child: Text(
                    _homePickReasons[(filtered[index]['id'] ?? '').toString()]!,
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 12,
                      height: 1.4,
                      color: secondary,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
