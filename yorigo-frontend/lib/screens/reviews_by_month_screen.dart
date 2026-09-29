import 'package:flutter/material.dart';
import '../widgets/app_refresh_indicator.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../theme/app_colors.dart';
import '../widgets/app_network_image.dart';
import '../services/review_service.dart';
import '../widgets/yorigo_header_logo.dart';
import 'review_detail_screen.dart';

class ReviewsByMonthScreen extends StatefulWidget {
  final String? userId; // If null, shows current user's reviews

  const ReviewsByMonthScreen({super.key, this.userId});

  @override
  State<ReviewsByMonthScreen> createState() => _ReviewsByMonthScreenState();
}

class _ReviewsByMonthScreenState extends State<ReviewsByMonthScreen> {
  final ReviewService _reviewService = ReviewService();
  final FirebaseAuth _auth = FirebaseAuth.instance;

  Map<String, List<Map<String, dynamic>>> _reviewsByMonth = {};
  List<Map<String, dynamic>> _allReviews = []; // Flat list for navigation
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadAllReviews();
  }

  Future<void> _loadAllReviews() async {
    // Use widget.userId if provided, otherwise use current user
    final targetUserId = widget.userId ?? _auth.currentUser?.uid;
    if (targetUserId == null) {
      setState(() {
        _isLoading = false;
      });
      return;
    }

    try {
      // Get all user reviews for the target user
      final reviews = await _reviewService.getUserReviews(targetUserId);

      // Group by month
      final Map<String, List<Map<String, dynamic>>> grouped = {};

      for (var review in reviews) {
        final createdAt = (review['createdAt'] as Timestamp?)?.toDate();
        if (createdAt == null) continue;

        final monthKey =
            '${createdAt.year}-${createdAt.month.toString().padLeft(2, '0')}';
        if (!grouped.containsKey(monthKey)) {
          grouped[monthKey] = [];
        }
        grouped[monthKey]!.add(review);
      }

      // Sort reviews within each month by date (most recent first)
      for (var monthKey in grouped.keys) {
        grouped[monthKey]!.sort((a, b) {
          final dateA = (a['createdAt'] as Timestamp?)?.toDate();
          final dateB = (b['createdAt'] as Timestamp?)?.toDate();
          if (dateA == null || dateB == null) return 0;
          return dateB.compareTo(dateA); // Descending (newest first)
        });
      }

      // Sort months by date (most recent first)
      final sortedMonths = grouped.keys.toList()
        ..sort((a, b) => b.compareTo(a)); // Descending (newest first)

      final sortedGrouped = <String, List<Map<String, dynamic>>>{};
      for (var monthKey in sortedMonths) {
        sortedGrouped[monthKey] = grouped[monthKey]!;
      }

      // Create flat list of all reviews sorted by date (newest first) for navigation
      final allReviewsList = <Map<String, dynamic>>[];
      for (var monthKey in sortedMonths) {
        allReviewsList.addAll(grouped[monthKey]!);
      }

      if (mounted) {
        setState(() {
          _reviewsByMonth = sortedGrouped;
          _allReviews = allReviewsList;
          _isLoading = false;
        });
      }
    } catch (e) {
      print('[ReviewsByMonthScreen] Error loading reviews: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  String _formatMonthKey(String monthKey) {
    final parts = monthKey.split('-');
    final year = int.parse(parts[0]);
    final month = int.parse(parts[1]);
    return '$month월 $year';
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
                widget.userId == null ? '내 게시물' : '게시물',
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
            : _reviewsByMonth.isEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.restaurant_menu,
                      size: 64,
                      color: AppColors.getTextTertiary(brightness),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '리뷰가 없습니다',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: AppColors.getTextPrimary(brightness),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '레시피를 완성하고 리뷰를 작성해보세요',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.getTextSecondary(brightness),
                      ),
                    ),
                  ],
                ),
              )
            : AppRefreshIndicator(
                onRefresh: _loadAllReviews,
                child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _reviewsByMonth.length,
                  itemBuilder: (context, index) {
                    final monthKey = _reviewsByMonth.keys.elementAt(index);
                    final reviews = _reviewsByMonth[monthKey]!;
                    return Padding(
                      padding: EdgeInsets.only(
                        bottom: index < _reviewsByMonth.length - 1 ? 32 : 0,
                      ),
                      child: _buildMonthSection(monthKey, reviews, brightness),
                    );
                  },
                ),
              ),
      ),
    );
  }

  Widget _buildMonthSection(
    String monthKey,
    List<Map<String, dynamic>> reviews,
    Brightness brightness,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Month header
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _formatMonthKey(monthKey),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.getTextPrimary(brightness),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${reviews.length}개의 레시피',
                style: TextStyle(
                  fontSize: 14,
                  color: AppColors.getTextSecondary(brightness),
                ),
              ),
            ],
          ),
        ),
        // Reviews grid
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 0.85,
          ),
          itemCount: reviews.length,
          itemBuilder: (context, index) {
            final review = reviews[index];
            // Find index in flat list
            final globalIndex = _allReviews.indexWhere(
              (r) => r['id'] == review['id'],
            );
            return _buildReviewCard(
              review,
              brightness,
              globalIndex >= 0 ? globalIndex : 0,
            );
          },
        ),
      ],
    );
  }

  Widget _buildReviewCard(
    Map<String, dynamic> review,
    Brightness brightness,
    int index,
  ) {
    final photoUrl = review['photoUrl'] as String?;
    final recipeTitle = review['recipeTitle'] as String? ?? '레시피';
    final hasPhoto = photoUrl != null && photoUrl.isNotEmpty;

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ReviewDetailScreen(
              allReviews: _allReviews,
              initialIndex: index,
            ),
          ),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Background image or gradient
              if (hasPhoto)
                AppNetworkImage(
                  imageUrl: photoUrl,
                  fit: BoxFit.cover,
                  // Width-only cap preserves source aspect ratio.
                  memCacheWidth: AppNetworkImage.feedImageCacheSize,
                  errorWidget: _buildGradientBackground(),
                )
              else
                _buildGradientBackground(),

              // Gradient overlay (black at bottom, transparent at top)
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.3),
                      Colors.black.withValues(alpha: 0.7),
                    ],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                ),
              ),

              // Recipe title at bottom left
              Positioned(
                left: 12,
                bottom: 12,
                right: 12,
                child: Text(
                  recipeTitle,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),

              // Fork & knife icon if no photo
              if (!hasPhoto)
                Center(
                  child: Icon(
                    Icons.restaurant_menu,
                    size: 48,
                    color: Colors.white.withValues(alpha: 0.7),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGradientBackground() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.grey.shade200, Colors.grey.shade400],
        ),
      ),
    );
  }
}
