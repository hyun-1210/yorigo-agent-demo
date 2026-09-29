// recipeCost.js — placeholder stub.
//
// 진짜 가격 추정 구현은 아직 작성되지 않았다. index.js 가 require("./recipeCost")
// 를 호출하기 때문에 require 가 실패하지 않도록 빈 stub 을 export 한다.
//
// 향후 실제 가격 추정 로직을 작성할 때 이 stub 을 덮어쓰세요.
// 두 함수가 정의되어야 합니다:
//   - onRecipeWriteReconcileCost(change, recipeId)
//   - recalculateAllRecipeCosts({pageSize, maxRecipes}?)

module.exports = {
  onRecipeWriteReconcileCost: async function () {
    return { status: "stub_not_implemented" };
  },
  recalculateAllRecipeCosts: async function () {
    return { status: "stub_not_implemented" };
  },
};
