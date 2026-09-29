/// 메인 [MainNavigatorState]가 등록하고, 신고 관리 등에서 피드 리뷰 열기에 사용.
/// (admin_reports ↔ main.dart 순환 import 방지)
void Function(String reviewId)? _openReviewInFeed;

void bindOpenReviewInFeed(void Function(String reviewId) fn) {
  _openReviewInFeed = fn;
}

void unbindOpenReviewInFeed() {
  _openReviewInFeed = null;
}

void requestOpenReviewInFeed(String reviewId) {
  _openReviewInFeed?.call(reviewId);
}
