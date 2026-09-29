import 'package:flutter/material.dart';

import '../services/recipe_service.dart';
import '../utils/recipe_display_title.dart';
import '../utils/recipe_thumbnail_resolver.dart';
import 'app_network_image.dart';

class TaggedRecipePick {
  const TaggedRecipePick({
    required this.id,
    required this.title,
    required this.thumbnailUrl,
  });

  final String id;
  final String title;
  final String thumbnailUrl;
}

/// Pick a recipe to tag on a board post. Saved recipes first, then recent.
class PickRecipeTagSheet extends StatefulWidget {
  const PickRecipeTagSheet({super.key});

  static Future<TaggedRecipePick?> show(BuildContext context) {
    return showModalBottomSheet<TaggedRecipePick>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const PickRecipeTagSheet(),
    );
  }

  @override
  State<PickRecipeTagSheet> createState() => _PickRecipeTagSheetState();
}

class _PickRecipeTagSheetState extends State<PickRecipeTagSheet> {
  final _query = TextEditingController();
  late final Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final service = RecipeService.shared;
    final saved = await service.getSavedRecipesForExplore(limit: 80);
    final recent = await service.getRecentlyAddedRecipes(limit: 40);
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];
    for (final recipe in [...saved, ...recent]) {
      final id = (recipe['id'] as String? ?? '').trim();
      if (id.isEmpty || seen.contains(id)) continue;
      seen.add(id);
      out.add(recipe);
    }
    return out;
  }

  String _titleOf(Map<String, dynamic> recipe) {
    final nested = recipe['recipe'] as Map<String, dynamic>? ?? {};
    return recipeCardDishTitle(
      name: (nested['name'] as String?) ?? (recipe['name'] as String?),
      title: (nested['title'] as String?) ?? (recipe['title'] as String?),
    );
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.text.trim().toLowerCase();
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFE5E7EB),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 14, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '레시피 태그',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF111827),
                    letterSpacing: -0.3,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _query,
                decoration: InputDecoration(
                  hintText: '레시피 이름 검색',
                  hintStyle: const TextStyle(
                    fontFamily: 'Pretendard',
                    color: Color(0xFF9CA3AF),
                  ),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    color: Color(0xFF9CA3AF),
                  ),
                  filled: true,
                  fillColor: const Color(0xFFF7F8FA),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                ),
              ),
            ),
            Expanded(
              child: FutureBuilder<List<Map<String, dynamic>>>(
                future: _future,
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final rows = snap.data!.where((recipe) {
                    if (q.isEmpty) return true;
                    return _titleOf(recipe).toLowerCase().contains(q);
                  }).toList();
                  if (rows.isEmpty) {
                    return const Center(
                      child: Text(
                        '태그할 레시피가 없어요',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          color: Color(0xFF9CA3AF),
                        ),
                      ),
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final recipe = rows[i];
                      final id = (recipe['id'] as String? ?? '').trim();
                      final title = _titleOf(recipe);
                      final thumb = RecipeThumbnailResolver.resolve(recipe);
                      return ListTile(
                        minLeadingWidth: 52,
                        minVerticalPadding: 8,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: SizedBox(
                            width: 44,
                            height: 55,
                            child: thumb.isEmpty
                                ? const ColoredBox(
                                    color: Color(0xFFF3F4F6),
                                    child: Icon(
                                      Icons.restaurant_rounded,
                                      color: Color(0xFF9CA3AF),
                                    ),
                                  )
                                : AppNetworkImage(
                                    imageUrl: thumb,
                                    fit: BoxFit.cover,
                                    width: 44,
                                    height: 55,
                                  ),
                          ),
                        ),
                        title: Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Pretendard',
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF111827),
                          ),
                        ),
                        trailing: const Icon(
                          Icons.chevron_right_rounded,
                          color: Color(0xFF9CA3AF),
                        ),
                        onTap: id.isEmpty
                            ? null
                            : () => Navigator.pop(
                                context,
                                TaggedRecipePick(
                                  id: id,
                                  title: title,
                                  thumbnailUrl: thumb,
                                ),
                              ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
