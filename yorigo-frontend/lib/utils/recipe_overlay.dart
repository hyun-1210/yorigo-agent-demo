import '../models/recipe_models.dart' as models;

/// 사용자 로컬 오버레이의 머지 결과.
///
/// `recipe` 는 그대로 가격/장바구니 등 기존 다운스트림 로직에 사용 가능하고,
/// `ingredientSources` / `stepSources` 는 UI 에서 해당 인덱스 항목의 메모 / 수정여부 /
/// 추가여부 / 삭제여부(원본 키) 를 정확히 룩업하기 위한 메타.
class MergedRecipe {
  MergedRecipe({
    required this.recipe,
    required this.ingredientSources,
    required this.stepSources,
    required this.recipeMemo,
    required this.removedIngredients,
    required this.removedSteps,
  });

  final models.Recipe recipe;
  final List<IngredientSource> ingredientSources;
  final List<StepSource> stepSources;

  /// 레시피 전체 메모 (없으면 빈 문자열).
  final String recipeMemo;

  /// 사용자가 삭제 표시한 원본 재료들의 (item, originalIndex). 화면 하단 "복원하기" 영역에서 사용.
  final List<RemovedIngredient> removedIngredients;

  /// 사용자가 삭제 표시한 원본 스텝들의 (order, instruction). 동일 용도.
  final List<RemovedStep> removedSteps;

  bool get hasIngredientEdits =>
      ingredientSources.any((s) => s.isEdited || s.isAdded) ||
      removedIngredients.isNotEmpty;

  bool get hasStepEdits =>
      stepSources.any((s) => s.isEdited || s.isAdded) ||
      removedSteps.isNotEmpty;
}

/// 머지 결과의 i번째 재료가 어디서 왔는지.
class IngredientSource {
  IngredientSource.original({
    required this.originalItem,
    required this.isEdited,
    required this.memo,
  })  : addedId = null,
        isAdded = false;

  IngredientSource.added({
    required this.addedId,
    required this.memo,
  })  : originalItem = null,
        isEdited = false,
        isAdded = true;

  /// 원본 재료의 item 이름 (added 인 경우 null).
  final String? originalItem;

  /// 사용자가 추가한 재료의 id (original 인 경우 null).
  final String? addedId;

  final bool isEdited;
  final bool isAdded;

  /// 메모 텍스트 (없으면 빈 문자열).
  final String memo;
}

class StepSource {
  StepSource.original({
    required this.originalOrder,
    required this.isEdited,
    required this.memo,
  })  : addedId = null,
        isAdded = false;

  StepSource.added({
    required this.addedId,
    required this.memo,
  })  : originalOrder = null,
        isEdited = false,
        isAdded = true;

  final int? originalOrder;
  final String? addedId;

  final bool isEdited;
  final bool isAdded;

  final String memo;
}

class RemovedIngredient {
  RemovedIngredient({required this.item});
  final String item;
}

class RemovedStep {
  RemovedStep({required this.order, required this.instruction});
  final int order;
  final String instruction;
}

/// 원본 [base] 위에 [overlay] 를 적용한 머지 결과를 반환.
///
/// overlay 가 비어있으면 원본을 그대로 감싼 [MergedRecipe] 를 반환.
MergedRecipe applyOverlay(
  models.Recipe base,
  Map<String, dynamic> overlay,
) {
  final ingredientResult = _mergeIngredients(base.ingredients, overlay);
  final stepResult = _mergeSteps(base.steps, overlay);

  final mergedRecipe = models.Recipe(
    name: base.name,
    servings: base.servings,
    ingredients: ingredientResult.ingredients,
    steps: stepResult.steps,
    equipment: base.equipment,
    notes: base.notes,
  );

  return MergedRecipe(
    recipe: mergedRecipe,
    ingredientSources: ingredientResult.sources,
    stepSources: stepResult.sources,
    recipeMemo: (overlay['recipeMemo'] as String?)?.trim() ?? '',
    removedIngredients: ingredientResult.removed,
    removedSteps: stepResult.removed,
  );
}

class _IngredientMergeResult {
  _IngredientMergeResult({
    required this.ingredients,
    required this.sources,
    required this.removed,
  });
  final List<models.Ingredient> ingredients;
  final List<IngredientSource> sources;
  final List<RemovedIngredient> removed;
}

class _StepMergeResult {
  _StepMergeResult({
    required this.steps,
    required this.sources,
    required this.removed,
  });
  final List<models.Step> steps;
  final List<StepSource> sources;
  final List<RemovedStep> removed;
}

_IngredientMergeResult _mergeIngredients(
  List<models.Ingredient> base,
  Map<String, dynamic> overlay,
) {
  final ingOverlay = (overlay['ingredients'] as Map?) ?? const {};
  final edits = (ingOverlay['edits'] as Map?) ?? const {};
  final removedRaw = (ingOverlay['removed'] as List?) ?? const [];
  final removedSet = removedRaw
      .map((e) => e?.toString() ?? '')
      .where((s) => s.isNotEmpty)
      .toSet();
  final addedRaw = (ingOverlay['added'] as List?) ?? const [];

  final mergedIngredients = <models.Ingredient>[];
  final sources = <IngredientSource>[];
  final removed = <RemovedIngredient>[];

  for (final ing in base) {
    if (removedSet.contains(ing.item)) {
      removed.add(RemovedIngredient(item: ing.item));
      continue;
    }
    final ov = edits[ing.item];
    if (ov is Map) {
      final qty = (ov['qty'] is num) ? (ov['qty'] as num).toDouble() : ing.qty;
      final unitOv = ov['unit'];
      final unit = (unitOv is String && unitOv.trim().isNotEmpty)
          ? unitOv
          : ing.unit;
      final memo = (ov['memo'] as String?)?.trim() ?? '';
      final qtyChanged = ov['qty'] is num &&
          (ov['qty'] as num).toDouble() != (ing.qty ?? double.nan);
      final unitChanged = unitOv is String &&
          unitOv.trim().isNotEmpty &&
          unitOv != (ing.unit ?? '');
      final isEdited = qtyChanged || unitChanged;

      mergedIngredients.add(models.Ingredient(
        qty: qty,
        unit: unit,
        qtyConventional: ing.qtyConventional,
        unitConventional: ing.unitConventional,
        item: ing.item,
        notes: ing.notes,
        category: ing.category,
        estimated: ing.estimated,
      ));
      sources.add(IngredientSource.original(
        originalItem: ing.item,
        isEdited: isEdited,
        memo: memo,
      ));
    } else {
      mergedIngredients.add(ing);
      sources.add(IngredientSource.original(
        originalItem: ing.item,
        isEdited: false,
        memo: '',
      ));
    }
  }

  for (final raw in addedRaw) {
    if (raw is! Map) continue;
    final id = raw['id']?.toString() ?? '';
    if (id.isEmpty) continue;
    final item = (raw['item'] as String?)?.trim() ?? '';
    if (item.isEmpty) continue;
    if (removedSet.contains(item)) continue;
    var qty = (raw['qty'] is num) ? (raw['qty'] as num).toDouble() : null;
    var unit = (raw['unit'] as String?)?.trim();
    final ov = edits[item];
    if (ov is Map) {
      if (ov['qty'] is num) qty = (ov['qty'] as num).toDouble();
      final unitOv = ov['unit'];
      if (unitOv is String && unitOv.trim().isNotEmpty) {
        unit = unitOv;
      }
    }
    final category = (raw['category'] as String?)?.trim();
    final memo = (raw['memo'] as String?)?.trim() ?? '';

    mergedIngredients.add(models.Ingredient(
      qty: qty,
      unit: (unit != null && unit.isNotEmpty) ? unit : null,
      item: item,
      category: (category != null && category.isNotEmpty) ? category : null,
    ));
    sources.add(IngredientSource.added(addedId: id, memo: memo));
  }

  return _IngredientMergeResult(
    ingredients: mergedIngredients,
    sources: sources,
    removed: removed,
  );
}

_StepMergeResult _mergeSteps(
  List<models.Step> base,
  Map<String, dynamic> overlay,
) {
  final stepOverlay = (overlay['steps'] as Map?) ?? const {};
  final edits = (stepOverlay['edits'] as Map?) ?? const {};
  final removedRaw = (stepOverlay['removed'] as List?) ?? const [];
  final removedSet = removedRaw
      .map((e) => e is num ? e.toInt() : int.tryParse(e?.toString() ?? ''))
      .whereType<int>()
      .toSet();
  final addedRaw = (stepOverlay['added'] as List?) ?? const [];

  // anchor 그래프를 풀어서 added 스텝들을 위치별로 분류.
  // 결과: insertionsBefore = anchor 후에 들어갈 added 항목 리스트.
  //   insertionsAtStart        : 맨 앞 (type "start")
  //   insertionsAfterOriginal  : originalOrder 키 → added 리스트
  //   insertionsAfterAdded     : addedId 키 → added 리스트 (체이닝)
  //   insertionsAtEnd          : 맨 뒤 (type "end" 또는 anchor 누락/해석 실패)
  final addedList = <Map<String, dynamic>>[];
  for (final raw in addedRaw) {
    if (raw is Map) addedList.add(Map<String, dynamic>.from(raw));
  }

  final insertionsAtStart = <Map<String, dynamic>>[];
  final insertionsAfterOriginal = <int, List<Map<String, dynamic>>>{};
  final insertionsAfterAdded = <String, List<Map<String, dynamic>>>{};
  final insertionsAtEnd = <Map<String, dynamic>>[];

  for (final added in addedList) {
    final anchor = added['anchor'];
    if (anchor is Map) {
      final type = anchor['type']?.toString() ?? 'end';
      final value = anchor['value'];
      switch (type) {
        case 'start':
          insertionsAtStart.add(added);
          break;
        case 'afterOriginal':
          if (value is num) {
            insertionsAfterOriginal
                .putIfAbsent(value.toInt(), () => [])
                .add(added);
          } else {
            insertionsAtEnd.add(added);
          }
          break;
        case 'afterAdded':
          if (value is String && value.isNotEmpty) {
            insertionsAfterAdded.putIfAbsent(value, () => []).add(added);
          } else {
            insertionsAtEnd.add(added);
          }
          break;
        case 'end':
        default:
          insertionsAtEnd.add(added);
      }
    } else {
      insertionsAtEnd.add(added);
    }
  }

  // 한 added 가 그 뒤에 또 다른 added 를 anchor 로 가지면 체이닝되어 같이 따라간다.
  void appendAddedChain(
    Map<String, dynamic> added,
    List<models.Step> steps,
    List<StepSource> sources,
    int Function() nextOrder,
  ) {
    final id = added['id']?.toString() ?? '';
    final instruction = (added['instruction'] as String?)?.trim() ?? '';
    final memo = (added['memo'] as String?)?.trim() ?? '';
    steps.add(models.Step(
      order: nextOrder(),
      instruction: instruction,
    ));
    sources.add(StepSource.added(addedId: id, memo: memo));
    final children = insertionsAfterAdded[id];
    if (children != null) {
      for (final child in children) {
        appendAddedChain(child, steps, sources, nextOrder);
      }
    }
  }

  final mergedSteps = <models.Step>[];
  final sources = <StepSource>[];
  final removed = <RemovedStep>[];
  var displayOrder = 1;
  int next() => displayOrder++;

  for (final added in insertionsAtStart) {
    appendAddedChain(added, mergedSteps, sources, next);
  }

  for (final s in base) {
    if (removedSet.contains(s.order)) {
      removed.add(RemovedStep(order: s.order, instruction: s.instruction));
      continue;
    }
    final ov = edits[s.order.toString()];
    String instruction = s.instruction;
    String memo = '';
    bool isEdited = false;
    if (ov is Map) {
      final instrOv = ov['instruction'];
      if (instrOv is String && instrOv.trim().isNotEmpty) {
        instruction = instrOv;
        if (instrOv != s.instruction) isEdited = true;
      }
      final memoOv = ov['memo'];
      if (memoOv is String) memo = memoOv.trim();
    }

    mergedSteps.add(models.Step(
      order: next(),
      instruction: instruction,
      tip: s.tip,
      stepIngredients: s.stepIngredients,
      estMinutes: s.estMinutes,
      tools: s.tools,
      startSec: s.startSec,
    ));
    sources.add(StepSource.original(
      originalOrder: s.order,
      isEdited: isEdited,
      memo: memo,
    ));

    final after = insertionsAfterOriginal[s.order];
    if (after != null) {
      for (final added in after) {
        appendAddedChain(added, mergedSteps, sources, next);
      }
    }
  }

  for (final added in insertionsAtEnd) {
    appendAddedChain(added, mergedSteps, sources, next);
  }

  return _StepMergeResult(
    steps: mergedSteps,
    sources: sources,
    removed: removed,
  );
}

/// 에이전트 proposed_patches 를 overlay JSON 에 한 번에 적용 (원자적 기록용).
Map<String, dynamic> applyPatchesToOverlay(
  Map<String, dynamic> overlay,
  List<Map<String, dynamic>> patches,
) {
  var next = Map<String, dynamic>.from(overlay);
  var index = 0;
  for (final raw in patches) {
    final action = (raw['action'] as String?)?.trim() ?? '';
    if (action.isEmpty) continue;
    if (action == 'ingredient.edit') {
      final item = (raw['item'] as String?)?.trim() ?? '';
      if (item.isEmpty) continue;
      next = _overlaySetIngredientEdit(
        next,
        item: item,
        qty: _patchQty(raw['qty']),
        unit: raw['unit'] as String?,
        memo: raw['memo'] as String?,
      );
    } else if (action == 'ingredient.remove') {
      final item = (raw['item'] as String?)?.trim() ?? '';
      if (item.isEmpty) continue;
      next = _overlayRemoveIngredient(next, item);
    } else if (action == 'ingredient.restore') {
      final item = (raw['item'] as String?)?.trim() ?? '';
      if (item.isEmpty) continue;
      next = _overlayRestoreIngredient(next, item);
    } else if (action == 'ingredient.add') {
      final item = (raw['item'] as String?)?.trim() ?? '';
      if (item.isEmpty) continue;
      next = _overlayAddIngredient(
        next,
        item: item,
        qty: _patchQty(raw['qty']),
        unit: raw['unit'] as String?,
        category: raw['category'] as String?,
        memo: raw['memo'] as String?,
        id: 'ua_${DateTime.now().millisecondsSinceEpoch}_$index',
      );
    } else if (action == 'step.edit') {
      final order = raw['order'];
      final orderInt = order is int
          ? order
          : int.tryParse(order?.toString() ?? '');
      if (orderInt == null) continue;
      next = _overlaySetStepEdit(
        next,
        order: orderInt,
        instruction: raw['instruction'] as String?,
        memo: raw['memo'] as String?,
      );
    }
    index += 1;
  }
  next['updatedAt'] = DateTime.now().toIso8601String();
  return next;
}

double? _patchQty(dynamic raw) {
  if (raw is num) return raw.toDouble();
  if (raw is String) return double.tryParse(raw.trim());
  return null;
}

Map<String, dynamic> _ingMap(Map<String, dynamic> overlay) {
  return Map<String, dynamic>.from(
    (overlay['ingredients'] as Map?) ?? const {},
  );
}

Map<String, dynamic> _overlaySetIngredientEdit(
  Map<String, dynamic> overlay, {
  required String item,
  double? qty,
  String? unit,
  String? memo,
}) {
  final next = Map<String, dynamic>.from(overlay);
  final ingredients = _ingMap(next);
  final edits = Map<String, dynamic>.from(
    (ingredients['edits'] as Map?) ?? const {},
  );
  final entry = <String, dynamic>{};
  if (qty != null) entry['qty'] = qty;
  final trimmedUnit = unit?.trim();
  if (trimmedUnit != null && trimmedUnit.isNotEmpty) {
    entry['unit'] = trimmedUnit;
  }
  final trimmedMemo = memo?.trim();
  if (trimmedMemo != null && trimmedMemo.isNotEmpty) {
    entry['memo'] = trimmedMemo;
  }
  if (entry.isEmpty) {
    edits.remove(item);
  } else {
    edits[item] = entry;
  }
  if (edits.isEmpty) {
    ingredients.remove('edits');
  } else {
    ingredients['edits'] = edits;
  }
  if (ingredients.isEmpty) {
    next.remove('ingredients');
  } else {
    next['ingredients'] = ingredients;
  }
  return next;
}

Map<String, dynamic> _overlayRemoveIngredient(
  Map<String, dynamic> overlay,
  String item,
) {
  final next = Map<String, dynamic>.from(overlay);
  final ingredients = _ingMap(next);
  final removed = List<String>.from(
    (ingredients['removed'] as List?)?.cast<String>() ?? const <String>[],
  );
  if (!removed.contains(item)) removed.add(item);
  ingredients['removed'] = removed;

  final added = List<Map<String, dynamic>>.from(
    ((ingredients['added'] as List?) ?? const []).map(
      (e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{},
    ),
  );
  added.removeWhere((e) => (e['item'] as String?)?.trim() == item);
  if (added.isEmpty) {
    ingredients.remove('added');
  } else {
    ingredients['added'] = added;
  }

  final edits = Map<String, dynamic>.from(
    (ingredients['edits'] as Map?) ?? const {},
  );
  edits.remove(item);
  if (edits.isEmpty) {
    ingredients.remove('edits');
  } else {
    ingredients['edits'] = edits;
  }

  next['ingredients'] = ingredients;
  return next;
}

Map<String, dynamic> _overlayRestoreIngredient(
  Map<String, dynamic> overlay,
  String item,
) {
  final next = Map<String, dynamic>.from(overlay);
  final ingredients = _ingMap(next);
  final removed = List<String>.from(
    (ingredients['removed'] as List?)?.cast<String>() ?? const <String>[],
  );
  removed.remove(item);
  if (removed.isEmpty) {
    ingredients.remove('removed');
  } else {
    ingredients['removed'] = removed;
  }
  if (ingredients.isEmpty) {
    next.remove('ingredients');
  } else {
    next['ingredients'] = ingredients;
  }
  return next;
}

Map<String, dynamic> _overlayAddIngredient(
  Map<String, dynamic> overlay, {
  required String item,
  double? qty,
  String? unit,
  String? category,
  String? memo,
  required String id,
}) {
  final next = Map<String, dynamic>.from(overlay);
  final ingredients = _ingMap(next);
  final added = List<Map<String, dynamic>>.from(
    ((ingredients['added'] as List?) ?? const []).map(
      (e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{},
    ),
  );
  added.add({
    'id': id,
    'item': item.trim(),
    if (qty != null) 'qty': qty,
    if (unit != null && unit.trim().isNotEmpty) 'unit': unit.trim(),
    if (category != null && category.trim().isNotEmpty) 'category': category.trim(),
    if (memo != null && memo.trim().isNotEmpty) 'memo': memo.trim(),
  });
  ingredients['added'] = added;
  next['ingredients'] = ingredients;
  return next;
}

Map<String, dynamic> _overlaySetStepEdit(
  Map<String, dynamic> overlay, {
  required int order,
  String? instruction,
  String? memo,
}) {
  final next = Map<String, dynamic>.from(overlay);
  final steps = Map<String, dynamic>.from(
    (next['steps'] as Map?) ?? const {},
  );
  final edits = Map<String, dynamic>.from(
    (steps['edits'] as Map?) ?? const {},
  );
  final entry = <String, dynamic>{};
  final trimmedInstr = instruction?.trim();
  if (trimmedInstr != null && trimmedInstr.isNotEmpty) {
    entry['instruction'] = trimmedInstr;
  }
  final trimmedMemo = memo?.trim();
  if (trimmedMemo != null && trimmedMemo.isNotEmpty) {
    entry['memo'] = trimmedMemo;
  }
  final key = order.toString();
  if (entry.isEmpty) {
    edits.remove(key);
  } else {
    edits[key] = entry;
  }
  if (edits.isEmpty) {
    steps.remove('edits');
  } else {
    steps['edits'] = edits;
  }
  if (steps.isEmpty) {
    next.remove('steps');
  } else {
    next['steps'] = steps;
  }
  return next;
}

