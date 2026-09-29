import 'package:flutter/material.dart';
import '../services/recipe_service.dart';
import '../theme/app_colors.dart';
import '../widgets/yorigo_header_logo.dart';
import '../widgets/app_confirm_dialog.dart';

class ReparseRecipesScreen extends StatefulWidget {
  const ReparseRecipesScreen({super.key});

  @override
  State<ReparseRecipesScreen> createState() => _ReparseRecipesScreenState();
}

class _ReparseRecipesScreenState extends State<ReparseRecipesScreen> {
  final RecipeService _recipeService = RecipeService();
  List<Map<String, dynamic>> _recipes = [];
  final Set<String> _selectedRecipeIds = {};
  bool _isLoading = true;
  bool _isReparsing = false;

  @override
  void initState() {
    super.initState();
    _loadRecipes();
  }

  Future<void> _loadRecipes() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final recipes = await _recipeService.getReparsableRecipes();
      setState(() {
        _recipes = recipes;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('레시피 목록을 불러오는 중 오류가 발생했습니다: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _handleReparse() async {
    if (_selectedRecipeIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('재파싱할 레시피를 선택해주세요'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Show confirmation dialog
    final confirmed = await AppConfirmDialog.show(
      context: context,
      title: '${_selectedRecipeIds.length}개의 레시피를 재파싱할까요?',
      description: '재파싱은 시간이 걸릴 수 있어요.',
      confirmLabel: '재파싱',
    );

    if (confirmed != true) return;

    setState(() {
      _isReparsing = true;
    });

    try {
      final result = await _recipeService.reparseSelectedRecipes(
        _selectedRecipeIds.toList(),
      );

      if (mounted) {
        setState(() {
          _isReparsing = false;
          _selectedRecipeIds.clear();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '재파싱 완료: ${result['reparsed']}개 재파싱, ${result['updated']}개 업데이트, ${result['skipped']}개 건너뜀, ${result['errors']}개 오류',
            ),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 5),
          ),
        );
        // Reload recipes to show updated data
        _loadRecipes();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isReparsing = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('재파싱 중 오류가 발생했습니다: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;

    return Scaffold(
      backgroundColor: AppColors.getBackground(brightness),
      appBar: AppBar(
        backgroundColor: AppColors.getBackground(brightness),
        elevation: 0,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back,
            color: AppColors.getTextPrimary(brightness),
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        titleSpacing: 0,
        centerTitle: false,
        title: Row(
          children: [
            const YorigoHeaderLogo(height: 22, maxWidth: 88),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '레시피 재파싱 (테스트)',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.getTextPrimary(brightness),
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        actions: [
          if (_selectedRecipeIds.isNotEmpty && !_isReparsing)
            TextButton(
              onPressed: () {
                setState(() {
                  _selectedRecipeIds.clear();
                });
              },
              child: Text(
                '선택 해제',
                style: TextStyle(color: AppColors.getTextPrimary(brightness)),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Info banner
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: AppColors.primary.withValues(alpha: 0.1),
              child: Text(
                '재파싱할 레시피를 선택하세요. sourceUrl이 있는 레시피만 표시됩니다.',
                style: TextStyle(
                  color: AppColors.getTextPrimary(brightness),
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            // Recipe list
            Expanded(
              child: _isLoading
                  ? Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                      ),
                    )
                  : _recipes.isEmpty
                  ? Center(
                      child: Text(
                        '재파싱 가능한 레시피가 없습니다',
                        style: TextStyle(
                          color: AppColors.getTextSecondary(brightness),
                          fontSize: 16,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _recipes.length,
                      itemBuilder: (context, index) {
                        final recipe = _recipes[index];
                        final recipeId = recipe['id'] as String;
                        final title =
                            recipe['title'] as String? ??
                            recipe['recipe']?['name'] as String? ??
                            '레시피';
                        final isSelected = _selectedRecipeIds.contains(
                          recipeId,
                        );

                        return CheckboxListTile(
                          value: isSelected,
                          onChanged: _isReparsing
                              ? null
                              : (value) {
                                  setState(() {
                                    if (value == true) {
                                      _selectedRecipeIds.add(recipeId);
                                    } else {
                                      _selectedRecipeIds.remove(recipeId);
                                    }
                                  });
                                },
                          title: Text(
                            title,
                            style: TextStyle(
                              color: AppColors.getTextPrimary(brightness),
                              fontSize: 16,
                            ),
                          ),
                          subtitle: Text(
                            recipe['sourceUrl'] as String? ?? '',
                            style: TextStyle(
                              color: AppColors.getTextSecondary(brightness),
                              fontSize: 12,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          activeColor: AppColors.primary,
                        );
                      },
                    ),
            ),
            // Action button
            if (!_isLoading && _recipes.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.getBackground(brightness),
                  border: Border(
                    top: BorderSide(
                      color: AppColors.getBorder(brightness),
                      width: 1,
                    ),
                  ),
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isReparsing || _selectedRecipeIds.isEmpty
                        ? null
                        : _handleReparse,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _isReparsing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          )
                        : Text(
                            '선택한 ${_selectedRecipeIds.length}개 재파싱',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
