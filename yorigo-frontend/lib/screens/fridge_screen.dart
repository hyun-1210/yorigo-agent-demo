import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/ingredient_shelf_life_seed.dart';
import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:firebase_auth/firebase_auth.dart';
import '../theme/app_colors.dart';
import '../utils/meal_calendar_launcher.dart';
import '../widgets/progressive_recipe_review_sheet.dart';
import '../widgets/cooking_instruction_sheet.dart';
import '../widgets/fridge_recipe_recommendation_sheet.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/receipt_scan_history_store.dart';
import '../services/fridge_scan_report_service.dart';
import '../utils/auth_session_ready.dart';
import '../services/user_service.dart';
import '../services/recipe_service.dart';
import '../services/meal_plan_service.dart';
import '../services/analytics_service.dart';
import '../utils/ingredient_unit_converter.dart';
import '../utils/ingredient_category_unifier.dart';
import '../utils/receipt_scan_item_normalizer.dart';
import '../utils/receipt_catalog_matcher.dart';
import '../utils/haptics.dart';
import '../widgets/app_toast.dart';
import '../services/ingredient_shelf_life_service.dart';
import '../widgets/app_network_image.dart';
import '../widgets/thumbnail_letterbox_mitigation.dart';
import '../widgets/app_header.dart';
import '../widgets/guest_locked_preview_backdrop.dart';
import '../widgets/ios_liquid_glass_tab_bar.dart';

double _safeQty(dynamic v) {
  if (v == null) return 0;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}

double _shoppingQtyForRecipeIngredient(
  Map<String, dynamic> ing,
  String ingredientName,
) {
  final storedShoppingQty = _safeQty(ing['shoppingQty']);
  final storedShoppingUnit = IngredientUnitConverter.normalizeUnit(
    ing['shoppingUnit']?.toString() ?? '',
  );
  if (storedShoppingQty > 0 && storedShoppingUnit.isNotEmpty) {
    return storedShoppingQty;
  }
  final qty = _safeQty(ing['qty']);
  final unit = ing['unit']?.toString() ?? '개';
  final converted = IngredientUnitConverter.toShoppingUnit(
    ingredientName: ingredientName,
    qty: qty,
    unit: unit,
  );
  return converted.qty;
}

String _shoppingUnitForRecipeIngredient(
  Map<String, dynamic> ing,
  String ingredientName,
) {
  final storedShoppingQty = _safeQty(ing['shoppingQty']);
  final storedShoppingUnit = IngredientUnitConverter.normalizeUnit(
    ing['shoppingUnit']?.toString() ?? '',
  );
  if (storedShoppingQty > 0 && storedShoppingUnit.isNotEmpty) {
    return storedShoppingUnit;
  }
  final qty = _safeQty(ing['qty']);
  final unit = ing['unit']?.toString() ?? '개';
  final converted = IngredientUnitConverter.toShoppingUnit(
    ingredientName: ingredientName,
    qty: qty,
    unit: unit,
  );
  return converted.unit;
}

const Color _fridgeAccentOrange = Color(0xFFFF6B35);
// Figma 97-4514 design tokens
const Color _figmaOrange = Color(0xFFFF6B00);
const Color _figmaTextPrimary = Color(0xFF111111);
const Color _figmaTextGray = Color(0xFF6B7280);
const Color _figmaTextGray2 = Color(0xFF6A7282);
const Color _figmaBorder = Color(0xFFF3F4F6);

const List<String> _weekdayShort = ['월', '화', '수', '목', '금', '토', '일'];

// Liquid / Korean-app design tokens
const double _fridgeScreenPaddingH = 16;

/// Step size for +/-. Step is NOT dynamic: it is set once by the initial required amount (originalQty / orderQty) and never changes.
/// 냉장고/재료 추가에서 쓰는 수량 스텝.
/// 셀 수·계량스푼은 세밀하게, g/ml 은 기존처럼 큰 단위로.
double _stepForLeftover(double amount, String unit, [double? scaleForMlG]) {
  final u = unit.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  if (_isFineCountableUnit(u)) return 0.5;
  if (_isSpoonOrCupUnit(u)) return 0.25;
  if (u == 'ml' || u == 'g' || u == '그램') {
    final scale = scaleForMlG ?? amount;
    if (scale >= 200) return 100;
    if (scale >= 100) return 50;
    if (scale >= 30) return 10;
    return 5;
  }
  if (u == 'kg' || u == 'l' || u == 'ℓ') return 0.1;
  if (amount >= 200) return 100;
  if (amount >= 100) return 50;
  if (amount >= 30) return 10;
  if (amount >= 5) return 5;
  return 1;
}

bool _isFineCountableUnit(String unit) {
  const units = {
    '개',
    '장',
    '단',
    '대',
    '줄',
    '모',
    '봉',
    '팩',
    '캔',
    '병',
    '쪽',
    '알',
    '조각',
  };
  return units.contains(unit);
}

bool _isSpoonOrCupUnit(String unit) {
  const units = {'큰술', '작은술', '컵', '꼬집', '티스푼', '테이블스푼'};
  return units.contains(unit);
}

/// 해당 단위에서 허용하는 최소 수량.
double _minQtyForUnit(String unit) {
  final u = unit.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  if (_isSpoonOrCupUnit(u)) return 0.25;
  if (_isFineCountableUnit(u)) return 0.5;
  if (u == 'kg' || u == 'l' || u == 'ℓ') return 0.1;
  if (u == 'ml' || u == 'g' || u == '그램') return 5;
  return 0.5;
}

/// 부동소수점 흔들림을 줄이기 위해 단위 스텝에 맞춰 스냅.
double _snapQtyToUnit(double qty, String unit) {
  final step = _stepForLeftover(qty, unit);
  if (step <= 0) return qty;
  final snapped = (qty / step).round() * step;
  // ⅓·⅔ 칩 값은 스텝 스냅으로 깨지지 않게 허용.
  if ((qty - 1 / 3).abs() < 0.02 || (qty - 2 / 3).abs() < 0.02) {
    return double.parse(qty.toStringAsFixed(3));
  }
  return double.parse(snapped.toStringAsFixed(3));
}

double _decrementQty(double qty, String unit) {
  final step = _stepForLeftover(qty, unit);
  final min = _minQtyForUnit(unit);
  final next = _snapQtyToUnit(qty - step, unit);
  if (next < min - 0.001) return min;
  return next;
}

double _incrementQty(double qty, String unit) {
  final step = _stepForLeftover(qty, unit);
  return _snapQtyToUnit(qty + step, unit);
}

/// 화면용 수량 표기. 흔한 분수는 기호로 보여준다.
String _formatQuantityLabel(double qty) {
  if (qty <= 0) return '0';
  final candidates = <(double, String)>[
    (0.25, '¼'),
    (1 / 3, '⅓'),
    (0.5, '½'),
    (2 / 3, '⅔'),
    (0.75, '¾'),
    (1.25, '1¼'),
    (1.5, '1½'),
    (1.75, '1¾'),
    (2.5, '2½'),
  ];
  for (final (value, label) in candidates) {
    if ((qty - value).abs() < 0.02) return label;
  }
  if ((qty - qty.roundToDouble()).abs() < 0.001) {
    return qty.round().toString();
  }
  final fixed = qty.toStringAsFixed(2);
  if (fixed.endsWith('0')) {
    return qty.toStringAsFixed(1);
  }
  return fixed;
}

/// Figma 97-4514: date like "11.10 일"
String _formatFridgeDateFigma(String isoDate) {
  try {
    final d = DateTime.parse(isoDate.substring(0, 10));
    final w = _weekdayShort[d.weekday - 1];
    return '${d.month}.${d.day} $w';
  } catch (_) {
    return isoDate;
  }
}

/// Days until expiry from today. Negative = expired. Null if no expiryDate.
int? _daysUntilExpiry(String? expiryDateIso) {
  if (expiryDateIso == null || expiryDateIso.isEmpty) return null;
  try {
    final expiry = DateTime.parse(expiryDateIso.substring(0, 10));
    final today = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    );
    final expiryDay = DateTime(expiry.year, expiry.month, expiry.day);
    return expiryDay.difference(today).inDays;
  } catch (_) {
    return null;
  }
}

/// Truncate unit string to prevent overflow (e.g. long "밀리리터", "tablespoons").
String _truncateUnit(String unit, [int maxLen = 12]) {
  if (unit.length <= maxLen) return unit;
  return '${unit.substring(0, maxLen)}…';
}

/// 수동 추가·영수증 스캔 등 이미 확보한 재료인지.
/// (쿠팡 장바구니 입고와 달리 배송중/도착 추정 없이 바로 D-day)
bool _isAlreadyOwnedFridgeSource(String? source, String? purchaseBatchId) {
  final s = (source ?? '').trim();
  final b = (purchaseBatchId ?? '').trim();
  if (s == 'manual' || s == 'photo_receipt') return true;
  if (s.startsWith('manual') || s.startsWith('photo_')) return true;
  if (b.startsWith('manual_') || b.startsWith('photo_receipt')) return true;
  return false;
}

class FridgeScreen extends StatefulWidget {
  const FridgeScreen({
    super.key,
    this.showArrivalAnimation,
    this.onArrivalAnimationDone,
  });

  /// When true, show a short "items arrived" animation (e.g. after 구매 완료). Null treated as false.
  final bool? showArrivalAnimation;
  final VoidCallback? onArrivalAnimationDone;

  @override
  State<FridgeScreen> createState() => _FridgeScreenState();
}

class _FridgeScreenState extends State<FridgeScreen> with TickerProviderStateMixin {
  final AuthService _authService = AuthService();
  final UserService _userService = UserService();
  final RecipeService _recipeService = RecipeService();
  final MealPlanService _mealPlanService = MealPlanService();
  final TextEditingController _searchController = TextEditingController();

  /// Fridge ingredient indices optimistically removed (trash) until server confirms.
  /// Uses index (not name) so deleting one item doesn't affect others with the same name.
  final Set<int> _optimisticallyDeletedFridgeIndices = {};

  /// Snapshot key we already started category backfill for (avoids duplicate runs).
  String? _categoryBackfillKey;
  String? _selectedIngredientFilterKey = 'all';
  final Set<String> _expandedIngredientBatchGroups = {};

  /// 헤더 '편집'으로 들어가는 냉장고 재료 선택 모드.
  bool _isFridgeSelecting = false;
  final Set<int> _selectedFridgeIndices = {};

  /// 목록을 일정 이상 스크롤하면 하단 액션 바를 작게 접는다.
  bool _fridgeBottomBarCompact = false;
  final ScrollController _fridgeListScrollController = ScrollController();

  late AnimationController _arrivalController;
  bool _arrivalAnimationStarted = false;

  @override
  void initState() {
    super.initState();
    _arrivalController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );
    _fridgeListScrollController.addListener(_onFridgeListScroll);
  }

  @override
  void didUpdateWidget(FridgeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.showArrivalAnimation != true) {
      _arrivalAnimationStarted = false;
      return;
    }
    if (oldWidget.showArrivalAnimation != true && !_arrivalAnimationStarted) {
      _startArrivalAnimationIfNeeded();
    }
  }

  @override
  void dispose() {
    _fridgeListScrollController.removeListener(_onFridgeListScroll);
    _fridgeListScrollController.dispose();
    _searchController.dispose();
    _arrivalController.dispose();
    super.dispose();
  }

  void _onFridgeListScroll() {
    if (!_fridgeListScrollController.hasClients) return;
    // iPhone: 하단 CTA 크기는 스크롤과 무관하게 유지한다.
    if (IosLiquidGlassTabBar.shouldUse(context)) {
      if (_fridgeBottomBarCompact) {
        setState(() => _fridgeBottomBarCompact = false);
      }
      return;
    }
    final offset = _fridgeListScrollController.offset;
    // 히스테리시스: 내려갈 때와 올라올 때 임계값을 달리해 깜빡임을 줄인다.
    final nextCompact = _fridgeBottomBarCompact
        ? offset > 16
        : offset > 56;
    if (nextCompact == _fridgeBottomBarCompact) return;
    setState(() => _fridgeBottomBarCompact = nextCompact);
  }

  Widget _buildFridgeAppHeader(Brightness brightness) {
    return AppHeader(
      showNotificationIcon: true,
      showCalendarIcon: true,
      onCalendarPressed: _openFridgeCalendarTab,
    );
  }

  void _openFridgeCalendarTab() {
    openMealCalendar(
      context,
      onStartCooking: _openRecipeCooking,
      onOpenRecipeDetail: _openRecipeDetail,
      onCookingComplete: (screenContext, recipe, fridgeData, brightness) =>
          _showCookingCompleteConfirmDialog(
            screenContext,
            recipe,
            fridgeData,
            brightness,
          ),
    );
  }

  void _startArrivalAnimationIfNeeded() {
    if (widget.showArrivalAnimation != true || _arrivalAnimationStarted) return;
    _arrivalAnimationStarted = true;
    _arrivalController.forward(from: 0.0).then((_) {
      if (mounted) widget.onArrivalAnimationDone?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;

    if (widget.showArrivalAnimation == true && !_arrivalAnimationStarted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            widget.showArrivalAnimation == true &&
            !_arrivalAnimationStarted) {
          _startArrivalAnimationIfNeeded();
        }
      });
    }

    return Scaffold(
      backgroundColor: AppColors.getBackground(brightness),
      body: DefaultTextStyle.merge(
        style: const TextStyle(fontFamily: 'Pretendard'),
        child: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  _buildFridgeAppHeader(brightness),
                  Expanded(
                    child: StreamBuilder<User?>(
                stream: _authService.authStateChanges,
                initialData: _authService.currentUser,
                builder: (context, authSnapshot) {
                  final user = authSnapshot.data;
                  if (user == null &&
                      (authSnapshot.connectionState ==
                              ConnectionState.waiting ||
                          shouldIgnoreTransientAuthNull())) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (user == null) {
                          return _buildGuestLockedFridge(context, brightness);
                  }
                  return StreamBuilder<Map<String, dynamic>?>(
                    stream: _userService.getFridgeDataStream(user.uid),
                    builder: (context, fridgeSnapshot) {
                      final fridgeData = fridgeSnapshot.data;

                      // 상단(제목 + 필터 pill)은 고정하고, 재료 목록만 스크롤.
                      return Container(
                              color: brightness == Brightness.dark
                                  ? AppColors.getBackground(brightness)
                                  : Colors.white,
                        child: Stack(
                          clipBehavior: Clip.none,
                            children: [
                            Column(
                              children: [
                                _buildFridgeSectionHeader(
                                  brightness,
                                  fridgeData,
                                ),
                                Expanded(
                                  child: KeyedSubtree(
                                      key: const ValueKey(
                                      'fridge-storage-ingredients',
                                      ),
                                      child: _buildLeftoverTab(
                                        context,
                                        brightness,
                                        fridgeData,
                                      ),
                                  ),
                                ),
                              ],
                            ),
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: _buildBottomActionBar(
                                brightness,
                                fridgeData,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
                    ),
                  ),
                ],
              ),
              if (widget.showArrivalAnimation == true)
                AnimatedBuilder(
                  animation: _arrivalController,
                  builder: (context, child) {
                    final t = _arrivalController.value;
                    double offsetY = 0;
                    double opacity = 0;
                    if (t <= 0.15) {
                      final p = t / 0.15;
                      offsetY = -1.0 + p;
                      opacity = p;
                    } else if (t <= 0.8) {
                      offsetY = 0;
                      opacity = 1;
                    } else {
                      final p = (t - 0.8) / 0.2;
                      offsetY = p;
                      opacity = 1 - p;
                    }
                    return IgnorePointer(
                      child: Align(
                        alignment: Alignment(0, offsetY.clamp(-1.0, 1.0)),
                        child: Opacity(
                          opacity: opacity.clamp(0.0, 1.0),
                          child: _buildArrivalOverlay(context, brightness),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildArrivalOverlay(BuildContext context, Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: _fridgeScreenPaddingH),
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2C2C2C) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _fridgeAccentOrange.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.kitchen,
                  size: 28,
                  color: _fridgeAccentOrange,
                ),
              ),
              const SizedBox(width: 14),
              Flexible(
                child: Text(
                  '재료가 냉장고에 추가되었습니다',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : const Color(0xFF1A1A1A),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.egg_outlined,
                size: 20,
                color: _fridgeAccentOrange.withValues(alpha: 0.9),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.local_grocery_store_outlined,
                size: 20,
                color: _fridgeAccentOrange.withValues(alpha: 0.9),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.restaurant_outlined,
                size: 20,
                color: _fridgeAccentOrange.withValues(alpha: 0.9),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 냉장고 전체 재료 수(leftover > 0). 제목 옆 카운트 pill과 '전체' 필터에 동일하게 쓰인다.
  int _countLeftoverIngredients(Map<String, dynamic>? fridgeData) {
    final ingredients =
        (fridgeData?['ingredients'] as List?)?.cast<Map<String, dynamic>>() ??
        const [];
    final recipes =
        (fridgeData?['recipes'] as List?)?.cast<Map<String, dynamic>>() ??
        const [];

    final usedQty = <String, double>{};
    final usedQtyByBatch = <String, double>{};
    for (final r in recipes) {
      final batchId = r['purchaseBatchId']?.toString();
      final ings =
          (r['ingredients'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
      for (final ing in ings) {
        final name = (ing['item'] ?? ing['name'])?.toString() ?? '';
        if (name.isEmpty) continue;
        final qty = _shoppingQtyForRecipeIngredient(ing, name);
        if (batchId != null && batchId.isNotEmpty) {
          final key = '$batchId|$name';
          usedQtyByBatch[key] = (usedQtyByBatch[key] ?? 0) + qty;
        } else {
        usedQty[name] = (usedQty[name] ?? 0) + qty;
      }
    }
    }

    // 같은 재료(카테고리+이름)는 여러 번/여러 배치로 추가돼도 1개로 센다.
    final distinctKeys = <String>{};
    for (var i = 0; i < ingredients.length; i++) {
      if (_optimisticallyDeletedFridgeIndices.contains(i)) continue;
      final ing = ingredients[i];
      final name = ing['name']?.toString() ?? '';
      final orderQty = (ing['totalQty'] as num?)?.toDouble() ?? 0;
      final batchId = ing['purchaseBatchId']?.toString();
      final batchKey = batchId == null || batchId.isEmpty
          ? null
          : '$batchId|$name';
      final usedFromRecipes = batchKey == null
          ? usedQty[name] ?? 0
          : usedQtyByBatch[batchKey] ?? 0;
      final adjustedUsed = (ing['adjustedUsedQty'] as num?)?.toDouble();
      final effectiveUsed = adjustedUsed ?? usedFromRecipes;
      if (orderQty - effectiveUsed > 0) {
        final categoryKey = _categorizeIngredient(
          name,
          ing['category']?.toString(),
        );
        distinctKeys.add('$categoryKey|$name');
      }
    }
    return distinctKeys.length;
  }

  /// 같은 재료(카테고리+이름)는 여러 번 추가돼도 1개로 센다.
  /// 배치 그룹 카드 1장 = 1개. 필터/섹션 카운트가 화면 카드 수와 일치하도록.
  int _distinctIngredientCount(List<Map<String, dynamic>> items) {
    final keys = <String>{};
    for (final ing in items) {
      final name = ing['name']?.toString() ?? '';
      final categoryKey = _categorizeIngredient(
        name,
        ing['category']?.toString(),
      );
      keys.add('$categoryKey|$name');
    }
    return keys.length;
  }

  /// Number of ingredients that have leftover (orderQty - usedQty > 0). Used for "남을 재료" badge.
  Widget _buildFridgeSectionHeader(
    Brightness brightness,
    Map<String, dynamic>? fridgeData,
  ) {
    final totalCount = _countLeftoverIngredients(fridgeData);
    final selectedCount = _selectedFridgeIndices.length;
    return Container(
      width: double.infinity,
      // 장바구니 '구매할 레시피'와 제목 위치를 맞춘다.
      padding: const EdgeInsets.fromLTRB(20, 12, 16, 12),
      color: AppColors.getBackground(brightness),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    _isFridgeSelecting ? '재료 선택' : '나의 냉장고',
                    style: TextStyle(
                      color: brightness == Brightness.dark
                          ? Colors.white
                          : _figmaTextPrimary,
                      fontSize: 19,
                      fontFamily: 'Pretendard',
                      fontWeight: FontWeight.w900,
                      height: 24 / 19,
                      letterSpacing: -0.40,
                    ),
                  ),
                ),
                if (!_isFridgeSelecting && totalCount > 0) ...[
                  const SizedBox(width: 8),
                  Container(
                    height: 20,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF6B35),
                      borderRadius: BorderRadius.circular(100),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '$totalCount',
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        height: 16.5 / 11,
                      ),
                    ),
                  ),
                ],
                if (_isFridgeSelecting) ...[
                  const SizedBox(width: 8),
                  Container(
                    height: 20,
                    padding: const EdgeInsets.symmetric(horizontal: 7),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF6422).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(100),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '$selectedCount개 선택',
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFFFF6422),
                        height: 16.5 / 11,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (totalCount > 0 || _isFridgeSelecting)
            _buildFridgeManageHeaderActions(
              brightness,
              fridgeData,
              totalCount: totalCount,
            ),
        ],
      ),
    );
  }

  Widget _buildFridgeManageHeaderActions(
    Brightness brightness,
    Map<String, dynamic>? fridgeData, {
    required int totalCount,
  }) {
    if (_isFridgeSelecting) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _FridgeHeaderTextButton(
            label: '전체',
            onTap: () => _toggleSelectAllVisibleFridgeIngredients(fridgeData),
          ),
          const SizedBox(width: 4),
          _FridgeHeaderTextButton(
            label: '완료',
            emphasized: true,
            onTap: _exitFridgeSelectionMode,
          ),
        ],
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: totalCount <= 0
          ? null
          : () {
              Haptics.light();
              _enterFridgeSelectionMode(selectAll: true, fridgeData: fridgeData);
            },
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: brightness == Brightness.dark
              ? Colors.white.withValues(alpha: 0.08)
              : const Color(0xFFF5F6F8),
          borderRadius: BorderRadius.circular(999),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.checklist_rounded, size: 15, color: Color(0xFF4E5968)),
            SizedBox(width: 4),
            Text(
              '관리',
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.2,
                color: Color(0xFF4E5968),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _enterFridgeSelectionMode({
    bool selectAll = false,
    Map<String, dynamic>? fridgeData,
  }) {
    setState(() {
      _isFridgeSelecting = true;
      _selectedFridgeIndices.clear();
      if (selectAll) {
        _selectedFridgeIndices.addAll(_allLeftoverFridgeIndices(fridgeData));
      }
    });
  }

  void _exitFridgeSelectionMode() {
    setState(() {
      _isFridgeSelecting = false;
      _selectedFridgeIndices.clear();
    });
  }

  void _toggleFridgeIngredientSelection(int fridgeIndex) {
    if (fridgeIndex < 0) return;
    setState(() {
      if (_selectedFridgeIndices.contains(fridgeIndex)) {
        _selectedFridgeIndices.remove(fridgeIndex);
      } else {
        _selectedFridgeIndices.add(fridgeIndex);
      }
    });
  }

  void _toggleFridgeIngredientGroupSelection(List<int> indices) {
    final valid = indices.where((i) => i >= 0).toSet();
    if (valid.isEmpty) return;
    setState(() {
      final allSelected = valid.every(_selectedFridgeIndices.contains);
      if (allSelected) {
        _selectedFridgeIndices.removeAll(valid);
      } else {
        _selectedFridgeIndices.addAll(valid);
      }
    });
  }

  /// 현재 필터와 무관하게, 화면에 남는 재료(leftover > 0) 인덱스 목록.
  List<int> _allLeftoverFridgeIndices(Map<String, dynamic>? fridgeData) {
    if (fridgeData == null) return const [];
    final ingredients =
        (fridgeData['ingredients'] as List?)?.cast<Map<String, dynamic>>() ??
        [];
    final recipes =
        (fridgeData['recipes'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final usedQty = <String, double>{};
    final usedQtyByBatch = <String, double>{};
    for (final recipe in recipes) {
      final batchId = recipe['purchaseBatchId']?.toString();
      final ings =
          (recipe['ingredients'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      for (final ing in ings) {
        final name = (ing['item'] ?? ing['name'])?.toString() ?? '';
        if (name.isEmpty) continue;
        final qty = _shoppingQtyForRecipeIngredient(ing, name);
        if (batchId != null && batchId.isNotEmpty) {
          final key = '$batchId|$name';
          usedQtyByBatch[key] = (usedQtyByBatch[key] ?? 0) + qty;
        } else {
          usedQty[name] = (usedQty[name] ?? 0) + qty;
        }
      }
    }

    final indices = <int>[];
    for (var i = 0; i < ingredients.length; i++) {
      if (_optimisticallyDeletedFridgeIndices.contains(i)) continue;
      final ing = ingredients[i];
      final name = ing['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      final orderQty = (ing['totalQty'] as num?)?.toDouble() ?? 0;
      final adjusted = (ing['adjustedUsedQty'] as num?)?.toDouble();
      final batchId = ing['purchaseBatchId']?.toString();
      final batchKey =
          (batchId != null && batchId.isNotEmpty) ? '$batchId|$name' : null;
      final recipeUsed = batchKey != null
          ? usedQtyByBatch[batchKey] ?? 0
          : usedQty[name] ?? 0;
      final effectiveUsed = adjusted ?? recipeUsed;
      final left = orderQty - effectiveUsed;
      if (left > 0) indices.add(i);
    }
    return indices;
  }

  void _toggleSelectAllVisibleFridgeIngredients(
    Map<String, dynamic>? fridgeData,
  ) {
    final all = _allLeftoverFridgeIndices(fridgeData).toSet();
    if (all.isEmpty) return;
    setState(() {
      final allSelected = all.every(_selectedFridgeIndices.contains);
      if (allSelected) {
        _selectedFridgeIndices.clear();
      } else {
        _selectedFridgeIndices
          ..clear()
          ..addAll(all);
      }
    });
  }

  /// Figma 97-4514: "My Fridge" (Caveat 16 orange) + "냉장고" (Inter 23 w800).
  /// Loads recipe meta (time, thumbnail, servings) only for fridge recipe IDs in parallel, then builds the tab.
  Map<String, List<_FridgeRecipeIngredientLink>> _buildRecipeLinksByIngredient(
    List<Map<String, dynamic>> recipes,
  ) {
    final out = <String, List<_FridgeRecipeIngredientLink>>{};
    for (final recipe in recipes) {
      final recipeId = recipe['recipeId']?.toString() ?? '';
      final recipeName = recipe['recipeName']?.toString() ?? '레시피';
      final date = recipe['date']?.toString();
      final batchId = recipe['purchaseBatchId']?.toString();
      final ingredients =
          (recipe['ingredients'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      for (final ing in ingredients) {
        final name = (ing['item'] ?? ing['name'])?.toString() ?? '';
        if (name.isEmpty) continue;
        final key = (batchId != null && batchId.isNotEmpty)
            ? '$batchId|$name'
            : name;
        out.putIfAbsent(key, () => []);
        final requiredQty = _shoppingQtyForRecipeIngredient(ing, name);
        final requiredUnit = _shoppingUnitForRecipeIngredient(ing, name);
        final existingIdx = out[key]!.indexWhere((link) => link.recipeId == recipeId);
        if (existingIdx >= 0) {
          final prev = out[key]![existingIdx];
          out[key]![existingIdx] = _FridgeRecipeIngredientLink(
            recipeId: recipeId,
            recipeName: recipeName,
            date: date,
            requiredQty: prev.requiredQty + requiredQty,
            unit: requiredUnit,
          );
        } else {
          out[key]!.add(
            _FridgeRecipeIngredientLink(
              recipeId: recipeId,
              recipeName: recipeName,
              date: date,
              requiredQty: requiredQty,
              unit: requiredUnit,
        ),
      );
    }
      }
    }
    for (final links in out.values) {
      links.sort((a, b) {
        final ad = a.date ?? '';
        final bd = b.date ?? '';
        if (ad != bd) return ad.compareTo(bd);
        return a.recipeName.compareTo(b.recipeName);
      });
    }
    return out;
  }

  String _formatFridgeIngredientAmount(double qty, String unit) {
    final normalized = unit.trim();
    if (normalized.toLowerCase() == 'g' && qty >= 1000) {
      final kg = qty / 1000;
      final text = kg % 1 == 0 ? '${kg.toInt()}' : kg.toStringAsFixed(1);
      return '${text}kg';
    }
    if (normalized.toLowerCase() == 'ml' && qty >= 1000) {
      final l = qty / 1000;
      final text = l % 1 == 0 ? '${l.toInt()}' : l.toStringAsFixed(1);
      return '${text}L';
    }
    final amount = _formatQuantityLabel(qty);
    return '$amount${_truncateUnit(normalized.isEmpty ? '개' : normalized, 8)}';
  }

  /// Opens review screen first; when user returns (submit or skip), runs 요리 완료.
  Future<void> _showCookingCompleteConfirmDialog(
    BuildContext context,
    Map<String, dynamic> recipe,
    Map<String, dynamic>? fridgeData,
    Brightness brightness,
  ) async {
    final rawId = recipe['recipeId'] ?? recipe['id'];
    final recipeId = rawId?.toString().trim();
    if (recipeId == null || recipeId.isEmpty) {
      await _onCookingComplete(recipe, fridgeData);
      return;
    }
    final parseResponse = await _recipeService.getRecipeById(recipeId);
    if (parseResponse == null || !context.mounted) {
      await _onCookingComplete(recipe, fridgeData);
      return;
    }
    final source = parseResponse.source;
    final recipeModel = parseResponse.recipe;
    String creatorUsername = '@ChefAntoine';
    final uploader = source['uploader'] as String? ?? '';
    final channel = source['channel'] as String? ?? '';
    if (uploader.isNotEmpty) {
      creatorUsername = uploader.startsWith('@') ? uploader : '@$uploader';
    } else if (channel.isNotEmpty) {
      creatorUsername = channel.startsWith('@') ? channel : '@$channel';
    }
    final platform = source['platform'] as String? ?? '';
    final thumbnailUrl = source['thumbnail'] as String?;
    final recipeTitle = recipeModel.name ?? '레시피';
    final servingsFromCart =
        (recipe['servings'] as num?)?.toInt() ?? recipeModel.servings ?? 2;

    final completeCooking = await showProgressiveRecipeReviewPopup(
      context,
      recipeId: recipeId,
      recipeTitle: recipeTitle,
      creatorUsername: creatorUsername,
      platform: platform,
      thumbnailUrl: thumbnailUrl,
      servings: servingsFromCart,
      fromFridgeCookingComplete: true,
    );
    if (context.mounted && completeCooking == true) {
      await _onCookingComplete(recipe, fridgeData);
    }
  }

  /// Remove this recipe and its ingredients from fridge (요리 완료).
  Future<void> _onCookingComplete(
    Map<String, dynamic> recipe,
    Map<String, dynamic>? fridgeData,
  ) async {
    final user = _authService.currentUser;
    if (user == null || fridgeData == null) return;

    final rawId = recipe['recipeId'] ?? recipe['id'];
    final recipeIdForAnalytics = rawId?.toString().trim();
    unawaited(
      AnalyticsService().trackCookingCompleted(
        recipeId: recipeIdForAnalytics,
        sourceScreen: 'fridge',
      ),
    );

    final recipes =
        (fridgeData['recipes'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final ingredients =
        (fridgeData['ingredients'] as List?)?.cast<Map<String, dynamic>>() ??
        [];
    final recipeId = recipeIdForAnalytics;
    if (recipeId == null || recipeId.isEmpty) return;

    // Quantities used by this recipe (in shopping units, matching totalQty)
    final usedByRecipe = <String, double>{};
    final ings =
        (recipe['ingredients'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    for (final ing in ings) {
      final name = (ing['item'] ?? ing['name'])?.toString() ?? '';
      if (name.isEmpty) continue;
      final qty = _shoppingQtyForRecipeIngredient(ing, name);
      usedByRecipe[name] = (usedByRecipe[name] ?? 0) + qty;
    }

    // Subtract used quantities from ingredient totalQty
    final updatedIngredients = ingredients.map((ing) {
      final name = ing['name']?.toString() ?? '';
      final used = usedByRecipe[name];
      if (used == null || used <= 0) return ing;
      final currentTotal = (ing['totalQty'] as num?)?.toDouble() ?? 0;
      final newTotal = (currentTotal - used).clamp(0.0, double.infinity);
      return {...ing, 'totalQty': newTotal};
    }).toList();

    // Remove the recipe from the list
    final newRecipes = recipes
        .where((r) => r['recipeId']?.toString() != recipeId)
        .toList();

    try {
      await _userService.saveFridgeData(
        user.uid,
        ingredients: updatedIngredients,
        recipes: newRecipes,
      );
      await _mealPlanService.markRecipeCompletedForToday(recipeId);
      if (mounted) {
        showAppSnackBar(context, 
          const SnackBar(
            content: Text('요리 완료로 재료를 냉장고에서 제거했습니다'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 
          SnackBar(content: Text('저장 실패: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _openRecipeCooking(Map<String, dynamic> recipeData) async {
    final recipeId = recipeData['recipeId']?.toString();
    if (recipeId == null) return;
    unawaited(_mealPlanService.markRecipeStartedForToday(recipeId));
    final parseResponse = await _recipeService.getRecipeById(recipeId);
    if (parseResponse == null || !mounted) return;
    // From fridge we want the same flow as tapping "요리 시작하기"
    // in the recipe detail screen's 요리법 tab: open CookingInstructionSheet.
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CookingInstructionSheet(
          recipe: parseResponse.recipe,
          recipeId: recipeId,
          source: parseResponse.source,
        ),
      ),
    );
  }

  /// Open the full recipe detail page when the user taps a fridge recipe card
  /// (image/title area, but not the action buttons). Mirrors the tap flow used
  /// elsewhere in the app (home/explore/cart).
  Future<void> _openRecipeDetail(Map<String, dynamic> recipeData) async {
    final recipeId = recipeData['recipeId']?.toString();
    if (recipeId == null || recipeId.isEmpty) return;
    final parseResponse = await _recipeService.getRecipeById(recipeId);
    if (parseResponse == null || !mounted) return;
    Navigator.pushNamed(
      context,
      '/recipe-detail',
      arguments: {'parseResponse': parseResponse, 'recipeId': recipeId},
    );
  }

  /// Figma 177-346: 남을 재료 layout — AI card (hardcoded) + category sections from account data
  void _openIngredientRecommendation(List<Map<String, dynamic>> items) {
    final seen = <String>{};
    final ingredients = <RecommendableIngredient>[];
    for (final it in items) {
      final name = (it['name'] ?? '').toString().trim();
      if (name.isEmpty || !seen.add(name)) continue;
      // 카탈로그 미매칭 재료(예: 영수증 스캔에서 DB에 없어 추가된 항목)는
      // 레시피 추천 입력에서 제외한다. 냉장고 목록/사용 기록에는 그대로 남는다.
      final catalogMatched = (it['catalogMatched'] as bool?) ?? true;
      if (!catalogMatched) continue;
      final qty = (it['leftoverQty'] as num?)?.toDouble();
      final unitRaw = it['unit']?.toString();
      ingredients.add(
        RecommendableIngredient(
          name: name,
          amountLeft: qty,
          unit: (unitRaw == null || unitRaw.isEmpty) ? null : unitRaw,
        ),
      );
    }
    if (ingredients.isEmpty) return;
    showFridgeRecipeRecommendationSheet(
      context,
      ingredients: ingredients,
      onOpenRecipe: (recipeId) => _openRecipeDetail({'recipeId': recipeId}),
    );
  }

  Widget _buildLeftoverTab(
    BuildContext context,
    Brightness brightness,
    Map<String, dynamic>? fridgeData,
  ) {
    final ingredients =
        (fridgeData?['ingredients'] as List?)?.cast<Map<String, dynamic>>() ??
        [];
    final recipes =
        (fridgeData?['recipes'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final recipeLinksByIngredient = _buildRecipeLinksByIngredient(recipes);

    // Total used per ingredient = sum of 필요 (qty) from each recipe. Editing 필요 in 사용할 재료 changes this.
    final usedQty = <String, double>{};
    final usedQtyByBatch = <String, double>{};
    for (final r in recipes) {
      final batchId = r['purchaseBatchId']?.toString();
      final ings =
          (r['ingredients'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      for (final ing in ings) {
        final name = (ing['item'] ?? ing['name'])?.toString() ?? '';
        if (name.isEmpty) continue;
        final qty = _shoppingQtyForRecipeIngredient(ing, name);
        if (batchId != null && batchId.isNotEmpty) {
          final key = '$batchId|$name';
          usedQtyByBatch[key] = (usedQtyByBatch[key] ?? 0) + qty;
        } else {
        usedQty[name] = (usedQty[name] ?? 0) + qty;
        }
      }
    }

    // Same category order and display names as recipe detail (재료 tab).
    // Stored category can be missing; we backfill via API, but still show a
    // best-effort unified group immediately via heuristics.
    final leftoverByCategory = <String, List<Map<String, dynamic>>>{
      '유통기한 지남': [],
      '유통기한 임박': [],
      for (final key in IngredientCategoryUnifier.groupOrder)
        IngredientCategoryUnifier.titleFromKey(key): [],
    };

    // Leftover = 주문 − sum(필요 from each recipe). So changing 필요 in 사용할 재료 updates 남을 재료.
    // Route expired and imminent ingredients into separate quick-filter buckets.
    const int imminentThreshold = 3;
    int uncategorizedCount = 0;

    // Fallback purchase date from fridgeData.lastSentAt (Firestore Timestamp).
    DateTime? fridgeLastSentAt;
    final rawLastSent = fridgeData?['lastSentAt'];
    if (rawLastSent is Timestamp) {
      fridgeLastSentAt = rawLastSent.toDate();
    }

    final shelfLifeService = IngredientShelfLifeService.instance;

    for (var i = 0; i < ingredients.length; i++) {
      final ing = ingredients[i];
      final name = ing['name']?.toString() ?? '';
      final orderQty = (ing['totalQty'] as num?)?.toDouble() ?? 0;
      final batchId = ing['purchaseBatchId']?.toString();
      final batchKey = batchId == null || batchId.isEmpty
          ? null
          : '$batchId|$name';
      final usedFromRecipes = batchKey == null
          ? usedQty[name] ?? 0
          : usedQtyByBatch[batchKey] ?? 0;
      final adjustedUsed = (ing['adjustedUsedQty'] as num?)?.toDouble();
      final effectiveUsed = adjustedUsed ?? usedFromRecipes;
      final left = orderQty - effectiveUsed;
      if (left <= 0) continue;

      // Parse purchasedAt — supports full ISO timestamp or date-only (legacy).
      final purchasedAtStr = ing['purchasedAt']?.toString();
      DateTime? orderTime;
      if (purchasedAtStr != null && purchasedAtStr.isNotEmpty) {
        try {
          orderTime = DateTime.parse(purchasedAtStr);
        } catch (_) {}
      }
      // Legacy fallback: fridgeLastSentAt as approximate order time.
      orderTime ??= fridgeLastSentAt;

      final knownInfo = shelfLifeService.lookup(name);

      // 배송중 상태 제거: 구매·추가 직후부터 보유 재료로 보고 D-day를 계산한다.
      const isDelivering = false;
      DateTime? deliveredAt;
      final deliveredAtStr = ing['deliveredAt']?.toString();
      if (deliveredAtStr != null && deliveredAtStr.isNotEmpty) {
        try {
          deliveredAt = DateTime.parse(deliveredAtStr);
        } catch (_) {}
      }
      final shelfLifeStart = deliveredAt ?? orderTime ?? DateTime.now();

      int? daysUntilExpiry;
      if (knownInfo != null) {
        final expiryDate = shelfLifeStart.add(
          Duration(days: knownInfo.shelfLifeDays),
        );
        final today = DateTime(
          DateTime.now().year,
          DateTime.now().month,
          DateTime.now().day,
        );
        final expiryDay = DateTime(
          expiryDate.year,
          expiryDate.month,
          expiryDate.day,
        );
        daysUntilExpiry = expiryDay.difference(today).inDays;
      } else {
        daysUntilExpiry = _daysUntilExpiry(ing['expiryDate']?.toString());
      }

      final effectiveStorageType =
          knownInfo?.storageType.firestoreValue ??
          ing['storageType']?.toString();

      final item = {
        ...ing,
        'orderQty': orderQty,
        'usedQty': effectiveUsed,
        'leftoverQty': left,
        'daysUntilExpiry': daysUntilExpiry,
        'storageType': effectiveStorageType,
        'isDelivering': isDelivering,
        '_fridgeIndex': i,
        'recipeLinks':
            (batchKey == null
                ? recipeLinksByIngredient[name]
                : recipeLinksByIngredient[batchKey]) ??
            const [],
      };
        final storedCat = ing['category']?.toString();
        if (storedCat == null || storedCat.isEmpty) uncategorizedCount++;
        final groupKey = _categorizeIngredient(name, storedCat);
        final category = IngredientCategoryUnifier.titleFromKey(groupKey);
      if (daysUntilExpiry != null && daysUntilExpiry < 0) {
        leftoverByCategory['유통기한 지남']!.add(item);
      } else if (daysUntilExpiry != null &&
          daysUntilExpiry <= imminentThreshold) {
        leftoverByCategory['유통기한 임박']!.add(item);
      }
        final list = leftoverByCategory[category];
        if (list != null) list.add(item);
    }
    if (uncategorizedCount > 0 && fridgeData != null) {
      final backfillKey = _leftoverBackfillKey(fridgeData);
      if (_categoryBackfillKey != backfillKey) {
        final dataToBackfill = Map<String, dynamic>.from(fridgeData);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _categoryBackfillKey = backfillKey;
          _backfillIngredientCategories(dataToBackfill);
        });
      }
    }

    // Filter out optimistically deleted ingredients (by fridge index) so count and list update immediately
    final displayedLeftoverByCategory =
        Map<String, List<Map<String, dynamic>>>.fromEntries(
          leftoverByCategory.entries.map(
            (e) => MapEntry(
              e.key,
              e.value.where((ing) {
                final idx = ing['_fridgeIndex'];
                return idx == null ||
                    !_optimisticallyDeletedFridgeIndices.contains(idx as int?);
              }).toList(),
            ),
          ),
        );
    // Remove from optimistic set when server data confirms deletion (ingredient at that index has leftover <= 0)
    final indicesStillInLeftover = leftoverByCategory.values
        .expand((l) => l)
        .map((ing) => ing['_fridgeIndex'] as int?)
        .whereType<int>()
        .toSet();
    final toRemove = _optimisticallyDeletedFridgeIndices
        .where((idx) => !indicesStillInLeftover.contains(idx))
        .toList();
    if (toRemove.isNotEmpty && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            for (final idx in toRemove) {
              _optimisticallyDeletedFridgeIndices.remove(idx);
              _selectedFridgeIndices.remove(idx);
            }
          });
        }
      });
    }

    final hasAny = displayedLeftoverByCategory.values.any((l) => l.isNotEmpty);
    if (!hasAny) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.restaurant_menu_rounded,
              size: 28,
              color: AppColors.getTextTertiary(
                brightness,
              ).withValues(alpha: 0.5),
            ),
            const SizedBox(height: 10),
            Text(
              '아직 남은 재료가 없어요',
              style: TextStyle(
                fontSize: 14,
                color: AppColors.getTextTertiary(brightness),
              ),
            ),
          ],
        ),
      );
    }

    bool isStandaloneLeftover(Map<String, dynamic> item) {
      final links = item['recipeLinks'] as List?;
      return links == null || links.isEmpty;
    }

    final allCategoryEntries = displayedLeftoverByCategory.entries
        .where(
          (entry) =>
              entry.key != '유통기한 지남' &&
              entry.key != '유통기한 임박' &&
              entry.value.isNotEmpty,
        )
        .toList();
    final allIngredientItems = allCategoryEntries
        .expand((entry) => entry.value)
        .toList();
    final standaloneLeftoverItems = allIngredientItems
        .where(isStandaloneLeftover)
        .toList();
    final normalCategoryEntries = displayedLeftoverByCategory.entries
        .where(
          (entry) =>
              entry.key != '유통기한 지남' &&
              entry.key != '유통기한 임박' &&
              entry.value.isNotEmpty,
        )
        .toList();
    final currentViewIngredientItems = normalCategoryEntries
        .expand((entry) => entry.value)
        .toList();
    final imminentItems =
        displayedLeftoverByCategory['유통기한 임박'] ??
        const <Map<String, dynamic>>[];
    final expiredItems =
        displayedLeftoverByCategory['유통기한 지남'] ??
        const <Map<String, dynamic>>[];
    // '남은 재료'(레시피 미배정)도 카테고리별로 묶어, '전체'와 동일하게
    // 하위 카테고리 pill / 섹션 분리를 지원한다.
    final standaloneCategoryEntries = normalCategoryEntries
        .map(
          (entry) => MapEntry(
            entry.key,
            entry.value.where(isStandaloneLeftover).toList(),
          ),
        )
        .where((entry) => entry.value.isNotEmpty)
        .toList();

    const standalonePrefix = 'standalone::';
    final validKeys = <String>{
      'all',
      if (standaloneLeftoverItems.isNotEmpty) 'standalone',
      if (expiredItems.isNotEmpty) '유통기한 지남',
      if (imminentItems.isNotEmpty) '유통기한 임박',
      ...normalCategoryEntries.map((e) => e.key),
      ...standaloneCategoryEntries.map((e) => standalonePrefix + e.key),
    };
    final requestedFilterKey = _selectedIngredientFilterKey ?? 'all';
    final selectedKey = validKeys.contains(requestedFilterKey)
        ? requestedFilterKey
        : 'all';
    final isStandaloneScope =
        selectedKey == 'standalone' || selectedKey.startsWith(standalonePrefix);

    // 윗줄: 스코프(전체·남은 재료) + 유통기한 경고(기한지남·임박)
    final scopeAndTimeOptions = <_FridgeIngredientFilterOption>[
      _FridgeIngredientFilterOption(
        key: 'all',
        label: '전체',
        count: _distinctIngredientCount(currentViewIngredientItems),
      ),
      if (standaloneLeftoverItems.isNotEmpty)
        _FridgeIngredientFilterOption(
          key: 'standalone',
          label: '남은 재료',
          count: _distinctIngredientCount(standaloneLeftoverItems),
        ),
      if (expiredItems.isNotEmpty)
        _FridgeIngredientFilterOption(
          key: '유통기한 지남',
          label: '기한지남',
          count: _distinctIngredientCount(expiredItems),
        ),
      if (imminentItems.isNotEmpty)
        _FridgeIngredientFilterOption(
          key: '유통기한 임박',
          label: '임박',
          count: _distinctIngredientCount(imminentItems),
        ),
    ];

    // 아랫줄: 현재 스코프('전체' 또는 '남은 재료')에 맞는 하위 카테고리 pill
    final categoryOptions = isStandaloneScope
        ? standaloneCategoryEntries
              .map(
                (entry) => _FridgeIngredientFilterOption(
                  key: standalonePrefix + entry.key,
                  label: entry.key,
                  count: _distinctIngredientCount(entry.value),
                ),
              )
              .toList()
        : normalCategoryEntries
              .map(
                (entry) => _FridgeIngredientFilterOption(
                  key: entry.key,
                  label: entry.key,
                  count: _distinctIngredientCount(entry.value),
                ),
              )
              .toList();

    // 현재 선택에 따른 표시 대상
    final selectedItems = <Map<String, dynamic>>[];
    if (selectedKey != 'all' && selectedKey != 'standalone') {
      if (selectedKey.startsWith(standalonePrefix)) {
        final cat = selectedKey.substring(standalonePrefix.length);
        final match = standaloneCategoryEntries.where((e) => e.key == cat);
        if (match.isNotEmpty) selectedItems.addAll(match.first.value);
      } else {
        selectedItems.addAll(
          displayedLeftoverByCategory[selectedKey] ??
              const <Map<String, dynamic>>[],
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 고정 영역: 필터 pill ──
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: _fridgeScreenPaddingH,
          ),
          child: _buildIngredientFilterPills(
            scopeAndTimeOptions,
            categoryOptions,
            selectedKey,
            isStandaloneScope,
          ),
        ),
        // ── 스크롤 영역: 재료 목록 (남은 재료 안내 문구도 함께 스크롤) ──
        Expanded(
          child: ListView(
            controller: _fridgeListScrollController,
      padding: const EdgeInsets.fromLTRB(
        _fridgeScreenPaddingH,
              14,
        _fridgeScreenPaddingH,
              118,
      ),
      children: [
              if (selectedKey == 'standalone') ...[
                _buildStandaloneLeftoverGuide(
                  _distinctIngredientCount(standaloneLeftoverItems),
                ),
                const SizedBox(height: 14),
              ],
              if (selectedKey == 'all')
                // 전체 보기: 카테고리별 섹션(헤더 + 그 아래 재료)으로 묶어서 표시
                if (normalCategoryEntries.isEmpty)
                  _buildStandaloneLeftoverEmptyState(brightness)
                else
                  ..._buildCategorySectionedList(
                    normalCategoryEntries,
          fridgeData,
                  )
              else if (selectedKey == 'standalone')
                // 남은 재료 전체: 카테고리별 섹션으로 묶어서 표시
                if (standaloneCategoryEntries.isEmpty)
                  _buildStandaloneLeftoverEmptyState(brightness)
                else
                  ..._buildCategorySectionedList(
                    standaloneCategoryEntries,
                    fridgeData,
                  )
              else if (selectedItems.isEmpty)
                _buildStandaloneLeftoverEmptyState(brightness)
              else
                // 기한지남·임박·상세 카테고리도 '전체'와 동일하게 섹션으로 표시
                ..._buildCategorySectionedList(
                  _groupItemsByCategorySections(selectedItems),
                  fridgeData,
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 임의의 재료 목록을 음식 카테고리(groupOrder) 기준으로 묶어
  /// '전체' 섹션 표시와 동일한 형식으로 반환한다.
  List<MapEntry<String, List<Map<String, dynamic>>>>
  _groupItemsByCategorySections(List<Map<String, dynamic>> items) {
    final byTitle = <String, List<Map<String, dynamic>>>{};
    for (final item in items) {
      final name = (item['name'] ?? '').toString();
      final storedCat = item['category']?.toString();
      final groupKey = _categorizeIngredient(name, storedCat);
      final title = IngredientCategoryUnifier.titleFromKey(groupKey);
      (byTitle[title] ??= <Map<String, dynamic>>[]).add(item);
    }
    final ordered = <MapEntry<String, List<Map<String, dynamic>>>>[];
    for (final key in IngredientCategoryUnifier.groupOrder) {
      final title = IngredientCategoryUnifier.titleFromKey(key);
      final list = byTitle[title];
      if (list != null && list.isNotEmpty) {
        ordered.add(MapEntry(title, list));
      }
    }
    return ordered;
  }

  /// 전체 보기에서 카테고리별로 헤더 + 그리드를 묶어 반환한다.
  List<Widget> _buildCategorySectionedList(
    List<MapEntry<String, List<Map<String, dynamic>>>> categoryEntries,
    Map<String, dynamic>? fridgeData,
  ) {
    final widgets = <Widget>[];
    for (var i = 0; i < categoryEntries.length; i++) {
      final entry = categoryEntries[i];
      if (entry.value.isEmpty) continue;
      if (widgets.isNotEmpty) widgets.add(const SizedBox(height: 20));
      widgets.add(
        _buildCategorySectionHeader(
          entry.key,
          _distinctIngredientCount(entry.value),
        ),
      );
      widgets.add(const SizedBox(height: 10));
      widgets.add(
        _buildFridgeIngredientGroupGrid(
          _groupFridgeIngredientBatches(entry.value),
          fridgeData,
          showCategoryLabel: false,
        ),
      );
    }
    return widgets;
  }

  Widget _buildCategorySectionHeader(String title, int count) {
    final key = IngredientCategoryUnifier.groupOrder.firstWhere(
      (k) => IngredientCategoryUnifier.titleFromKey(k) == title,
      orElse: () => IngredientCategoryUnifier.vegFruit,
    );
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Row(
        children: [
          IngredientCategoryUnifier.buildCategoryIcon(key: key, size: 18),
          const SizedBox(width: 6),
          Text(
            title,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 14.5,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.3,
              color: Color(0xFF191F28),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: Color(0xFF9AA3AF),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFridgeIngredientGroupGrid(
    List<_FridgeIngredientBatchGroup> groups,
    Map<String, dynamic>? fridgeData, {
    bool showCategoryLabel = true,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = (constraints.maxWidth - 10) / 2;
        final rows = <Widget>[];
        for (var i = 0; i < groups.length; i += 2) {
          final rowGroups = groups.skip(i).take(2).toList();
          rows.add(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: itemWidth,
                  child: _buildFridgeIngredientGroupTile(
                    rowGroups[0],
                    fridgeData,
                    showCategoryLabel: showCategoryLabel,
                  ),
                ),
                if (rowGroups.length > 1) ...[
                  const SizedBox(width: 10),
                  SizedBox(
                    width: itemWidth,
                    child: _buildFridgeIngredientGroupTile(
                      rowGroups[1],
                      fridgeData,
                      showCategoryLabel: showCategoryLabel,
                    ),
                  ),
                ],
              ],
            ),
          );

          for (final group in rowGroups) {
            if (_isFridgeSelecting) continue;
            final expanded = _expandedIngredientBatchGroups.contains(group.key);
            if (expanded && group.items.length > 1) {
              rows.add(
                _FridgeIngredientBatchExpansionPanel(
                  key: ValueKey('expanded-${group.key}'),
                  group: group,
                  buildBatchCard: (ing) => _buildFridgeIngredientGridCard(
                    ing,
                    fridgeData,
                    compact: true,
                    showCategoryLabel: showCategoryLabel,
                  ),
                ),
              );
            }
          }

          if (i + 2 < groups.length) {
            rows.add(const SizedBox(height: 10));
          }
        }

        return AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: Column(children: rows),
        );
      },
    );
  }

  Widget _buildFridgeIngredientGroupTile(
    _FridgeIngredientBatchGroup group,
    Map<String, dynamic>? fridgeData, {
    bool showCategoryLabel = true,
  }) {
    if (group.items.length == 1) {
      return _buildFridgeIngredientGridCard(
        group.items.first,
        fridgeData,
        showCategoryLabel: showCategoryLabel,
      );
    }
    final indices = group.items
        .map((ing) => ing['_fridgeIndex'] as int? ?? -1)
        .where((i) => i >= 0)
        .toList();
    if (_isFridgeSelecting) {
      final selectedCount =
          indices.where(_selectedFridgeIndices.contains).length;
      return _FridgeIngredientBatchGroupCard(
        group: group,
        expanded: false,
        includeExpandedPanel: false,
        showCategory: showCategoryLabel,
        selectionMode: true,
        selectedCount: selectedCount,
        onToggle: () => _toggleFridgeIngredientGroupSelection(indices),
        buildBatchCard: (ing) => _buildFridgeIngredientGridCard(
          ing,
          fridgeData,
          compact: true,
          showCategoryLabel: showCategoryLabel,
        ),
      );
    }
    final expanded = _expandedIngredientBatchGroups.contains(group.key);
    return _FridgeIngredientBatchGroupCard(
      group: group,
      expanded: expanded,
      includeExpandedPanel: false,
      showCategory: showCategoryLabel,
      onToggle: () => setState(() {
        if (expanded) {
          _expandedIngredientBatchGroups.remove(group.key);
        } else {
          _expandedIngredientBatchGroups.add(group.key);
        }
      }),
      buildBatchCard: (ing) => _buildFridgeIngredientGridCard(
        ing,
        fridgeData,
        compact: true,
        showCategoryLabel: showCategoryLabel,
      ),
    );
  }

  List<_FridgeIngredientBatchGroup> _groupFridgeIngredientBatches(
    List<Map<String, dynamic>> items,
  ) {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final ing in items) {
      final name = ing['name']?.toString() ?? '';
      final categoryKey = _categorizeIngredient(
        name,
        ing['category']?.toString(),
      );
      final key = '$categoryKey|$name';
      grouped.putIfAbsent(key, () => []).add(ing);
    }

    return grouped.entries.map((entry) {
      final groupItems = [...entry.value];
      groupItems.sort((a, b) {
        final ad = a['daysUntilExpiry'] as int?;
        final bd = b['daysUntilExpiry'] as int?;
        if (ad != null && bd != null && ad != bd) return ad.compareTo(bd);
        if (ad != null) return -1;
        if (bd != null) return 1;
        final ap = a['purchasedAt']?.toString() ?? '';
        final bp = b['purchasedAt']?.toString() ?? '';
        return bp.compareTo(ap);
      });
      final first = groupItems.first;
      final name = first['name']?.toString() ?? '';
      final categoryKey = _categorizeIngredient(
        name,
        first['category']?.toString(),
      );
      return _FridgeIngredientBatchGroup(
        key: entry.key,
        name: name,
        categoryKey: categoryKey,
        items: groupItems,
      );
    }).toList();
  }

  Widget _buildFridgeIngredientGridCard(
    Map<String, dynamic> ing,
    Map<String, dynamic>? fridgeData, {
    bool compact = false,
    bool showCategoryLabel = true,
  }) {
    final name = ing['name']?.toString() ?? '';
    final fridgeIndex = ing['_fridgeIndex'] as int? ?? -1;
    final left = (ing['leftoverQty'] as num?)?.toDouble() ?? 0;
    final orderQty = (ing['orderQty'] as num?)?.toDouble() ?? 0;
    final unit = ing['unit']?.toString() ?? '개';
    final imageUrl = ing['productImageUrl']?.toString() ?? '';
    final daysUntilExpiry = ing['daysUntilExpiry'] as int?;
    final isDelivering = ing['isDelivering'] as bool? ?? false;
    final recipeLinks =
        (ing['recipeLinks'] as List?)?.cast<_FridgeRecipeIngredientLink>() ??
        const <_FridgeRecipeIngredientLink>[];
    final categoryKey = _categorizeIngredient(
      name,
      ing['category']?.toString(),
    );
    return _FridgeIngredientGridCard(
      key: ValueKey<int>(fridgeIndex),
      name: name,
      amount: left,
      unit: unit,
      imageUrl: imageUrl,
      daysUntilExpiry: daysUntilExpiry,
      isDelivering: isDelivering,
      recipeLinks: recipeLinks,
      categoryKey: categoryKey,
      orderQty: orderQty,
      fridgeIndex: fridgeIndex,
      compact: compact,
      showCategory: showCategoryLabel,
      selectionMode: _isFridgeSelecting,
      selected: fridgeIndex >= 0 && _selectedFridgeIndices.contains(fridgeIndex),
      onToggleSelect: fridgeIndex < 0
          ? null
          : () => _toggleFridgeIngredientSelection(fridgeIndex),
      onResetFreshness: (_isFridgeSelecting || fridgeIndex < 0)
          ? null
          : () => _confirmAndResetIngredientFreshness(
              fridgeData,
              fridgeIndex,
              name,
            ),
      onAdjustLeftover: (_isFridgeSelecting || fridgeIndex < 0)
          ? null
          : (newAdjustedUsedQty) =>
                _onAdjustLeftover(fridgeData, fridgeIndex, newAdjustedUsedQty),
      onDelete: (_isFridgeSelecting || fridgeIndex < 0)
          ? null
          : () => _confirmAndDeleteIngredient(
              fridgeData,
              fridgeIndex,
              name,
              orderQty,
            ),
      onShowRecipes: (_isFridgeSelecting || recipeLinks.isEmpty)
          ? null
          : () => _showIngredientRecipeLinks(
              name,
              recipeLinks,
              orderQty,
              left,
              unit,
              fridgeData,
            ),
    );
  }

  void _showIngredientRecipeLinks(
    String ingredientName,
    List<_FridgeRecipeIngredientLink> links,
    double totalQty,
    double leftoverQty,
    String unit,
    Map<String, dynamic>? fridgeData,
  ) {
    if (links.isEmpty) return;
    final recipes =
        (fridgeData?['recipes'] as List?)?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];
    final recipeById = <String, Map<String, dynamic>>{
      for (final recipe in recipes)
        if ((recipe['recipeId']?.toString() ?? '').isNotEmpty)
          recipe['recipeId'].toString(): recipe,
    };
    final screenContext = context;
    final brightness = Theme.of(screenContext).brightness;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return SafeArea(
          top: false,
          child: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.86,
            ),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x1A000000),
                  blurRadius: 24,
                  offset: Offset(0, 10),
                ),
              ],
            ),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '$ingredientName 쓰는 요리',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.35,
                            color: Color(0xFF191F28),
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF2F4F6),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '${links.length}개',
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF6B7684),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ...links.map((link) {
                    final recipeData =
                        recipeById[link.recipeId] ??
                        {
                          'recipeId': link.recipeId,
                          'recipeName': link.recipeName,
                          'date': link.date,
                        };
                    final totalMinutes = (recipeData['totalMinutes'] as num?)
                        ?.toInt();
                    final servings =
                        (recipeData['servings'] as num?)?.toInt() ?? 1;
                    final dateStr = recipeData['date']?.toString();
                    final dateLabel = dateStr != null && dateStr.length >= 10
                        ? _formatFridgeDateFigma(dateStr)
                        : '';
                    final timeLabel = totalMinutes != null && totalMinutes > 0
                        ? '$totalMinutes분'
                        : '—분';
                    return Container(
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: const Color(0xFFE9EDF2),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GestureDetector(
                            onTap: () {
                              Navigator.pop(context);
                              _openRecipeDetail(recipeData);
                            },
                            behavior: HitTestBehavior.opaque,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  link.recipeName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 15.5,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: -0.35,
                                    color: Color(0xFF191F28),
                                  ),
                                ),
                                const SizedBox(height: 11),
                                Wrap(
                                  spacing: 7,
                                  runSpacing: 7,
                                  children: [
                                    if (dateLabel.isNotEmpty)
                                      _TinyIconPill(
                                        icon: Icons.calendar_today_rounded,
                                        label: dateLabel,
                                        color: const Color(0xFFFF6422),
                                        background: const Color(0xFFFFF6F1),
                                      ),
                                    _TinyIconPill(
                                      icon: Icons.schedule_rounded,
                                      label: timeLabel,
                                    ),
                                    _TinyIconPill(
                                      icon: Icons.group_rounded,
                                      label: '$servings인분',
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Expanded(
                                child: _RecipeSheetActionButton(
                                  label: '요리 시작',
                                  icon: Icons.play_arrow_rounded,
                                  filled: false,
                                  onTap: () {
                                    Navigator.pop(context);
                                    _openRecipeCooking(recipeData);
                                  },
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _RecipeSheetActionButton(
                                  label: '요리 완료',
                                  icon: Icons.check_circle_outline_rounded,
                                  filled: true,
                                  onTap: () {
                                    Navigator.pop(context);
                                    _showCookingCompleteConfirmDialog(
                                      screenContext,
                                      recipeData,
                                      fridgeData,
          brightness,
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 12),
                  _buildIngredientRecipeUsageSummary(
                    links: links,
                    totalQty: totalQty,
                    leftoverQty: leftoverQty,
                    unit: unit,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildIngredientRecipeUsageSummary({
    required List<_FridgeRecipeIngredientLink> links,
    required double totalQty,
    required double leftoverQty,
    required String unit,
  }) {
    final visibleLinks = links.take(3).toList();
    final extraCount = links.length - visibleLinks.length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFEDEFF3), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _IngredientUsageLedgerRow(
            label: '총량',
            value: _formatFridgeIngredientAmount(totalQty, unit),
            emphasized: true,
          ),
          const SizedBox(height: 9),
          ...visibleLinks.map(
            (link) => Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: _IngredientUsageLedgerRow(
                label: link.recipeName,
                value:
                    '-${_formatFridgeIngredientAmount(link.requiredQty, link.unit)}',
              ),
            ),
          ),
          if (extraCount > 0)
            Text(
              '외 $extraCount개 레시피',
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF8B95A1),
              ),
            ),
          const SizedBox(height: 9),
          Container(height: 1, color: const Color(0xFFEDEFF3)),
          const SizedBox(height: 9),
          _IngredientUsageLedgerRow(
            label: '남는 양',
            value: _formatFridgeIngredientAmount(leftoverQty, unit),
            emphasized: true,
            accent: true,
          ),
        ],
      ),
    );
  }

  Widget _buildStandaloneLeftoverGuide(int count) {
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Text(
        count > 0 ? '레시피에 아직 배정되지 않은 남은 재료만 모았어요' : '아직 따로 남은 재료는 없어요',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
          color: Color(0xFF8B95A1),
        ),
      ),
    );
  }

  Widget _buildStandaloneLeftoverEmptyState(Brightness brightness) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inventory_2_outlined,
            size: 26,
            color: AppColors.getTextTertiary(brightness),
          ),
          const SizedBox(height: 8),
          Text(
            '이 필터에 맞는 재료가 없어요',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.getTextSecondary(brightness),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '전체에서 다른 재료를 확인하거나 필터를 바꿔보세요',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: AppColors.getTextTertiary(brightness),
            ),
          ),
        ],
      ),
    );
  }

  /// 필터 pill을 2단으로 표시: 윗줄=스코프(전체/남은 재료)+유통기한(기한지남/임박),
  /// 아랫줄=현재 스코프의 하위 카테고리. '전체'와 '남은 재료' 모두 카테고리로 펼친다.
  Widget _buildIngredientFilterPills(
    List<_FridgeIngredientFilterOption> scopeAndTimeOptions,
    List<_FridgeIngredientFilterOption> categoryOptions,
    String selectedKey,
    bool isStandaloneScope,
  ) {
    const timeKeys = {'유통기한 지남', '유통기한 임박'};
    final scopeOptions =
        scopeAndTimeOptions.where((o) => !timeKeys.contains(o.key)).toList();
    final timeOptions =
        scopeAndTimeOptions.where((o) => timeKeys.contains(o.key)).toList();

    final isTimeSelected = timeKeys.contains(selectedKey);
    // 카테고리는 '전체'/'남은 재료' 스코프의 하위. 유통기한 경고를 고르면 숨긴다.
    final showCategoryRow = categoryOptions.isNotEmpty && !isTimeSelected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 윗줄: 스코프 + 구분선 + 유통기한 경고
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            clipBehavior: Clip.none,
            child: Row(
              children: [
                ...scopeOptions.map(
                  (option) => _buildFilterPillChip(
                    option,
                    selectedKey,
                    forceSelected: option.key == 'all'
                        ? (!isStandaloneScope && !isTimeSelected)
                        : option.key == 'standalone'
                        ? isStandaloneScope
                        : null,
                  ),
                ),
                if (timeOptions.isNotEmpty) ...[
                  Container(
                    width: 1,
                    height: 18,
                    margin: const EdgeInsets.only(right: 8, top: 2),
                    color: const Color(0xFFE5E8EB),
                  ),
                  ...timeOptions.map(
                    (option) => _buildFilterPillChip(option, selectedKey),
                  ),
                ],
              ],
            ),
          ),
        ),
        // 아랫줄: 현재 스코프('전체'/'남은 재료')의 하위 카테고리
        if (showCategoryRow)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 4),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              clipBehavior: Clip.none,
              child: Row(
                children: categoryOptions
                    .map(
                      (option) => _buildFilterPillChip(option, selectedKey),
                    )
                    .toList(),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildFilterPillChip(
    _FridgeIngredientFilterOption option,
    String selectedKey, {
    bool? forceSelected,
  }) {
    final selected = forceSelected ?? (option.key == selectedKey);
    final isExpired = option.key == '유통기한 지남';
    final isUrgent = option.key == '유통기한 임박';

    // 유통기한(시간) 묶음은 색+아이콘의 "경고 칩"으로, 나머지(스코프/카테고리)는
    // 중립 회색 칩으로 구분한다.
    late final Color bgSelected;
    late final Color bgUnselected;
    late final Color borderSelected;
    late final Color typeText; // 미선택 글자색
    late final Color accent; // 카운트 강조색 / 아이콘색
    IconData? icon;
    if (isExpired) {
      bgSelected = const Color(0xFFFFF1F2);
      bgUnselected = const Color(0xFFFFF6F6);
      borderSelected = const Color(0xFFFFCDD2);
      typeText = const Color(0xFFDC2626);
      accent = const Color(0xFFDC2626);
      icon = Icons.error_outline_rounded;
    } else if (isUrgent) {
      bgSelected = const Color(0xFFFFF4E5);
      bgUnselected = const Color(0xFFFFFAF2);
      borderSelected = const Color(0xFFFAD9A6);
      typeText = const Color(0xFFC2610C);
      accent = const Color(0xFFE38800);
      icon = Icons.schedule_rounded;
    } else {
      bgSelected = Colors.white;
      bgUnselected = const Color(0xFFF7F8FA);
      borderSelected = const Color(0xFFE8EBEF);
      typeText = const Color(0xFF8B95A1);
      accent = const Color(0xFFFF6422);
    }

    final labelStyle = TextStyle(
      fontFamily: 'Pretendard',
      fontSize: 12.5,
      fontWeight: FontWeight.w900,
      height: 1,
      letterSpacing: -0.25,
      color: selected ? const Color(0xFF191F28) : typeText,
    );

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () {
          Haptics.selection();
          setState(() => _selectedIngredientFilterKey = option.key);
        },
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 9,
          ),
          decoration: BoxDecoration(
            color: selected ? bgSelected : bgUnselected,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? borderSelected : const Color(0x00FFFFFF),
              width: 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.045),
                      blurRadius: 14,
                      spreadRadius: -4,
                      offset: const Offset(0, 5),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 13, color: accent),
                const SizedBox(width: 4),
              ],
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: option.label),
                    const TextSpan(text: ' '),
                    TextSpan(
                      text: '${option.count}',
                      style: TextStyle(
                        color: selected ? accent : const Color(0xFF9AA3AF),
                      ),
                    ),
                  ],
                ),
                style: labelStyle,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onAdjustLeftover(
    Map<String, dynamic>? fridgeData,
    int fridgeIndex,
    double newAdjustedUsedQty,
  ) async {
    final user = _authService.currentUser;
    if (user == null || fridgeData == null) return;
    final ingredients =
        (fridgeData['ingredients'] as List?)?.cast<Map<String, dynamic>>() ??
        [];
    final recipes =
        (fridgeData['recipes'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    if (fridgeIndex < 0 || fridgeIndex >= ingredients.length) return;
    final updated = ingredients.asMap().entries.map<Map<String, dynamic>>((e) {
      final i = e.key;
      final ing = e.value;
      if (i != fridgeIndex) return Map<String, dynamic>.from(ing);
      return Map<String, dynamic>.from(ing)
        ..['adjustedUsedQty'] = newAdjustedUsedQty;
    }).toList();
    try {
      await _userService.saveFridgeData(
        user.uid,
        ingredients: updated,
        recipes: recipes,
        updateLastSentAt: false,
      );
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 
          SnackBar(content: Text('저장 실패: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _confirmAndDeleteIngredient(
    Map<String, dynamic>? fridgeData,
    int fridgeIndex,
    String ingredientName,
    double orderQty,
  ) async {
    final confirmed = await _showIngredientActionConfirmDialog(
      title: '재료를 삭제할까요?',
      message: '$ingredientName을(를) 보관 재료에서 삭제해요.\n삭제하면 이 카드에서는 다시 보이지 않아요.',
      confirmText: '삭제',
      confirmColor: const Color(0xFFEF4444),
    );
    if (!confirmed || !mounted) return;

    await _deleteFridgeIngredientsByIndices(fridgeData, {fridgeIndex});
  }

  Future<void> _confirmAndDeleteSelectedFridgeIngredients(
    Map<String, dynamic>? fridgeData,
  ) async {
    final selected = _selectedFridgeIndices.toSet();
    if (selected.isEmpty) return;
    final confirmed = await _showIngredientActionConfirmDialog(
      title: '선택한 재료를 삭제할까요?',
      message: '선택한 ${selected.length}개 재료를 냉장고에서 삭제해요.\n삭제하면 이 목록에서 다시 보이지 않아요.',
      confirmText: '${selected.length}개 삭제',
      confirmColor: const Color(0xFFEF4444),
    );
    if (!confirmed || !mounted) return;
    await _deleteFridgeIngredientsByIndices(fridgeData, selected);
    if (!mounted) return;
    _exitFridgeSelectionMode();
  }

  Future<void> _confirmAndDeleteAllFridgeIngredients(
    Map<String, dynamic>? fridgeData,
  ) async {
    final all = _allLeftoverFridgeIndices(fridgeData).toSet();
    if (all.isEmpty) return;
    final confirmed = await _showIngredientActionConfirmDialog(
      title: '냉장고를 비울까요?',
      message: '보관 중인 재료 ${all.length}개를 모두 삭제해요.\n이 작업은 되돌릴 수 없어요.',
      confirmText: '전체 삭제',
      confirmColor: const Color(0xFFEF4444),
    );
    if (!confirmed || !mounted) return;
    await _deleteFridgeIngredientsByIndices(fridgeData, all);
    if (!mounted) return;
    _exitFridgeSelectionMode();
  }

  /// leftover를 0으로 만들어 목록에서 숨긴다. 개별/선택/전체 삭제 공통 경로.
  Future<void> _deleteFridgeIngredientsByIndices(
    Map<String, dynamic>? fridgeData,
    Set<int> indices,
  ) async {
    final user = _authService.currentUser;
    if (user == null || fridgeData == null || indices.isEmpty) return;

    final ingredients =
        (fridgeData['ingredients'] as List?)?.cast<Map<String, dynamic>>() ??
        [];
    final recipes =
        (fridgeData['recipes'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    final updated = ingredients.asMap().entries.map<Map<String, dynamic>>((e) {
      final i = e.key;
      final ing = Map<String, dynamic>.from(e.value);
      if (!indices.contains(i)) return ing;
      final orderQty = (ing['totalQty'] as num?)?.toDouble() ?? 0;
      ing['adjustedUsedQty'] = orderQty;
      return ing;
    }).toList();

    setState(() => _optimisticallyDeletedFridgeIndices.addAll(indices));

    try {
      await _userService.saveFridgeData(
        user.uid,
        ingredients: updated,
        recipes: recipes,
        updateLastSentAt: false,
      );
      final names = [
        for (final i in indices)
          if (i >= 0 && i < ingredients.length)
            ((ingredients[i]['item'] ?? ingredients[i]['name'])
                        ?.toString()
                        .trim() ??
                    ''),
      ].where((name) => name.isNotEmpty).toList();
      if (names.isNotEmpty) {
        unawaited(
          AnalyticsService().trackFridgeIngredientsRemoved(
            ingredientNames: names,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _optimisticallyDeletedFridgeIndices.removeAll(indices));
      showAppSnackBar(
        context,
        SnackBar(content: Text('삭제 실패: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _confirmAndResetIngredientFreshness(
    Map<String, dynamic>? fridgeData,
    int fridgeIndex,
    String ingredientName,
  ) async {
    final confirmed = await _showIngredientActionConfirmDialog(
      title: '유통기한을 초기화할까요?',
      message: '$ingredientName의 보관 시작일을 오늘로 바꿔요.\nD-day 표시도 새로 계산됩니다.',
      confirmText: '초기화',
      confirmColor: const Color(0xFFFF6422),
    );
    if (!confirmed || !mounted) return;

    await _resetIngredientFreshness(fridgeData, fridgeIndex, ingredientName);
  }

  Future<bool> _showIngredientActionConfirmDialog({
    required String title,
    required String message,
    required String confirmText,
    required Color confirmColor,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          contentPadding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
          actionsPadding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
          title: Text(
            title,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 18,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.4,
              color: Color(0xFF191F28),
            ),
          ),
          content: Text(
            message,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
              height: 1.45,
              letterSpacing: -0.2,
              color: Color(0xFF6B7684),
            ),
          ),
          actions: [
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                    style: TextButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      foregroundColor: const Color(0xFF6B7684),
                      backgroundColor: const Color(0xFFF2F4F6),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text(
                      '취소',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(true),
                    style: TextButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      foregroundColor: Colors.white,
                      backgroundColor: confirmColor,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(
                      confirmText,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<void> _resetIngredientFreshness(
    Map<String, dynamic>? fridgeData,
    int fridgeIndex,
    String ingredientName,
  ) async {
    final user = _authService.currentUser;
    if (user == null || fridgeData == null) return;
    final ingredients =
        (fridgeData['ingredients'] as List?)?.cast<Map<String, dynamic>>() ??
        [];
    final recipes =
        (fridgeData['recipes'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    if (fridgeIndex < 0 || fridgeIndex >= ingredients.length) return;

    final now = DateTime.now();
    final shelfLifeService = IngredientShelfLifeService.instance;
    final shelfInfo = shelfLifeService.lookup(ingredientName);
    final updated = ingredients
        .map<Map<String, dynamic>>((ing) => Map<String, dynamic>.from(ing))
        .toList();
    final target = updated[fridgeIndex];
    target['purchasedAt'] = now.toIso8601String();
    // 초기화한 항목은 배송 도착 추정을 건너뛰고 즉시 오늘부터 D-day 계산.
    target['deliveredAt'] = now.toIso8601String();
    if (shelfInfo != null) {
      target['expiryDate'] = shelfLifeService.computeExpiryDate(
        ingredientName,
        now,
      );
      target['storageType'] = shelfInfo.storageType.firestoreValue;
    } else {
      target.remove('expiryDate');
    }

    try {
      await _userService.saveFridgeData(
        user.uid,
        ingredients: updated,
        recipes: recipes,
        updateLastSentAt: false,
      );
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 
          SnackBar(content: Text('초기화 실패: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// 재료 추가 시트용: 실제 남은 수량(left > 0)만 집계. 냉장고 목록과 동일 기준.
  Map<String, _ExistingIngredientInfo> _existingIngredientsWithLeftover(
    Map<String, dynamic> fridgeData,
  ) {
    final ingredients =
        (fridgeData['ingredients'] as List?)?.cast<Map<String, dynamic>>() ??
        [];
    final recipes =
        (fridgeData['recipes'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    final usedQty = <String, double>{};
    final usedQtyByBatch = <String, double>{};
    for (final r in recipes) {
      final batchId = r['purchaseBatchId']?.toString();
      final ings =
          (r['ingredients'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      for (final ing in ings) {
        final name = (ing['item'] ?? ing['name'])?.toString() ?? '';
        if (name.isEmpty) continue;
        final qty = _shoppingQtyForRecipeIngredient(ing, name);
        if (batchId != null && batchId.isNotEmpty) {
          final key = '$batchId|$name';
          usedQtyByBatch[key] = (usedQtyByBatch[key] ?? 0) + qty;
        } else {
          usedQty[name] = (usedQty[name] ?? 0) + qty;
        }
      }
    }

    final existingIngredients = <String, _ExistingIngredientInfo>{};
    for (final ing in ingredients) {
      final name = ing['name']?.toString().trim() ?? '';
      if (name.isEmpty) continue;
      final orderQty = (ing['totalQty'] as num?)?.toDouble() ?? 0;
      final batchId = ing['purchaseBatchId']?.toString();
      final batchKey = batchId == null || batchId.isEmpty
          ? null
          : '$batchId|$name';
      final usedFromRecipes = batchKey == null
          ? usedQty[name] ?? 0
          : usedQtyByBatch[batchKey] ?? 0;
      final adjustedUsed = (ing['adjustedUsedQty'] as num?)?.toDouble();
      final effectiveUsed = adjustedUsed ?? usedFromRecipes;
      final left = orderQty - effectiveUsed;
      if (left <= 0) continue;

      final unit = ing['unit']?.toString() ?? '개';
      final current = existingIngredients[name];
      if (current == null) {
        existingIngredients[name] = _ExistingIngredientInfo(
          qty: left,
          unit: unit,
        );
      } else if (current.unit == unit) {
        existingIngredients[name] = _ExistingIngredientInfo(
          qty: current.qty + left,
          unit: unit,
        );
      }
    }
    return existingIngredients;
  }

  /// 하단 CTA용: leftover > 0 인 재료 전부 (레시피 연결 여부와 무관).
  List<Map<String, dynamic>> _leftoverItemsForRecommendation(
    Map<String, dynamic>? fridgeData,
  ) {
    final ingredients =
        (fridgeData?['ingredients'] as List?)?.cast<Map<String, dynamic>>() ??
        [];
    final recipes =
        (fridgeData?['recipes'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    final usedQty = <String, double>{};
    final usedQtyByBatch = <String, double>{};
    for (final r in recipes) {
      final batchId = r['purchaseBatchId']?.toString();
      final ings =
          (r['ingredients'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      for (final ing in ings) {
        final name = (ing['item'] ?? ing['name'])?.toString() ?? '';
        if (name.isEmpty) continue;
        final qty = _shoppingQtyForRecipeIngredient(ing, name);
        if (batchId != null && batchId.isNotEmpty) {
          final key = '$batchId|$name';
          usedQtyByBatch[key] = (usedQtyByBatch[key] ?? 0) + qty;
        } else {
          usedQty[name] = (usedQty[name] ?? 0) + qty;
        }
      }
    }

    final items = <Map<String, dynamic>>[];
    for (var i = 0; i < ingredients.length; i++) {
      final ing = ingredients[i];
      final name = ing['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      final orderQty = (ing['totalQty'] as num?)?.toDouble() ?? 0;
      final batchId = ing['purchaseBatchId']?.toString();
      final batchKey = batchId == null || batchId.isEmpty
          ? null
          : '$batchId|$name';
      final usedFromRecipes = batchKey == null
          ? usedQty[name] ?? 0
          : usedQtyByBatch[batchKey] ?? 0;
      final adjustedUsed = (ing['adjustedUsedQty'] as num?)?.toDouble();
      final effectiveUsed = adjustedUsed ?? usedFromRecipes;
      final left = orderQty - effectiveUsed;
      if (left <= 0) continue;
      if (_optimisticallyDeletedFridgeIndices.contains(i)) continue;

      items.add({...ing, 'leftoverQty': left, '_fridgeIndex': i});
    }
    return items;
  }

  /// 하단 고정 액션 바: 왼쪽은 레시피 추천 CTA, 오른쪽은 재료 추가 수단 묶음.
  Widget _buildBottomActionBar(
    Brightness brightness,
    Map<String, dynamic>? fridgeData,
  ) {
    final surface = brightness == Brightness.dark
        ? AppColors.getBackground(brightness)
        : Colors.white;
    final compact = !IosLiquidGlassTabBar.shouldUse(context) &&
        _fridgeBottomBarCompact &&
        !_isFridgeSelecting;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 0),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 바 본체는 불투명 — 투명 페이드만 쓰면 목록이 틈으로 비친다.
          Positioned.fill(
            child: ColoredBox(color: surface),
          ),
          // 위쪽으로만 짧은 페이드 (목록과의 경계 부드럽게)
          Positioned(
            left: 0,
            right: 0,
            top: -18,
            height: 18,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      surface.withValues(alpha: 0),
                      surface,
                    ],
                  ),
                ),
              ),
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.fromLTRB(
              _fridgeScreenPaddingH,
              compact ? 6 : 8,
              _fridgeScreenPaddingH,
              compact ? 6 : 8,
            ),
            child: _isFridgeSelecting
                ? _buildSelectionActionBar(fridgeData)
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: _buildRecipeDrawPill(
                          _leftoverItemsForRecommendation(fridgeData),
                          compact: compact,
                        ),
                      ),
                      SizedBox(width: compact ? 8 : 10),
                      _buildIngredientAddCluster(
                        brightness,
                        fridgeData,
                        compact: compact,
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectionActionBar(Map<String, dynamic>? fridgeData) {
    final selectedCount = _selectedFridgeIndices.length;
    final allCount = _allLeftoverFridgeIndices(fridgeData).length;
    final allSelected = allCount > 0 && selectedCount == allCount;
    return SizedBox(
      height: 70,
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _toggleSelectAllVisibleFridgeIngredients(fridgeData),
              child: Container(
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F6F8),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  allSelected ? '선택 해제' : '전체 선택',
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.25,
                    color: Color(0xFF4E5968),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: selectedCount == 0
                  ? null
                  : () {
                      Haptics.light();
                      _confirmAndDeleteSelectedFridgeIngredients(fridgeData);
                    },
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 160),
                opacity: selectedCount == 0 ? 0.45 : 1,
                child: Container(
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEF4444),
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFEF4444).withValues(alpha: 0.28),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Text(
                    selectedCount == 0
                        ? '선택 삭제'
                        : '$selectedCount개 삭제',
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 14.5,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.3,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecipeDrawPill(
    List<Map<String, dynamic>> items, {
    bool compact = false,
  }) {
    final enabled = items.isNotEmpty;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? () => _openIngredientRecommendation(items) : null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: enabled ? 1 : 0.45,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          height: compact ? 40 : 48,
          padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 14),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF1F2430),
                Color(0xFF3B2A50),
                Color(0xFFFF6422),
              ],
              stops: [0.0, 0.48, 1.0],
            ),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.52),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFF6422).withValues(alpha: compact ? 0.22 : 0.32),
                blurRadius: compact ? 14 : 24,
                spreadRadius: 1,
                offset: Offset(0, compact ? 4 : 8),
              ),
              BoxShadow(
                color: const Color(0xFF7C3AED).withValues(alpha: compact ? 0.14 : 0.22),
                blurRadius: compact ? 16 : 28,
                spreadRadius: 3,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.center,
                  child: Text(
                    enabled ? '남은 재료로 레시피 추천' : '남은 재료가 없어요',
                    maxLines: 1,
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: compact ? 12.5 : 13.2,
                      fontWeight: FontWeight.w900,
                      height: 1,
                      letterSpacing: -0.35,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              if (enabled) ...[
                SizedBox(width: compact ? 5 : 7),
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? 5 : 6,
                    vertical: compact ? 2 : 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${items.length}',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: compact ? 10 : 10.5,
                      fontWeight: FontWeight.w900,
                      height: 1,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 영수증 스캔 + 직접 추가를 하나의 캡슐로 묶어 '재료를 넣는 곳'을 한 덩어리로 보여준다.
  Widget _buildIngredientAddCluster(
    Brightness brightness,
    Map<String, dynamic>? fridgeData, {
    bool compact = false,
  }) {
    final isDark = brightness == Brightness.dark;
    final hairline = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : const Color(0xFFFFE0CC);
    final actionSize = compact ? 34.0 : 40.0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      height: compact ? 40 : 48,
      padding: EdgeInsets.all(compact ? 3 : 4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2C2C2C) : Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: hairline, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFF6422).withValues(alpha: isDark ? 0.18 : 0.1),
            blurRadius: compact ? 12 : 18,
            offset: Offset(0, compact ? 4 : 6),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildFridgeAddAction(
            icon: Icons.receipt_long_rounded,
            label: '영수증으로 재료 추가',
            size: actionSize,
            onTap: () {
              Haptics.light();
              _showReceiptScan(fridgeData);
            },
          ),
          Container(width: 1, height: compact ? 14 : 18, color: hairline),
          _buildFridgeAddAction(
            icon: Icons.add_rounded,
            label: '재료 직접 추가',
            useRefinedPlus: true,
            size: actionSize,
            plusSize: compact ? 14 : 16,
            onTap: () {
              Haptics.light();
              _showAddIngredientSheet(fridgeData);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildFridgeAddAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool useRefinedPlus = false,
    double size = 40,
    double plusSize = 16,
  }) {
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            alignment: Alignment.center,
            child: useRefinedPlus
                ? SizedBox(
                    width: plusSize,
                    height: plusSize,
                    child: const CustomPaint(
                      painter: _FridgeRefinedPlusPainter(
                        color: Color(0xFFFF6422),
                      ),
                    ),
                  )
                : Icon(
                    icon,
                    size: size >= 40 ? 19 : 16,
                    color: const Color(0xFFFF6422),
                  ),
          ),
        ),
      ),
    );
  }

  void _showAddIngredientSheet(Map<String, dynamic>? fridgeData) {
    // Firestore에 fridgeData 필드가 없을 때(장바구니 구매 완료 전)도 수동 추가 가능.
    final effectiveFridgeData = fridgeData ??
        <String, dynamic>{
          'ingredients': <dynamic>[],
          'recipes': <dynamic>[],
        };
    final existingIngredients =
        _existingIngredientsWithLeftover(effectiveFridgeData);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _AddIngredientSheet(
          existingIngredients: existingIngredients,
          onAdd: (name, qty, unit) =>
              _addManualIngredient(effectiveFridgeData, name, qty, unit),
          onAddBatch: (items, {source, analyticsMethod}) =>
              _addManualIngredientsBatch(
            effectiveFridgeData,
            items,
            source: source ?? 'manual',
            analyticsMethod: analyticsMethod ?? 'manual_batch',
          ),
        ),
      ),
    );
  }

  /// 냉장고 헤더의 "영수증" 버튼 → 촬영/갤러리 → 인식 → 확인 후 일괄 추가.
  void _showReceiptScan(Map<String, dynamic>? fridgeData) {
    final effectiveFridgeData = fridgeData ??
        <String, dynamic>{
          'ingredients': <dynamic>[],
          'recipes': <dynamic>[],
        };
    final existingIngredients =
        _existingIngredientsWithLeftover(effectiveFridgeData);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _AddIngredientSheet(
          existingIngredients: existingIngredients,
          startWithReceiptScan: true,
          onAdd: (name, qty, unit) =>
              _addManualIngredient(effectiveFridgeData, name, qty, unit),
          onAddBatch: (items, {source, analyticsMethod}) =>
              _addManualIngredientsBatch(
            effectiveFridgeData,
            items,
            source: source ?? 'manual',
            analyticsMethod: analyticsMethod ?? 'manual_batch',
          ),
        ),
      ),
    );
  }

  Future<void> _addManualIngredient(
    Map<String, dynamic> fridgeData,
    String name,
    double qty,
    String unit,
  ) async {
    final user = _authService.currentUser;
    if (user == null) return;
    // 다이얼로그를 연 시점 스냅샷 대신 저장 직전 최신 데이터를 사용 (동시 구매 완료 등).
    final latestFridgeData =
        await _userService.getFridgeData(user.uid) ?? fridgeData;
    final ingredients =
        (latestFridgeData['ingredients'] as List?)
            ?.cast<Map<String, dynamic>>() ??
        [];
    final recipes =
        (latestFridgeData['recipes'] as List?)?.cast<Map<String, dynamic>>() ??
        [];

    final now = DateTime.now();
    final shelfLifeService = IngredientShelfLifeService.instance;
    final shelfInfo = shelfLifeService.lookup(name);

    final newIng = <String, dynamic>{
      'name': name,
      'totalQty': qty,
      'unit': unit,
      'purchasedAt': now.toIso8601String(),
      // 이미 냉장고에 있는 재료 — 배송 대기 없이 바로 D-day.
      'deliveredAt': now.toIso8601String(),
      'source': 'manual',
      'purchaseBatchId': 'manual_${now.microsecondsSinceEpoch}',
      'category': IngredientCategoryUnifier.groupKeyFromIngredient(
        internalCategory: null,
        ingredientName: name,
      ),
      if (shelfInfo != null) ...{
        'expiryDate': shelfLifeService.computeExpiryDate(
          name,
          now,
          alreadyOwned: true,
        ),
        'storageType': shelfInfo.storageType.firestoreValue,
      },
    };

    final updated = [
      ...ingredients.map((e) => Map<String, dynamic>.from(e)),
      newIng,
    ];

    try {
      await _userService.saveFridgeData(
        user.uid,
        ingredients: updated,
        recipes: recipes,
        updateLastSentAt: false,
      );
      unawaited(
        AnalyticsService().trackFridgeIngredientAdded(
          itemCount: 1,
          method: 'manual',
          ingredientNames: [name],
        ),
      );
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 
          SnackBar(content: Text('추가 실패: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// 추천 재료 모음 등 여러 재료를 한 번의 저장으로 추가한다.
  /// 개별 [_addManualIngredient] 를 반복 호출하면 read-modify-write 가
  /// 경쟁하여 일부가 유실되므로, 단일 write 로 모두 반영한다.
  Future<void> _addManualIngredientsBatch(
    Map<String, dynamic> fridgeData,
    List<({String name, double qty, String unit})> items, {
    // 사진/영수증 스캔에서 추가된 재료를 구분하기 위한 태그. 기존 호출부는
    // 인자를 넘기지 않으므로 기본값('manual')으로 동작이 그대로 유지된다.
    String source = 'manual',
    String analyticsMethod = 'manual_batch',
  }) async {
    final user = _authService.currentUser;
    if (user == null || items.isEmpty) return;
    final latestFridgeData =
        await _userService.getFridgeData(user.uid) ?? fridgeData;
    final ingredients =
        (latestFridgeData['ingredients'] as List?)
            ?.cast<Map<String, dynamic>>() ??
        [];
    final recipes =
        (latestFridgeData['recipes'] as List?)?.cast<Map<String, dynamic>>() ??
        [];

    final shelfLifeService = IngredientShelfLifeService.instance;
    final updated = [
      ...ingredients.map((e) => Map<String, dynamic>.from(e)),
    ];
    final now0 = DateTime.now();
    final batchId = '${source}_${now0.microsecondsSinceEpoch}';
    var i = 0;
    final isReceipt = source == 'photo_receipt';
    final alreadyOwned = _isAlreadyOwnedFridgeSource(source, batchId);
    final added = <({String name, double qty, String unit})>[];
    for (final item in items) {
      final trimmed = item.name.trim();
      if (trimmed.isEmpty) continue;
      // 영수증 스캔만 카탈로그 재매칭을 시도한다 (수동/쿠팡 추가는 이미
      // 자동완성으로 카탈로그명만 고르게 되어 있어 항상 매칭됨).
      // 매칭에 실패해도 이름은 그대로 두고 냉장고에 담는다 — 다만
      // `catalogMatched: false`로 남겨 레시피 추천 입력에서 제외한다.
      final catalogName =
          isReceipt ? ReceiptCatalogMatcher.resolveCatalogName(trimmed) : trimmed;
      final catalogMatched = !isReceipt || catalogName != null;
      final name = catalogName ?? trimmed;
      if (name.isEmpty) continue;
      final now = DateTime.now();
      final shelfInfo = shelfLifeService.lookup(name);
      updated.add(<String, dynamic>{
        'name': name,
        'totalQty': item.qty,
        'unit': item.unit,
        'purchasedAt': now.toIso8601String(),
        if (alreadyOwned) 'deliveredAt': now.toIso8601String(),
        'source': source,
        'purchaseBatchId': '${batchId}_${i++}',
        'category': IngredientCategoryUnifier.groupKeyFromIngredient(
          internalCategory: null,
          ingredientName: name,
        ),
        // false면: 유통기한 추정 불가(시드 미매칭) + 레시피 추천 입력에서
        // 제외 (_openIngredientRecommendation 참고). 냉장고 목록에는 보인다.
        'catalogMatched': catalogMatched,
        if (shelfInfo != null) ...{
          'expiryDate': shelfLifeService.computeExpiryDate(
            name,
            now,
            alreadyOwned: alreadyOwned,
          ),
          'storageType': shelfInfo.storageType.firestoreValue,
        },
      });
      added.add((name: name, qty: item.qty, unit: item.unit));
    }
    if (added.isEmpty) return;

    try {
      await _userService.saveFridgeData(
        user.uid,
        ingredients: updated,
        recipes: recipes,
        updateLastSentAt: false,
      );
      unawaited(
        AnalyticsService().trackFridgeIngredientAdded(
          itemCount: added.length,
          method: analyticsMethod,
          ingredientNames: [for (final item in added) item.name],
        ),
      );
      if (mounted) {
        showAppSnackBar(
          context,
          SnackBar(
            content: Text(
              '재료 ${added.length}개를 냉장고에 담았어요',
              style: const TextStyle(color: Colors.white),
            ),
            backgroundColor: const Color(0xFF191F28),
          ),
        );
        // 영수증 스캔 직후 레시피 추천 팝업은 띄우지 않는다.
        // (흐름이 끊기고 사용자가 원하지 않는 경우가 많음)
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(
          context,
          SnackBar(
            content: Text(
              '추가 실패: $e',
              style: const TextStyle(color: Colors.white),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Unified 6-group key for this fridge ingredient.
  /// Uses internal stored category + name heuristics so the UI is consistent
  /// even when the stored category system is older.
  String _categorizeIngredient(String name, String? fromData) {
    return IngredientCategoryUnifier.groupKeyFromIngredient(
      internalCategory: fromData,
      ingredientName: name,
    );
  }

  /// Stable key for this fridge snapshot (used to run category backfill only once per snapshot).
  String _leftoverBackfillKey(Map<String, dynamic> fridgeData) {
    final ingredients =
        (fridgeData['ingredients'] as List?)?.cast<Map<String, dynamic>>() ??
        [];
    final withoutCategory = ingredients
        .where((e) {
          final c = e['category']?.toString();
          return c == null || c.isEmpty;
        })
        .map((e) => e['name']?.toString() ?? '')
        .toList();
    return withoutCategory.join('|');
  }

  /// Fetch category from backend (same system as recipe detail) for ingredients missing category, then save.
  Future<void> _backfillIngredientCategories(
    Map<String, dynamic> fridgeData,
  ) async {
    final user = _authService.currentUser;
    if (user == null) return;
    final ingredients =
        (fridgeData['ingredients'] as List?)?.cast<Map<String, dynamic>>() ??
        [];
    final recipes =
        (fridgeData['recipes'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final updated = ingredients
        .map<Map<String, dynamic>>((ing) => Map<String, dynamic>.from(ing))
        .toList();
    bool changed = false;
    for (var i = 0; i < ingredients.length; i++) {
      final ing = ingredients[i];
      final c = ing['category']?.toString();
      if (c != null && c.isNotEmpty) continue;
      final name = ing['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      try {
        final category = await ApiService.reclassifyIngredient(
          ingredientName: name,
        );
        updated[i] = Map<String, dynamic>.from(updated[i])
          ..['category'] = category;
        changed = true;
      } catch (_) {
        // Keep without category; will retry next time.
      }
    }
    if (changed && mounted) {
      try {
        await _userService.saveFridgeData(
          user.uid,
          ingredients: updated,
          recipes: recipes,
        );
      } catch (_) {}
    }
  }

  Widget _buildGuestLockedFridge(BuildContext context, Brightness brightness) {
    return Stack(
      children: [
        const GuestLockedPreviewBackdrop(asset: 'assets/fridge_preview.png'),
        Center(
          child: Container(
            width: 272,
            padding: const EdgeInsets.fromLTRB(27, 27, 27, 27),
            decoration: ShapeDecoration(
              color: Colors.white.withValues(alpha: 0.80),
              shape: RoundedRectangleBorder(
                side: const BorderSide(width: 0.57, color: Colors.white),
                borderRadius: BorderRadius.circular(27),
              ),
              shadows: const [
                BoxShadow(
                  color: Color(0x14000000),
                  blurRadius: 51,
                  offset: Offset(0, 20),
                  spreadRadius: -10,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: ShapeDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment(0.00, 1.00),
                      end: Alignment(1.00, 0.00),
                      colors: [Colors.white, Color(0xFFF9FAFB)],
                    ),
                    shape: RoundedRectangleBorder(
                      side: const BorderSide(width: 0.57, color: Colors.white),
                      borderRadius: BorderRadius.circular(22369600),
                    ),
                    shadows: const [
                      BoxShadow(
                        color: Color(0x0C000000),
                        blurRadius: 10,
                        offset: Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Center(
                    child: Image.asset(
                      'assets/icons/nav_fridge.png',
                      width: 24,
                      height: 24,
                      color: const Color(0xFF6B7280),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  '냉장고 관리, 이렇게 쉬워요',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF111111),
                    fontSize: 17,
                    fontFamily: 'Pretendard',
                    fontWeight: FontWeight.w900,
                    height: 1.25,
                    letterSpacing: -0.42,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '로그인하면 식단 관리, 보관 재료 확인,\n레시피 추천까지 한 번에!',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF6B7280),
                    fontSize: 11,
                    fontFamily: 'Pretendard',
                    fontWeight: FontWeight.w500,
                    height: 1.60,
                    letterSpacing: -0.27,
                  ),
                ),
                const SizedBox(height: 24),
                GestureDetector(
                  onTap: () => Navigator.pushNamed(context, '/login'),
                  child: Container(
                    width: double.infinity,
                    height: 46,
                    decoration: ShapeDecoration(
                      color: const Color(0xFF111111),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      shadows: const [
                        BoxShadow(
                          color: Color(0x26000000),
                          blurRadius: 17,
                          offset: Offset(0, 7),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: const Text(
                      '3초 만에 로그인하기',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontFamily: 'Pretendard',
                        fontWeight: FontWeight.w700,
                        height: 1.50,
                        letterSpacing: -0.32,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

}

class _FridgeIngredientFilterOption {
  const _FridgeIngredientFilterOption({
    required this.key,
    required this.label,
    required this.count,
  });

  final String key;
  final String label;
  final int count;
}

class _FridgeRefinedPlusPainter extends CustomPainter {
  const _FridgeRefinedPlusPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide * 0.125;
    final paint = Paint()
      ..color = color
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final inset = stroke * 0.55;
    final cx = size.width / 2;
    final cy = size.height / 2;
    canvas.drawLine(
      Offset(inset, cy),
      Offset(size.width - inset, cy),
      paint,
    );
    canvas.drawLine(
      Offset(cx, inset),
      Offset(cx, size.height - inset),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _FridgeRefinedPlusPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _FridgeHeaderTextButton extends StatelessWidget {
  const _FridgeHeaderTextButton({
    required this.label,
    required this.onTap,
    this.emphasized = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    const orange = Color(0xFFFF6422);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        Haptics.light();
        onTap();
      },
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: emphasized ? orange : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: emphasized ? orange : const Color(0xFFD1D6DB),
            width: 1.2,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 13,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.2,
            color: emphasized ? Colors.white : const Color(0xFF4E5968),
          ),
        ),
      ),
    );
  }
}

class _FridgeSelectionCheck extends StatelessWidget {
  const _FridgeSelectionCheck({
    required this.selected,
    this.partial = false,
  });

  final bool selected;
  final bool partial;

  @override
  Widget build(BuildContext context) {
    final active = selected || partial;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: selected
            ? const Color(0xFFFF6422)
            : partial
            ? const Color(0xFFFF6422).withValues(alpha: 0.18)
            : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active ? const Color(0xFFFF6422) : const Color(0xFFD1D6DB),
          width: 1.5,
        ),
      ),
      child: active
          ? Icon(
              selected ? Icons.check_rounded : Icons.remove_rounded,
              size: 15,
              color: selected ? Colors.white : const Color(0xFFFF6422),
            )
          : null,
    );
  }
}

class _FridgeIngredientBatchGroup {
  const _FridgeIngredientBatchGroup({
    required this.key,
    required this.name,
    required this.categoryKey,
    required this.items,
  });

  final String key;
  final String name;
  final String categoryKey;
  final List<Map<String, dynamic>> items;
}

class _FridgeIngredientBatchGroupCard extends StatelessWidget {
  const _FridgeIngredientBatchGroupCard({
    required this.group,
    required this.expanded,
    required this.onToggle,
    required this.buildBatchCard,
    this.includeExpandedPanel = true,
    this.showCategory = true,
    this.selectionMode = false,
    this.selectedCount = 0,
  });

  final _FridgeIngredientBatchGroup group;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget Function(Map<String, dynamic> ing) buildBatchCard;
  final bool includeExpandedPanel;
  final bool showCategory;
  final bool selectionMode;
  final int selectedCount;

  String _amountLabel() {
    final units = group.items
        .map((e) => e['unit']?.toString() ?? '개')
        .where((u) => u.isNotEmpty)
        .toSet();
    if (units.length != 1) return '${group.items.length}묶음';
    final unit = units.first;
    final total = group.items.fold<double>(
      0,
      (sum, ing) => sum + ((ing['leftoverQty'] as num?)?.toDouble() ?? 0),
    );
    final amount = total % 1 == 0
        ? '${total.toInt()}'
        : total.toStringAsFixed(1);
    return '$amount${_truncateUnit(unit, 8)}';
  }

  String _statusText() {
    final first = group.items.first;
    if (first['isDelivering'] as bool? ?? false) return '배송중';
    final days = first['daysUntilExpiry'] as int?;
    if (days == null) return '가장 임박한 묶음 기준';
    if (days < 0) return '기한 지남';
    if (days == 0) return '오늘까지';
    return 'D-$days 남음';
  }

  Color _statusColor() {
    final first = group.items.first;
    if (first['isDelivering'] as bool? ?? false) return const Color(0xFF3182F6);
    final days = first['daysUntilExpiry'] as int?;
    if (days == null) return const Color(0xFF8B95A1);
    if (days <= 1) return const Color(0xFFFF4D4F);
    if (days <= 3) return const Color(0xFFFF8A00);
    return const Color(0xFF6B7280);
  }

  int _recipeLinkCount() {
    final ids = <String>{};
    for (final ing in group.items) {
      final links =
          (ing['recipeLinks'] as List?)?.cast<_FridgeRecipeIngredientLink>() ??
          const <_FridgeRecipeIngredientLink>[];
      for (final link in links) {
        ids.add(link.recipeId.isEmpty ? link.recipeName : link.recipeId);
      }
    }
    return ids.length;
  }

  @override
  Widget build(BuildContext context) {
    final categoryLabel = IngredientCategoryUnifier.titleFromKey(
      group.categoryKey,
    );
    final recipeLinkCount = _recipeLinkCount();
    return AnimatedSize(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        padding: expanded
            ? const EdgeInsets.all(8)
            : const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: expanded ? const Color(0xFFF8FAFC) : Colors.transparent,
          borderRadius: BorderRadius.circular(22),
          border: expanded
              ? Border.all(color: const Color(0xFFE9EDF2), width: 1)
              : null,
        ),
      child: Column(
          children: [
            GestureDetector(
              onTap: onToggle,
              behavior: HitTestBehavior.opaque,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  if (!expanded && !selectionMode) ...[
                    // 뒷판은 카드 높이를 따라가며 아래로만 8px/4px 겹쳐 보이게 한다.
                    Positioned(
                      left: 8,
                      right: 8,
                      top: 8,
                      bottom: -8,
                      child: _BatchStackBackplate(opacity: 0.65),
                    ),
                    Positioned(
                      left: 4,
                      right: 4,
                      top: 4,
                      bottom: -4,
                      child: _BatchStackBackplate(opacity: 0.85),
                    ),
                  ],
                  Container(
                    padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: selectionMode &&
                                selectedCount == group.items.length
                            ? const Color(0xFFFF6422)
                            : const Color(0xFFE9EDF2),
                        width: selectionMode &&
                                selectedCount == group.items.length
                            ? 1.5
                            : 1,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x08000000),
                          blurRadius: 16,
                          offset: Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (showCategory) ...[
                          Padding(
                            padding: EdgeInsets.only(
                              right: selectionMode ? 28 : 0,
                            ),
                            child: Row(
                              children: [
                                IngredientCategoryUnifier.buildCategoryIcon(
                                  key: group.categoryKey,
                                  size: 12,
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    categoryLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontFamily: 'Pretendard',
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w800,
                                      height: 1.1,
                                      letterSpacing: -0.2,
                                      color: Color(0xFF8B95A1),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 11),
                        ],
                        Text(
                          group.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                            height: 1.15,
                            letterSpacing: -0.35,
                            color: Color(0xFF191F28),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _statusText(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            height: 1,
                            color: _statusColor(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              height: 34,
                              decoration: BoxDecoration(
                                color: const Color(0xFFF5F6F8),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: const Color(0xFFECEFF3),
                                  width: 1,
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    selectionMode
                                        ? (selectedCount == group.items.length
                                              ? '묶음 전체 선택됨'
                                              : selectedCount > 0
                                              ? '$selectedCount/${group.items.length} 선택'
                                              : '탭해서 묶음 선택')
                                        : '총 ${_amountLabel()}',
                                    style: TextStyle(
                                      fontFamily: 'Pretendard',
                                      fontSize: 13,
                                      fontWeight: FontWeight.w800,
                                      height: 1,
                                      letterSpacing: -0.3,
                                      color: selectionMode
                                          ? const Color(0xFFFF6422)
                                          : const Color(0xFF4E5968),
                                    ),
                                  ),
                                  if (!selectionMode) ...[
                                    const SizedBox(width: 5),
                                    AnimatedRotation(
                                      turns: expanded ? 0.5 : 0,
                                      duration: const Duration(
                                        milliseconds: 220,
                                      ),
                                      curve: Curves.easeOutCubic,
                                      child: const Icon(
                                        Icons.keyboard_arrow_down_rounded,
                                        size: 17,
                                        color: Color(0xFF8B95A1),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            if (!selectionMode && recipeLinkCount > 0)
                              Positioned(
                                right: -5,
                                bottom: -8,
                                child: _FridgeRecipeCountBadge(
                                  count: recipeLinkCount,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (selectionMode)
                    Positioned(
                      top: 10,
                      right: 10,
                      child: _FridgeSelectionCheck(
                        selected: selectedCount == group.items.length,
                        partial: selectedCount > 0 &&
                            selectedCount < group.items.length,
                      ),
                    ),
                ],
              ),
            ),
            if (includeExpandedPanel)
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) {
                  final slide = Tween<Offset>(
                    begin: const Offset(0, -0.04),
                    end: Offset.zero,
                  ).animate(animation);
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(position: slide, child: child),
                  );
                },
                child: expanded
                    ? Padding(
                        key: const ValueKey('expanded-batches'),
                        padding: const EdgeInsets.only(top: 8),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final batchWidth = (constraints.maxWidth - 8) / 2;
                            return Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: group.items
                                  .map(
                                    (ing) => SizedBox(
                                      width: batchWidth,
                                      child: buildBatchCard(ing),
                                    ),
                                  )
                                  .toList(),
                            );
                          },
                        ),
                      )
                    : const SizedBox.shrink(key: ValueKey('collapsed-batches')),
              ),
          ],
        ),
      ),
    );
  }
}

class _BatchStackBackplate extends StatelessWidget {
  const _BatchStackBackplate({required this.opacity});

  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: opacity),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE9EDF2), width: 1),
      ),
    );
  }
}

class _FridgeIngredientBatchExpansionPanel extends StatelessWidget {
  const _FridgeIngredientBatchExpansionPanel({
    super.key,
    required this.group,
    required this.buildBatchCard,
  });

  final _FridgeIngredientBatchGroup group;
  final Widget Function(Map<String, dynamic> ing) buildBatchCard;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        builder: (context, value, child) {
          return Opacity(
            opacity: value,
            child: Transform.translate(
              offset: Offset(0, -6 * (1 - value)),
              child: child,
            ),
          );
        },
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFFE9EDF2), width: 1),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final batchWidth = (constraints.maxWidth - 8) / 2;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: group.items
                    .map(
                      (ing) => SizedBox(
                        width: batchWidth,
                        child: buildBatchCard(ing),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _FridgeIngredientGridCard extends StatefulWidget {
  const _FridgeIngredientGridCard({
    super.key,
    required this.name,
    required this.amount,
    required this.orderQty,
    required this.fridgeIndex,
    required this.unit,
    required this.imageUrl,
    required this.daysUntilExpiry,
    required this.isDelivering,
    required this.recipeLinks,
    required this.categoryKey,
    required this.onResetFreshness,
    required this.onAdjustLeftover,
    required this.onDelete,
    required this.onShowRecipes,
    this.compact = false,
    this.showCategory = true,
    this.selectionMode = false,
    this.selected = false,
    this.onToggleSelect,
  });

  final String name;
  final double amount;
  final double orderQty;
  final int fridgeIndex;
  final String unit;
  final String imageUrl;
  final int? daysUntilExpiry;
  final bool isDelivering;
  final List<_FridgeRecipeIngredientLink> recipeLinks;
  final String categoryKey;
  final VoidCallback? onResetFreshness;
  final ValueChanged<double>? onAdjustLeftover;
  final VoidCallback? onDelete;
  final VoidCallback? onShowRecipes;
  final bool compact;
  final bool showCategory;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onToggleSelect;

  @override
  State<_FridgeIngredientGridCard> createState() =>
      _FridgeIngredientGridCardState();
}

class _FridgeIngredientGridCardState extends State<_FridgeIngredientGridCard> {
  late double _currentAmount;

  @override
  void initState() {
    super.initState();
    _currentAmount = widget.amount;
  }

  @override
  void didUpdateWidget(covariant _FridgeIngredientGridCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.amount - widget.amount).abs() > 0.001) {
      _currentAmount = widget.amount;
    }
  }

  String get _amountText {
    return '${_formatQuantityLabel(_currentAmount)}${_truncateUnit(widget.unit, 8)}';
  }

  String get _statusText {
    if (widget.isDelivering) return '배송중';
    final days = widget.daysUntilExpiry;
    if (days == null) return '';
    if (days < 0) return '기한 지남';
    if (days == 0) return '오늘까지';
    return 'D-$days 남음';
  }

  Color get _statusColor {
    if (widget.isDelivering) return const Color(0xFF3182F6);
    final days = widget.daysUntilExpiry;
    if (days == null) return const Color(0xFF8B95A1);
    if (days <= 1) return const Color(0xFFFF4D4F);
    if (days <= 3) return const Color(0xFFFF8A00);
    return const Color(0xFF6B7280);
  }

  double get _step =>
      _stepForLeftover(_currentAmount, widget.unit, widget.orderQty);

  void _setAmount(double nextAmount) {
    final clamped = nextAmount < 0 ? 0.0 : nextAmount;
    if ((_currentAmount - clamped).abs() < 0.001) return;
    setState(() => _currentAmount = clamped);
    // adjustedUsedQty = orderQty - leftover. Allowing it to go negative lets the
    // user freely increase the leftover amount above the original order qty.
    widget.onAdjustLeftover?.call(widget.orderQty - clamped);
  }

  void _onMinus() {
    // 카드 leftover는 0까지 내려 숨길 수 있게 둔다.
    if (_currentAmount <= _step + 1e-9) {
      _setAmount(0);
      return;
    }
    _setAmount(double.parse((_currentAmount - _step).toStringAsFixed(3)));
  }

  void _onPlus() {
    _setAmount(double.parse((_currentAmount + _step).toStringAsFixed(3)));
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.name.isEmpty ? '재료' : widget.name;
    final subtitle = _statusText.isNotEmpty ? _statusText : '보관 중';
    final categoryLabel = IngredientCategoryUnifier.titleFromKey(
      widget.categoryKey,
    );
    final cardPadding = widget.compact
        ? const EdgeInsets.fromLTRB(12, 11, 12, 11)
        : const EdgeInsets.fromLTRB(13, 12, 13, 12);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        GestureDetector(
          onTap: widget.selectionMode
              ? widget.onToggleSelect
              : widget.onShowRecipes,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: cardPadding,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: widget.selectionMode && widget.selected
                    ? const Color(0xFFFF6422)
                    : const Color(0xFFE9EDF2),
                width: widget.selectionMode && widget.selected ? 1.5 : 1,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x05000000),
                  blurRadius: 14,
                  offset: Offset(0, 5),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.showCategory) ...[
                  Padding(
                    padding: EdgeInsets.only(
                      right: (widget.onDelete != null || widget.selectionMode)
                          ? 30
                          : 0,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        IngredientCategoryUnifier.buildCategoryIcon(
                          key: widget.categoryKey,
                          size: 12,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            categoryLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                              height: 1.1,
                              letterSpacing: -0.2,
                              color: Color(0xFF8B95A1),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: widget.compact ? 9 : 11),
                ],
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    height: 1.15,
                    letterSpacing: -0.35,
                    color: Color(0xFF191F28),
                  ),
                ),
                SizedBox(height: widget.compact ? 7 : 8),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          height: 1,
                          color: _statusColor,
                        ),
                      ),
                    ),
                    if (widget.onResetFreshness != null) ...[
                      const SizedBox(width: 5),
                      _FreshnessResetChip(onTap: widget.onResetFreshness),
                    ],
                  ],
                ),
                SizedBox(height: widget.compact ? 9 : 10),
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    _FridgeAmountStepper(
                      amountText: _amountText,
                      currentAmount: _currentAmount,
                      unit: widget.unit,
                      onMinus: widget.onAdjustLeftover == null
                          ? null
                          : _onMinus,
                      onPlus: widget.onAdjustLeftover == null ? null : _onPlus,
                      onSetAmount: widget.onAdjustLeftover == null
                          ? null
                          : (v) => _setAmount(v),
                    ),
                    if (!widget.selectionMode && widget.recipeLinks.isNotEmpty)
                      Positioned(
                        right: -5,
                        bottom: -8,
                        child: IgnorePointer(
                          child: _FridgeRecipeCountBadge(
                            count: widget.recipeLinks.length,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (widget.selectionMode)
          Positioned(
            top: 10,
            right: 10,
            child: GestureDetector(
              onTap: widget.onToggleSelect,
              behavior: HitTestBehavior.opaque,
              child: _FridgeSelectionCheck(selected: widget.selected),
            ),
          )
        else if (widget.onDelete != null)
          Positioned(
            top: 10,
            right: 10,
            child: GestureDetector(
              onTap: widget.onDelete,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: const Color(0xFFF2F4F6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Center(
                  child: Icon(
                    Icons.delete_outline_rounded,
                    size: 13,
                    color: Color(0xFFB0B8C1),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _IngredientUsageLedgerRow extends StatelessWidget {
  const _IngredientUsageLedgerRow({
    required this.label,
    required this.value,
    this.emphasized = false,
    this.accent = false,
  });

  final String label;
  final String value;
  final bool emphasized;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: emphasized ? 13.5 : 13,
              fontWeight: emphasized ? FontWeight.w900 : FontWeight.w800,
              letterSpacing: -0.25,
              color: emphasized
                  ? const Color(0xFF191F28)
                  : const Color(0xFF4E5968),
            ),
          ),
        ),
        const SizedBox(width: 10),
          Text(
          value,
            style: TextStyle(
              fontFamily: 'Pretendard',
            fontSize: emphasized ? 13.5 : 12.5,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.25,
            color: accent ? const Color(0xFFFF6422) : const Color(0xFF6B7684),
          ),
        ),
      ],
    );
  }
}

class _FridgeRecipeIngredientLink {
  const _FridgeRecipeIngredientLink({
    required this.recipeId,
    required this.recipeName,
    required this.requiredQty,
    required this.unit,
    this.date,
  });

  final String recipeId;
  final String recipeName;
  final double requiredQty;
  final String unit;
  final String? date;
}

class _FreshnessResetChip extends StatelessWidget {
  const _FreshnessResetChip({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
              child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                decoration: BoxDecoration(
          color: const Color(0xFFF2F4F6),
                  borderRadius: BorderRadius.circular(999),
        ),
        child: const Text(
          '초기화',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 10,
            fontWeight: FontWeight.w800,
            height: 1,
            letterSpacing: -0.2,
            color: Color(0xFF6B7684),
          ),
        ),
      ),
    );
  }
}

class _FridgeRecipeCountBadge extends StatelessWidget {
  const _FridgeRecipeCountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFEDEFF3), width: 1),
                  boxShadow: [
                    BoxShadow(
            color: Colors.black.withValues(alpha: 0.07),
            blurRadius: 10,
            offset: const Offset(0, 4),
                    ),
                  ],
                ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.restaurant_rounded,
            size: 10,
            color: Color(0xFF191F28),
          ),
          const SizedBox(width: 3),
          Text(
            '$count',
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 10,
              fontWeight: FontWeight.w900,
              height: 1,
              color: Color(0xFFFF6422),
            ),
          ),
        ],
      ),
    );
  }
}

class _FridgeAmountStepper extends StatefulWidget {
  const _FridgeAmountStepper({
    required this.amountText,
    required this.onMinus,
    required this.onPlus,
    required this.currentAmount,
    required this.unit,
    this.onSetAmount,
  });

  final String amountText;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;
  final double currentAmount;
  final String unit;
  final void Function(double)? onSetAmount;

  @override
  State<_FridgeAmountStepper> createState() => _FridgeAmountStepperState();
}

class _FridgeAmountStepperState extends State<_FridgeAmountStepper> {
  bool _editing = false;
  bool _typing = false;
  late TextEditingController _textCtrl;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _textCtrl = TextEditingController();
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus && _typing) {
      _applyTypedValue();
    }
  }

  void _startTyping() {
    // 분수 기호는 편집 필드에 넣지 않고 숫자로 넣는다.
    final editStr = (widget.currentAmount - widget.currentAmount.roundToDouble())
                .abs() <
            0.001
        ? '${widget.currentAmount.round()}'
        : widget.currentAmount.toStringAsFixed(
            (widget.currentAmount * 100).round() % 10 == 0 ? 1 : 2,
          );
    _textCtrl.text = editStr;
    _textCtrl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: editStr.length,
    );
    setState(() => _typing = true);
    // TextField 가 트리에 붙은 다음 프레임에 포커스해야 키보드가 안정적으로 뜬다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_typing) return;
      _focusNode.requestFocus();
    });
  }

  void _beginEditingWithKeyboard() {
    final editStr = (widget.currentAmount - widget.currentAmount.roundToDouble())
                .abs() <
            0.001
        ? '${widget.currentAmount.round()}'
        : widget.currentAmount.toStringAsFixed(
            (widget.currentAmount * 100).round() % 10 == 0 ? 1 : 2,
          );
    _textCtrl.text = editStr;
    _textCtrl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: editStr.length,
    );
    setState(() {
      _editing = true;
      _typing = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_typing) return;
      _focusNode.requestFocus();
    });
  }

  void _applyTypedValue() {
    final v = double.tryParse(_textCtrl.text.trim());
    if (v != null && v >= 0) {
      widget.onSetAmount?.call(v);
    }
    setState(() => _typing = false);
  }

  void _handleMinus() {
    if (_typing) _applyTypedValue();
    widget.onMinus?.call();
  }

  void _handlePlus() {
    if (_typing) _applyTypedValue();
    widget.onPlus?.call();
  }

  void _collapse() {
    if (_typing) _applyTypedValue();
    setState(() {
      _editing = false;
      _typing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return TapRegion(
      onTapOutside: _editing ? (_) => _collapse() : null,
      child: GestureDetector(
        onTap: _editing ? null : _beginEditingWithKeyboard,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          height: 34,
          decoration: BoxDecoration(
            color: _editing ? const Color(0xFFFFF7F3) : const Color(0xFFF5F6F8),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _editing
                  ? const Color(0xFFFFD8C8)
                  : const Color(0xFFECEFF3),
              width: 1,
            ),
          ),
          child: _editing
              ? Row(
                  children: [
                    _FridgeStepperIconButton(
                      icon: Icons.remove_rounded,
                      onTap: widget.onMinus == null ? null : _handleMinus,
                    ),
                    Expanded(
                      child: GestureDetector(
                        onTap: _typing ? null : _startTyping,
                        behavior: HitTestBehavior.opaque,
                        child: Center(
                          child: _typing
                              ? TextField(
                                  controller: _textCtrl,
                                  focusNode: _focusNode,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 12,
                                    fontWeight: FontWeight.w900,
                                    height: 1,
                                    letterSpacing: -0.3,
                                    color: Color(0xFFFF6422),
                                  ),
                                  decoration: const InputDecoration(
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.zero,
                                    isDense: true,
                                  ),
                                  onSubmitted: (_) => _applyTypedValue(),
                                )
                              : Text(
                                  widget.amountText,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 12,
                                    fontWeight: FontWeight.w900,
                                    height: 1,
                                    letterSpacing: -0.3,
                                    color: Color(0xFF191F28),
                                  ),
                                ),
                        ),
                      ),
                    ),
                    _FridgeStepperIconButton(
                      icon: Icons.add_rounded,
                      onTap: widget.onPlus == null ? null : _handlePlus,
                    ),
                  ],
                )
              : Center(
                  child: Text(
                    widget.amountText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      height: 1,
                      letterSpacing: -0.3,
                      color: Color(0xFF4E5968),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

class _FridgeStepperIconButton extends StatelessWidget {
  const _FridgeStepperIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;
  static const Color _color = Color(0xFFFF6422);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Opacity(
        opacity: onTap == null ? 0.35 : 1,
        child: SizedBox(
          width: 44,
          height: 34,
          child: Center(child: Icon(icon, size: 18, color: _color)),
        ),
      ),
    );
  }
}

class _TinyIconPill extends StatelessWidget {
  const _TinyIconPill({
    required this.icon,
    required this.label,
    this.color = const Color(0xFF6B7684),
    this.background = const Color(0xFFF2F4F6),
  });

  final IconData icon;
  final String label;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
                  style: TextStyle(
                    fontFamily: 'Pretendard',
              fontSize: 11,
              fontWeight: FontWeight.w800,
              height: 1,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecipeSheetActionButton extends StatelessWidget {
  const _RecipeSheetActionButton({
    required this.label,
    required this.icon,
    required this.filled,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = filled ? const Color(0xFFFF6422) : Colors.white;
    final fg = filled ? Colors.white : const Color(0xFF4E5968);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(13),
          border: filled
              ? null
              : Border.all(color: const Color(0xFFE5E8EB), width: 1),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.max,
          children: [
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 12.5,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.2,
                color: fg,
            ),
          ),
        ],
        ),
      ),
    );
  }
}

/// Figma 97-4514: fridge recipe card — 80x100 image, title, date·time·servings, 요리 시작 | 요리 완료, 구매한 재료 row.
class _FigmaFridgeRecipeCard extends StatefulWidget {
  const _FigmaFridgeRecipeCard({
    required this.recipe,
    required this.thumbnailUrl,
    required this.brightness,
    required this.allRecipes,
    required this.recipeMetaById,
    required this.purchasedByName,
    required this.onStartCooking,
    required this.onCookingComplete,
    required this.onOpenRecipeDetail,
  });

  final Map<String, dynamic> recipe;
  final String thumbnailUrl;
  final Brightness brightness;
  final List<Map<String, dynamic>> allRecipes;
  final Map<String, Map<String, dynamic>> recipeMetaById;
  final Map<String, Map<String, dynamic>> purchasedByName;
  final VoidCallback onStartCooking;
  final VoidCallback onCookingComplete;
  final VoidCallback onOpenRecipeDetail;

  @override
  State<_FigmaFridgeRecipeCard> createState() => _FigmaFridgeRecipeCardState();
}

class _FigmaFridgeRecipeCardState extends State<_FigmaFridgeRecipeCard> {
  bool _ingredientsExpanded = false;

  String _fmtQtyWithUnit(double qty, String unit) {
    final u = unit.trim().toLowerCase();
    // Auto-scale g→kg and ml→L so the display matches cart card "담은양" labels.
    if (u == 'g' && qty >= 1000) {
      final kg = qty / 1000;
      final s = kg % 1 == 0 ? '${kg.toInt()}' : kg.toStringAsFixed(1);
      return '${s}kg';
    }
    if (u == 'ml' && qty >= 1000) {
      final l = qty / 1000;
      final s = l % 1 == 0 ? '${l.toInt()}' : l.toStringAsFixed(1);
      return '${s}L';
    }
    final display = _truncateUnit(unit, 10);
    if (qty % 1 == 0) return '${qty.toInt()}$display';
    return '${qty.toStringAsFixed(qty >= 100 ? 0 : 1)}$display';
  }

  Widget _buildPurchasedUsedRow({
    required String displayName,
    required String imageUrl,
    required String purchasedText,
    required String usedText,
  }) {
    return Container(
      height: 55.33,
      padding: const EdgeInsets.symmetric(horizontal: 12.667, vertical: 0.667),
      decoration: ShapeDecoration(
        color: const Color(0xFFF9F9FB),
        shape: RoundedRectangleBorder(
          side: const BorderSide(width: 0.67, color: Color(0xFFF0F0F5)),
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 38,
            height: 38,
            clipBehavior: Clip.antiAlias,
            decoration: ShapeDecoration(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: imageUrl.isNotEmpty
                ? AppNetworkImage(
                    imageUrl: imageUrl,
                    fit: BoxFit.cover,
                    width: 38,
                    height: 38,
                    memCacheWidth: AppNetworkImage.listThumbCacheSize,
                    memCacheHeight: AppNetworkImage.listThumbCacheSize,
                    errorWidget: _placeholderSmallIngredientImage(),
                  )
                : _placeholderSmallIngredientImage(),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    color: Color(0xFF111111),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    height: 1.50,
                    letterSpacing: -0.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      purchasedText,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        color: Color(0xFFAEAEB2),
                        fontSize: 10,
                        fontWeight: FontWeight.w400,
                        height: 1.50,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      '→',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        color: Color(0xFFD1D5DB),
                        fontSize: 9,
                        fontWeight: FontWeight.w400,
                        height: 1.50,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      usedText,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        color: Color(0xFFFF6422),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        height: 1.50,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeholderSmallIngredientImage() {
    return Container(
      color: const Color(0xFFE8E8EC),
      child: Image.asset(
        'assets/default_profile_avatar.png',
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            const Icon(Icons.eco, size: 18, color: Color(0xFFB0B0B5)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final recipe = widget.recipe;
    final currentRecipeId = recipe['recipeId']?.toString() ?? '';
    final meta = widget.recipeMetaById[currentRecipeId] ?? const {};
    final sourceRaw = recipe['source'];
    final platform =
        (meta['platform'] as String?)?.trim() ??
        (sourceRaw is Map
            ? (sourceRaw['platform'] as String?)?.trim() ?? ''
            : recipe['platform']?.toString().trim() ?? '');
    final sourceUrl =
        (meta['sourceUrl'] as String?)?.trim() ??
        (recipe['sourceUrl'] as String?)?.trim() ??
        (sourceRaw is Map ? (sourceRaw['url'] as String?)?.trim() : null) ??
        '';
    final recipeName = recipe['recipeName']?.toString() ?? '레시피';
    final dateStr = recipe['date']?.toString();
    final servings = (recipe['servings'] as num?)?.toInt() ?? 1;
    final totalMinutes = (recipe['totalMinutes'] as num?)?.toInt();
    final ingredients =
        (recipe['ingredients'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final dateDisplay = dateStr != null && dateStr.length >= 10
        ? _formatFridgeDateFigma(dateStr)
        : '';
    final timeDisplay = totalMinutes != null && totalMinutes > 0
        ? '$totalMinutes분'
        : '—분';
    final servingsDisplay = '$servings인분';

    return Container(
      padding: const EdgeInsets.all(0.67),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          width: 0.67,
          color: Colors.black.withValues(alpha: 0.05),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 16,
            offset: Offset(0, 2),
            spreadRadius: 0,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onOpenRecipeDetail,
            child: SizedBox(
              height: 124,
              child: Stack(
                children: [
                  Positioned(
                    left: 104,
                    top: 12,
                    right: 12,
                    child: SizedBox(
                      height: 100,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  recipeName,
                                  style: const TextStyle(
                                    fontFamily: 'Pretendard',
                                    color: Color(0xFF111111),
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w800,
                                    height: 1.50,
                                    letterSpacing: -0.4,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    if (dateDisplay.isNotEmpty) ...[
                                      Icon(
                                        Icons.calendar_today_rounded,
                                        size: 11,
                                        color: _figmaOrange,
                                      ),
                                      const SizedBox(width: 3),
                                      Text(
                                        dateDisplay,
                                        style: const TextStyle(
                                          fontFamily: 'Pretendard',
                                          color: Color(0xFFFF6422),
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          height: 1.50,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      const Text(
                                        '·',
                                        style: TextStyle(
                                          fontFamily: 'Pretendard',
                                          color: Color(0xFFD1D5DB),
                                          fontSize: 9,
                                          fontWeight: FontWeight.w400,
                                          height: 1.50,
                                        ),
                                      ),
                                    ],
                                    const SizedBox(width: 6),
                                    Icon(
                                      Icons.schedule_rounded,
                                      size: 11,
                                      color: _figmaTextGray,
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      timeDisplay,
                                      style: const TextStyle(
                                        fontFamily: 'Pretendard',
                                        color: Color(0xFF6B7280),
                                        fontSize: 11,
                                        fontWeight: FontWeight.w400,
                                        height: 1.50,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    const Text(
                                      '·',
                                      style: TextStyle(
                                        fontFamily: 'Pretendard',
                                        color: Color(0xFFD1D5DB),
                                        fontSize: 9,
                                        fontWeight: FontWeight.w400,
                                        height: 1.50,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Icon(
                                      Icons.people_outline_rounded,
                                      size: 11,
                                      color: _figmaTextGray,
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      servingsDisplay,
                                      style: const TextStyle(
                                        fontFamily: 'Pretendard',
                                        color: Color(0xFF6B7280),
                                        fontSize: 11,
                                        fontWeight: FontWeight.w400,
                                        height: 1.50,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            Row(
                              children: [
                                Expanded(
                                  child: GestureDetector(
                                    onTap: widget.onStartCooking,
                                    child: Container(
                                      height: 30,
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(
                                          100,
                                        ),
                                        border: Border.all(
                                          width: 1.33,
                                          color: const Color(0xFFE5E7EB),
                                        ),
                                      ),
                                      alignment: Alignment.center,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                      child: const FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Text(
                                          '요리 시작',
                                          style: TextStyle(
                                            fontFamily: 'Pretendard',
                                            color: Color(0xFF6B7280),
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            height: 1.50,
                                            letterSpacing: -0.2,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: GestureDetector(
                                    onTap: widget.onCookingComplete,
                                    child: Container(
                                      height: 30,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFFF6422),
                                        borderRadius: BorderRadius.circular(
                                          100,
                                        ),
                                      ),
                                      alignment: Alignment.center,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                      child: const FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons
                                                  .check_circle_outline_rounded,
                                              size: 12,
                                              color: Colors.white,
                                            ),
                                            SizedBox(width: 4),
                                            Text(
                                              '요리 완료',
                                              style: TextStyle(
                                                fontFamily: 'Pretendard',
                                                color: Colors.white,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                                height: 1.50,
                                                letterSpacing: -0.2,
                                              ),
                                            ),
                                          ],
                                        ),
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
                  ),
                  Positioned(
                    left: 12,
                    top: 12,
                    child: Container(
                      width: 80,
                      height: 100,
                      decoration: BoxDecoration(
                        color: _figmaBorder,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: widget.thumbnailUrl.isNotEmpty
                          ? ThumbnailLetterboxMitigation(
                              platform: platform,
                              imageUrl: widget.thumbnailUrl,
                              sourceUrl: sourceUrl,
                              child: AppNetworkImage(
                                imageUrl: widget.thumbnailUrl,
                                fit: BoxFit.cover,
                                width: 80,
                                height: 100,
                                memCacheWidth:
                                    AppNetworkImage.listThumbCacheSize,
                                memCacheHeight:
                                    AppNetworkImage.listThumbCacheSize,
                                errorWidget: _placeholderImage(),
                              ),
                            )
                          : _placeholderImage(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          GestureDetector(
            onTap: () {
              if (ingredients.isNotEmpty) {
                setState(() => _ingredientsExpanded = !_ingredientsExpanded);
              }
            },
            child: Container(
              height: 40.67,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(width: 0.67, color: const Color(0xFFF2F2F7)),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (ingredients.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: _buildRecipeThumbnailCircles(ingredients),
                        ),
                      Text(
                        ingredients.isEmpty
                            ? '재료 없음'
                            : '재료 ${ingredients.length}개',
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          color: Color(0xFF6B7280),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          height: 1.50,
                        ),
                      ),
                    ],
                  ),
                  Icon(
                    _ingredientsExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 14,
                    color: const Color(0xFF9CA3AF),
                  ),
                ],
              ),
            ),
          ),
          if (_ingredientsExpanded && ingredients.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
              decoration: BoxDecoration(color: Colors.white),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (int i = 0; i < ingredients.length; i++) ...[
                    if (i > 0) const SizedBox(height: 6),
                    Builder(
                      builder: (context) {
                        final ing = ingredients[i];
                        final keyName =
                            (ing['item'] ?? ing['name'])?.toString() ?? '';
                        final purchased = widget.purchasedByName[keyName];

                        // Re-derive the "담은 양" from stored product metadata
                        // so it always matches what the shopping cart displayed,
                        // even if totalQty was saved incorrectly by old code.
                        final storedProductName =
                            purchased?['productName']?.toString() ?? '';
                        final storedPkgSize =
                            (purchased?['packageSize'] as num?)?.toDouble();
                        final storedPkgUnit = purchased?['packageUnit']
                            ?.toString();
                        final reParsed = storedProductName.isNotEmpty
                            ? IngredientUnitConverter.parseProductAmount(
                                productName: storedProductName,
                                packageSize: storedPkgSize,
                                packageUnit: storedPkgUnit,
                              )
                            : null;
                        final purchasedQty =
                            (reParsed?.rawAmount != null &&
                                reParsed!.rawAmount! > 0)
                            ? reParsed.rawAmount!
                            : (purchased?['totalQty'] as num?)?.toDouble();
                        final purchasedUnit =
                            (reParsed?.rawUnit != null &&
                                reParsed!.rawUnit!.isNotEmpty)
                            ? reParsed.rawUnit!
                            : purchased?['unit']?.toString() ??
                                  ing['unit']?.toString() ??
                                  '개';
                        final purchasedLabel =
                            (reParsed?.label != null &&
                                reParsed!.label.isNotEmpty)
                            ? reParsed.label
                            : null;

                        final usedUnit =
                            ing['unit']?.toString() ?? purchasedUnit;
                        final usedQty = _safeQty(ing['qty']);
                        final usedShoppingQty = _shoppingQtyForRecipeIngredient(
                          ing,
                          keyName,
                        );
                        final purchasedQtySafe =
                            purchasedQty ?? usedShoppingQty;

                        final productName =
                            (purchased?['productName']
                                    ?.toString()
                                    .trim()
                                    .isNotEmpty ==
                                true)
                            ? purchased!['productName'].toString()
                            : (ing['productName']
                                      ?.toString()
                                      .trim()
                                      .isNotEmpty ==
                                  true)
                            ? ing['productName'].toString()
                            : (keyName.isNotEmpty ? keyName : '—');

                        final imageUrl =
                            (purchased?['productImageUrl']
                                    ?.toString()
                                    .trim()
                                    .isNotEmpty ==
                                true)
                            ? purchased!['productImageUrl'].toString()
                            : (ing['productImageUrl']
                                      ?.toString()
                                      .trim()
                                      .isNotEmpty ==
                                  true)
                            ? ing['productImageUrl'].toString()
                            : '';

                        // Show recipe amount in its original cooking unit.
                        // If the cooking unit differs from the purchase unit AND
                        // the ingredient has a researched conversion, append "(약 Xg)".
                        // e.g. "1개 (약 200g) 사용" for 양파, or "2큰술 사용" for 간장.
                        // Use the re-parsed label (e.g. "300g") when available,
                        // otherwise fall back to formatting from stored numbers.
                        final purchasedDisplay =
                            purchasedLabel ??
                            _fmtQtyWithUnit(purchasedQtySafe, purchasedUnit);

                        return _buildPurchasedUsedRow(
                          displayName: productName,
                          imageUrl: imageUrl,
                          purchasedText: '구매 $purchasedDisplay',
                          usedText:
                              IngredientUnitConverter.formatCookingWithShoppingApprox(
                                ingredientName: keyName,
                                cookingQty: usedQty,
                                cookingUnit: usedUnit,
                                shoppingUnit: purchasedUnit,
                              ),
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Overlapping circles showing recipe thumbnails by relevance of ingredients.
  /// Recipes that use more of this card's ingredients appear first.
  Widget _buildRecipeThumbnailCircles(List<Map<String, dynamic>> ingredients) {
    const double circleSize = 16.0;
    const double overlap = 2.0;
    const double borderWidth = 2.0;

    // Ingredient names in this recipe
    final ingredientNames = ingredients
        .map((ing) => (ing['item'] ?? ing['name'])?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .toSet();

    // Score each recipe by relevance: how many of this card's ingredients it uses.
    // This recipe first, then others sorted by shared ingredient count.
    final currentRecipeId = widget.recipe['recipeId']?.toString() ?? '';
    final scored = <Map<String, dynamic>>[];
    for (final r in widget.allRecipes) {
      final rid = r['recipeId']?.toString() ?? '';
      final ings =
          (r['ingredients'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      int matchCount = 0;
      for (final ing in ings) {
        final name = (ing['item'] ?? ing['name'])?.toString() ?? '';
        if (ingredientNames.contains(name)) matchCount++;
      }
      if (matchCount > 0) {
        scored.add({'recipeId': rid, 'matchCount': matchCount});
      }
    }
    scored.sort((a, b) {
      final aId = a['recipeId'] as String? ?? '';
      final bId = b['recipeId'] as String? ?? '';
      final aIsCurrent = aId == currentRecipeId;
      final bIsCurrent = bId == currentRecipeId;
      if (aIsCurrent && !bIsCurrent) return -1;
      if (!aIsCurrent && bIsCurrent) return 1;
      return (b['matchCount'] as int).compareTo(a['matchCount'] as int);
    });

    final imageUrls = scored
        .take(3)
        .map(
          (s) =>
              widget.recipeMetaById[s['recipeId'] as String?]?['thumbnailUrl']
                  ?.toString() ??
              '',
        )
        .where((url) => url.isNotEmpty)
        .toList();

    if (imageUrls.isEmpty) {
      return Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: borderWidth),
          boxShadow: const [
            BoxShadow(
              color: Color(0x19000000),
              blurRadius: 4,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: ClipOval(
          child: Icon(
            Icons.restaurant_outlined,
            size: 12,
            color: _figmaTextGray2,
          ),
        ),
      );
    }

    final n = imageUrls.length;
    final totalWidth =
        (circleSize + borderWidth * 2) + (n - 1) * (circleSize - overlap);
    return SizedBox(
      width: totalWidth,
      height: circleSize + borderWidth * 2,
      child: Stack(
        clipBehavior: Clip.none,
        children: List.generate(n, (i) {
          final url = imageUrls[i];
          return Positioned(
            left: i * (circleSize - overlap),
            top: 0,
            child: Container(
              width: circleSize + borderWidth * 2,
              height: circleSize + borderWidth * 2,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                border: Border.all(color: Colors.white, width: borderWidth),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x19000000),
                    blurRadius: 4,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
              child: ClipOval(
                child: url.isNotEmpty
                    ? AppNetworkImage(
                        imageUrl: url,
                        width: circleSize,
                        height: circleSize,
                        fit: BoxFit.cover,
                        memCacheWidth: AppNetworkImage.avatarCacheSize,
                        memCacheHeight: AppNetworkImage.avatarCacheSize,
                        errorWidget: Icon(
                          Icons.restaurant_outlined,
                          size: circleSize * 0.7,
                          color: _figmaTextGray2,
                        ),
                      )
                    : Icon(
                        Icons.restaurant_outlined,
                        size: circleSize * 0.7,
                        color: _figmaTextGray2,
                      ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _placeholderImage() {
    return Center(
      child: Icon(Icons.restaurant_rounded, size: 32, color: _figmaTextGray),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Figma-style ingredient row with tap-to-edit amount (uses _stepForLeftover)
// ═══════════════════════════════════════════════════════════════════════════════

class _ExistingIngredientInfo {
  const _ExistingIngredientInfo({required this.qty, required this.unit});

  final double qty;
  final String unit;

  String get amountLabel {
    final normalized = unit.trim();
    if (normalized.toLowerCase() == 'g' && qty >= 1000) {
      final kg = qty / 1000;
      final text = kg % 1 == 0 ? '${kg.toInt()}' : kg.toStringAsFixed(1);
      return '${text}kg';
    }
    if (normalized.toLowerCase() == 'ml' && qty >= 1000) {
      final l = qty / 1000;
      final text = l % 1 == 0 ? '${l.toInt()}' : l.toStringAsFixed(1);
      return '${text}L';
    }
    final amount = _formatQuantityLabel(qty);
    return '$amount${_truncateUnit(normalized.isEmpty ? '개' : normalized, 8)}';
  }
}

class _ExistingIngredientBadge extends StatelessWidget {
  const _ExistingIngredientBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3EE),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 11,
          fontWeight: FontWeight.w900,
          height: 1,
          letterSpacing: -0.2,
          color: Color(0xFFFF6422),
        ),
      ),
    );
  }
}

/// 추천 재료 모음(번들) 정의. 우리 시드 데이터(`ingredientShelfLifeSeedData`)에
/// 존재하는 재료명만 사용한다.
class _IngredientBundle {
  const _IngredientBundle({
    required this.title,
    required this.subtitle,
    required this.categoryKey,
    required this.items,
  });

  final String title;
  final String subtitle;
  final String categoryKey;
  final List<String> items;
}

class _AddIngredientSheet extends StatefulWidget {
  const _AddIngredientSheet({
    required this.existingIngredients,
    required this.onAdd,
    this.onAddBatch,
    this.startWithReceiptScan = false,
  });

  final Map<String, _ExistingIngredientInfo> existingIngredients;
  final void Function(String name, double qty, String unit) onAdd;
  // source/analyticsMethod: 영수증 스캔처럼 출처가 다른 배치 추가를 구분하기
  // 위한 선택 태그. 생략하면 호출부가 기본값('manual')으로 처리한다.
  final void Function(
    List<({String name, double qty, String unit})> items, {
    String? source,
    String? analyticsMethod,
  })?
      onAddBatch;

  /// true면 재료 추가 UI 대신 영수증 스캔 플로우를 바로 시작한다
  /// (냉장고 헤더 "영수증" 버튼 진입점).
  final bool startWithReceiptScan;

  @override
  State<_AddIngredientSheet> createState() => _AddIngredientSheetState();
}

class _AddIngredientSheetState extends State<_AddIngredientSheet> {
  final _searchController = TextEditingController();
  final _qtyController = TextEditingController(text: '1');
  String? _selectedName;
  String? _selectedUnit;
  List<String> _suggestions = [];

  /// 영수증 사진 업로드 → 인식 중 로딩 상태 (버튼 중복 탭 방지 겸용).
  bool _isScanningReceipt = false;
  final ImagePicker _receiptImagePicker = ImagePicker();

  /// 검색 결과 인라인 다중 선택 상태 (번들 팝업과 동일 UX).
  final Map<String, bool> _searchSelected = {};
  final Map<String, double> _searchQty = {};
  final Map<String, String> _searchUnit = {};

  /// 재료 추가 홈에서 영수증 플로우로 인라인 전환했는지.
  /// (헤더 "영수증" 진입의 [startWithReceiptScan] 과 구분)
  bool _inlineReceiptMode = false;

  /// 카테고리 그리드에서 고른 그룹. null 이면 브라우즈 홈.
  String? _browsingCategoryKey;

  /// SharedPreferences 에 저장된 최근 담은 재료 이름.
  List<String> _recentIngredients = [];

  /// 영수증 분석 결과 히스토리 (사진 제외).
  List<ReceiptScanHistoryEntry> _receiptScanHistory = [];

  static const String _recentIngredientsPrefsKey = 'fridge_recent_ingredients';
  static const int _recentIngredientsMax = 12;

  static final List<String> _allIngredients =
      ingredientShelfLifeSeedData.keys.toList()..sort();

  /// 사용자가 직접 고를 수 있는 단위 목록.
  static const List<String> _unitOptions = [
    '개', 'g', 'kg', 'ml', 'L', '모', '장', '단', '대', '줄',
    '봉', '팩', '캔', '병', '컵', '큰술', '작은술', '꼬집',
  ];

  /// 추천 재료 모음. 처음 시트를 열었을 때(검색 전) 노출해 재료 추가를 돕는다.
  static const List<_IngredientBundle> _bundles = [
    _IngredientBundle(
      title: '자취 필수 양념',
      subtitle: '없으면 요리가 안 되는 기본 양념',
      categoryKey: IngredientCategoryUnifier.seasoningsSauces,
      items: ['소금', '설탕', '간장', '식용유', '다진 마늘', '후추'],
    ),
    _IngredientBundle(
      title: '국·찌개 베이스',
      subtitle: '국물 요리에 자주 쓰는 재료',
      categoryKey: IngredientCategoryUnifier.seasoningsSauces,
      items: ['된장', '고추장', '고춧가루', '멸치', '다시마', '대파'],
    ),
    _IngredientBundle(
      title: '볶음·구이 채소',
      subtitle: '어떤 요리에나 잘 어울리는 채소',
      categoryKey: IngredientCategoryUnifier.vegFruit,
      items: ['양파', '대파', '당근', '애호박', '마늘', '청양고추'],
    ),
    _IngredientBundle(
      title: '정육 기본 모음',
      subtitle: '단백질을 책임지는 기본 고기',
      categoryKey: IngredientCategoryUnifier.meatProcessedEgg,
      items: ['삼겹살', '돼지고기', '소고기', '닭가슴살', '달걀'],
    ),
    _IngredientBundle(
      title: '아침·간단식',
      subtitle: '바쁜 날 든든한 한 끼',
      categoryKey: IngredientCategoryUnifier.dairy,
      items: ['달걀', '우유', '식빵', '치즈', '버터'],
    ),
    _IngredientBundle(
      title: '면·밥 요리 기본',
      subtitle: '한 그릇 요리에 필요한 재료',
      categoryKey: IngredientCategoryUnifier.grains,
      items: ['쌀', '소면', '라면', '스파게티', '당면', '두부'],
    ),
  ];

  _ExistingIngredientInfo? _existingInfoFor(String name) {
    return widget.existingIngredients[name.trim()];
  }

  /// 단위에 맞는 기본 수량.
  static double _defaultQtyForUnit(String unit) {
    final u = unit.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    if (u == 'g' || u == 'ml') return 100;
    if (u == 'kg' || u == 'l' || u == 'ℓ') return 1;
    if (_isSpoonOrCupUnit(u)) return 1;
    return 1;
  }

  static String _formatQty(double v) => _formatQuantityLabel(v);

  void _setQtyControllerValue(double qty) {
    _qtyController.text = _editableQtyText(qty);
  }

  static String _editableQtyText(double qty) {
    if ((qty - qty.roundToDouble()).abs() < 0.001) return qty.round().toString();
    if ((qty - 1 / 3).abs() < 0.02) return (1 / 3).toStringAsFixed(3);
    if ((qty - 2 / 3).abs() < 0.02) return (2 / 3).toStringAsFixed(3);
    final fixed = qty.toStringAsFixed(2);
    if (fixed.endsWith('0')) return qty.toStringAsFixed(1);
    return fixed;
  }

  /// 수량 숫자를 탭했을 때 임의 값을 직접 입력받는다.
  Future<double?> _promptEditableQty({
    required double qty,
    required String unit,
  }) async {
    final controller = TextEditingController(text: _editableQtyText(qty));
    final focusNode = FocusNode();
    final result = await showDialog<double>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        // 다이얼로그 레이아웃 직후 포커스 — Chrome/웹에서도 키보드가 안정적으로 뜬다.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!focusNode.canRequestFocus) return;
          focusNode.requestFocus();
          controller.selection = TextSelection(
            baseOffset: 0,
            extentOffset: controller.text.length,
          );
        });
        return AlertDialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
          contentPadding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
          actionsPadding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          title: const Text(
            '수량 입력',
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 17,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.35,
              color: Color(0xFF191F28),
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '원하는 숫자를 직접 입력해 주세요. ($unit)',
                style: const TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  height: 1.4,
                  color: Color(0xFF8B95A1),
                ),
              ),
              const SizedBox(height: 14),
              Container(
                height: 52,
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F6F8),
                  borderRadius: BorderRadius.circular(14),
                ),
                alignment: Alignment.center,
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textInputAction: TextInputAction.done,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.4,
                    color: Color(0xFF191F28),
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  onSubmitted: (raw) {
                    final v = double.tryParse(raw.trim());
                    if (v != null && v >= 0) {
                      Navigator.of(dialogContext).pop(v);
                    }
                  },
                ),
              ),
            ],
          ),
          actions: [
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    style: TextButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      foregroundColor: const Color(0xFF6B7684),
                      backgroundColor: const Color(0xFFF2F4F6),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text(
                      '취소',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextButton(
                    onPressed: () {
                      final v = double.tryParse(controller.text.trim());
                      if (v == null || v < 0) return;
                      Navigator.of(dialogContext).pop(v);
                    },
                    style: TextButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      foregroundColor: Colors.white,
                      backgroundColor: const Color(0xFFFF6422),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text(
                      '확인',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
    focusNode.dispose();
    controller.dispose();
    return result;
  }

  double _currentQtyFromField() {
    return double.tryParse(_qtyController.text.trim()) ?? 1;
  }

  void _bumpSelectedQty(double delta) {
    final unit = _selectedUnit ??
        _defaultUnitForIngredient(_selectedName ?? _searchController.text.trim());
    final current = _currentQtyFromField();
    final next = delta < 0
        ? _decrementQty(current, unit)
        : _incrementQty(current, unit);
    setState(() => _setQtyControllerValue(next));
  }

  void _applyFractionChip(double value) {
    setState(() => _setQtyControllerValue(value));
  }

  static String _defaultUnitForIngredient(String name) {
    final catKey = IngredientCategoryUnifier.groupKeyFromIngredient(
      internalCategory: null,
      ingredientName: name,
    );
    switch (catKey) {
      case IngredientCategoryUnifier.meatProcessedEgg:
      case IngredientCategoryUnifier.seafood:
      case IngredientCategoryUnifier.grains:
        return 'g';
      case IngredientCategoryUnifier.dairy:
        if (name.contains('우유') ||
            name.contains('크림') ||
            name.contains('요거트')) {
          return 'ml';
        }
        return '개';
      case IngredientCategoryUnifier.seasoningsSauces:
        if (name.contains('소스') ||
            name.contains('식초') ||
            name.contains('기름') ||
            name.contains('오일') ||
            name.contains('참기름') ||
            name.contains('들기름') ||
            name.contains('간장') ||
            name.contains('액젓') ||
            name.contains('맛술') ||
            name.contains('술') ||
            name.contains('미림') ||
            name.contains('물엿') ||
            name.contains('시럽') ||
            name.contains('주스')) {
          return 'ml';
        }
        return 'g';
      case IngredientCategoryUnifier.vegFruit:
        if (name.contains('두부')) return '모';
        return '개';
      default:
        return '개';
    }
  }

  /// 영수증 진입 단계: choose → scanning → review.
  String _receiptPhase = 'choose';

  /// review 단계용 인식 결과 상태.
  List<FridgeScanItemResult> _reviewItems = [];
  List<bool> _reviewSelected = [];
  List<double> _reviewQty = [];
  List<String> _reviewUnit = [];
  bool _receiptReportSent = false;
  bool _receiptReportSending = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    unawaited(_loadRecentIngredients());
    unawaited(_loadReceiptScanHistory());
  }

  @override
  void dispose() {
    _searchController.dispose();
    _qtyController.dispose();
    super.dispose();
  }

  Future<void> _loadRecentIngredients() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_recentIngredientsPrefsKey) ?? const [];
      if (!mounted) return;
      setState(() {
        _recentIngredients = stored
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .take(_recentIngredientsMax)
            .toList();
      });
    } catch (_) {
      // 최근 목록은 보조 UX — 실패해도 추가 플로우는 그대로 동작.
    }
  }

  Future<void> _loadReceiptScanHistory() async {
    final entries = await ReceiptScanHistoryStore.load();
    if (!mounted) return;
    setState(() => _receiptScanHistory = entries);
  }

  Future<void> _persistReceiptScanHistory(
    List<FridgeScanItemResult> items,
  ) async {
    final next = await ReceiptScanHistoryStore.addFromScan(items: items);
    if (!mounted) return;
    setState(() => _receiptScanHistory = next);
  }

  Future<void> _deleteReceiptScanHistory(String id) async {
    Haptics.light();
    final next = await ReceiptScanHistoryStore.remove(id);
    if (!mounted) return;
    setState(() => _receiptScanHistory = next);
  }

  Future<void> _openReceiptHistoryEntry(ReceiptScanHistoryEntry entry) async {
    if (entry.items.isEmpty) return;
    Haptics.light();
    _enterReceiptReview(entry.items);
  }

  void _enterReceiptReview(List<FridgeScanItemResult> items) {
    final normalized = <FridgeScanItemResult>[];
    for (final it in items) {
      final normalizedName = ReceiptScanItemNormalizer.normalizeName(
        it.name,
        rawLine: it.rawLine,
      );
      final isFood = it.isFood &&
          ReceiptScanItemNormalizer.isLikelyFood(
            normalizedName,
            rawLine: it.rawLine,
          );
      final catalogName = ReceiptCatalogMatcher.resolveCatalogName(
        normalizedName,
        rawLine: it.rawLine,
      );
      final inCatalog = catalogName != null;
      final name = catalogName ?? normalizedName;
      normalized.add(
        it.copyWith(
          name: name,
          category: ReceiptScanItemNormalizer.categoryForNormalizedName(
            name,
            it.category,
          ),
          isFood: isFood,
          inCatalog: inCatalog,
        ),
      );
    }
    final catalogFood =
        normalized.where((e) => e.isFood && e.inCatalog).toList();
    final unknownFood =
        normalized.where((e) => e.isFood && !e.inCatalog).toList();
    final nonFood = normalized.where((e) => !e.isFood).toList();
    final ordered = [...catalogFood, ...unknownFood, ...nonFood];
    setState(() {
      _reviewItems = ordered;
      _reviewSelected = [
        // 카탈로그 매칭된(확실한) 재료만 기본 선택. DB에 없는 재료는
        // 담을 수는 있지만, 확신이 덜하므로 사용자가 직접 선택하게 한다.
        for (final it in ordered)
          it.inCatalog && !it.isLowConfidence,
      ];
      _reviewUnit = [for (final it in ordered) it.unit];
      _reviewQty = [for (final it in ordered) it.qty];
      _receiptPhase = 'review';
      _isScanningReceipt = false;
      _receiptReportSent = false;
      _receiptReportSending = false;
    });
  }

  void _exitReceiptReview() {
    setState(() {
      _receiptPhase = 'choose';
      _reviewItems = [];
      _reviewSelected = [];
      _reviewQty = [];
      _reviewUnit = [];
      _receiptReportSent = false;
      _receiptReportSending = false;
    });
  }

  Future<void> _openReceiptRecognitionReportSheet({
    FridgeScanItemResult? focusItem,
  }) async {
    if (_receiptReportSent || _receiptReportSending) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        const SnackBar(
          content: Text('이미 알려주셨어요. 확인 후 개선할게요!'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    const reasons = <({String id, String label, String hint})>[
      (
        id: 'wrong_name',
        label: '이름이 틀려요',
        hint: '예: 브로콜리인데 다른 이름으로 나왔어요',
      ),
      (
        id: 'blocked_item',
        label: '레시피 추천에서 빠졌어요',
        hint: '식재료인데 찾지 못했다고 나와요',
      ),
      (
        id: 'missing_item',
        label: '빠진 재료가 있어요',
        hint: '영수증에 있는데 목록에 없어요',
      ),
      (
        id: 'junk_item',
        label: '이상한 게 재료로 나왔어요',
        hint: '식재료가 아닌데 위에 있어요',
      ),
      (id: 'other', label: '기타', hint: '자유롭게 적어 주세요'),
    ];

    var selectedReason = 'wrong_name';
    if (focusItem != null) {
      if (!focusItem.isFood) {
        selectedReason = 'junk_item';
      } else if (!focusItem.inCatalog) {
        selectedReason = 'blocked_item';
      }
    }
    final noteController = TextEditingController(
      text: focusItem == null
          ? ''
          : '${focusItem.name}'
              '${focusItem.rawLine != null && focusItem.rawLine!.trim().isNotEmpty ? ' / ${focusItem.rawLine}' : ''}',
    );

    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 12,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: StatefulBuilder(
            builder: (ctx, setModal) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE5E8EB),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '인식이 이상했나요?',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                      color: Color(0xFF191F28),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '알려주시면 바로 살펴보고 고칠게요.',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      height: 1.4,
                      letterSpacing: -0.2,
                      color: Color(0xFF8B95A1),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final r in reasons)
                        GestureDetector(
                          onTap: () => setModal(() => selectedReason = r.id),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 140),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 9,
                            ),
                            decoration: BoxDecoration(
                              color: selectedReason == r.id
                                  ? const Color(0xFF191F28)
                                  : const Color(0xFFF5F6F8),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              r.label,
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: selectedReason == r.id
                                    ? Colors.white
                                    : const Color(0xFF4E5968),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    reasons
                        .firstWhere((e) => e.id == selectedReason)
                        .hint,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFFAEB6BE),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: noteController,
                    maxLines: 3,
                    maxLength: 300,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                      color: Color(0xFF191F28),
                    ),
                    decoration: InputDecoration(
                      hintText: '어떻게 잘못됐는지 짧게 적어 주세요 (선택)',
                      hintStyle: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFFAEB6BE),
                      ),
                      filled: true,
                      fillColor: const Color(0xFFF7F8FA),
                      counterText: '',
                      contentPadding: const EdgeInsets.all(14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 50,
                    child: FilledButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF191F28),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text(
                        '보내기',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );

    final note = noteController.text.trim();
    noteController.dispose();
    if (submitted != true || !mounted) return;

    setState(() => _receiptReportSending = true);
    try {
      await FridgeScanReportService.instance.report(
        reason: selectedReason,
        note: note,
        photoType: 'receipt',
        items: _reviewItems,
        focusItemName: focusItem?.name,
        focusRawLine: focusItem?.rawLine,
      );
      if (!mounted) return;
      setState(() {
        _receiptReportSent = true;
        _receiptReportSending = false;
      });
      showAppSnackBar(
        context,
        const SnackBar(
          content: Text('알려주셔서 감사해요! 빠르게 살펴보고 개선할게요.'),
          duration: Duration(seconds: 3),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _receiptReportSending = false);
      showAppSnackBar(
        context,
        const SnackBar(
          content: Text('잠시 후 다시 시도해 주세요.'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _submitReceiptReview() {
    final onAddBatch = widget.onAddBatch;
    if (onAddBatch == null) return;
    final chosen = <({String name, double qty, String unit})>[];
    for (var i = 0; i < _reviewItems.length; i++) {
      if (i >= _reviewSelected.length || !_reviewSelected[i]) continue;
      final it = _reviewItems[i];
      // 비식품만 제외. 카탈로그 미매칭 식재료는 이름 그대로 담는다
      // (레시피 추천 제외 플래그는 저장 시 붙는다).
      if (!it.canAddToFridge) continue;
      final catalogName = ReceiptCatalogMatcher.resolveCatalogName(it.name) ??
          it.name;
      chosen.add((
        name: catalogName,
        qty: i < _reviewQty.length ? _reviewQty[i] : it.qty,
        unit: i < _reviewUnit.length ? _reviewUnit[i] : it.unit,
      ));
    }
    if (chosen.isEmpty) return;
    Haptics.light();
    onAddBatch(
      chosen,
      source: 'photo_receipt',
      analyticsMethod: 'photo_receipt',
    );
    unawaited(_rememberRecentNames(chosen.map((e) => e.name)));
    Navigator.of(context).pop();
  }

  String _formatReceiptHistoryTime(DateTime at) {
    final local = at.toLocal();
    final now = DateTime.now();
    final sameDay = local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    if (sameDay) return '오늘 $hh:$mm';
    return '${local.month}/${local.day} $hh:$mm';
  }

  String _formatReceiptWon(int amount) {
    final s = amount.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  Future<void> _rememberRecentNames(Iterable<String> names) async {
    final incoming = names
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (incoming.isEmpty) return;
    final merged = <String>[
      ...incoming,
      ..._recentIngredients.where((e) => !incoming.contains(e)),
    ];
    final next = merged.take(_recentIngredientsMax).toList();
    setState(() => _recentIngredients = next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_recentIngredientsPrefsKey, next);
    } catch (_) {}
  }

  void _onSearchChanged() {
    if (_selectedName != null) return;
    final q = _searchController.text.trim();
    if (q.isEmpty) {
      setState(() => _suggestions = []);
      return;
    }
    setState(() {
      // 검색 시작하면 카테고리 브라우즈는 해제.
      _browsingCategoryKey = null;
      _suggestions = _allIngredients
          .where((n) => n.contains(q))
          .take(20)
          .toList();
    });
  }

  static String _shortCategoryTitle(String key) {
    switch (key) {
      case IngredientCategoryUnifier.meatProcessedEgg:
        return '육류';
      case IngredientCategoryUnifier.seafood:
        return '해산물';
      case IngredientCategoryUnifier.vegFruit:
        return '채소·과일';
      case IngredientCategoryUnifier.dairy:
        return '유제품';
      case IngredientCategoryUnifier.grains:
        return '곡류·면';
      case IngredientCategoryUnifier.seasoningsSauces:
        return '양념·소스';
      default:
        return IngredientCategoryUnifier.titleFromKey(key);
    }
  }

  /// 카테고리별 대표(자주 쓰는) 재료. 전체 seed 대신 이 목록만 그리드에서 노출하고,
  /// 나머지는 상단 검색으로 찾게 한다.
  static const Map<String, List<String>> _featuredIngredientsByCategory = {
    IngredientCategoryUnifier.meatProcessedEgg: [
      '삼겹살',
      '돼지고기',
      '소고기',
      '닭가슴살',
      '닭고기',
      '베이컨',
      '햄',
      '소시지',
      '달걀',
    ],
    IngredientCategoryUnifier.seafood: [
      '고등어',
      '새우',
      '오징어',
      '연어',
      '참치',
      '멸치',
      '다시마',
      '미역',
      '어묵',
      '갈치',
    ],
    IngredientCategoryUnifier.vegFruit: [
      '양파',
      '대파',
      '당근',
      '마늘',
      '감자',
      '애호박',
      '청양고추',
      '배추',
      '토마토',
      '오이',
      '시금치',
      '콩나물',
      '두부',
      '버섯',
    ],
    IngredientCategoryUnifier.dairy: [
      '우유',
      '치즈',
      '버터',
      '요거트',
      '생크림',
      '달걀',
    ],
    IngredientCategoryUnifier.grains: [
      '쌀',
      '라면',
      '소면',
      '스파게티',
      '당면',
      '식빵',
      '밀가루',
      '떡',
    ],
    IngredientCategoryUnifier.seasoningsSauces: [
      '소금',
      '설탕',
      '간장',
      '된장',
      '고추장',
      '고춧가루',
      '식용유',
      '참기름',
      '후추',
      '다진 마늘',
      '맛술',
      '식초',
    ],
  };

  /// 카테고리 브라우즈용 대표 재료만 반환 (seed에 있는 이름만).
  List<String> _featuredIngredientsForCategory(String categoryKey) {
    final featured = _featuredIngredientsByCategory[categoryKey] ?? const [];
    final seed = _allIngredients.toSet();
    return [
      for (final name in featured)
        if (seed.contains(name)) name,
    ];
  }

  void _enterInlineReceiptMode() {
    Haptics.light();
    setState(() {
      _inlineReceiptMode = true;
      _receiptPhase = 'choose';
      _isScanningReceipt = false;
      _browsingCategoryKey = null;
    });
  }

  void _exitInlineReceiptMode() {
    setState(() {
      _inlineReceiptMode = false;
      _receiptPhase = 'choose';
      _isScanningReceipt = false;
    });
  }

  void _openCategoryBrowse(String categoryKey) {
    Haptics.light();
    setState(() {
      _browsingCategoryKey = categoryKey;
      _searchController.clear();
      _suggestions = [];
    });
  }

  void _exitCategoryBrowse() {
    setState(() => _browsingCategoryKey = null);
  }

  Future<void> _pickUnit() async {
    final name = _selectedName ?? _searchController.text.trim();
    final current = _selectedUnit ?? _defaultUnitForIngredient(name);
    final picked = await _pickUnitValue(current);
    if (picked != null && mounted) {
      setState(() => _selectedUnit = picked);
    }
  }

  /// 단위 선택 모달을 띄우고 선택된 단위를 반환한다(번들 시트 등에서 재사용).
  Future<String?> _pickUnitValue(String current) async {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFE5E8EB),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(height: 16),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '단위 선택',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.3,
                      color: Color(0xFF191F28),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _unitOptions.map((u) {
                    final selected = u == current;
                    return GestureDetector(
                      onTap: () => Navigator.pop(ctx, u),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: selected
                              ? const Color(0xFFFFF1EA)
                              : const Color(0xFFF2F4F6),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: selected
                                ? const Color(0xFFFF6422)
                                : Colors.transparent,
                            width: 1.2,
                          ),
                        ),
                        child: Text(
                          u,
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: selected
                                ? const Color(0xFFFF6422)
                                : const Color(0xFF191F28),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _submit() {
    final name = _selectedName ?? _searchController.text.trim();
    if (name.isEmpty) return;
    final qty = double.tryParse(_qtyController.text.trim()) ?? 1;
    final unit = _selectedUnit ?? _defaultUnitForIngredient(name);
    unawaited(_rememberRecentNames([name]));
    widget.onAdd(name, qty, unit);
    Navigator.pop(context);
  }

  bool get _canSubmit =>
      (_selectedName ?? _searchController.text.trim()).isNotEmpty;

  /// 검색 결과에서 선택된 재료 이름들.
  List<String> get _searchSelectedNames =>
      _searchSelected.entries.where((e) => e.value).map((e) => e.key).toList();

  void _toggleSearchSelect(String name) {
    setState(() {
      final on = _searchSelected[name] == true;
      if (on) {
        _searchSelected[name] = false;
    } else {
        _searchSelected[name] = true;
        final unit =
            _searchUnit.putIfAbsent(name, () => _defaultUnitForIngredient(name));
        _searchQty.putIfAbsent(name, () => _defaultQtyForUnit(unit));
      }
    });
  }

  /// 검색 전 홈: 빠른 액션 + 최근 + 카테고리 그리드.
  Widget _buildBrowseHome() {
    return ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 12),
      physics: const BouncingScrollPhysics(),
      children: [
        _buildQuickActionCard(
          icon: Icons.receipt_long_rounded,
          title: '영수증으로 재료 추가',
          subtitle: '사진만 올리면 재료를 자동으로 읽어 담아요',
          onTap: _enterInlineReceiptMode,
        ),
        const SizedBox(height: 10),
        _buildQuickActionCard(
          icon: Icons.local_fire_department_rounded,
          title: '자주 쓰는 재료 모음',
          subtitle: '자취·국물·채소 등 묶음으로 빠르게 담아요',
          onTap: _openFrequentBundlesSheet,
        ),
        const SizedBox(height: 22),
        const Text(
          '카테고리에서 고르기',
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 14,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.3,
            color: Color(0xFF191F28),
          ),
        ),
        const SizedBox(height: 12),
        _buildCategoryGrid(),
      ],
    );
  }

  Widget _buildQuickActionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE9EDF2)),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: const Color(0xFFE5E8EB),
                    width: 1.2,
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 22, color: const Color(0xFFFF6422)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                        color: Color(0xFF191F28),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.2,
                        color: Color(0xFF8B95A1),
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: Color(0xFFC4CAD2),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryGrid() {
    final keys = IngredientCategoryUnifier.groupOrder;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: keys.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.92,
      ),
      itemBuilder: (context, i) {
        final key = keys[i];
        final accent = IngredientCategoryUnifier.colorFromKey(key);
        return Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            onTap: () => _openCategoryBrowse(key),
            borderRadius: BorderRadius.circular(18),
            child: Container(
              padding: const EdgeInsets.fromLTRB(8, 14, 8, 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFFE9EDF2)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.03),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Text(
                    _shortCategoryTitle(key),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.25,
                      color: Color(0xFF191F28),
                    ),
                  ),
                  const Spacer(),
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Center(
                      child: IngredientCategoryUnifier.buildCategoryIcon(
                        key: key,
                        size: 30,
                      ),
                    ),
                  ),
                  const Spacer(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 카테고리별 대표 재료 선택 리스트. 나머지는 상단 검색으로 찾는다.
  Widget _buildCategoryBrowseList(String categoryKey) {
    final names = _featuredIngredientsForCategory(categoryKey);
    if (names.isEmpty) {
      return const Center(
        child: Text(
          '이 카테고리에 등록된 재료가 없어요',
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Color(0xFF8B95A1),
          ),
        ),
      );
    }

    Widget buildTile(String name) {
      final isOn = _searchSelected[name] == true;
      final unit = _searchUnit[name] ?? _defaultUnitForIngredient(name);
      final qty = _searchQty[name] ?? _defaultQtyForUnit(unit);
      return _buildSelectableIngredientTile(
        name: name,
        isOn: isOn,
        qty: qty,
        unit: unit,
        onToggle: () => _toggleSearchSelect(name),
        onDec: () => setState(() {
          _searchQty[name] = _decrementQty(qty, unit);
        }),
        onInc: () =>
            setState(() => _searchQty[name] = _incrementQty(qty, unit)),
        onPickUnit: () async {
          final picked = await _pickUnitValue(unit);
          if (picked != null && mounted) {
            setState(() => _searchUnit[name] = picked);
          }
        },
        onSetQty: (v) => setState(() {
          _searchQty[name] = v <= 0 ? _minQtyForUnit(unit) : v;
        }),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 6),
      physics: const BouncingScrollPhysics(),
      itemCount: names.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return const Padding(
            padding: EdgeInsets.fromLTRB(2, 0, 2, 12),
            child: Text(
              '자주 쓰는 재료만 모았어요. 다른 재료는 위에서 검색해 주세요',
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                letterSpacing: -0.2,
                height: 1.4,
                color: Color(0xFF8B95A1),
              ),
            ),
          );
        }
        final name = names[i - 1];
        return Padding(
          padding: EdgeInsets.only(bottom: i == names.length ? 0 : 9),
          child: buildTile(name),
        );
      },
    );
  }

  Future<void> _openFrequentBundlesSheet() async {
    Haptics.light();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE5E8EB),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  '자주 쓰는 재료 모음',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.35,
                    color: Color(0xFF191F28),
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  '묶음에서 골라 한 번에 담아보세요',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF8B95A1),
                  ),
                ),
                const SizedBox(height: 14),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(ctx).size.height * 0.55,
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _bundles.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final bundle = _bundles[i];
                      return _buildBundleCard(
                        bundle,
                        onTap: () async {
                          Navigator.pop(ctx);
                          await _openBundleSheet(bundle);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildBundleCard(
    _IngredientBundle bundle, {
    VoidCallback? onTap,
  }) {
    final accent = IngredientCategoryUnifier.colorFromKey(bundle.categoryKey);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap ?? () => _openBundleSheet(bundle),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFEDEFF3), width: 1),
          ),
                  child: Row(
                            children: [
                              Container(
                width: 44,
                height: 44,
                                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(13),
                ),
                                  child: Center(
                  child: IngredientCategoryUnifier.buildCategoryIcon(
                    key: bundle.categoryKey,
                    size: 22,
                                  ),
                                ),
                          ),
              const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                    Text(
                      bundle.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontFamily: 'Pretendard',
                        fontSize: 14.5,
                                      fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                        color: Color(0xFF191F28),
                      ),
                    ),
                    const SizedBox(height: 3),
                            Text(
                      bundle.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 12,
                        fontWeight: FontWeight.w500,
                                letterSpacing: -0.2,
                        color: Color(0xFF8B95A1),
                              ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      bundle.items.join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.2,
                        color: accent.withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              const Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: Color(0xFFC4CAD2),
              ),
            ],
                ),
              ),
            ),
    );
  }

  /// 선택 가능한 재료 타일(번들 팝업 + 검색 결과 공용).
  /// 선택 시 아래로 수량 스텝퍼가 펼쳐진다.
  Widget _buildSelectableIngredientTile({
    required String name,
    required bool isOn,
    required double qty,
    required String unit,
    required VoidCallback onToggle,
    required VoidCallback onDec,
    required VoidCallback onInc,
    required VoidCallback onPickUnit,
    required ValueChanged<double> onSetQty,
    // 사진/영수증 스캔 결과 전용 — 인식 신뢰도가 낮은 항목에 "확인 필요" 배지를
    // 붙여 즉시 보정을 유도한다. 영수증 원문(subtitle)이 있으면 이름 아래 표시.
    bool lowConfidence = false,
    String? subtitle,
    /// false면 비식품 — 회색 표시 + 선택/수량 조작 불가.
    bool selectable = true,
    /// selectable=false 일 때 우측 배지 문구.
    String? disabledBadge,
    /// selectable=true 여도 보여주는 안내 배지 (예: "추천 제외").
    /// 선택/수량 조작은 그대로 가능하다.
    String? infoBadge,
    /// 영수증 라인 금액(원). 있으면 이름 옆에 표시.
    int? price,
  }) {
    const orange = Color(0xFFFF6422);
    final muted = !selectable;
    final mutedBadge = disabledBadge ?? '선택 안 됨';
    final priceLabel = (price != null && price > 0)
        ? '${_formatReceiptWon(price)}원'
        : null;
    final existing = muted ? null : _existingInfoFor(name);
    final catKey = IngredientCategoryUnifier.groupKeyFromIngredient(
      internalCategory: null,
      ingredientName: name,
    );
    final catColor = muted
        ? const Color(0xFFB0B8C1)
        : IngredientCategoryUnifier.colorFromKey(catKey);
    return GestureDetector(
      onTap: selectable ? onToggle : null,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
          color: muted
              ? const Color(0xFFF3F4F6)
              : (isOn ? Colors.white : const Color(0xFFF8FAFB)),
          borderRadius: BorderRadius.circular(16),
            border: Border.all(
            color: muted
                ? const Color(0xFFE5E7EB)
                : (isOn ? orange : const Color(0xFFEDEFF3)),
            width: !muted && isOn ? 1.5 : 1,
          ),
          boxShadow: !muted && isOn
              ? [
                  BoxShadow(
                    color: orange.withValues(alpha: 0.13),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ]
              : const [],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: catColor.withValues(alpha: muted ? 0.08 : 0.10),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Center(
                    child: Opacity(
                      opacity: muted ? 0.45 : 1,
                      child: IngredientCategoryUnifier.buildCategoryIcon(
                        key: catKey,
                        size: 18,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                          color: muted
                              ? const Color(0xFF9CA3AF)
                              : const Color(0xFF191F28),
                        ),
                      ),
                      if (priceLabel != null ||
                          (subtitle != null && subtitle.trim().isNotEmpty)) ...[
                        const SizedBox(height: 2),
                        Text(
                          [
                            if (priceLabel != null) priceLabel,
                            if (subtitle != null && subtitle.trim().isNotEmpty)
                              subtitle.trim(),
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            letterSpacing: -0.1,
                            color: muted
                                ? const Color(0xFFC4CAD2)
                                : const Color(0xFFAEB6BE),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (muted) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8EAED),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      mutedBadge,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: Color(0xFF9CA3AF),
                      ),
                    ),
                  ),
                ] else ...[
                if (infoBadge != null) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF2F4F6),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      infoBadge,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: Color(0xFF8B95A1),
                      ),
                    ),
                  ),
                  const SizedBox(width: 9),
                ],
                if (lowConfidence) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF1EA),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text(
                      '확인 필요',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: Color(0xFFFF6422),
                      ),
                    ),
                  ),
                  const SizedBox(width: 9),
                ],
                if (existing != null) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF2F4F6),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text(
                      '보관 중',
                      style: TextStyle(
                  fontFamily: 'Pretendard',
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: Color(0xFF8B95A1),
                      ),
                    ),
                  ),
                  const SizedBox(width: 9),
                ],
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: isOn
                        ? const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFFFF7A3D), Color(0xFFFF6422)],
                          )
                        : null,
                    color: isOn ? null : Colors.white,
                    border: isOn
                        ? null
                        : Border.all(
                            color: const Color(0xFFD1D6DB),
                            width: 1.6,
                          ),
                    boxShadow: isOn
                        ? [
                            BoxShadow(
                              color: orange.withValues(alpha: 0.35),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ]
                        : const [],
                  ),
                  child: isOn
                      ? const Icon(
                          Icons.check_rounded,
                          size: 15,
                          color: Colors.white,
                        )
                      : const Icon(
                          Icons.add_rounded,
                          size: 15,
                          color: Color(0xFFB0B8C1),
                        ),
                ),
                ],
              ],
            ),
            if (!muted && isOn) ...[
              const SizedBox(height: 10),
              GestureDetector(
                onTap: () {},
                behavior: HitTestBehavior.opaque,
                child: Row(
      children: [
                    const Text(
                      '수량',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: Color(0xFF8B95A1),
                      ),
                    ),
                    const Spacer(),
        Container(
          decoration: BoxDecoration(
                        color: const Color(0xFFF4F6F8),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                            onTap: onDec,
                            behavior: HitTestBehavior.opaque,
                            child: const SizedBox(
                              width: 36,
                  height: 34,
                    child: Icon(
                      Icons.remove_rounded,
                                size: 18,
                                color: Color(0xFF4E5968),
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: () async {
                              final next = await _promptEditableQty(
                                qty: qty,
                                unit: unit,
                              );
                              if (next != null) onSetQty(next);
                            },
                            behavior: HitTestBehavior.opaque,
                            child: Container(
                              constraints: const BoxConstraints(minWidth: 40),
                              alignment: Alignment.center,
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: Text(
                                _formatQty(qty),
                                style: const TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.2,
                                  color: Color(0xFF191F28),
                                  decoration: TextDecoration.underline,
                                  decorationColor: Color(0xFFD1D6DB),
                                  decorationThickness: 1.2,
                                ),
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: onPickUnit,
                            behavior: HitTestBehavior.opaque,
                            child: Container(
                              constraints: const BoxConstraints(minWidth: 36),
                              alignment: Alignment.center,
                              padding: const EdgeInsets.only(right: 2),
                              child: Text(
                                unit,
                                style: const TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.2,
                                  color: Color(0xFF6B7684),
                                ),
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: onInc,
                            behavior: HitTestBehavior.opaque,
                            child: const SizedBox(
                              width: 36,
                              height: 34,
                              child: Icon(
                                Icons.add_rounded,
                                size: 18,
                                color: Color(0xFFFF6422),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 카메라/갤러리에서 영수증 사진을 고른 뒤 인식 플로우를 시작한다.
  /// 권한은 OS가 소스별로 요청한다(카메라→카메라, 갤러리→사진).
  /// 이미 허용된 경우 시스템 팝업은 뜨지 않는다.
  Future<void> _startReceiptFromSource(ImageSource source) async {
    if (_isScanningReceipt) return;
    XFile? picked;
    try {
      picked = await _receiptImagePicker.pickImage(
        source: source,
        imageQuality: 85,
        maxWidth: 2000,
      );
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().toLowerCase();
      final isCamera = source == ImageSource.camera;
      final denied = msg.contains('permission') ||
          msg.contains('denied') ||
          msg.contains('not allowed') ||
          msg.contains('access');
      showAppSnackBar(
        context,
        SnackBar(
          content: Text(
            denied
                ? (isCamera
                    ? '카메라 권한이 필요해요. 설정에서 허용해 주세요.'
                    : '사진 권한이 필요해요. 설정에서 허용해 주세요.')
                : '이미지를 불러올 수 없어요. 잠시 후 다시 시도해 주세요.',
          ),
        ),
      );
      return;
    }
    if (picked == null || !mounted) return;

    setState(() {
      _isScanningReceipt = true;
      _receiptPhase = 'scanning';
    });
    try {
      final bytes = await picked.readAsBytes();
      final result = await ApiService.scanFridgePhoto(
        imageBytes: bytes,
        photoType: 'receipt',
      );
      if (!mounted) return;
      if (result == null) {
        showAppSnackBar(
          context,
          const SnackBar(content: Text('영수증을 인식하지 못했어요. 잠시 후 다시 시도해주세요.')),
        );
        setState(() => _receiptPhase = 'choose');
        return;
      }
      if (result.items.isEmpty) {
        showAppSnackBar(
          context,
          SnackBar(
            content: Text(
              result.warning ?? '영수증에서 재료를 찾지 못했어요. 직접 추가해주세요.',
            ),
          ),
        );
        setState(() => _receiptPhase = 'choose');
        return;
      }
      await _persistReceiptScanHistory(result.items);
      if (!mounted) return;
      _enterReceiptReview(result.items);
    } finally {
      if (mounted) {
        setState(() => _isScanningReceipt = false);
      }
    }
  }

  /// 영수증 인식 결과 — 같은 화면 인라인 리뷰.
  Widget _buildReceiptReviewState() {
    final items = _reviewItems;
    final catalogIndices = <int>[
      for (var i = 0; i < items.length; i++)
        if (items[i].isFood && items[i].inCatalog) i,
    ];
    final unknownFoodIndices = <int>[
      for (var i = 0; i < items.length; i++)
        if (items[i].isFood && !items[i].inCatalog) i,
    ];
    final nonFoodIndices = <int>[
      for (var i = 0; i < items.length; i++)
        if (!items[i].isFood) i,
    ];
    final foodCount = catalogIndices.length;
    final selectedCount = _reviewSelected.where((s) => s).length;
    final lowConfidenceCount =
        catalogIndices.where((i) => items[i].isLowConfidence).length;
    final foodSelectedAll = catalogIndices.isNotEmpty &&
        catalogIndices.every(
          (i) => i < _reviewSelected.length && _reviewSelected[i],
        );
    const orange = Color(0xFFFF6422);
    const ink = Color(0xFF191F28);
    const sub = Color(0xFF8B95A1);
    final subtitle = foodCount == 0
        ? (unknownFoodIndices.isNotEmpty
            ? '찾지 못했지만 담을 수 있는 재료가 있어요'
            : '인식된 식재료가 없어요')
        : lowConfidenceCount > 0
            ? '확인 필요 $lowConfidenceCount개 포함'
            : '수량만 확인하면 돼요';

    return Column(
      key: const ValueKey('receipt-review'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text(
                              '인식된 재료',
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.6,
                                height: 1.2,
                                color: ink,
                              ),
                            ),
                            if (foodCount > 0) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF2F4F6),
                                  borderRadius: BorderRadius.circular(7),
                                ),
                                child: Text(
                                  '$foodCount',
                                  style: const TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.2,
                                    height: 1,
                                    color: Color(0xFF4E5968),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            letterSpacing: -0.25,
                            height: 1.3,
                            color: sub,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (foodCount > 0) ...[
                    const SizedBox(width: 12),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            setState(() {
                              for (final i in catalogIndices) {
                                _reviewSelected[i] = !foodSelectedAll;
                              }
                            });
                          },
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            height: 34,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: const Color(0xFFE5E8EB),
                              ),
                            ),
                            child: Text(
                              foodSelectedAll ? '선택 해제' : '전체 선택',
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.2,
                                color: ink,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (selectedCount > 0 && foodCount > 0) ...[
                const SizedBox(height: 12),
                Text(
                  '$selectedCount개 선택됨',
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                    color: Color(0xFF6B7684),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (lowConfidenceCount > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 11,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFFF7F8FA),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Icon(
                      Icons.info_outline_rounded,
                      size: 16,
                      color: Color(0xFF8B95A1),
                    ),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '흐릿한 항목은 빼 두었어요. 맞으면 체크만 켜 주세요.',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        height: 1.4,
                        letterSpacing: -0.15,
                        color: Color(0xFF6B7684),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        Container(height: 1, color: const Color(0xFFEEF0F3)),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
            physics: const BouncingScrollPhysics(),
            children: [
              for (var fi = 0; fi < catalogIndices.length; fi++) ...[
                if (fi > 0) const SizedBox(height: 9),
                _buildReceiptReviewTile(catalogIndices[fi]),
              ],
              if (unknownFoodIndices.isNotEmpty) ...[
                Padding(
                  padding: EdgeInsets.only(
                    top: catalogIndices.isEmpty ? 0 : 22,
                    bottom: 10,
                  ),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '찾지 못한 재료 · 레시피 추천 제외',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.15,
                            color: Color(0xFFAEB6BE),
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => unawaited(
                          _openReceiptRecognitionReportSheet(
                            focusItem: items[unknownFoodIndices.first],
                          ),
                        ),
                        behavior: HitTestBehavior.opaque,
                        child: const Text(
                          '잘못됐나요?',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.15,
                            color: Color(0xFF6B7684),
                            decoration: TextDecoration.underline,
                            decorationColor: Color(0xFFC4CAD2),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                for (var ui = 0; ui < unknownFoodIndices.length; ui++) ...[
                  if (ui > 0) const SizedBox(height: 9),
                  _buildReceiptReviewTile(unknownFoodIndices[ui]),
                ],
              ],
              if (nonFoodIndices.isNotEmpty) ...[
                Padding(
                  padding: EdgeInsets.only(
                    top: (catalogIndices.isEmpty &&
                            unknownFoodIndices.isEmpty)
                        ? 0
                        : 22,
                    bottom: 10,
                  ),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '식재료가 아닌 항목',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.15,
                            color: Color(0xFFAEB6BE),
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => unawaited(
                          _openReceiptRecognitionReportSheet(
                            focusItem: items[nonFoodIndices.first],
                          ),
                        ),
                        behavior: HitTestBehavior.opaque,
                        child: const Text(
                          '잘못됐나요?',
                          style: TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.15,
                            color: Color(0xFF6B7684),
                            decoration: TextDecoration.underline,
                            decorationColor: Color(0xFFC4CAD2),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                for (var ni = 0; ni < nonFoodIndices.length; ni++) ...[
                  if (ni > 0) const SizedBox(height: 9),
                  _buildReceiptReviewTile(nonFoodIndices[ni]),
                ],
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
          child: SizedBox(
            width: double.infinity,
            height: 54,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              decoration: BoxDecoration(
                gradient: selectedCount == 0
                    ? null
                    : const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFFF8A4C), Color(0xFFFF6422)],
                      ),
                color: selectedCount == 0 ? const Color(0xFFEAEDF0) : null,
                borderRadius: BorderRadius.circular(16),
                boxShadow: selectedCount == 0
                    ? const []
                    : [
                        BoxShadow(
                          color: orange.withValues(alpha: 0.28),
                          blurRadius: 18,
                          offset: const Offset(0, 8),
                        ),
                      ],
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: selectedCount == 0 ? null : _submitReceiptReview,
                  child: Center(
                    child: Text(
                      selectedCount == 0
                          ? '재료를 선택해 주세요'
                          : '$selectedCount개 냉장고에 담기',
                      style: TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                        color: selectedCount == 0
                            ? const Color(0xFFAEB6BE)
                            : Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildReceiptReviewTile(int i) {
    final it = _reviewItems[i];
    final isOn = i < _reviewSelected.length && _reviewSelected[i];
    final unit = i < _reviewUnit.length ? _reviewUnit[i] : it.unit;
    final qty = i < _reviewQty.length ? _reviewQty[i] : it.qty;
    // 비식품만 선택 불가. 카탈로그 미매칭 식재료는 담을 수 있되
    // "추천 제외" 안내만 붙인다 (레시피 매칭엔 안 쓰인다).
    final selectable = it.isFood;
    final disabledBadge = it.isFood ? null : '선택 안 됨';
    final infoBadge = it.isFood && !it.inCatalog ? '추천 제외' : null;
    return _buildSelectableIngredientTile(
      name: it.name,
      isOn: isOn,
      qty: qty,
      unit: unit,
      lowConfidence: it.isLowConfidence,
      subtitle: it.rawLine,
      selectable: selectable,
      disabledBadge: disabledBadge,
      infoBadge: infoBadge,
      price: it.price,
      onToggle: () {
        if (!selectable) return;
        setState(() => _reviewSelected[i] = !isOn);
      },
      onDec: () => setState(() {
        _reviewQty[i] = _decrementQty(qty, unit);
      }),
      onInc: () => setState(() {
        _reviewQty[i] = _incrementQty(qty, unit);
      }),
      onPickUnit: () async {
        final picked = await _pickUnitValue(unit);
        if (picked != null && mounted) {
          setState(() => _reviewUnit[i] = picked);
        }
      },
      onSetQty: (v) => setState(() {
        _reviewQty[i] = v <= 0 ? _minQtyForUnit(unit) : v;
      }),
    );
  }

  Widget _buildReceiptScanScreen() {
    final scanning = _receiptPhase == 'scanning' || _isScanningReceipt;
    final reviewing = _receiptPhase == 'review';
    return Scaffold(
      backgroundColor: const Color(0xFFFAFAFB),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFAFAFB),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(
            reviewing || _inlineReceiptMode
                ? Icons.arrow_back_ios_new_rounded
                : Icons.close_rounded,
            size: reviewing || _inlineReceiptMode ? 20 : 22,
            color: const Color(0xFF191F28),
          ),
          onPressed: scanning
              ? null
              : () {
                  if (reviewing) {
                    _exitReceiptReview();
                    return;
                  }
                  if (_inlineReceiptMode) {
                    _exitInlineReceiptMode();
                  } else {
                    Navigator.pop(context);
                  }
                },
        ),
        title: Text(
          reviewing ? '인식된 재료' : '영수증으로 재료 추가',
          style: const TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 17,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
            color: Color(0xFF191F28),
          ),
        ),
        actions: [
          if (reviewing)
            IconButton(
              tooltip: _receiptReportSent ? '접수됨' : '오류 신고',
              onPressed: _receiptReportSending
                  ? null
                  : () => unawaited(_openReceiptRecognitionReportSheet()),
              icon: Icon(
                _receiptReportSent
                    ? Icons.check_circle_outline_rounded
                    : Icons.flag_rounded,
                size: 22,
                color: _receiptReportSent
                    ? const Color(0xFFAEB6BE)
                    : const Color(0xFFE53935),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: scanning
              ? _buildReceiptScanningState()
              : reviewing
              ? _buildReceiptReviewState()
              : _buildReceiptChooseState(),
        ),
      ),
    );
  }

  Widget _buildReceiptChooseState() {
    return Padding(
      key: const ValueKey('receipt-choose'),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildReceiptHistoryCard(),
          const SizedBox(height: 22),
          _buildReceiptSourceCard(
            icon: Icons.photo_camera_rounded,
            title: '카메라로 촬영',
            subtitle: '지금 바로 영수증을 찍어요',
            onTap: () {
              Haptics.light();
              unawaited(_startReceiptFromSource(ImageSource.camera));
            },
          ),
          const SizedBox(height: 10),
          _buildReceiptSourceCard(
            icon: Icons.photo_library_rounded,
            title: '갤러리에서 선택',
            subtitle: '저장된 영수증 사진을 불러와요',
            onTap: () {
              Haptics.light();
              unawaited(_startReceiptFromSource(ImageSource.gallery));
            },
          ),
          const Spacer(),
          const Text(
            '글자가 선명한 사진일수록 인식이 정확해요',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: Color(0xFFAEB6BE),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReceiptHistoryCard() {
    final history = _receiptScanHistory;
    const ink = Color(0xFF191F28);
    const muted = Color(0xFF6B7684);
    const line = Color(0xFFE5E8EB);
    const wash = Color(0xFFF5F6F8);

    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: wash,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 16, 0),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: line),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.history_rounded,
                    size: 16,
                    color: muted,
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    '최근 분석',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 15.5,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.35,
                      color: ink,
                    ),
                  ),
                ),
                if (history.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: line),
                    ),
                    child: Text(
                      '${history.length}',
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: muted,
                        height: 1,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (history.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
              child: Column(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: line,
                        width: 1.2,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.receipt_long_rounded,
                      size: 28,
                      color: muted,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    '첫 영수증을 올려보세요',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 15.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                      color: ink,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '분석이 끝나면 재료 목록이 여기에 남아요.\n나중에 다시 열어 바로 담을 수 있어요.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      height: 1.45,
                      letterSpacing: -0.15,
                      color: Color(0xFF8B95A1),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: line),
                    ),
                    child: const Row(
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          size: 15,
                          color: muted,
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '사진은 저장되지 않고, 인식 결과만 기록돼요',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.15,
                              color: muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 196),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  physics: const BouncingScrollPhysics(),
                  itemCount: history.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final entry = history[i];
                    final total = entry.totalPrice;
                    return Material(
                      color: Colors.white,
                      elevation: 0,
                      borderRadius: BorderRadius.circular(16),
                      shadowColor: Colors.black.withValues(alpha: 0.04),
                      child: InkWell(
                        onTap: () =>
                            unawaited(_openReceiptHistoryEntry(entry)),
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: line,
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          '재료 ${entry.addableCount}개',
                                          style: const TextStyle(
                                            fontFamily: 'Pretendard',
                                            fontSize: 14,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: -0.25,
                                            color: Color(0xFF191F28),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFF5F6F8),
                                            borderRadius:
                                                BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            _formatReceiptHistoryTime(
                                              entry.scannedAt,
                                            ),
                                            style: const TextStyle(
                                              fontFamily: 'Pretendard',
                                              fontSize: 10.5,
                                              fontWeight: FontWeight.w700,
                                              color: Color(0xFF8B95A1),
                                              height: 1.1,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      entry.summaryNames,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontFamily: 'Pretendard',
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w500,
                                        color: Color(0xFF8B95A1),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (total != null) ...[
                                const SizedBox(width: 8),
                                Text(
                                  '${_formatReceiptWon(total)}원',
                                  style: const TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.3,
                                    color: ink,
                                  ),
                                ),
                              ],
                              IconButton(
                                tooltip: '기록 삭제',
                                onPressed: () => unawaited(
                                  _deleteReceiptScanHistory(entry.id),
                                ),
                                icon: const Icon(
                                  Icons.close_rounded,
                                  size: 17,
                                  color: Color(0xFFC4CAD2),
                                ),
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 32,
                                  minHeight: 32,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildReceiptSourceCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Color(0xFFE9EDF2)),
      ),
      shadowColor: Colors.black.withValues(alpha: 0.06),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 14, 16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: const Color(0xFFE5E8EB),
                    width: 1.2,
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 22, color: const Color(0xFFFF6422)),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 15.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                        color: Color(0xFF191F28),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF8B95A1),
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                size: 22,
                color: Color(0xFFC4CAD2),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReceiptScanningState() {
    return SizedBox.expand(
      key: const ValueKey('receipt-scanning'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 96,
              height: 96,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  const SizedBox(
                    width: 96,
                    height: 96,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      valueColor: AlwaysStoppedAnimation(Color(0xFFFF6422)),
                      backgroundColor: Color(0xFFFFE8DC),
                    ),
                  ),
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFFE5E8EB),
                        width: 1.2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFFF6422).withValues(alpha: 0.08),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.receipt_long_rounded,
                      size: 28,
                      color: Color(0xFFFF6422),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            const Text(
              '영수증을 읽고 있어요',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 18,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.35,
                color: Color(0xFF191F28),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '재료와 수량을 찾아 정리하는 중이에요\n잠시만 기다려 주세요',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                height: 1.45,
                color: Color(0xFF8B95A1),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 번들 상세: 재료를 체크해서 한 번에 담기.
  Future<void> _openBundleSheet(_IngredientBundle bundle) async {
    final onAddBatch = widget.onAddBatch;
    if (onAddBatch == null) return;

    final selected = <String, bool>{
      for (final name in bundle.items) name: false,
    };
    final unitByName = <String, String>{
      for (final name in bundle.items) name: _defaultUnitForIngredient(name),
    };
    final qtyByName = <String, double>{
      for (final name in bundle.items)
        name: _defaultQtyForUnit(_defaultUnitForIngredient(name)),
    };

    const orange = Color(0xFFFF6422);
    final added = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'bundle',
      barrierColor: Colors.black.withValues(alpha: 0.42),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (dialogContext, _, __) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final selectedNames =
                bundle.items.where((n) => selected[n] == true).toList();
            final accent =
                IngredientCategoryUnifier.colorFromKey(bundle.categoryKey);
            final allOn = selectedNames.length == bundle.items.length;
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    constraints: BoxConstraints(
                      maxWidth: 420,
                      maxHeight:
                          MediaQuery.of(dialogContext).size.height * 0.78,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x26000000),
                          blurRadius: 40,
                          offset: Offset(0, 18),
                        ),
                      ],
                    ),
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                        // ── Header ──
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 22, 16, 18),
                          child: Row(
                            children: [
                              Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      accent.withValues(alpha: 0.18),
                                      accent.withValues(alpha: 0.07),
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(15),
                                ),
                                child: Center(
                                  child: IngredientCategoryUnifier
                                      .buildCategoryIcon(
                                    key: bundle.categoryKey,
                                    size: 24,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 13),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      bundle.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontFamily: 'Pretendard',
                                        fontSize: 18,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: -0.45,
                                        color: Color(0xFF191F28),
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                          Text(
                                      bundle.subtitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Pretendard',
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w500,
                                        letterSpacing: -0.2,
                                        color: Color(0xFF8B95A1),
                            ),
                          ),
                        ],
                      ),
                    ),
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: () =>
                                    Navigator.pop(dialogContext, false),
                                behavior: HitTestBehavior.opaque,
                                child: Container(
                                  width: 34,
                                  height: 34,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF4F6F8),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Center(
                                    child: Icon(
                                      Icons.close_rounded,
                                      size: 17,
                                      color: Color(0xFF8B95A1),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Divider(
                          height: 1,
                          thickness: 1,
                          color: Color(0xFFF1F3F5),
                        ),
                        // ── 전체 선택 토글 ──
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 14, 16, 6),
                          child: Row(
                            children: [
                              Text(
                                '재료 ${bundle.items.length}개',
                                style: const TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.2,
                                  color: Color(0xFF8B95A1),
                                ),
                              ),
                              const Spacer(),
              GestureDetector(
                                onTap: () => setSheetState(() {
                                  for (final n in bundle.items) {
                                    selected[n] = !allOn;
                                  }
                                }),
                                behavior: HitTestBehavior.opaque,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        allOn
                                            ? Icons.remove_done_rounded
                                            : Icons.done_all_rounded,
                      size: 16,
                      color: orange,
                    ),
                                      const SizedBox(width: 5),
                                      Text(
                                        allOn ? '전체 해제' : '전체 선택',
                                        style: const TextStyle(
                                          fontFamily: 'Pretendard',
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: -0.2,
                                          color: orange,
                                        ),
                                      ),
                                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
                        // ── 재료 목록 ──
                        Flexible(
                          child: ListView.separated(
                            shrinkWrap: true,
                            padding:
                                const EdgeInsets.fromLTRB(20, 6, 20, 8),
                            physics: const BouncingScrollPhysics(),
                            itemCount: bundle.items.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 9),
                            itemBuilder: (context, i) {
                              final name = bundle.items[i];
                              final isOn = selected[name] == true;
                              final unit = unitByName[name]!;
                              final qty = qtyByName[name]!;
                              return _buildSelectableIngredientTile(
                                name: name,
                                isOn: isOn,
                                qty: qty,
                                unit: unit,
                                onToggle: () => setSheetState(
                                  () => selected[name] = !isOn,
                                ),
                                onDec: () => setSheetState(() {
                                  qtyByName[name] = _decrementQty(qty, unit);
                                }),
                                onInc: () => setSheetState(
                                  () => qtyByName[name] =
                                      _incrementQty(qty, unit),
                                ),
                                onPickUnit: () async {
                                  final picked = await _pickUnitValue(unit);
                                  if (picked != null) {
                                    setSheetState(
                                      () => unitByName[name] = picked,
                                    );
                                  }
                                },
                                onSetQty: (v) => setSheetState(() {
                                  qtyByName[name] =
                                      v <= 0 ? _minQtyForUnit(unit) : v;
                                }),
                              );
                            },
                          ),
                        ),
                        // ── CTA ──
                        Padding(
                          padding:
                              const EdgeInsets.fromLTRB(20, 10, 20, 20),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOutCubic,
                            width: double.infinity,
                            height: 54,
            decoration: BoxDecoration(
                              color: selectedNames.isEmpty
                                  ? const Color(0xFFEAEDF0)
                                  : const Color(0xFF191F28),
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: selectedNames.isEmpty
                                  ? const []
                                  : const [
                                      BoxShadow(
                                        color: Color(0x33191F28),
                                        blurRadius: 18,
                                        offset: Offset(0, 8),
                                      ),
                                    ],
                            ),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(16),
                                onTap: selectedNames.isEmpty
                                    ? null
                                    : () {
                                        final items = selectedNames
                                            .map(
                                              (name) => (
                                                name: name,
                                                qty: qtyByName[name] ?? 1.0,
                                                unit: unitByName[name] ??
                                                    _defaultUnitForIngredient(
                                                      name,
                                                    ),
                                              ),
                                            )
                                            .toList();
                                        onAddBatch(items);
                                        unawaited(
                                          _rememberRecentNames(selectedNames),
                                        );
                                        Navigator.pop(dialogContext, true);
                                      },
                                child: Center(
                                  child: Text(
                                    selectedNames.isEmpty
                                        ? '재료를 선택해 주세요'
                                        : '${selectedNames.length}개 담기',
              style: TextStyle(
                fontFamily: 'Pretendard',
                                      fontSize: 16,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
                                      color: selectedNames.isEmpty
                                          ? const Color(0xFFAEB6BE)
                                          : Colors.white,
                                    ),
                                  ),
                                ),
              ),
            ),
          ),
        ),
      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
      transitionBuilder: (ctx, anim, _, child) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.95, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
    );

    if (added == true && mounted) {
      Navigator.pop(context);
    }
  }

  /// 검색 결과 목록 (페이지 모드에서 Expanded 로 채워짐).
  Widget _buildSuggestionsList() {
    if (_suggestions.isEmpty) {
      return const Center(
        child: Text(
          '검색 결과가 없어요',
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: Color(0xFF9AA3AF),
          ),
        ),
      );
    }
    // 검색 결과를 카테고리(groupOrder) 기준으로 묶어 헤더 + 항목으로 표시.
    final byKey = <String, List<String>>{};
    for (final name in _suggestions) {
      final key = IngredientCategoryUnifier.groupKeyFromIngredient(
        internalCategory: null,
        ingredientName: name,
      );
      (byKey[key] ??= <String>[]).add(name);
    }
    final orderedKeys = <String>[
      ...IngredientCategoryUnifier.groupOrder.where(byKey.containsKey),
      ...byKey.keys.where(
        (k) => !IngredientCategoryUnifier.groupOrder.contains(k),
      ),
    ];

    Widget buildTile(String name) {
      final isOn = _searchSelected[name] == true;
      final unit = _searchUnit[name] ?? _defaultUnitForIngredient(name);
      final qty = _searchQty[name] ?? _defaultQtyForUnit(unit);
      return _buildSelectableIngredientTile(
        name: name,
        isOn: isOn,
        qty: qty,
        unit: unit,
        onToggle: () => _toggleSearchSelect(name),
        onDec: () => setState(() {
          _searchQty[name] = _decrementQty(qty, unit);
        }),
        onInc: () =>
            setState(() => _searchQty[name] = _incrementQty(qty, unit)),
        onPickUnit: () async {
          final picked = await _pickUnitValue(unit);
          if (picked != null) {
            setState(() => _searchUnit[name] = picked);
          }
        },
        onSetQty: (v) => setState(() {
          _searchQty[name] = v <= 0 ? _minQtyForUnit(unit) : v;
        }),
      );
    }

    final children = <Widget>[];
    for (final key in orderedKeys) {
      final names = byKey[key]!;
      if (children.isNotEmpty) children.add(const SizedBox(height: 16));
      children.add(
        Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Row(
            children: [
              IngredientCategoryUnifier.buildCategoryIcon(key: key, size: 18),
              const SizedBox(width: 6),
              Text(
                IngredientCategoryUnifier.titleFromKey(key),
                style: const TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 14.5,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.3,
                  color: Color(0xFF191F28),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${names.length}',
                style: const TextStyle(
          fontFamily: 'Pretendard',
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF9AA3AF),
                ),
              ),
            ],
        ),
      ),
    );
      children.add(const SizedBox(height: 10));
      for (var i = 0; i < names.length; i++) {
        children.add(buildTile(names[i]));
        if (i != names.length - 1) children.add(const SizedBox(height: 9));
      }
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: children,
    );
  }

  /// 페이지 하단 CTA. 검색 결과에서 선택한 재료가 있으면 일괄 담기,
  /// 없으면 직접 입력한 재료 단건 추가.
  Widget _buildPageBottomButton() {
    final searchSelected = _searchSelectedNames;
    final batchMode = _selectedName == null && searchSelected.isNotEmpty;
    final enabled = batchMode || _canSubmit;
    final existing = _existingInfoFor(
      _selectedName ?? _searchController.text.trim(),
    );
    final label = batchMode
        ? '${searchSelected.length}개 담기'
        : (existing != null ? '새 묶음으로 추가' : '추가하기');
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
          color: enabled ? const Color(0xFF191F28) : const Color(0xFFEAEDF0),
          borderRadius: BorderRadius.circular(16),
          boxShadow: enabled
              ? const [
          BoxShadow(
                    color: Color(0x33191F28),
                    blurRadius: 18,
                    offset: Offset(0, 8),
                  ),
                ]
              : const [],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: !enabled
                ? null
                : () {
                    if (batchMode) {
                      final onAddBatch = widget.onAddBatch;
                      if (onAddBatch == null) return;
                      final items = searchSelected
                          .map(
                            (name) => (
                              name: name,
                              qty: _searchQty[name] ?? 1.0,
                              unit: _searchUnit[name] ??
                                  _defaultUnitForIngredient(name),
                            ),
                          )
                          .toList();
                      onAddBatch(items);
                      unawaited(_rememberRecentNames(searchSelected));
                      Navigator.pop(context);
                    } else {
                      _submit();
                    }
                  },
            child: Center(
      child: Text(
        label,
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                  color: enabled ? Colors.white : const Color(0xFFAEB6BE),
                ),
              ),
            ),
          ),
        ),
      ),
    );
}

  @override
  Widget build(BuildContext context) {
    if (widget.startWithReceiptScan || _inlineReceiptMode) {
      return _buildReceiptScanScreen();
    }

    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final browsingCategory = _browsingCategoryKey;
    final searching = _searchController.text.trim().isNotEmpty;
    final showBottomCta = _selectedName != null ||
        searching ||
        _searchSelectedNames.isNotEmpty;

    return Scaffold(
      backgroundColor: Colors.white,
      // 본문 패딩에서 키보드 인셋(bottomInset)을 직접 처리하므로 Scaffold의
      // 자동 리사이즈는 끈다. (둘 다 켜져 있으면 키보드가 올라올 때 이중으로
      // 밀려 레이아웃이 깜빡이거나 잠깐 다른 화면처럼 보이는 버그가 생김)
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            size: 20,
            color: Color(0xFF191F28),
          ),
          onPressed: () {
            if (browsingCategory != null && !searching) {
              _exitCategoryBrowse();
              return;
            }
            Navigator.pop(context);
          },
        ),
        title: Text(
          browsingCategory != null && !searching
              ? _shortCategoryTitle(browsingCategory)
              : '재료 추가',
          style: const TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 17,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
            color: Color(0xFF191F28),
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 8, 20, 12 + bottomInset),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_selectedName == null) ...[
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF2F4F6),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: TextField(
                    controller: _searchController,
                    autofocus: false,
                    textInputAction: TextInputAction.search,
                    // 검색 갱신은 initState의 addListener(_onSearchChanged) 한 경로만 사용.
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF191F28),
                    ),
                    decoration: InputDecoration(
                      hintText: '재료 이름 검색',
                      hintStyle: const TextStyle(
                        fontFamily: 'Pretendard',
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFFB0B8C1),
                      ),
                      prefixIcon: const Padding(
                        padding: EdgeInsets.only(left: 14, right: 8),
                        child: Icon(
                          Icons.search_rounded,
                          size: 20,
                          color: Color(0xFF8B95A1),
                        ),
                      ),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 42,
                        minHeight: 20,
                      ),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? GestureDetector(
                              onTap: () {
                                _searchController.clear();
                                setState(() => _suggestions = []);
                              },
                              child: const Padding(
                                padding: EdgeInsets.only(right: 12),
                                child: Icon(
                                  Icons.cancel_rounded,
                                  size: 18,
                                  color: Color(0xFFB0B8C1),
                                ),
                              ),
                            )
                          : null,
                      suffixIconConstraints: const BoxConstraints(
                        minWidth: 30,
                        minHeight: 18,
                      ),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        vertical: 14,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: searching
                      ? _buildSuggestionsList()
                      : browsingCategory != null
                      ? _buildCategoryBrowseList(browsingCategory)
                      : _buildBrowseHome(),
                ),
              ],
              if (_selectedName != null) ...[
                const SizedBox(height: 10),
                () {
                  final selCatKey =
                      IngredientCategoryUnifier.groupKeyFromIngredient(
                        internalCategory: null,
                        ingredientName: _selectedName!,
                      );
                  final selCatLabel =
                      IngredientCategoryUnifier.titleFromKey(selCatKey);
                  final existingInfo = _existingInfoFor(_selectedName!);
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF9FAFB),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(
                          0xFFFF6422,
                        ).withValues(alpha: 0.25),
                        width: 1.5,
                      ),
                    ),
                    child: Row(
                      children: [
                        IngredientCategoryUnifier.buildCategoryIcon(
                          key: selCatKey,
                          size: 18,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _selectedName!,
                                style: const TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  height: 1.2,
                                  color: Color(0xFF191F28),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                existingInfo == null
                                    ? selCatLabel
                                    : '$selCatLabel · 현재 ${existingInfo.amountLabel} 보관 중',
                                style: const TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF8B95A1),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (existingInfo != null) ...[
                          const SizedBox(width: 8),
                          const _ExistingIngredientBadge(label: '새 묶음'),
                        ],
                        GestureDetector(
                          onTap: () {
                            _searchController.clear();
                            setState(() {
                              _selectedName = null;
                              _selectedUnit = null;
                              _suggestions = [];
                            });
                          },
                          behavior: HitTestBehavior.opaque,
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: const Color(0xFFF2F4F6),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Center(
                              child: Icon(
                                Icons.close_rounded,
                                size: 14,
                                color: Color(0xFF8B95A1),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }(),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 50,
                        decoration: BoxDecoration(
                          color: const Color(0xFFF2F4F6),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          children: [
                            _FridgeQtyChipButton(
                              icon: Icons.remove_rounded,
                              onTap: () => _bumpSelectedQty(-1),
                            ),
                            Expanded(
                              child: TextField(
                                controller: _qtyController,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontFamily: 'Pretendard',
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF191F28),
                                ),
                                decoration: const InputDecoration(
                                  hintText: '수량',
                                  hintStyle: TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFFD1D6DB),
                                  ),
                                  border: InputBorder.none,
                                  contentPadding: EdgeInsets.zero,
                                  isDense: true,
                                ),
                              ),
                            ),
                            _FridgeQtyChipButton(
                              icon: Icons.add_rounded,
                              onTap: () => _bumpSelectedQty(1),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _pickUnit,
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        height: 50,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF2F4F6),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _selectedUnit ??
                                  _defaultUnitForIngredient(_selectedName!),
                              style: const TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF191F28),
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 18,
                              color: Color(0xFF8B95A1),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _buildQtyFractionChips(),
              ],
              if (showBottomCta) ...[
                const SizedBox(height: 14),
                _buildPageBottomButton(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQtyFractionChips() {
    final unit = _selectedUnit ??
        _defaultUnitForIngredient(_selectedName ?? '');
    final u = unit.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    // g/ml 은 분수보다 절대량이 자연스러워서 가벼운 프리셋만 노출.
    final chips = (u == 'g' || u == 'ml')
        ? const <(String, double)>[
            ('50', 50),
            ('100', 100),
            ('200', 200),
            ('500', 500),
          ]
        : (u == 'kg' || u == 'l' || u == 'ℓ')
        ? const <(String, double)>[
            ('0.5', 0.5),
            ('1', 1),
            ('1.5', 1.5),
            ('2', 2),
          ]
        : const <(String, double)>[
            ('¼', 0.25),
            ('⅓', 1 / 3),
            ('½', 0.5),
            ('1', 1),
            ('1½', 1.5),
            ('2', 2),
          ];
    // 셀 수 단위는 ¼·⅓보다 ½ 단위가 자연스럽다.
    final filtered = _isFineCountableUnit(u)
        ? const <(String, double)>[
            ('½', 0.5),
            ('1', 1),
            ('1½', 1.5),
            ('2', 2),
            ('3', 3),
          ]
        : chips;
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: filtered.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final (label, value) = filtered[i];
          final current = _currentQtyFromField();
          final selected = (current - value).abs() < 0.02;
          return GestureDetector(
            onTap: () {
              Haptics.selection();
              _applyFractionChip(value);
            },
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? const Color(0xFFFF6422).withValues(alpha: 0.12)
                    : const Color(0xFFF7F8FA),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: selected
                      ? const Color(0xFFFF6422)
                      : const Color(0xFFE9EDF2),
                  width: 1.2,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontFamily: 'Pretendard',
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: selected
                      ? const Color(0xFFFF6422)
                      : const Color(0xFF4E5968),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _FridgeQtyChipButton extends StatelessWidget {
  const _FridgeQtyChipButton({
    required this.icon,
    required this.onTap,
  });

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        Haptics.selection();
        onTap();
      },
      child: SizedBox(
        width: 42,
        height: 50,
        child: Icon(icon, size: 20, color: const Color(0xFF4E5968)),
      ),
    );
  }
}
