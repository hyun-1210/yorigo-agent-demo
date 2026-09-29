import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart' show mainNavigatorKey;
import '../services/background_parsing_service.dart';
import '../services/parse_failure_report_service.dart';
import '../services/parse_history_service.dart';
import '../services/recipe_service.dart';
import '../utils/parse_error_type.dart';
import '../widgets/app_media_query_merge_nav_insets.dart';

/// "분석 기록" 화면.
///
/// 사용자가 시도한 모든 레시피 분석을 한곳에 모아 보여준다.
/// - 분석 중: 진행 표시
/// - 완료: 탭하면 레시피 상세로 이동
/// - 실패: 다시 시도 / 개발팀에 알리기 / 삭제
///
/// "레시피를 놓쳤다"는 불안을 없애기 위한 안전망. 실패해도 링크/입력이
/// 여기 남아 있어 언제든 다시 시도할 수 있다.
class ParseHistoryScreen extends StatefulWidget {
  const ParseHistoryScreen({super.key});

  @override
  State<ParseHistoryScreen> createState() => _ParseHistoryScreenState();
}

class _ParseHistoryScreenState extends State<ParseHistoryScreen> {
  static const Color _accent = Color(0xFFFF6B00);

  final RecipeService _recipeService = RecipeService();
  final BackgroundParsingService _parsingService = BackgroundParsingService();
  final Set<String> _busyIds = <String>{};

  @override
  void initState() {
    super.initState();
    ParseHistoryService.instance.init();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: const Text(
          '분석 기록',
          style: TextStyle(
            color: Color(0xFF111111),
            fontSize: 17,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.4,
          ),
        ),
        actions: [
          ValueListenableBuilder<int>(
            valueListenable: ParseHistoryService.instance.revision,
            builder: (context, _, __) {
              if (!ParseHistoryService.instance.hasAny) {
                return const SizedBox.shrink();
              }
              return TextButton(
                onPressed: _confirmClearAll,
                child: const Text(
                  '전체 삭제',
                  style: TextStyle(
                    color: Color(0xFF9CA3AF),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: ParseHistoryService.instance.revision,
        builder: (context, _, __) {
          final items = ParseHistoryService.instance.items;
          if (items.isEmpty) return _buildEmptyState();
          return ListView.separated(
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              24 + appSystemNavBottomInset(context),
            ),
            itemCount: items.length + 1,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              if (index == 0) return _buildHeaderBanner();
              return _buildAttemptCard(items[index - 1]);
            },
          );
        },
      ),
    );
  }

  Widget _buildHeaderBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.fromLTRB(24, 12, 16, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFF1F3F5)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.verified_user_rounded,
            color: _accent,
            size: 22,
          ),
          const SizedBox(width: 15),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '링크는 안전하게 보관돼요',
                  style: TextStyle(
                    color: Color(0xFF191F28),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  '분석에 실패해도 언제든 다시 시도할 수 있어요',
                  style: TextStyle(
                    color: Color(0xFF8B95A1),
                    fontSize: 12.5,
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history_rounded,
                size: 56, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            const Text(
              '아직 분석 기록이 없어요',
              style: TextStyle(
                color: Color(0xFF111111),
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '레시피 링크나 글을 분석하면\n여기에 기록이 쌓여요',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.grey.shade500,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAttemptCard(ParseAttempt a) {
    final bool busy = _busyIds.contains(a.id);
    final bool hasUrl = (a.url ?? '').isNotEmpty;
    final bool hasRealTitle =
        (a.title ?? '').trim().isNotEmpty && a.title != '분석 중..';
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFEEF0F3)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 모든 상태(분석 중·완료·실패) 좌측 상단에 상태 칩 표시.
            // 실패의 경우 '실패 사유'는 이미지·링크 행 아래에 별도로 둔다.
            _buildStatusChip(a),
            const SizedBox(height: 9),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildThumb(a),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              _displayTitle(a),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFF191F28),
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                                height: 1.3,
                                letterSpacing: -0.3,
                              ),
                            ),
                          ),
                          // 링크가 곧 제목인 경우(영상 제목 미수신)엔 제목 옆에 복사.
                          if (hasUrl && !hasRealTitle) ...[
                            const SizedBox(width: 6),
                            _copyIconButton(a),
                          ],
                        ],
                      ),
                      // 영상 제목이 들어온 경우: 제목 아래에 링크를 함께 표시(+복사).
                      if (hasRealTitle && hasUrl) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                a.url!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.grey.shade500,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            _copyIconButton(a),
                          ],
                        ),
                      ],
                      const SizedBox(height: 3),
                      Text(
                        _subtitle(a),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.grey.shade500,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (a.isError) ...[
              const SizedBox(height: 11),
              _buildFailureReason(a),
              const SizedBox(height: 11),
              _buildErrorActions(a, busy),
            ] else if (a.isCompleted) ...[
              const SizedBox(height: 9),
              _buildCompletedAction(a),
            ],
          ],
        ),
      ),
    );
  }

  Widget _copyIconButton(ParseAttempt a) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _copyLink(a),
      child: const Padding(
        padding: EdgeInsets.only(top: 1),
        child: Icon(
          Icons.copy_rounded,
          size: 16,
          color: Color(0xFF9CA3AF),
        ),
      ),
    );
  }

  Widget _buildThumb(ParseAttempt a) {
    final hasThumb = (a.thumbnailUrl ?? '').isNotEmpty;
    IconData fallback;
    switch (a.kind) {
      case 'text':
        fallback = Icons.notes_rounded;
        break;
      case 'image':
        fallback = Icons.image_outlined;
        break;
      default:
        fallback = Icons.link_rounded;
    }
    return Container(
      width: 48,
      height: 60,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFFF1F3F5),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: const Color(0xFFEAEDF0)),
      ),
      child: hasThumb
          ? Image.network(
              a.thumbnailUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  Icon(fallback, color: Colors.grey.shade400, size: 22),
            )
          : Icon(fallback, color: Colors.grey.shade400, size: 22),
    );
  }

  Widget _buildStatusChip(ParseAttempt a) {
    late Color fg;
    late String label;
    late IconData icon;
    Color? iconColor;
    if (a.isParsing) {
      fg = const Color(0xFF2563EB);
      label = '분석 중';
      icon = Icons.autorenew_rounded;
    } else if (a.isCompleted) {
      fg = const Color(0xFF059669);
      label = '완료';
      icon = Icons.check_circle_rounded;
    } else {
      fg = _accent;
      label = '실패';
      icon = Icons.error_rounded;
      iconColor = const Color(0xFFEF4444);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFECEFF3), width: 0.9),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 5,
            offset: const Offset(0, 1.5),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: iconColor ?? fg),
          const SizedBox(width: 3.5),
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompletedAction(ParseAttempt a) {
    return SizedBox(
      width: double.infinity,
      child: _ghostButton(
        label: '레시피 보기',
        icon: Icons.arrow_forward_rounded,
        onTap: () => _openCompleted(a),
      ),
    );
  }

  /// 실패한 분석이 "왜" 실패했는지 정확한 사유를 항상 보여준다.
  Widget _buildFailureReason(ParseAttempt a) {
    final reason = _failureReason(a);
    final detail = _failureRawDetail(a);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(11, 10, 12, 11),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0xFFF0F1F4)),
        boxShadow: [
          BoxShadow(
            color: _accent.withValues(alpha: 0.07),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '· 실패 사유',
                  style: TextStyle(
                    color: _accent,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.1,
                  ),
                ),
                const SizedBox(height: 2.5),
                Text(
                  reason,
                  style: const TextStyle(
                    color: Color(0xFF3D4351),
                    fontSize: 12,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                ),
                if (detail != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    detail,
                    style: const TextStyle(
                      color: Color(0xFFAEB4BE),
                      fontSize: 10.5,
                      height: 1.3,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.1,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// errorType → 사용자 친화 사유 멘트(홈 팝업과 동일 기준).
  String _failureReason(ParseAttempt a) {
    final raw = (a.error ?? '').trim();
    switch (resolveDisplayedParseErrorType(
      errorType: a.errorType,
      errorMessage: a.error,
    )) {
      case 'not_cooking':
        return '요리·레시피 영상이 아니라 분석할 수 없었어요.';
      case 'video_too_long':
        return '영상이 너무 길어요. 15분 이내 영상만 분석할 수 있어요.';
      case 'insufficient_info':
        return '재료·조리법 정보가 부족해 레시피를 정리하지 못했어요.';
      case 'unsupported_url':
      case 'invalid_url':
        return '지원하지 않거나 잘못된 링크예요.';
      case 'network_error':
        return '네트워크를 확인한 뒤 다시 시도해 주세요. 서버가 고장난 것은 아니에요.';
      case 'server_error':
        return '서버가 일시적으로 혼잡했어요. 조금 시간이 지난 뒤 다시 시도해 주세요.';
      case 'timeout':
        return '시간이 지나 분석을 멈췄어요. 링크는 기록에 보관했으니 다시 시도해 주세요.';
      case 'concurrent_limit':
        return '동시에 분석 중인 레시피가 많아요. 진행 중인 분석이 끝난 뒤 다시 시도해 주세요.';
      case 'client_error':
      case 'duplicate':
        return '분석을 시작하지 못했어요. 잠시 후 다시 시도해 주세요.';
      default:
        if (raw.isNotEmpty) return raw;
        return '영상에 레시피 내용이 담겨 있지 않은 것 같아요.';
    }
  }

  /// 서버가 보낸 원본 메시지(타입 멘트와 다를 때만 부가 표시).
  String? _failureRawDetail(ParseAttempt a) {
    final raw = (a.error ?? '').trim();
    if (raw.isEmpty) return null;
    final type = a.errorType;
    // 타입이 없거나 server_error면 기본 멘트가 원본을 대체하므로 중복 방지.
    if (type == null ||
        type.isEmpty ||
        type == 'server_error' ||
        type == 'network_error' ||
        looksLikeNetworkParseFailure(raw)) {
      return null;
    }
    return '상세: $raw';
  }

  Widget _buildErrorActions(ParseAttempt a, bool busy) {
    final bool canRetryLink = a.kind == 'link' && (a.url ?? '').isNotEmpty;
    final bool canRetryText =
        a.kind == 'text' && (a.manualText ?? '').trim().isNotEmpty;
    final bool canRetryImage = a.kind == 'image' && a.savedImageCount > 0;
    final bool canRetry = canRetryLink || canRetryText || canRetryImage;
    return Row(
      children: [
        if (canRetry) ...[
          Expanded(
            child: _primaryButton(
              label: busy ? '시도 중…' : '다시 시도',
              icon: Icons.refresh_rounded,
              onTap: busy ? null : () => _retry(a),
            ),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: _ghostButton(
            label: a.reported ? '알림 보냄' : '개발팀에 알리기',
            icon: a.reported
                ? Icons.check_rounded
                : Icons.campaign_outlined,
            onTap: a.reported ? null : () => _report(a),
          ),
        ),
        const SizedBox(width: 8),
        _iconButton(
          icon: Icons.close_rounded,
          onTap: () => _confirmRemove(a),
        ),
      ],
    );
  }

  Widget _primaryButton({
    required String label,
    required IconData icon,
    required VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 33,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: onTap == null ? _accent.withValues(alpha: 0.5) : _accent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 13, color: Colors.white),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ghostButton({
    required String label,
    required IconData icon,
    required VoidCallback? onTap,
  }) {
    final bool disabled = onTap == null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 33,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFFF4F5F7),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 13,
                color: disabled
                    ? const Color(0xFF9CA3AF)
                    : const Color(0xFF4B5563)),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: disabled
                      ? const Color(0xFF9CA3AF)
                      : const Color(0xFF4B5563),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconButton({required IconData icon, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 33,
        height: 33,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFFF4F5F7),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 15, color: const Color(0xFF6B7280)),
      ),
    );
  }

  Future<void> _copyLink(ParseAttempt a) async {
    final url = a.url ?? '';
    if (url.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) _snack('링크를 복사했어요');
  }

  Future<void> _confirmRemove(ParseAttempt a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('기록 삭제'),
        content: const Text('이 분석 기록을 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제',
                style: TextStyle(color: Color(0xFFEF4444))),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ParseHistoryService.instance.remove(a.id);
    }
  }

  String _displayTitle(ParseAttempt a) {
    if ((a.title ?? '').isNotEmpty && a.title != '분석 중..') return a.title!;
    if ((a.url ?? '').isNotEmpty) return a.url!;
    switch (a.kind) {
      case 'text':
        return '붙여넣은 레시피 글';
      case 'image':
        return '스크린샷 분석';
      default:
        return '레시피 링크';
    }
  }

  String _subtitle(ParseAttempt a) {
    final platform = (a.platform ?? '').trim();
    final when = _relativeTime(a.updatedAt);
    if (platform.isNotEmpty) return '$platform · $when';
    switch (a.kind) {
      case 'text':
        return '글 분석 · $when';
      case 'image':
        return '스크린샷 분석 · $when';
      default:
        return when;
    }
  }

  String _relativeTime(int ms) {
    final diff = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (diff.inMinutes < 1) return '방금 전';
    if (diff.inMinutes < 60) return '${diff.inMinutes}분 전';
    if (diff.inHours < 24) return '${diff.inHours}시간 전';
    if (diff.inDays < 7) return '${diff.inDays}일 전';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.month}월 ${d.day}일';
  }

  Future<void> _openCompleted(ParseAttempt a) async {
    try {
      final parseResponse = await _recipeService.getRecipeById(a.id);
      if (!mounted) return;
      if (parseResponse != null) {
        Navigator.pushNamed(
          context,
          '/recipe-detail',
          arguments: {'parseResponse': parseResponse, 'recipeId': a.id},
        );
      } else {
        _snack('레시피를 찾을 수 없어요. 삭제되었을 수 있어요.');
      }
    } catch (_) {
      if (mounted) _snack('레시피를 여는 중 문제가 생겼어요.');
    }
  }

  Future<void> _retry(ParseAttempt a) async {
    setState(() => _busyIds.add(a.id));
    try {
      if (a.kind == 'link') {
        final url = a.url ?? '';
        if (url.isEmpty) {
          _snack('링크 정보가 없어요.');
          return;
        }
        await _parsingService.retryParsing(
          recipeId: a.id,
          url: url,
          preferLang: 'ko',
          naverSharedMetaDedup: a.isNaverDedup,
        );
      } else {
        final text = (a.manualText ?? '').trim();
        final images = await ParseHistoryService.instance.loadAttemptImages(a.id);
        if (text.isEmpty && images.isEmpty) {
          _snack('저장된 입력이 없어요. 레시피 추가 화면에서 다시 입력해 주세요.');
          return;
        }
        await _parsingService.retryContentParsing(
          recipeId: a.id,
          text: text.isNotEmpty ? text : null,
          images: images.isNotEmpty ? images : null,
          preferLang: 'ko',
        );
      }
      await ParseHistoryService.instance.markParsing(a.id);
      await ParseHistoryService.instance.record(
        id: a.id,
        kind: a.kind,
        url: a.url,
        manualText: a.manualText,
      );
      if (mounted) {
        // 모든 오버레이(분석 기록 화면 + 레시피 추가 시트)를 즉시 닫고
        // 홈의 레시피북으로 이동한다. 재분석은 레시피북에서 진행 상황이 보인다.
        Navigator.of(context, rootNavigator: true)
            .popUntil((route) => route.isFirst);
        mainNavigatorKey.currentState?.navigateToHome();
      }
    } catch (e) {
      if (mounted) {
        _snack('다시 시도에 실패했어요: ${e.toString().replaceFirst('Exception: ', '')}');
      }
    } finally {
      if (mounted) setState(() => _busyIds.remove(a.id));
    }
  }

  Future<void> _report(ParseAttempt a) async {
    try {
      await ParseFailureReportService.instance.report(
        reason: 'failed',
        recipeId: a.id,
        sourceUrl: a.url,
        kind: a.kind,
        errorType: a.errorType,
        errorMessage: a.error,
        platform: a.platform,
      );
      await ParseHistoryService.instance.markReported(a.id);
      if (mounted) _snack('알려주셔서 감사해요! 빠르게 살펴보고 개선할게요.');
    } catch (_) {
      if (mounted) _snack('잠시 후 다시 시도해 주세요.');
    }
  }

  Future<void> _confirmClearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('분석 기록 전체 삭제'),
        content: const Text('모든 분석 기록을 삭제할까요? 진행 중인 분석은 영향받지 않아요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제',
                style: TextStyle(color: Color(0xFFEF4444))),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ParseHistoryService.instance.clear();
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }
}
