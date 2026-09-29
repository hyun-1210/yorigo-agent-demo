/// 유저 리뷰/다이어리 목록 쿼리에서 `isHidden` 문서를 포함할지 결정.
///
/// - [includeHiddenFlag]: 호출측이 명시적으로 요청한 경우 (예: 내 프로필)
/// - 쿼리 대상 [queriedUserIds]에 로그인 uid가 있으면 본인 조회로 간주
///   ([ReviewService.getUserReviews]와 동일 계약)
bool shouldIncludeHiddenUserReviews({
  required bool includeHiddenFlag,
  required String? currentUserId,
  required Iterable<String> queriedUserIds,
}) {
  if (includeHiddenFlag) return true;
  final uid = currentUserId?.trim() ?? '';
  if (uid.isEmpty) return false;
  for (final id in queriedUserIds) {
    if (id.trim() == uid) return true;
  }
  return false;
}

/// 뷰어 기준으로 다이어리에 노출할 리뷰만 남긴다.
///
/// 본인 다이어리: private(`isHidden`/`visibility`) 포함.
/// 타인 프로필: 공개만.
List<Map<String, dynamic>> filterReviewsForDiaryViewer({
  required List<Map<String, dynamic>> reviews,
  required bool isViewingOwnProfile,
}) {
  if (isViewingOwnProfile) return List<Map<String, dynamic>>.from(reviews);
  return reviews.where((r) {
    if (r['isHidden'] == true) return false;
    final visibility = (r['visibility'] as String?)?.trim();
    if (visibility == 'private') return false;
    return true;
  }).toList();
}
