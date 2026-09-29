// 같은 영상 URL을 `recipes`에서 찾을 때 쓰는 조회·재사용 규칙.
//
// Firestore list 규칙은 매칭 문서 중 하나라도 못 읽으면 쿼리 전체가 실패한다.
// 숨김 껍데기(`isHidden: true`, `hiddenReason: duplicate_of:*`)가 섞이면
// 공개 원본까지 못 받으므로, 공개 조회는 쿼리에 `isHidden == false` 가 필요하다.

/// 쿼리에 `.where('isHidden', isEqualTo: false)` 를 넣을지.
///
/// - [includeHidden]: 네이버 메타처럼 숨김 문서를 의도적으로 찾을 때 true.
/// - [userId]: 본인 소유 조회는 규칙상 숨김도 읽을 수 있어 쿼리 제약이 필요 없다.
///   (클라에서 공개 문서만 고른다.)
bool shouldConstrainSourceQueryToVisible({
  required bool includeHidden,
  String? userId,
}) {
  if (includeHidden) return false;
  if (userId != null && userId.isNotEmpty) return false;
  return true;
}

/// 공개 피드를 가져오는 list 쿼리에 숨김 제외가 필요한지.
///
/// 문서 id만 훑거나 컬렉션 전체를 가져오면 숨김 껍데기가 후보에 섞인다.
bool shouldConstrainPublicRecipeListToVisible() => true;

/// 같은 URL의 기존 문서를 새 파싱 대신 재사용할 수 있는지.
///
/// 실패·취소·숨김 사본은 제외하고, 완료본과 진행 중(`parsing`)은 포함한다.
bool isReusableSourceDocForDedup(Map<String, dynamic> data) {
  final status = (data['status'] as String?)?.toLowerCase();
  if (status == 'failed' || status == 'error' || status == 'cancelled') {
    return false;
  }
  return data['isHidden'] != true;
}

/// 완료된 공개 레시피인지 (payload 유무는 호출측에서 추가 검사).
bool isCompletedLikeSourceDoc(Map<String, dynamic> data) {
  final status = (data['status'] as String?)?.toLowerCase();
  return status == null || status == 'completed';
}

/// 진행 중 파싱 문서인지. 새 id 를 만들지 않고 이 문서를 붙여야 한다.
bool isInProgressSourceDoc(Map<String, dynamic> data) {
  final status = (data['status'] as String?)?.toLowerCase();
  return status == 'parsing' && data['isHidden'] != true;
}

/// 식단·후기 피커에 넣어도 되는 저장 레시피인지.
///
/// 실패·취소·분석 중 임시 문서는 레시피북에서 숨기더라도
/// `savedRecipes` id 가 남을 수 있어, 피커에서 한 번 더 걸러낸다.
bool isEligibleSavedRecipeForMealPlan(Map<String, dynamic> recipe) {
  final id = (recipe['id'] as String? ?? '').trim();
  if (id.isEmpty || id.startsWith('opt_')) return false;

  final status = (recipe['status'] as String? ?? 'completed').toLowerCase();
  if (status == 'parsing' ||
      status == 'error' ||
      status == 'cancelled' ||
      status == 'failed') {
    return false;
  }

  final recipeData = recipe['recipe'];
  final nested = recipeData is Map<String, dynamic> ? recipeData : const {};
  final title = ((recipe['title'] as String?) ??
          (nested['title'] as String?) ??
          (nested['name'] as String?) ??
          '')
      .trim();
  if (title.isEmpty || title == '분석 중..' || title.startsWith('분석 중')) {
    return false;
  }
  if (recipe['isTemporary'] == true && status != 'completed') {
    return false;
  }
  return true;
}

/// 본인 실패 문서만 재시도 슬롯으로 쓴다. 공용 완료본·타인 error 는 제외.
bool isReusableFailedRecipeData(
  Map<String, dynamic> data, {
  required String userId,
}) {
  if (userId.isEmpty) return false;
  final status = (data['status'] as String?)?.toLowerCase();
  if (status != 'error' && status != 'failed') return false;
  if ((data['userId'] as String?) != userId) return false;
  final reason = (data['hiddenReason'] as String?) ?? '';
  if (reason.startsWith('duplicate_of:')) return false;
  return true;
}

/// 같은 URL의 재사용 가능 문서가 있으면 새 `recipes` 문서를 만들지 않는다.
bool shouldCreateNewRecipeDocument(Map<String, dynamic>? existing) {
  if (existing == null) return true;
  return !isReusableSourceDocForDedup(existing);
}
