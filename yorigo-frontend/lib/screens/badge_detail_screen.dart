import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../services/user_service.dart';
import '../widgets/yorigo_header_logo.dart';
import 'package:firebase_auth/firebase_auth.dart';

class BadgeDetailScreen extends StatefulWidget {
  const BadgeDetailScreen({super.key});

  @override
  State<BadgeDetailScreen> createState() => _BadgeDetailScreenState();
}

class _BadgeDetailScreenState extends State<BadgeDetailScreen> {
  final UserService _userService = UserService();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  List<Map<String, dynamic>> _badges = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadBadges();
  }

  Future<void> _loadBadges() async {
    final user = _auth.currentUser;
    if (user == null) {
      setState(() {
        _isLoading = false;
      });
      return;
    }

    try {
      final badges = await _userService.getAvailableBadgesWithProgress(
        user.uid,
      );
      setState(() {
        _badges = badges;
        _isLoading = false;
      });
    } catch (e) {
      print('[BadgeDetailScreen] Error loading badges: $e');
      setState(() {
        _isLoading = false;
      });
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
            const YorigoHeaderLogo(height: 22, maxWidth: 96),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '획득한 배지',
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
      ),
      body: SafeArea(
        child: _isLoading
            ? Center(child: CircularProgressIndicator(color: AppColors.primary))
            : _badges.isEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.emoji_events_outlined,
                      size: 64,
                      color: AppColors.getTextTertiary(brightness),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '배지가 없습니다',
                      style: TextStyle(
                        fontSize: 16,
                        color: AppColors.getTextSecondary(brightness),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '곧 새로운 배지를 추가할 예정입니다',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.getTextTertiary(brightness),
                      ),
                    ),
                  ],
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: _badges.length,
                itemBuilder: (context, index) {
                  final badge = _badges[index];
                  return _buildBadgeCard(badge, brightness);
                },
              ),
      ),
    );
  }

  Widget _buildBadgeCard(Map<String, dynamic> badge, Brightness brightness) {
    // TODO: Implement actual badge display when badge system is ready
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.getBackgroundSecondary(brightness),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.getBorder(brightness), width: 1),
      ),
      child: Row(
        children: [
          // Placeholder badge icon
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.primary, width: 2),
            ),
            child: Icon(Icons.emoji_events, color: AppColors.primary, size: 32),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '배지 이름',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppColors.getTextPrimary(brightness),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '진행률: 0%',
                  style: TextStyle(
                    fontSize: 14,
                    color: AppColors.getTextSecondary(brightness),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
