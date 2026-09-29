import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/screens/cart_screen.dart';
import 'package:yorigo/screens/category_explore_screen.dart';
import 'package:yorigo/screens/follow_list_screen.dart';
import 'package:yorigo/screens/home_screen.dart';
import 'package:yorigo/screens/notifications_screen.dart';
import 'package:yorigo/screens/parse_history_screen.dart';
import 'package:yorigo/screens/pass_verification_webview_screen.dart';
import 'package:yorigo/screens/profile_edit_screen.dart';
import 'package:yorigo/screens/profile_screen.dart';
import 'package:yorigo/screens/recipe_detail_screen.dart';
import 'package:yorigo/screens/recipe_review_feed_scroll_screen.dart';
import 'package:yorigo/screens/received_likes_list_screen.dart';
import 'package:yorigo/screens/user_reviews_list_screen.dart';
import 'package:yorigo/widgets/ingredient_select_sheet.dart';
import 'package:yorigo/widgets/pick_recipe_for_review_sheet.dart';

/// 컴파일/import 스모크: API 36 inset 수정 파일이 분석기에서 깨지지 않는지 확인.
void main() {
  test('API 36 inset 수정 심볼이 로드된다', () {
    expect(PickRecipeForReviewSheet.directReviewId, isNotEmpty);
    expect(FollowListKind.followers, isNotNull);
    expect(NotificationsScreen, isNotNull);
    expect(ParseHistoryScreen, isNotNull);
    expect(PassVerificationWebviewScreen, isNotNull);
    expect(ProfileEditScreen, isNotNull);
    expect(RecipeReviewFeedScrollScreen, isNotNull);
    expect(ReceivedLikesListScreen, isNotNull);
    expect(UserReviewsListScreen, isNotNull);
    expect(groupIngredientsByCategory, isNotNull);
    expect(CartScreen, isNotNull);
    expect(CategoryExploreScreen, isNotNull);
    expect(HomeScreen, isNotNull);
    expect(ProfileScreen, isNotNull);
    expect(RecipeDetailScreen, isNotNull);
  });
}
