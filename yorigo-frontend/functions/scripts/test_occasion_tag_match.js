/**
 * occasionTags 가 홈 섹션 anyTags 매칭에 포함되는지 확인.
 * 실행: node scripts/test_occasion_tag_match.js
 */
const assert = require("assert");
const { matchesSectionRuleForKey } = require("../homeSectionRules");

const recipe = {
  status: "completed",
  isHidden: false,
  title: "잔치국수",
  tags: ["매콤한", "한그릇"],
  occasionTags: ["혼밥", "저녁"],
};

assert.strictEqual(
  matchesSectionRuleForKey(recipe, "moment_solo"),
  true,
  "occasionTags 혼밥 은 moment_solo 에 들어가야 함"
);
assert.strictEqual(
  matchesSectionRuleForKey(
    { ...recipe, occasionTags: ["손님상"] },
    "moment_solo"
  ),
  false,
  "관계없는 occasionTags 는 moment_solo 에 들어가면 안 됨"
);

console.log("ok occasionTags section match");
