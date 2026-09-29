import 'package:flutter/material.dart';

const Color kCommunityInk = Color(0xFF191F28);
const Color kCommunityInkSub = Color(0xFF4E5968);
const Color kCommunityMuted = Color(0xFF8B95A1);
const Color kCommunityOrange = Color(0xFFFF6B00);

class CommunitySectionHeader extends StatelessWidget {
  const CommunitySectionHeader({
    super.key,
    required this.title,
    required this.description,
    this.trailing,
  });

  final String title;
  final String description;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    color: kCommunityInk,
                    letterSpacing: -0.45,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  description,
                  style: const TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: kCommunityMuted,
                    letterSpacing: -0.2,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class CommunitySoftChip extends StatelessWidget {
  const CommunitySoftChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF1E6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: Color(0xFFE56A1F),
          letterSpacing: -0.2,
          height: 1.0,
        ),
      ),
    );
  }
}

class CommunityMeetupCard extends StatelessWidget {
  const CommunityMeetupCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.meta,
    required this.tag,
    required this.trailing,
    required this.icon,
    this.cancelled = false,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final String meta;
  final String tag;
  final String trailing;
  final IconData icon;
  final bool cancelled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFEDEFF3), width: 0.8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFFF7F8FA), Color(0xFFEFF1F4)],
                ),
                border: Border.all(color: const Color(0xFFEDEFF3), width: 0.8),
              ),
              child: Icon(icon, size: 26, color: const Color(0xFFA0A8B3)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    cancelled ? '$title (취소됨)' : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 15.5,
                      fontWeight: FontWeight.w800,
                      color: kCommunityInk,
                      letterSpacing: -0.35,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: kCommunityInkSub,
                      letterSpacing: -0.2,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: kCommunityMuted,
                      letterSpacing: -0.15,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      CommunitySoftChip(label: tag),
                      const SizedBox(width: 8),
                      Text(
                        trailing,
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: kCommunityInkSub,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CommunityChallengeCard extends StatelessWidget {
  const CommunityChallengeCard({
    super.key,
    required this.tag,
    required this.title,
    required this.subtitle,
    this.progress,
    this.progressLabel,
    this.progressGoal,
    this.onTap,
  });

  final String tag;
  final String title;
  final String subtitle;
  final double? progress;
  final String? progressLabel;
  final String? progressGoal;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final showProgress =
        progress != null && progressLabel != null && progressGoal != null;
    final percent = showProgress ? (progress! * 100).clamp(0, 100).round() : 0;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFEDEFF3), width: 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CommunitySoftChip(label: tag),
            const SizedBox(height: 14),
            Text(
              title,
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: kCommunityInk,
                letterSpacing: -0.4,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                color: kCommunityInkSub,
                letterSpacing: -0.25,
                height: 1.4,
              ),
            ),
            if (showProgress) ...[
              const SizedBox(height: 18),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 6,
                  backgroundColor: const Color(0xFFF1F3F5),
                  color: kCommunityOrange,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    '$percent%',
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: kCommunityOrange,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '$progressLabel · $progressGoal',
                    style: const TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: kCommunityMuted,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class CommunityEmptyState extends StatelessWidget {
  const CommunityEmptyState({
    super.key,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        children: [
          Text(
            message,
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: kCommunityMuted,
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 12),
            TextButton(
              onPressed: onAction,
              child: Text(
                actionLabel!,
                style: const TextStyle(
                  fontFamily: 'Pretendard',
                  fontWeight: FontWeight.w800,
                  color: kCommunityOrange,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
