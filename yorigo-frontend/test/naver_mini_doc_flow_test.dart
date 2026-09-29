import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/naver_mini_doc_utils.dart';

/// In-memory Firestore `users/{uid}/savedRecipes/{rid}` stub.
class _FakeMiniDocStore {
  final Map<String, Map<String, dynamic>> _docs = {};

  String _key(String uid, String recipeId) => '$uid/$recipeId';

  Map<String, dynamic>? get(String uid, String recipeId) {
    final raw = _docs[_key(uid, recipeId)];
    return raw == null ? null : Map<String, dynamic>.from(raw);
  }

  void set(String uid, String recipeId, Map<String, dynamic> mini) {
    _docs[_key(uid, recipeId)] = Map<String, dynamic>.from(mini);
  }

  /// Mirrors [RecipeService.updateNaverSavedRecipeMiniDoc].
  void updateNaverFromParse({
    required String uid,
    required String recipeId,
    required Map<String, dynamic> mainData,
    required int ingredientCount,
    required num calories,
    required int totalMinutes,
  }) {
    final mini = buildNaverMainMetaMiniMap(
      recipeId: recipeId,
      mainData: mainData,
    );
    applyNaverParseCountsToMini(
      mini,
      ingredientCount: ingredientCount,
      calories: calories,
      totalMinutes: totalMinutes,
    );
    set(uid, recipeId, mini);
  }

  /// Mirrors [_writeSavedRecipeMiniDoc] + preserve for naver backfill.
  void syncMiniFromMain({
    required String uid,
    required String recipeId,
    required Map<String, dynamic> mainData,
  }) {
    final mini = buildNaverMainMetaMiniMap(
      recipeId: recipeId,
      mainData: mainData,
    );
    if (isNaverBlogRecipeData(mainData) || isNaverBlogMiniDoc(mini)) {
      preserveNaverMiniCardCountsFromExisting(mini, get(uid, recipeId));
    }
    set(uid, recipeId, mini);
  }
}

void main() {
  const uid = 'user_a';
  const recipeId = 'naver_recipe_1';

  final naverMainMeta = <String, dynamic>{
    'title': '된장찌개',
    'status': 'completed',
    'isHidden': true,
    'sourceUrl': 'https://m.blog.naver.com/foo/123',
    'sourceKey': 'naver_blog:foo__123',
    'source': <String, dynamic>{
      'platform': 'naver_blog',
      'url': 'https://m.blog.naver.com/foo/123',
      'uploader': 'foo',
    },
    'recipe': <String, dynamic>{
      'name': '된장찌개',
      'servings': 2,
    },
    'tags': <String>['찌개'],
  };

  test('parse complete writes non-zero counts to mini doc', () {
    final store = _FakeMiniDocStore();
    store.updateNaverFromParse(
      uid: uid,
      recipeId: recipeId,
      mainData: naverMainMeta,
      ingredientCount: 13,
      calories: 420,
      totalMinutes: 35,
    );

    final mini = store.get(uid, recipeId)!;
    expect(mini['ingredientCount'], 13);
    expect(mini['calories'], 420);
    expect(mini['totalMinutes'], 35);
  });

  test('fast-path backfill after reload does NOT zero counts (bug regression)', () {
    final store = _FakeMiniDocStore();

    // 1) Parse complete
    store.updateNaverFromParse(
      uid: uid,
      recipeId: recipeId,
      mainData: naverMainMeta,
      ingredientCount: 13,
      calories: 420,
      totalMinutes: 35,
    );

    // 2) reloadSavedRecipesFromNetwork → _tryFastSavedRecipesEmit backfill
    store.syncMiniFromMain(
      uid: uid,
      recipeId: recipeId,
      mainData: naverMainMeta,
    );

    final mini = store.get(uid, recipeId)!;
    expect(mini['ingredientCount'], 13, reason: 'backfill must preserve counts');
    expect(mini['calories'], 420);
    expect(mini['totalMinutes'], 35);
    expect(mini['tags'], ['찌개'], reason: 'backfill still merges tags');
  });

  test('recipebook card shows correct ingredient count and calories', () {
    final store = _FakeMiniDocStore();
    store.updateNaverFromParse(
      uid: uid,
      recipeId: recipeId,
      mainData: naverMainMeta,
      ingredientCount: 13,
      calories: 420,
      totalMinutes: 35,
    );
    store.syncMiniFromMain(
      uid: uid,
      recipeId: recipeId,
      mainData: naverMainMeta,
    );

    final card = recipebookCardFromMini(
      recipeId: recipeId,
      mini: store.get(uid, recipeId)!,
    );
    final ingredients = card['recipe']['ingredients'] as List;
    expect(ingredients.length, 13);
    expect(card['calories'], 420);
  });

  test('without preserve, backfill would produce 0/0 (old bug)', () {
    final mini = buildNaverMainMetaMiniMap(
      recipeId: recipeId,
      mainData: naverMainMeta,
    );
    expect(mini['ingredientCount'], 0);
    expect(mini['calories'], 0);

    final card = recipebookCardFromMini(recipeId: recipeId, mini: mini);
    expect((card['recipe']['ingredients'] as List).length, 0);
    expect(card['calories'], 0);
  });

  test('parsing→completed patch path preserves counts', () {
    final store = _FakeMiniDocStore();

    // Mini still parsing (legacy) but main completed — patch uses main-only build.
    final parsingMain = Map<String, dynamic>.from(naverMainMeta)
      ..['status'] = 'completed';

    store.updateNaverFromParse(
      uid: uid,
      recipeId: recipeId,
      mainData: parsingMain,
      ingredientCount: 8,
      calories: 310,
      totalMinutes: 20,
    );

    final staleParsingMini = Map<String, dynamic>.from(store.get(uid, recipeId)!)
      ..['status'] = 'parsing'
      ..['ingredientCount'] = 8
      ..['calories'] = 310;
    store.set(uid, recipeId, staleParsingMini);

    // Patch: rebuild from main (0 counts) then preserve from... actually patch
    // overwrites via updateSavedRecipeMiniDoc without reading old mini in prod.
    // Our fix reads existing before set.
    store.syncMiniFromMain(
      uid: uid,
      recipeId: recipeId,
      mainData: parsingMain,
    );

    final mini = store.get(uid, recipeId)!;
    expect(mini['status'], 'completed');
    expect(mini['ingredientCount'], 8);
    expect(mini['calories'], 310);
  });
}
