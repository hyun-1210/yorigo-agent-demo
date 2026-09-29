/**
 * homeSectionIndex 단위 테스트 (in-memory fake Firestore).
 *
 * 실행: node scripts/test_home_section_index.js
 */
const assert = require("assert");
const {
  syncHomeSectionIndexForRecipe,
  buildSectionRecipeIds,
  rebuildProgramHomeSectionIndexes,
  programSectionKeys,
  PAGE_SIZE,
} = require("../homeSectionIndex");

function makeFakeDb(seed) {
  const store = {
    recipes: JSON.parse(JSON.stringify(seed.recipes || {})),
    home_section_overrides: JSON.parse(JSON.stringify(seed.overrides || {})),
    home_section_index: JSON.parse(JSON.stringify(seed.index || {})),
  };
  let overridesCollectionReadCount = 0;
  let recipesPageReads = 0;

  function makeDocRef(collectionName, id) {
    return {
      id,
      get: async () => {
        const data = store[collectionName][id];
        return { exists: !!data, data: () => data };
      },
      set: async (data, opts) => {
        const prev = opts && opts.merge ? store[collectionName][id] || {} : {};
        const next = { ...prev, ...data };
        // serverTimestamp placeholder 제거
        if (next.updatedAt && typeof next.updatedAt === "object") {
          next.updatedAt = "SERVER_TIMESTAMP";
        }
        store[collectionName][id] = next;
      },
    };
  }

  function makeRecipesQuery() {
    const state = { limit: PAGE_SIZE, startAfterId: null };
    const api = {
      orderBy: () => api,
      limit: (n) => {
        state.limit = n;
        return api;
      },
      startAfter: (doc) => {
        state.startAfterId = doc && doc.id ? doc.id : null;
        return api;
      },
      get: async () => {
        recipesPageReads += 1;
        const ids = Object.keys(store.recipes).sort();
        let start = 0;
        if (state.startAfterId) {
          const idx = ids.indexOf(state.startAfterId);
          start = idx >= 0 ? idx + 1 : ids.length;
        }
        const page = ids.slice(start, start + state.limit);
        const docs = page.map((id) => ({
          id,
          data: () => store.recipes[id],
        }));
        return { empty: docs.length === 0, docs };
      },
    };
    return api;
  }

  return {
    collection: (name) => {
      if (name === "recipes") {
        return {
          ...makeRecipesQuery(),
          doc: (id) => makeDocRef("recipes", id),
          get: async () => {
            throw new Error("recipes collection.get() not supported in fake");
          },
        };
      }
      return {
        get: async () => {
          if (name === "home_section_overrides") overridesCollectionReadCount += 1;
          return {
            docs: Object.keys(store[name] || {}).map((id) => ({
              id,
              data: () => store[name][id],
            })),
          };
        },
        doc: (id) => makeDocRef(name, id),
      };
    },
    runTransaction: async (fn) => {
      const tx = {
        get: async (docRef) => docRef.get(),
        set: (docRef, data, opts) => docRef.set(data, opts),
      };
      return fn(tx);
    },
    _store: store,
    _overridesCollectionReadCount: () => overridesCollectionReadCount,
    _recipesPageReads: () => recipesPageReads,
  };
}

let passed = 0;
function check(name, fn) {
  return (async () => {
    try {
      await fn();
      passed += 1;
      console.log("OK  " + name);
    } catch (e) {
      console.error("FAIL " + name);
      console.error(e);
      process.exitCode = 1;
    }
  })();
}

const RECIPE_ALTORAN = {
  status: "completed",
  isHidden: false,
  source: { title: "알토란 표고버섯전" },
  completedAt: { toDate: () => new Date("2026-08-01T00:00:00Z") },
};

const RECIPE_SUMI = {
  status: "completed",
  isHidden: false,
  source: { title: "수미네 반찬 시금치나물" },
  completedAt: { toDate: () => new Date("2026-08-02T00:00:00Z") },
};

const RECIPE_NAVER_ALTORAN = {
  status: "completed",
  isHidden: false,
  source: { title: "알토란 따라하기", platform: "naver_blog" },
  completedAt: { toDate: () => new Date("2026-08-03T00:00:00Z") },
};

const RECIPE_PLAIN = {
  status: "completed",
  isHidden: false,
  source: { title: "그냥 집밥" },
  completedAt: { toDate: () => new Date("2026-07-01T00:00:00Z") },
};

async function main() {
  await check("신규 레시피는 home_section_overrides를 읽지 않는다", async () => {
    const db = makeFakeDb({
      overrides: { program_altoran: { pinnedIds: ["other-id"], blockedIds: [] } },
      index: {},
    });
    await syncHomeSectionIndexForRecipe(db, "new-recipe-1", {}, RECIPE_ALTORAN, true);
    assert.strictEqual(db._overridesCollectionReadCount(), 0, "overrides 컬렉션을 읽으면 안 됨");
    const idx = db._store.home_section_index.program_altoran;
    assert.ok(idx && idx.recipeIds.includes("new-recipe-1"), "규칙 매칭 섹션에 추가되어야 함");
  });

  await check("수정으로 규칙 매칭이 사라지면 기존 인덱스에서 제거된다", async () => {
    const db = makeFakeDb({
      overrides: {},
      index: { program_altoran: { recipeIds: ["r1", "r2"], count: 2 } },
    });
    const editedAway = { status: "completed", isHidden: false, source: { title: "그냥 반찬 레시피" } };
    await syncHomeSectionIndexForRecipe(db, "r1", RECIPE_ALTORAN, editedAway, false);
    assert.strictEqual(db._overridesCollectionReadCount(), 1, "수정 건은 overrides를 1번 읽어야 함");
    const idx = db._store.home_section_index.program_altoran;
    assert.ok(!idx.recipeIds.includes("r1"), "규칙에서 벗어난 레시피는 제거되어야 함");
  });

  await check("block된 레시피는 여전히 규칙 매칭돼도 인덱스에 재추가되지 않는다", async () => {
    const db = makeFakeDb({
      overrides: { program_altoran: { pinnedIds: [], blockedIds: ["r1"] } },
      index: { program_altoran: { recipeIds: ["r2"], count: 1 } },
    });
    await syncHomeSectionIndexForRecipe(db, "r1", RECIPE_ALTORAN, RECIPE_ALTORAN, false);
    const idx = db._store.home_section_index.program_altoran;
    assert.ok(!idx.recipeIds.includes("r1"), "block된 레시피는 계속 제외 상태를 유지해야 함");
  });

  await check("규칙 매칭 안 돼도 pin되어 있으면 인덱스에 포함된다", async () => {
    const db = makeFakeDb({
      overrides: { program_altoran: { pinnedIds: ["r3"], blockedIds: [] } },
      index: { program_altoran: { recipeIds: [], count: 0 } },
    });
    const nonMatching = { status: "completed", isHidden: false, source: { title: "그냥 레시피" } };
    await syncHomeSectionIndexForRecipe(db, "r3", {}, nonMatching, false);
    const idx = db._store.home_section_index.program_altoran;
    assert.ok(idx.recipeIds.includes("r3"), "pin된 레시피는 규칙 불일치여도 포함되어야 함");
  });

  await check("overrides 전체 읽기는 섹션별 재조회 없이 1번으로 끝난다", async () => {
    const db = makeFakeDb({
      overrides: {
        program_altoran: { pinnedIds: [], blockedIds: [] },
        program_sumi: { pinnedIds: [], blockedIds: [] },
      },
      index: {},
    });
    await syncHomeSectionIndexForRecipe(db, "r4", {}, RECIPE_ALTORAN, false);
    assert.strictEqual(db._overridesCollectionReadCount(), 1, "overrides 컬렉션 read는 정확히 1번이어야 함");
  });

  await check("programSectionKeys 는 program_ 접두사만 반환한다", async () => {
    const keys = programSectionKeys();
    assert.ok(keys.length >= 10, "program 키가 충분히 있어야 함");
    assert.ok(keys.every((k) => k.startsWith("program_")));
    assert.ok(keys.includes("program_altoran"));
    assert.ok(keys.includes("program_pyeonstorang"));
    assert.ok(!keys.includes("moment_dinner"));
  });

  await check("단일 패스 결과는 키별 buildSectionRecipeIds 와 동일하다", async () => {
    const recipes = {
      a1: RECIPE_ALTORAN,
      a2: {
        ...RECIPE_ALTORAN,
        source: { title: "알토란 두부조림" },
        completedAt: { toDate: () => new Date("2026-08-04T00:00:00Z") },
      },
      s1: RECIPE_SUMI,
      n1: RECIPE_NAVER_ALTORAN,
      p1: RECIPE_PLAIN,
      hidden1: { ...RECIPE_ALTORAN, isHidden: true },
      draft1: { ...RECIPE_ALTORAN, status: "draft" },
    };
    const seed = {
      recipes,
      overrides: {
        program_altoran: { pinnedIds: ["pin1"], blockedIds: ["a1"] },
        program_sumi_side_dishes: { pinnedIds: [], blockedIds: [] },
      },
      index: {},
    };
    // pin 대상 레시피 (규칙 불일치여도 포함)
    seed.recipes.pin1 = {
      status: "completed",
      isHidden: false,
      source: { title: "핀만 된 레시피" },
      completedAt: { toDate: () => new Date("2026-06-01T00:00:00Z") },
    };

    const dbSingle = makeFakeDb(seed);
    const single = await rebuildProgramHomeSectionIndexes(dbSingle, { dryRun: false });
    assert.strictEqual(single.dryRun, false);
    const recipeCount = Object.keys(seed.recipes).length;
    assert.strictEqual(single.scannedRecipes, recipeCount);

    const dbPerKey = makeFakeDb(seed);
    const keys = programSectionKeys();
    for (const key of keys) {
      const perKeyIds = await buildSectionRecipeIds(dbPerKey, key);
      const singleIds =
        (dbSingle._store.home_section_index[key] &&
          dbSingle._store.home_section_index[key].recipeIds) ||
        [];
      assert.deepStrictEqual(
        singleIds,
        perKeyIds,
        `${key}: single-pass 와 per-key 결과가 같아야 함`
      );
      assert.strictEqual(single.counts[key], perKeyIds.length);
    }

    // naver_blog 제외, a1 block, pin1 포함
    const altoran =
      dbSingle._store.home_section_index.program_altoran.recipeIds;
    assert.ok(altoran.includes("pin1"), "pin 포함");
    assert.ok(altoran.includes("a2"), "알토란 매칭 포함");
    assert.ok(!altoran.includes("a1"), "block 제외");
    assert.ok(!altoran.includes("n1"), "naver_blog 제외");
    assert.ok(!altoran.includes("p1"), "비매칭 제외");

    const sumi =
      dbSingle._store.home_section_index.program_sumi_side_dishes.recipeIds;
    assert.ok(sumi.includes("s1"));
  });

  await check("dryRun 은 home_section_index 를 쓰지 않는다", async () => {
    const db = makeFakeDb({
      recipes: { a1: RECIPE_ALTORAN, s1: RECIPE_SUMI },
      overrides: {},
      index: { program_altoran: { recipeIds: ["old"], count: 1 } },
    });
    const result = await rebuildProgramHomeSectionIndexes(db, { dryRun: true });
    assert.strictEqual(result.dryRun, true);
    assert.ok(result.counts.program_altoran >= 1);
    assert.deepStrictEqual(
      db._store.home_section_index.program_altoran.recipeIds,
      ["old"],
      "dryRun 이면 기존 index 유지"
    );
  });

  await check("단일 패스는 recipes 페이지를 섹션 수만큼 반복하지 않는다", async () => {
    // 페이지가 여러 개 나오도록 PAGE_SIZE 보다 많은 레시피
    const recipes = {};
    for (let i = 0; i < PAGE_SIZE + 5; i += 1) {
      const id = `r${String(i).padStart(4, "0")}`;
      recipes[id] =
        i % 2 === 0
          ? {
              ...RECIPE_ALTORAN,
              source: { title: `알토란 ${i}` },
            }
          : RECIPE_PLAIN;
    }
    const db = makeFakeDb({ recipes, overrides: {}, index: {} });
    await rebuildProgramHomeSectionIndexes(db, { dryRun: true });
    // 마지막 empty 페이지 1회 포함 (실제 Firestore 순회와 동일).
    const expectedPages = Math.ceil((PAGE_SIZE + 5) / PAGE_SIZE) + 1;
    assert.strictEqual(
      db._recipesPageReads(),
      expectedPages,
      `페이지 read 는 ${expectedPages} 회여야 함 (섹션수×가 아님)`
    );
    assert.ok(
      db._recipesPageReads() < programSectionKeys().length,
      "섹션 수보다 페이지 read 가 적어야 단일 패스"
    );
  });

  console.log(`\nPassed ${passed} checks`);
}

main();
