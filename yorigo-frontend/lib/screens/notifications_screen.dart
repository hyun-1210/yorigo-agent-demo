import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../services/notification_service.dart';
import '../widgets/app_media_query_merge_nav_insets.dart';
import '../widgets/user_initial_avatar.dart';

class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  static const _textPrimary = Color(0xFF111111);
  static const _textSecondary = Color(0xFF6B7280);
  static const _textTertiary = Color(0xFF9CA3AF);
  static const _dividerColor = Color(0xFFF3F4F6);
  static const _unreadDot = Color(0xFFFF6B00);

  String _formatTimeAgo(dynamic createdAt) {
    if (createdAt == null) return '';
    DateTime date;
    if (createdAt is Timestamp) {
      date = createdAt.toDate();
    } else if (createdAt is DateTime) {
      date = createdAt;
    } else {
      return '';
    }
    final now = DateTime.now();
    final diff = now.difference(date);
    if (diff.inMinutes < 1) return '방금 전';
    if (diff.inHours < 1) return '${diff.inMinutes}분 전';
    if (diff.inDays < 1) return '${diff.inHours}시간 전';
    if (diff.inDays < 7) return '${diff.inDays}일 전';
    if (diff.inDays < 30) return '${(diff.inDays / 7).floor()}주 전';
    if (diff.inDays < 365) return '${(diff.inDays / 30).floor()}개월 전';
    return '${(diff.inDays / 365).floor()}년 전';
  }

  String _buildMessage(Map<String, dynamic> n) {
    final raw = (n['message'] ?? '').toString();
    if (raw.isNotEmpty) return raw;
    final actor = (n['actorName'] ?? '사용자').toString();
    final type = (n['type'] ?? '').toString();
    switch (type) {
      case 'review_like':
        return '$actor님이 회원님의 리뷰를 좋아합니다.';
      case 'review_comment':
        return '$actor님이 회원님의 리뷰에 댓글을 남겼습니다.';
      case 'comment_reply':
        return '$actor님이 회원님의 댓글에 답글을 남겼습니다.';
      case 'comment_like':
        return '$actor님이 회원님의 댓글을 좋아합니다.';
      case 'review_hidden':
        return '회원님의 리뷰가 숨김 처리되었습니다.';
      case 'review_deleted':
        return '회원님의 리뷰가 삭제 처리되었습니다.';
      case 'comment_hidden':
        return '회원님의 댓글이 숨김 처리되었습니다.';
      case 'comment_deleted':
        return '회원님의 댓글이 삭제 처리되었습니다.';
      case 'follow':
        return '$actor님이 회원님을 팔로우하기 시작했습니다.';
      case 'meal_plan_breakfast_reminder':
        return '아침 식사로 예약한 레시피가 기다리고 있어요. 지금 요리를 시작해보세요!';
      case 'meal_plan_lunch_reminder':
        return '점심 식사로 예약한 레시피가 기다리고 있어요. 지금 요리를 시작해보세요!';
      case 'meal_plan_dinner_reminder':
        return '저녁 식사로 예약한 레시피가 기다리고 있어요. 지금 요리를 시작해보세요!';
      case 'daily_streak_reminder':
        return '오늘 출석하고 캘린더를 확인해보세요!';
      case 'weekly_streak_reminder':
        return '이번 주 출석 기록을 이어가보세요!';
      case 'system_announcement':
        return (n['message'] ?? '').toString();
      case 'admin_push_debug':
        return (n['message'] ?? '').toString();
      case 'meetup_join':
        return '$actor님이 모임에 참여했어요.';
      case 'meetup_confirmed':
        return '오픈 클래스 신청이 수락되었어요.';
      case 'challenge_join':
        return '$actor님이 친구 챌린지에 참여했어요.';
      case 'challenge_proof':
        return '$actor님이 챌린지를 인증했어요.';
      default:
        return '새 알림이 도착했습니다.';
    }
  }

  bool _isSystemNotification(String type) {
    return type == 'review_hidden' ||
        type == 'review_deleted' ||
        type == 'comment_hidden' ||
        type == 'comment_deleted' ||
        type == 'system_announcement' ||
        type == 'admin_push_debug' ||
        type == 'daily_streak_reminder' ||
        type == 'weekly_streak_reminder' ||
        type == 'meal_plan_breakfast_reminder' ||
        type == 'meal_plan_lunch_reminder' ||
        type == 'meal_plan_dinner_reminder';
  }

  IconData _systemIcon(String type) {
    switch (type) {
      case 'review_hidden':
      case 'comment_hidden':
        return Icons.visibility_off_rounded;
      case 'review_deleted':
      case 'comment_deleted':
        return Icons.delete_outline_rounded;
      case 'system_announcement':
        return Icons.campaign_outlined;
      case 'daily_streak_reminder':
      case 'weekly_streak_reminder':
        return Icons.local_fire_department_rounded;
      case 'meal_plan_breakfast_reminder':
      case 'meal_plan_lunch_reminder':
      case 'meal_plan_dinner_reminder':
        return Icons.restaurant_rounded;
      default:
        return Icons.info_outline_rounded;
    }
  }

  Widget _buildAvatar(Map<String, dynamic> n) {
    final type = (n['type'] ?? '').toString();

    if (_isSystemNotification(type)) {
      return Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFFF0F2F5)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Icon(_systemIcon(type), size: 22, color: const Color(0xFFFF6B00)),
      );
    }

    final photoUrl = (n['actorPhotoUrl'] ?? '').toString();
    final actorId = (n['actorId'] ?? n['actorUid'] ?? n['fromUid'] ?? '')
        .toString();
    final actorName = (n['actorName'] ?? '').toString();
    final actorHandle = (n['actorHandle'] ?? '').toString();
    if (photoUrl.isNotEmpty) {
      return Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFFE5E7EB), width: 0.5),
        ),
        child: ClipOval(
          child: Image.network(
            photoUrl,
            width: 44,
            height: 44,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) =>
                _initialFallbackAvatar(actorId, actorName, actorHandle),
          ),
        ),
      );
    }

    return _initialFallbackAvatar(actorId, actorName, actorHandle);
  }

  Widget _initialFallbackAvatar(String actorId, String name, String handle) {
    final hasIdentity =
        actorId.isNotEmpty || name.isNotEmpty || handle.isNotEmpty;
    if (hasIdentity) {
      return UserInitialAvatar(
        seed: actorId.isNotEmpty
            ? actorId
            : (handle.isNotEmpty ? handle : name),
        name: name.isNotEmpty ? name : (handle.isNotEmpty ? handle : '사용자'),
        size: 44,
      );
    }
    return Container(
      width: 44,
      height: 44,
      decoration: const BoxDecoration(
        color: Color(0xFFF3F4F6),
        shape: BoxShape.circle,
      ),
      child: const Icon(
        Icons.person_rounded,
        size: 24,
        color: Color(0xFF9CA3AF),
      ),
    );
  }

  Widget _buildRichMessage(Map<String, dynamic> n) {
    final type = (n['type'] ?? '').toString();
    final actorName = (n['actorName'] ?? '사용자').toString();
    final rawMessage = (n['message'] ?? '').toString();

    if (_isSystemNotification(type)) {
      final title = (n['title'] ?? '').toString().trim();
      final body = rawMessage.isNotEmpty ? rawMessage : _buildMessage(n);
      final label = switch (type) {
        'review_hidden' || 'review_deleted' => '운영 알림',
        'comment_hidden' || 'comment_deleted' => '댓글 알림',
        'system_announcement' => '공지',
        'daily_streak_reminder' || 'weekly_streak_reminder' => '출석 알림',
        'meal_plan_breakfast_reminder' ||
        'meal_plan_lunch_reminder' ||
        'meal_plan_dinner_reminder' => '식사 알림',
        _ => '알림',
      };

      if (title.isNotEmpty) {
        return RichText(
          maxLines: 6,
          overflow: TextOverflow.ellipsis,
          text: TextSpan(
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 13.5,
              color: _textPrimary,
              height: 1.45,
              letterSpacing: -0.2,
            ),
            children: [
              TextSpan(
                text: '$label · $title\n',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              TextSpan(
                text: body,
                style: const TextStyle(fontWeight: FontWeight.w400),
              ),
            ],
          ),
        );
      }

      return RichText(
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(
          style: const TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 13.5,
            color: _textPrimary,
            height: 1.45,
            letterSpacing: -0.2,
          ),
          children: [
            TextSpan(
              text: '$label · ',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            TextSpan(
              text: body,
              style: const TextStyle(fontWeight: FontWeight.w400),
            ),
          ],
        ),
      );
    }

    if (rawMessage.isNotEmpty && rawMessage.contains(actorName)) {
      final idx = rawMessage.indexOf(actorName);
      final before = rawMessage.substring(0, idx);
      final after = rawMessage.substring(idx + actorName.length);
      return RichText(
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(
          style: const TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 13.5,
            color: _textPrimary,
            height: 1.45,
            letterSpacing: -0.2,
          ),
          children: [
            if (before.isNotEmpty) TextSpan(text: before),
            TextSpan(
              text: actorName,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            if (after.isNotEmpty) TextSpan(text: after),
          ],
        ),
      );
    }

    return RichText(
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: const TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 13.5,
          color: _textPrimary,
          height: 1.45,
          letterSpacing: -0.2,
        ),
        children: [
          TextSpan(
            text: actorName,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          TextSpan(text: _getMessageSuffix(type)),
        ],
      ),
    );
  }

  String _getMessageSuffix(String type) {
    switch (type) {
      case 'review_like':
        return '님이 회원님의 리뷰를 좋아합니다.';
      case 'review_comment':
        return '님이 회원님의 리뷰에 댓글을 남겼습니다.';
      case 'comment_reply':
        return '님이 회원님의 댓글에 답글을 남겼습니다.';
      case 'comment_like':
        return '님이 회원님의 댓글을 좋아합니다.';
      case 'follow':
        return '님이 회원님을 팔로우하기 시작했습니다.';
      case 'meetup_join':
        return '님이 모임에 참여했어요.';
      case 'meetup_confirmed':
        return ' · 오픈 클래스 신청이 수락되었어요.';
      case 'challenge_join':
        return '님이 친구 챌린지에 참여했어요.';
      case 'challenge_proof':
        return '님이 챌린지를 인증했어요.';
      case 'meal_plan_breakfast_reminder':
        return ' · 아침 식사 예약 레시피를 요리할 시간이에요.';
      case 'meal_plan_lunch_reminder':
        return ' · 점심 식사 예약 레시피를 요리할 시간이에요.';
      case 'meal_plan_dinner_reminder':
        return ' · 저녁 식사 예약 레시피를 요리할 시간이에요.';
      case 'daily_streak_reminder':
        return ' · 오늘 출석하고 캘린더를 확인해보세요.';
      case 'weekly_streak_reminder':
        return ' · 이번 주 출석 기록을 이어가보세요.';
      default:
        return ' · 새 알림이 도착했습니다.';
    }
  }

  Widget _buildTrailing(Map<String, dynamic> n, BuildContext context) {
    final type = (n['type'] ?? '').toString();

    if (type == 'follow') {
      return GestureDetector(
        onTap: () {
          // TODO: follow back
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: _textPrimary,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text(
            '맞팔로우',
            style: TextStyle(
              fontFamily: 'Pretendard',
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
            ),
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildTimeRow(Map<String, dynamic> n) {
    final isRead = n['isRead'] == true;
    final timeText = _formatTimeAgo(n['createdAt']);

    return Row(
      children: [
        Text(
          timeText,
          style: const TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 12,
            color: _textTertiary,
            fontWeight: FontWeight.w400,
            letterSpacing: -0.2,
          ),
        ),
        if (!isRead) ...[
          const SizedBox(width: 6),
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: _unreadDot,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildNotificationTile(Map<String, dynamic> n, BuildContext context) {
    final id = (n['id'] ?? '').toString();
    final isRead = n['isRead'] == true;
    final type = (n['type'] ?? '').toString();
    final action = NotificationService.parseActionFromDoc(n);
    final trailing = _buildTrailing(n, context);
    final hasTrailing = type == 'follow';
    // 실제로 이동할 대상이 있는 알림만 탭 시 화면을 닫고 연결한다.
    final isActionable =
        (action.isFollow && action.actorId.isNotEmpty) ||
        (action.isReviewTarget && action.reviewId.isNotEmpty) ||
        action.isRecipeTarget ||
        action.isStreakCalendarTarget;
        // 모임·챌린지 딥링크: 배포 전까지 비활성.
        // action.isMeetupTarget ||
        // action.isChallengeTarget;

    return Material(
      color: isRead ? Colors.white : const Color(0xFFFFFBF5),
      child: InkWell(
        onTap: () async {
          await NotificationService.instance.markAsRead(id);
          if (!context.mounted) return;
          // 연결 대상이 없으면 화면을 닫지 않고 머문다(읽음 처리만).
          if (!isActionable) return;
          Navigator.pop(context, action);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildAvatar(n),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _buildRichMessage(n)),
                        if (hasTrailing) ...[
                          const SizedBox(width: 12),
                          trailing,
                        ],
                      ],
                    ),
                    const SizedBox(height: 5),
                    _buildTimeRow(n),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEndOfList(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        0,
        32,
        0,
        32 + appSystemNavBottomInset(context),
      ),
      child: Column(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFE5E7EB), width: 1),
            ),
            child: const Icon(
              Icons.access_time_rounded,
              size: 20,
              color: Color(0xFF9CA3AF),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '이전 알림이 없습니다!',
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 13,
              color: _textTertiary,
              fontWeight: FontWeight.w400,
              letterSpacing: -0.2,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = NotificationService.instance;
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: service.myNotificationsStream(),
      builder: (context, snapshot) {
        final items = snapshot.data ?? [];
        final hasUnread = items.any((n) => n['isRead'] != true);
        return Scaffold(
          backgroundColor: Colors.white,
          appBar: AppBar(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0.5,
            centerTitle: true,
            leading: IconButton(
              icon: const Icon(
                Icons.arrow_back_ios_new_rounded,
                size: 20,
                color: _textPrimary,
              ),
              onPressed: () => Navigator.pop(context),
            ),
            title: const Text(
              '알림',
              style: TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: _textPrimary,
                letterSpacing: -0.3,
              ),
            ),
          ),
          body: items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: const Color(0xFFF3F4F6),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0xFFE5E7EB),
                            width: 1,
                          ),
                        ),
                        child: const Icon(
                          Icons.notifications_none_rounded,
                          size: 28,
                          color: Color(0xFF9CA3AF),
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        '알림이 없습니다.',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 14,
                          color: _textSecondary,
                          fontWeight: FontWeight.w400,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: items.length + 2,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Padding(
                        padding: const EdgeInsets.only(
                          left: 20,
                          right: 20,
                          top: 8,
                          bottom: 4,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              '모든 알림',
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: _textPrimary,
                                letterSpacing: -0.3,
                              ),
                            ),
                            if (hasUnread)
                              GestureDetector(
                                onTap: () => service.markAllAsRead(),
                                child: const Text(
                                  '모두 읽음 표시',
                                  style: TextStyle(
                                    fontFamily: 'Pretendard',
                                    fontSize: 13,
                                    fontWeight: FontWeight.w400,
                                    color: _textTertiary,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    }

                    if (index == items.length + 1) {
                      return _buildEndOfList(context);
                    }

                    final n = items[index - 1];
                    return Column(
                      children: [
                        _buildNotificationTile(n, context),
                        if (index < items.length)
                          const Divider(
                            height: 1,
                            thickness: 0.5,
                            color: _dividerColor,
                            indent: 76,
                            endIndent: 20,
                          ),
                      ],
                    );
                  },
                ),
        );
      },
    );
  }
}
