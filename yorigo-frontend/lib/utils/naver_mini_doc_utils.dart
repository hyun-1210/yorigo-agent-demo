/// 네이버 레시피북 mini doc 집계 필드(재료 수/칼로리/시간) 동기화 유틸.
/// Firestore main doc 에 본문이 없어도 parseResponse 기록이 백필에 덮이지 않게 한다.
library;

bool isNaverBlogRecipeData(Map<String, dynamic> r) {
  final source = r['source'];
  if (source is Map &&
      (source['platform'] as String?)?.toLowerCase() == 'naver_blog') {
    return true;
  }
  final sourceKey = (r['sourceKey'] as String?) ?? '';
  return sourceKey.startsWith('naver_blog:');
}

bool isNaverBlogMiniDoc(Map<String, dynamic> m) {
  if ((m['sourcePlatform'] as String?)?.toLowerCase() == 'naver_blog') {
    return true;
  }
  final sourceKey = (m['sourceKey'] as String?) ?? '';
  return sourceKey.startsWith('naver_blog:');
}

/// parseResponse 집계값을 mini doc map 에 반영한다.
void applyNaverParseCountsToMini(
  Map<String, dynamic> mini, {
  required int ingredientCount,
  required num calories,
  required int totalMinutes,
}) {
  mini['ingredientCount'] = ingredientCount;
  mini['calories'] = calories;
  mini['totalMinutes'] = totalMinutes;
}

/// main-doc 기준 mini sync 시 기존 parseResponse 집계값을 보존한다.
void preserveNaverMiniCardCountsFromExisting(
  Map<String, dynamic> mini,
  Map<String, dynamic>? existing,
) {
  if (existing == null) return;
  if (!isNaverBlogMiniDoc(mini) &&
      (mini['ingredientCount'] as num?)?.toInt() != 0) {
    return;
  }

  final existingIng = (existing['ingredientCount'] as num?)?.toInt() ?? 0;
  final newIng = (mini['ingredientCount'] as num?)?.toInt() ?? 0;
  if (existingIng > 0 && newIng == 0) {
    mini['ingredientCount'] = existingIng;
  }

  final existingCal = (existing['calories'] as num?)?.toDouble() ?? 0;
  final newCal = (mini['calories'] as num?)?.toDouble() ?? 0;
  if (existingCal > 0 && newCal == 0) {
    mini['calories'] = existingCal;
  }

  final existingMin = (existing['totalMinutes'] as num?)?.toInt() ?? 0;
  final newMin = (mini['totalMinutes'] as num?)?.toInt() ?? 0;
  if (existingMin > 0 && newMin == 0) {
    mini['totalMinutes'] = existingMin;
  }
}

/// `recipes/{rid}` main 메타(네이버) → mini doc 필드 (본문 없음 → counts 0).
Map<String, dynamic> buildNaverMainMetaMiniMap({
  required String recipeId,
  required Map<String, dynamic> mainData,
}) {
  final source = mainData['source'];
  final sourcePlatform =
      source is Map ? source['platform'] as String? : null;
  final recipeBody = mainData['recipe'] is Map ? mainData['recipe'] as Map : null;
  final ingredients = recipeBody?['ingredients'] as List? ?? const [];
  final steps = recipeBody?['steps'] as List? ?? const [];
  var totalMinutes = 0;
  for (final s in steps) {
    if (s is Map && s['est_minutes'] is num) {
      totalMinutes += (s['est_minutes'] as num).toInt();
    }
  }
  return <String, dynamic>{
    'recipeId': recipeId,
    'title': mainData['title'],
    'sourceUrl': mainData['sourceUrl'],
    if (sourcePlatform != null) 'sourcePlatform': sourcePlatform,
    'sourceKey': mainData['sourceKey'],
    'status': mainData['status'] ?? 'completed',
    'isHidden': mainData['isHidden'] == true,
    'calories': (mainData['calories'] as num?) ?? 0,
    'ingredientCount': ingredients.length,
    'totalMinutes': totalMinutes,
    if (mainData['tags'] is List) 'tags': mainData['tags'],
  };
}

/// 레시피북 카드가 읽는 ingredient/calorie 필드 (fast path).
Map<String, dynamic> recipebookCardFromMini({
  required String recipeId,
  required Map<String, dynamic> mini,
}) {
  final ingCount = (mini['ingredientCount'] as num?)?.toInt() ?? 0;
  final totalMin = (mini['totalMinutes'] as num?)?.toInt() ?? 0;
  return <String, dynamic>{
    'id': recipeId,
    'title': mini['title'],
    'calories': mini['calories'] ?? 0,
    'recipe': <String, dynamic>{
      'ingredients': List<Map<String, dynamic>>.filled(
        ingCount,
        const <String, dynamic>{},
      ),
      'steps': totalMin > 0
          ? <Map<String, dynamic>>[
              <String, dynamic>{'est_minutes': totalMin},
            ]
          : <Map<String, dynamic>>[],
    },
  };
}
