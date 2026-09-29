// Recommendation screen — horizontal trending lists (legacy recipes tab 대체).
import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../utils/recipe_search_match.dart';
import '../utils/recipe_tag_filters.dart';
import '../widgets/app_network_image.dart';
import '../services/auth_service.dart';
import '../services/recipe_service.dart';
import '../widgets/local_storage_warning.dart';
import '../widgets/recipe_search_text_field.dart';
import '../widgets/yorigo_header_logo.dart';

/// In-memory cache for the four horizontal lists so revisiting the screen skips refetch.
class _RecommendationListsCache {
  static List<Map<String, dynamic>>? allTime;
  static List<Map<String, dynamic>>? weekly;
  static List<Map<String, dynamic>>? monthly;
  static List<Map<String, dynamic>>? recent;
  static bool loaded = false;

  static void save(
    List<Map<String, dynamic>> a,
    List<Map<String, dynamic>> b,
    List<Map<String, dynamic>> c,
    List<Map<String, dynamic>> d,
  ) {
    allTime = List<Map<String, dynamic>>.from(a);
    weekly = List<Map<String, dynamic>>.from(b);
    monthly = List<Map<String, dynamic>>.from(c);
    recent = List<Map<String, dynamic>>.from(d);
    loaded = true;
  }

  static void clear() {
    allTime = null;
    weekly = null;
    monthly = null;
    recent = null;
    loaded = false;
  }
}

/// Precaches only the first [count] search-result thumbnails (warm disk decode for top rows).
class _PrecacheSearchThumbRow extends StatefulWidget {
  const _PrecacheSearchThumbRow({
    required this.recipes,
    required this.count,
    required this.child,
  });

  final List<Map<String, dynamic>> recipes;
  final int count;
  final Widget child;

  @override
  State<_PrecacheSearchThumbRow> createState() =>
      _PrecacheSearchThumbRowState();
}

class _PrecacheSearchThumbRowState extends State<_PrecacheSearchThumbRow> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _precache());
  }

  @override
  void didUpdateWidget(covariant _PrecacheSearchThumbRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recipes != widget.recipes) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _precache());
    }
  }

  void _precache() {
    if (!mounted) return;
    final n = math.min(widget.count, widget.recipes.length);
    for (var i = 0; i < n; i++) {
      final url = widget.recipes[i]['thumbnailUrl'] as String? ?? '';
      if (url.isEmpty) continue;
      precacheImage(
        CachedNetworkImageProvider(
          url,
          maxWidth: AppNetworkImage.listThumbCacheSize,
          maxHeight: AppNetworkImage.listThumbCacheSize,
        ),
        context,
      );
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class RecommendationScreen extends StatefulWidget {
  const RecommendationScreen({super.key});

  @override
  State<RecommendationScreen> createState() => _RecommendationScreenState();
}

class _RecommendationScreenState extends State<RecommendationScreen> {
  final RecipeService _recipeService = RecipeService();
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  /// 검색용 전체 레시피는 '검색을 실제로 할 때' 최신 상한만 조회한다.
  static Future<List<Map<String, dynamic>>>? _sharedAllRecipesFuture;

  StreamSubscription<dynamic>? _authSub;

  // Cached recipe lists
  List<Map<String, dynamic>> _allTimePopular = [];
  List<Map<String, dynamic>> _weeklyPopular = [];
  List<Map<String, dynamic>> _monthlyPopular = [];
  List<Map<String, dynamic>> _recentlyAdded = [];

  bool _isLoading = true;

  @override
  void initState() {
    super.initState();

    if (_RecommendationListsCache.loaded &&
        _RecommendationListsCache.allTime != null) {
      _allTimePopular = List<Map<String, dynamic>>.from(
        _RecommendationListsCache.allTime!,
      );
      _weeklyPopular = List<Map<String, dynamic>>.from(
        _RecommendationListsCache.weekly!,
      );
      _monthlyPopular = List<Map<String, dynamic>>.from(
        _RecommendationListsCache.monthly!,
      );
      _recentlyAdded = List<Map<String, dynamic>>.from(
        _RecommendationListsCache.recent!,
      );
      _isLoading = false;
    } else {
      _loadRecipes();
    }

    _authSub = AuthService().authStateChanges.listen((user) {
      if (user == null) {
        _RecommendationListsCache.clear();
        // 로그아웃 시 캐시된 검색용 전체 레시피도 폐기(다음 검색 때 재조회).
        _sharedAllRecipesFuture = null;
      }
    });

    // Add listener to search controller
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.trim();
      });
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadRecipes() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // Load all recipe lists in parallel
      final results = await Future.wait([
        _recipeService.getAllTimePopularRecipes(limit: 10),
        _recipeService.getWeeklyPopularRecipes(limit: 10),
        _recipeService.getMonthlyPopularRecipes(limit: 10),
        _recipeService.getRecentlyAddedRecipes(limit: 10),
      ]);

      setState(() {
        _allTimePopular = results[0];
        _weeklyPopular = results[1];
        _monthlyPopular = results[2];
        _recentlyAdded = results[3];
        _isLoading = false;
      });
      _RecommendationListsCache.save(
        _allTimePopular,
        _weeklyPopular,
        _monthlyPopular,
        _recentlyAdded,
      );
    } catch (e) {
      print('Error loading recipes: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  // Check if recipe matches search query and return priority score
  // Returns: -1 if no match, 0+ for match priority (higher = better match)
  int _getSearchMatchPriority(Map<String, dynamic> recipe, String query) {
    return recipeSearchMatchPriority(recipe, query);
  }

  // Build search results with home page card format
  Widget _buildSearchResults(Brightness brightness) {
    // 검색을 실제로 시작한 이 시점에만 전체 레시피를 1회 조회한다(지연 로딩).
    // 조회 실패 시 메모이즈된 Future를 비워, 다음 검색 시도에서 재조회되게 한다
    // (실패한 Future가 영구 캐시되어 검색이 계속 막히는 것을 방지).
    final allRecipesFuture = _sharedAllRecipesFuture ??= _recipeService
        .fetchAllRecipesForSearch()
        .catchError((Object e) {
          _sharedAllRecipesFuture = null;
          throw e;
        });
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: allRecipesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(40),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 64,
                    color: AppColors.getTextTertiary(brightness),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '오류가 발생했습니다: ${snapshot.error}',
                    style: TextStyle(
                      fontSize: 16,
                      color: AppColors.getTextSecondary(brightness),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        final allRecipes = snapshot.data ?? [];

        // 검색은 필터만 적용하고, 서비스에서 내려온 최신순을 유지합니다.
        final filteredResults = allRecipes
            .where((recipe) => _getSearchMatchPriority(recipe, _searchQuery) != -1)
            .toList();

        if (filteredResults.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(40),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.search_off,
                    size: 64,
                    color: AppColors.getTextTertiary(brightness),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '검색 결과가 없습니다',
                    style: TextStyle(
                      fontSize: 16,
                      color: AppColors.getTextSecondary(brightness),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return _PrecacheSearchThumbRow(
          recipes: filteredResults,
          count: 5,
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '검색 결과 (${filteredResults.length}개)',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppColors.getTextPrimary(brightness),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ...filteredResults.map(
                    (recipe) => _buildRecipeCard(recipe, brightness),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;

    return Scaffold(
      backgroundColor: AppColors.getBackground(brightness),
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back,
            color: AppColors.getTextPrimary(brightness),
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        titleSpacing: 0,
        centerTitle: false,
        title: Row(
          children: [
            const YorigoHeaderLogo(height: 22, maxWidth: 100),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '추천',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.getTextPrimary(brightness),
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: AppColors.getBackground(brightness),
        elevation: 0,
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Search bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.getBackground(brightness),
                border: Border(
                  bottom: BorderSide(
                    color: AppColors.getBorder(brightness),
                    width: 1,
                  ),
                ),
              ),
              child: RecipeSearchTextField(controller: _searchController),
            ),
            const CompactLocalStorageWarning(),
            // Content
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _searchQuery.isNotEmpty
                  ? _buildSearchResults(brightness)
                  : SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 20),
                          // All time Popular
                          _buildSection(
                            title: '인기 최고',
                            recipes: _allTimePopular,
                            brightness: brightness,
                          ),
                          const SizedBox(height: 24),
                          // 주간 베스트
                          _buildSection(
                            title: '주간 베스트',
                            recipes: _weeklyPopular,
                            brightness: brightness,
                          ),
                          const SizedBox(height: 24),
                          // 월간 베스트
                          _buildSection(
                            title: '월간 베스트',
                            recipes: _monthlyPopular,
                            brightness: brightness,
                          ),
                          const SizedBox(height: 24),
                          // 가장 최근 추가된
                          _buildSection(
                            title: '가장 최근 추가된',
                            recipes: _recentlyAdded,
                            brightness: brightness,
                          ),
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required List<Map<String, dynamic>> recipes,
    required Brightness brightness,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: AppColors.getTextPrimary(brightness),
            ),
          ),
        ),
        const SizedBox(height: 12),
        recipes.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
                  height: 200,
                  decoration: BoxDecoration(
                    color: AppColors.getBackgroundSecondary(brightness),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Center(
                    child: Text(
                      '레시피가 없습니다',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.getTextSecondary(brightness),
                      ),
                    ),
                  ),
                ),
              )
            : SizedBox(
                height: 200,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: recipes.length,
                  itemBuilder: (context, index) {
                    return Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: _buildRecipeCard(recipes[index], brightness),
                    );
                  },
                ),
              ),
      ],
    );
  }

  Widget _buildRecipeCard(Map<String, dynamic> recipe, Brightness brightness) {
    final title = recipe['title'] as String? ?? '레시피';
    final thumbnailUrl = recipe['thumbnailUrl'] as String? ?? '';
    final calories = recipe['calories'] as num? ?? 0;
    final recipeId = recipe['id'] as String;

    // Calculate cooking time from steps
    final recipeData = recipe['recipe'] as Map<String, dynamic>? ?? {};
    final steps = recipeData['steps'] as List? ?? [];
    int totalMinutes = 0;
    for (var step in steps) {
      if (step is Map && step['est_minutes'] != null) {
        totalMinutes += (step['est_minutes'] as num).toInt();
      }
    }
    if (totalMinutes == 0) totalMinutes = 15;

    // Get first tag (drop UI-blocked tokens)
    final tags = filterRecipeTagsForDisplay(recipe['tags'] as List?);
    final firstTag = tags.isNotEmpty ? tags[0] : '';

    return GestureDetector(
      onTap: () async {
        final parseResponse = await _recipeService.getRecipeById(recipeId);
        if (parseResponse != null && mounted) {
          Navigator.pushNamed(
            context,
            '/recipe-detail',
            arguments: {'parseResponse': parseResponse, 'recipeId': recipeId},
          );
        }
      },
      child: Container(
        width: 160,
        decoration: BoxDecoration(
          color: AppColors.getBackground(brightness),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.getBorder(brightness), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Thumbnail
            ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(12),
              ),
              child: Container(
                height: 100,
                width: double.infinity,
                color: AppColors.getBackgroundTertiary(brightness),
                child: thumbnailUrl.isNotEmpty
                    ? AppNetworkImage(
                        imageUrl: thumbnailUrl,
                        fit: BoxFit.cover,
                        memCacheWidth: AppNetworkImage.listThumbCacheSize,
                        memCacheHeight: AppNetworkImage.listThumbCacheSize,
                        errorWidget: Icon(
                          Icons.restaurant,
                          size: 32,
                          color: AppColors.getTextTertiary(brightness),
                        ),
                      )
                    : Icon(
                        Icons.restaurant,
                        size: 32,
                        color: AppColors.getTextTertiary(brightness),
                      ),
              ),
            ),
            // Content
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Recipe name
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.getTextPrimary(brightness),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  // Cooking time and calories
                  Row(
                    children: [
                      Icon(
                        Icons.access_time,
                        size: 12,
                        color: AppColors.getTextSecondary(brightness),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '$totalMinutes분',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.getTextSecondary(brightness),
                        ),
                      ),
                      if (calories > 0) ...[
                        const SizedBox(width: 8),
                        Icon(
                          Icons.local_fire_department,
                          size: 12,
                          color: AppColors.getTextSecondary(brightness),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${calories.toInt()}kcal',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.getTextSecondary(brightness),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (firstTag.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        firstTag,
                        style: TextStyle(
                          fontSize: 10,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
