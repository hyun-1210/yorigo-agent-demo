import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../main.dart' show mainNavigatorKey, appNavigatorKey;
import '../services/local_storage_service.dart';
import '../utils/naver_blog_utils.dart';

/// 네이버 블로그 레시피의 본문은 사용자 본인 디바이스 로컬에만 저장되므로
/// (저작권법 §30 사적 복제 안전성), 본인이 분석한 적 없는 네이버 레시피는
/// 디테일 화면에 진입해도 본문이 비어 있다. 이 다이얼로그는 진입을 막고
/// 사용자에게 두 가지 선택지를 제공한다:
///
/// - **블로그 열기** — 외부 브라우저로 원본 블로그 글 보기
/// - **내가 분석하기** — 분석 팝업으로 redirect (URL prefilled)
///
/// 호출 측은 디테일 진입 직전에 [shouldShowNaverAccessDialog] 로 게이트해야 한다.
Future<void> showNaverBlogAccessDialog({
  required BuildContext context,
  required String sourceUrl,
}) async {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (dialogCtx) {
      return AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: const Text(
          '네이버 블로그 레시피',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        content: const Text(
          '네이버 블로그 레시피는 본인이 직접 분석해야 재료/조리법을 볼 수 있어요.\n원본 블로그를 그대로 보거나, 내 레시피북으로 분석해서 추가할 수 있어요.',
          style: TextStyle(fontSize: 14, height: 1.45),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.of(dialogCtx).pop();
              try {
                final uri = Uri.parse(sourceUrl);
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              } catch (_) {
                // launch 실패 시 무시 — 사용자가 다시 시도할 수 있다.
              }
            },
            child: const Text('블로그 열기'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFFF6B35),
            ),
            onPressed: () {
              Navigator.of(dialogCtx).pop();
              // 사용자 명세: "분석하기 누르면 홈에서 분석 시작 팝업이 뜨게".
              // push 된 라우트(TrendingAllPage / 리뷰 피드 등)를 모두 pop 하고
              // 홈 탭으로 전환한 뒤 root shell 의 sheet 를 띄운다.
              final root = mainNavigatorKey.currentState;
              if (root == null) return;
              appNavigatorKey.currentState?.popUntil((route) => route.isFirst);
              root.navigateToHome();
              root.showAddRecipeSheet(initialUrl: sourceUrl);
            },
            child: const Text(
              '내가 분석하기',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      );
    },
  );
}

/// 주어진 레시피가 네이버 블로그이고 본인 디바이스에 본문이 없으면 true.
/// true 인 경우 호출 측은 디테일 진입 대신 [showNaverBlogAccessDialog] 를 띄워야 한다.
///
/// - [platform] : `recipes/{id}.source.platform` 또는 동일 위치 string
/// - [recipeId] : 본문 로컬 조회용 키 (없으면 본문 체크 생략하고 platform 만으로 판정)
/// - [sourceUrl] : 폴백으로 platform 비어 있을 때 URL 패턴으로 판정
Future<bool> shouldShowNaverAccessDialog({
  required String? platform,
  required String? recipeId,
  required String? sourceUrl,
}) async {
  final p = (platform ?? '').toLowerCase();
  final isNaver = p == 'naver_blog' ||
      (sourceUrl != null && isNaverBlogUrl(sourceUrl));
  if (!isNaver) return false;
  if (recipeId == null || recipeId.isEmpty) return true;
  try {
    final body = await LocalStorageService().getNaverBody(recipeId);
    return body == null;
  } catch (_) {
    return true;
  }
}
