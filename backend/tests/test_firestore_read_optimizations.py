import unittest
from pathlib import Path
from unittest.mock import patch

from services import product_service


class _FakeRef:
    def __init__(self, document_id):
        self.id = document_id


class _FakeCollection:
    def document(self, document_id):
        if "/" in document_id:
            raise ValueError("invalid document id")
        return _FakeRef(document_id)

    def stream(self):
        raise AssertionError("full collection stream must not be used")


class _FakeSnapshot:
    def __init__(self, document_id, *, exists=True, data=None):
        self.id = document_id
        self.exists = exists
        self._data = data or {}

    def to_dict(self):
        return self._data


class _CoverageDB:
    def __init__(self, existing_ids):
        self.existing_ids = set(existing_ids)
        self.requested_ids = []

    def collection(self, name):
        self.collection_name = name
        return _FakeCollection()

    def get_all(self, refs):
        refs = list(refs)
        self.requested_ids.extend(ref.id for ref in refs)
        return [
            _FakeSnapshot(ref.id, exists=ref.id in self.existing_ids)
            for ref in refs
        ]


class _CoverageFirebase:
    def __init__(self, db):
        self.db = db
        self.verified_added = []
        self.missing_queued = []

    def is_available(self):
        return True

    def get_product_coverage_verified(self):
        return {"already"}

    def add_product_coverage_verified(self, names):
        self.verified_added.extend(names)
        return True

    def add_priority_scraping_ingredients_batch(self, names, source):
        self.missing_queued.extend(names)
        return True


class FirestoreReadOptimizationTests(unittest.TestCase):
    def test_purchase_search_expands_preserved_ingredient_variant(self):
        self.assertEqual(
            product_service.get_search_names("대파 흰 부분"),
            ["대파 흰 부분", "대파"],
        )

    def test_removed_costly_sources_do_not_return(self):
        backend_dir = Path(__file__).resolve().parents[1]
        recipe_source = (backend_dir / "services" / "recipe_service.py").read_text(
            encoding="utf-8"
        )
        backend_source = (backend_dir / "backend.py").read_text(encoding="utf-8")
        functions_source = (
            backend_dir.parent / "yorigo-frontend" / "functions" / "index.js"
        ).read_text(encoding="utf-8")

        self.assertNotIn(
            'collection("coupang_products").stream()',
            recipe_source,
        )
        self.assertNotIn("IngredientCacheWarmup", backend_source)
        self.assertNotIn("ENABLE_PRODUCT_CATALOG_PARSE_ALIGNMENT", backend_source)
        self.assertNotIn("exports.exportUserAnalyticsToSheet", functions_source)
        self.assertNotIn("exports.exportRecipeAnalyticsToSheet", functions_source)
        self.assertNotIn("exports.exportProductAnalyticsToSheet", functions_source)

    def test_product_coverage_batch_gets_only_unverified_ingredients(self):
        db = _CoverageDB(existing_ids={"covered"})
        firebase = _CoverageFirebase(db)

        with patch(
            "services.firebase_service.get_firebase_service",
            return_value=firebase,
        ), patch.object(
            product_service,
            "_load_all_ingredients",
            return_value={"already", "covered", "missing", "bad/name"},
        ):
            result = product_service.check_ingredient_product_coverage()

        self.assertEqual(db.collection_name, "coupang_products")
        self.assertCountEqual(db.requested_ids, ["covered", "missing"])
        self.assertEqual(firebase.verified_added, ["covered"])
        self.assertCountEqual(firebase.missing_queued, ["missing", "bad/name"])
        self.assertEqual(result["checked_this_run"], 3)
        self.assertEqual(result["newly_verified"], 1)

    def test_deprecated_parse_catalog_hooks_never_read_or_mutate(self):
        from services.recipe_service import RecipeService

        service = RecipeService.__new__(RecipeService)
        recipe = {
            "ingredients": [
                {"item": "대파 흰 부분", "category": "vegetable"},
            ],
        }

        service._load_ingredient_lookup_data(force=True)
        service._schedule_background_refresh()
        result = service._align_ingredients_with_known_db_and_queue(recipe)

        self.assertEqual(result, ([], 0, 0))
        self.assertEqual(recipe["ingredients"][0]["item"], "대파 흰 부분")

    def test_manual_similarity_seed_strips_only_trailing_recipe_phrases(self):
        from services.recipe_service import RecipeService

        normalize = RecipeService._normalize_canonical_dish_seed
        self.assertEqual(normalize("초간단 백종원 김치찌개 만드는 법"), "김치찌개")
        self.assertEqual(normalize("제육볶음 황금 레시피"), "제육볶음")
        self.assertEqual(normalize("레시피"), "레시피")
        self.assertEqual(normalize("레시피 닭볶음탕"), "레시피 닭볶음탕")


if __name__ == "__main__":
    unittest.main()
