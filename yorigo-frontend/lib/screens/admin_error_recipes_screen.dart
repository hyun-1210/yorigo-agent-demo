import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../widgets/app_refresh_indicator.dart';
import '../services/admin_service.dart';
import '../services/recipe_service.dart';
import '../widgets/app_confirm_dialog.dart';
import '../widgets/app_prompt_dialog.dart';

class AdminErrorRecipesScreen extends StatefulWidget {
  const AdminErrorRecipesScreen({super.key});

  @override
  State<AdminErrorRecipesScreen> createState() => _AdminErrorRecipesScreenState();
}

class _AdminErrorRecipesScreenState extends State<AdminErrorRecipesScreen> {
  final RecipeService _recipeService = RecipeService();

  Future<void> _refreshErrorRecipes() async {
    await FirebaseFirestore.instance
        .collection('recipes')
        .where('status', isEqualTo: 'error')
        .orderBy('updatedAt', descending: true)
        .get(const GetOptions(source: Source.server));
  }

  Future<String?> _promptHiddenReason({
    required String initialValue,
    required bool isHide,
  }) {
    return AppPromptDialog.show(
      context: context,
      title: isHide ? '숨김 사유를 입력해주세요' : '복구 사유를 입력해주세요',
      hintText: '사유를 입력해주세요',
      initialValue: initialValue,
    );
  }

  Future<void> _toggleHidden({
    required String recipeId,
    required bool hidden,
    required String defaultReason,
  }) async {
    final reason = await _promptHiddenReason(
      initialValue: defaultReason,
      isHide: hidden,
    );
    if (reason == null || reason.isEmpty) return;
    await _recipeService.setRecipeHidden(
      recipeId: recipeId,
      hidden: hidden,
      reason: reason,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(hidden ? '레시피 숨김 처리 완료' : '레시피 복구 완료'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<bool> _confirmDeleteRecipe() async {
    final result = await AppConfirmDialog.show(
      context: context,
      title: '레시피를 완전히 삭제할까요?',
      description: '삭제된 레시피는 복구할 수 없어요.',
      confirmLabel: '삭제',
      destructive: true,
    );
    return result == true;
  }

  Future<void> _deleteRecipe(String recipeId) async {
    final confirmed = await _confirmDeleteRecipe();
    if (!confirmed) return;

    try {
      await FirebaseFirestore.instance.collection('recipes').doc(recipeId).delete();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('레시피 삭제 완료'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('레시피 삭제 실패: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);
    if (diff.inMinutes < 1) return '방금 전';
    if (diff.inHours < 1) return '${diff.inMinutes}분 전';
    if (diff.inDays < 1) return '${diff.inHours}시간 전';
    return '${date.month}/${date.day}';
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: AdminService.instance.isAdmin(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (snapshot.data != true) {
          return Scaffold(
            appBar: AppBar(title: const Text('권한 없음')),
            body: const Center(child: Text('관리자 권한이 필요합니다.')),
          );
        }

        return Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          appBar: AppBar(
            title: const Text('오류 레시피 검수'),
          ),
          body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('recipes')
                .where('status', isEqualTo: 'error')
                .orderBy('updatedAt', descending: true)
                .snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return Center(child: Text('오류: ${snap.error}'));
              }
              final docs = snap.data?.docs ?? [];

              return AppRefreshIndicator(
                onRefresh: _refreshErrorRecipes,
                child: docs.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [
                          SizedBox(height: 120),
                          Center(child: Text('오류 레시피가 없습니다.')),
                        ],
                      )
                    : ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                itemCount: docs.length,
                itemBuilder: (context, index) {
                  final doc = docs[index];
                  final data = doc.data();
                  final recipeId = doc.id;
                  final status = data['status'] as String? ?? '';
                  final title = (data['recipe'] is Map)
                      ? (data['recipe'] as Map)['title']?.toString() ?? ''
                      : (data['title']?.toString() ?? '');
                  final errorMessage = data['error']?.toString() ?? '파싱 실패';
                  final isHidden = data['isHidden'] == true;

                  final updatedAt = data['updatedAt'] as Timestamp?;
                  final addedDate = updatedAt?.toDate() ?? DateTime.now();

                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title.isNotEmpty ? title : '레시피',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '상태: $status',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '오류: $errorMessage',
                            style: const TextStyle(color: Colors.red),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '업데이트: ${_formatDate(addedDate)}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () async {
                                  await _toggleHidden(
                                    recipeId: recipeId,
                                    hidden: !isHidden,
                                    defaultReason: isHidden ? 'restore_from_error' : 'manual_hide_error',
                                  );
                                },
                                child: Text(isHidden ? '복구' : '숨김'),
                              ),
                              TextButton(
                                onPressed: () => _deleteRecipe(recipeId),
                                child: const Text(
                                  '삭제',
                                  style: TextStyle(color: Colors.red),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              );
            },
          ),
        );
      },
    );
  }
}

