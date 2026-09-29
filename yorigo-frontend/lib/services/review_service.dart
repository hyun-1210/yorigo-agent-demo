import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'analytics_service.dart';
import 'rewards_service.dart';
import 'user_service.dart';
import '../utils/review_visibility_utils.dart';

/// 커뮤니티 사진 후기 한 페이지.
///
/// [reviews] 는 이미 사진이 있는 문서만. [lastRawDocument] 는 사진 필터
/// 전 원본 쿼리의 마지막 문서라서 다음 `startAfter` 에 그대로 쓴다.
class CommunityReviewsPageResult {
  const CommunityReviewsPageResult({
    required this.reviews,
    required this.lastRawDocument,
    required this.hasMore,
  });

  final List<Map<String, dynamic>> reviews;
  final DocumentSnapshot? lastRawDocument;
  final bool hasMore;
}

class ReviewService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final AnalyticsService _analyticsService = AnalyticsService();
  final UserService _userService = UserService();
  final ImagePicker _imagePicker = ImagePicker();
  final ImageCropper _imageCropper = ImageCropper();

  /// Launch the 1:1 square cropper UI for a picked image.
  ///
  /// Returns a new [XFile] pointing at the cropped result, or `null` if the
  /// user cancels. [webContext] must be provided on Flutter Web so the
  /// cropper can render its dialog.
  Future<XFile?> cropToSquare(XFile source, {BuildContext? webContext}) async {
    try {
      if (kIsWeb && webContext != null) {
        return _cropToSquareInApp(source, webContext);
      }

      final int webCropperSide = _webCropperSide(webContext);
      final CroppedFile? cropped = await _imageCropper.cropImage(
        sourcePath: source.path,
        compressFormat: ImageCompressFormat.jpg,
        compressQuality: 85,
        aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: '후기 사진 편집',
            toolbarColor: Colors.black,
            toolbarWidgetColor: Colors.white,
            backgroundColor: Colors.black,
            activeControlsWidgetColor: Colors.orange,
            initAspectRatio: CropAspectRatioPreset.square,
            lockAspectRatio: true,
            hideBottomControls: true,
            showCropGrid: true,
          ),
          IOSUiSettings(
            title: '후기 사진 편집',
            doneButtonTitle: '완료',
            cancelButtonTitle: '취소',
            aspectRatioLockEnabled: true,
            resetAspectRatioEnabled: false,
            aspectRatioPickerButtonHidden: true,
            rotateButtonsHidden: true,
            rotateClockwiseButtonHidden: true,
          ),
          if (kIsWeb && webContext != null)
            WebUiSettings(
              context: webContext,
              presentStyle: WebPresentStyle.dialog,
              size: CropperSize(width: webCropperSide, height: webCropperSide),
              viewwMode: WebViewMode.mode_3,
              dragMode: WebDragMode.move,
              initialAspectRatio: 1.0,
              zoomable: true,
              zoomOnWheel: true,
              zoomOnTouch: true,
              cropBoxMovable: false,
              cropBoxResizable: false,
              toggleDragModeOnDblclick: false,
              minCropBoxWidth: webCropperSide,
              minCropBoxHeight: webCropperSide,
              minContainerWidth: webCropperSide,
              minContainerHeight: webCropperSide,
              background: false,
              guides: true,
              center: true,
              modal: true,
              barrierColor: Colors.black.withValues(alpha: 0.55),
              translations: const WebTranslations(
                title: '사진 영역 맞추기',
                rotateLeftTooltip: '왼쪽으로 회전',
                rotateRightTooltip: '오른쪽으로 회전',
                cancelButton: '취소',
                cropButton: '적용',
              ),
              themeData: const WebThemeData(
                rotateIconColor: Color(0xFFFF6B00),
              ),
            ),
        ],
      );
      if (cropped == null) return null;
      return XFile(cropped.path);
    } catch (e) {
      print('[ReviewService] Crop failed, using original: $e');
      return source;
    }
  }

  int _webCropperSide(BuildContext? context) {
    if (context == null) return 360;
    final size = MediaQuery.sizeOf(context);
    final widthLimit = size.width - 72;
    final heightLimit = size.height - 300;
    final side = math.min(420.0, math.min(widthLimit, heightLimit));
    return side.clamp(240.0, 420.0).round();
  }

  Future<XFile?> _cropToSquareInApp(XFile source, BuildContext context) async {
    final bytes = await source.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return source;

    final side = _webCropperSide(context).toDouble();
    final croppedBytes = await showDialog<Uint8List?>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      barrierDismissible: false,
      builder: (_) => _YorigoSquareCropDialog(
        imageBytes: bytes,
        sourceWidth: decoded.width,
        sourceHeight: decoded.height,
        viewportSide: side,
      ),
    );

    if (croppedBytes == null) return null;
    return XFile.fromData(
      croppedBytes,
      mimeType: 'image/jpeg',
      name: 'yorigo_review_photo.jpg',
      length: croppedBytes.length,
    );
  }

  /// Pick an image from gallery and force a 1:1 square crop.
  ///
  /// [webContext] is required on Flutter Web for the cropper dialog.
  Future<XFile?> pickImage({BuildContext? webContext}) async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1920,
        maxHeight: 1920,
      );
      if (image == null) return null;
      // Caller is expected to ensure [webContext] is still valid when the
      // cropper is presented (usually right after a user-initiated pick).
      // ignore: use_build_context_synchronously
      return await cropToSquare(image, webContext: webContext);
    } catch (e) {
      print('[ReviewService] Error picking image: $e');
      return null;
    }
  }

  /// Pick up to [maxCount] images from the gallery (multi-select when
  /// supported), then launch the 1:1 cropper UI sequentially for each one.
  ///
  /// Images the user cancels during cropping are skipped. [webContext] is
  /// required on Flutter Web so the cropper can render its dialog.
  Future<List<XFile>> pickImagesFromGallery({
    int maxCount = 3,
    BuildContext? webContext,
  }) async {
    if (maxCount <= 0) return [];
    List<XFile> images;
    try {
      images = await _imagePicker.pickMultiImage(
        imageQuality: 85,
        maxWidth: 1920,
        maxHeight: 1920,
      );
    } catch (e) {
      print(
        '[ReviewService] pickMultiImage failed, falling back to single: $e',
      );
      final XFile? one = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1920,
        maxHeight: 1920,
      );
      images = one == null ? <XFile>[] : <XFile>[one];
    }

    if (images.isEmpty) return <XFile>[];
    if (images.length > maxCount) {
      images = images.sublist(0, maxCount);
    }

    final cropped = <XFile>[];
    for (final x in images) {
      // Caller is expected to ensure [webContext] is still valid while the
      // user goes through the cropper UI per-image.
      // ignore: use_build_context_synchronously
      final result = await cropToSquare(x, webContext: webContext);
      if (result != null) {
        cropped.add(result);
      }
    }
    return cropped;
  }

  /// Get content type from file extension or mime type
  String _getContentType(String filePath, String? mimeType) {
    // First try to get from mimeType if available
    if (mimeType != null && mimeType.startsWith('image/')) {
      return mimeType;
    }

    // Fallback to file extension
    final extension = path.extension(filePath).toLowerCase();
    switch (extension) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.heic':
      case '.heif':
        return 'image/heic';
      default:
        // Default to JPEG if unknown (image_picker usually converts to JPEG)
        return 'image/jpeg';
    }
  }

  /// Get file extension from content type or file path
  String _getFileExtension(String filePath, String contentType) {
    // Try to get from file path first
    final pathExtension = path.extension(filePath).toLowerCase();
    if (pathExtension.isNotEmpty && pathExtension != '.') {
      return pathExtension;
    }

    // Fallback to content type
    switch (contentType.toLowerCase()) {
      case 'image/jpeg':
        return '.jpg';
      case 'image/png':
        return '.png';
      case 'image/gif':
        return '.gif';
      case 'image/webp':
        return '.webp';
      case 'image/heic':
      case 'image/heif':
        return '.heic';
      default:
        return '.jpg'; // Default to JPEG
    }
  }

  /// Upload review photo to Firebase Storage.
  /// Pass either [imageFile] (mobile/desktop) or [imageBytes] (web / in-memory).
  Future<String?> uploadReviewPhoto({
    required String reviewId,
    required int imageIndex,
    File? imageFile,
    Uint8List? imageBytes,
    String? mimeType,

    /// Used for extension / content-type when only bytes are available (e.g. web).
    String? fileNameHint,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User must be logged in to upload photos');
    }
    if (imageFile == null && imageBytes == null) {
      throw Exception('Either imageFile or imageBytes must be provided');
    }

    try {
      final int fileSize = imageFile != null
          ? await imageFile.length()
          : imageBytes!.length;
      const maxSize = 10 * 1024 * 1024; // 10MB

      if (fileSize > maxSize) {
        throw Exception('이미지 크기가 10MB를 초과합니다. 더 작은 이미지를 선택해주세요.');
      }

      final pathForType = imageFile?.path ?? fileNameHint ?? 'upload.jpg';
      final contentType = _getContentType(pathForType, mimeType);
      final fileExtension = _getFileExtension(pathForType, contentType);

      final storagePath =
          'reviews/${user.uid}/${reviewId}_$imageIndex$fileExtension';
      final storageRef = _storage.ref().child(storagePath);

      print(
        '[ReviewService] Uploading photo: path=$storagePath, contentType=$contentType, size=${(fileSize / 1024 / 1024).toStringAsFixed(2)}MB',
      );

      final SettableMetadata metadata = SettableMetadata(
        contentType: contentType,
        customMetadata: {
          'uploadedBy': user.uid,
          'reviewId': reviewId,
          'imageIndex': '$imageIndex',
          if (imageFile != null) 'originalPath': imageFile.path,
        },
      );

      final TaskSnapshot snapshot;
      if (imageBytes != null) {
        snapshot = await storageRef.putData(imageBytes, metadata);
      } else {
        snapshot = await storageRef.putFile(imageFile!, metadata);
      }
      final downloadUrl = await snapshot.ref.getDownloadURL();

      print('[ReviewService] Photo uploaded successfully: $downloadUrl');
      return downloadUrl;
    } catch (e, stackTrace) {
      print('[ReviewService] Error uploading photo: $e');
      print('[ReviewService] Stack trace: $stackTrace');
      if (imageFile != null) {
        print('[ReviewService] File path: ${imageFile.path}');
        print('[ReviewService] File size: ${await imageFile.length()} bytes');
      } else {
        print('[ReviewService] Bytes length: ${imageBytes?.length}');
      }

      // Provide more specific error messages
      if (e.toString().contains('permission') ||
          e.toString().contains('unauthorized')) {
        throw Exception('업로드 권한이 없습니다. 로그인 상태를 확인해주세요.');
      } else if (e.toString().contains('size') ||
          e.toString().contains('too large')) {
        throw Exception('이미지 크기가 너무 큽니다. 10MB 이하의 이미지를 선택해주세요.');
      } else if (e.toString().contains('network') ||
          e.toString().contains('connection')) {
        throw Exception('네트워크 연결을 확인해주세요.');
      }

      rethrow;
    }
  }

  /// Generate a unique review ID
  String generateReviewId() {
    return _firestore.collection('reviews').doc().id;
  }

  /// Submit a review for a recipe
  Future<String> submitReview({
    required String reviewId,
    required String? recipeId,
    required int rating, // 1-5 stars
    /// First image URL (legacy). Ignored if [photoUrls] is non-empty.
    String? photoUrl,

    /// All review images (max typically 3). First item is the primary [photoUrl].
    List<String>? photoUrls,
    String? comment,
    required num servings,
    required String recipeTitle,
    required String creatorUsername,
    required String platform,
    String? thumbnailUrl,
    String? difficultyLabel,
    String? recipeExplanationLabel,
    List<String>? benefitLabels,
    bool isHidden = false,
    String reviewSourceType = 'recipe',
    DateTime? cookedAt,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User must be logged in to submit reviews');
    }

    if (rating < 1 || rating > 5) {
      throw Exception('Rating must be between 1 and 5');
    }

    final List<String> resolvedUrls = photoUrls != null && photoUrls.isNotEmpty
        ? List<String>.from(photoUrls)
        : (photoUrl != null && photoUrl.isNotEmpty
              ? <String>[photoUrl]
              : <String>[]);
    final String? primaryPhoto = resolvedUrls.isNotEmpty
        ? resolvedUrls.first
        : null;

    final cleanedRecipeId = recipeId?.trim() ?? '';
    final cleanedSourceType = reviewSourceType.trim().isEmpty
        ? (cleanedRecipeId.isEmpty ? 'freeform' : 'recipe')
        : reviewSourceType.trim();

    try {
      // Create review document
      final reviewData = {
        'reviewId': reviewId,
        'recipeId': cleanedRecipeId,
        'userId': user.uid,
        'isHidden': isHidden,
        'visibility': isHidden ? 'private' : 'public',
        'reviewSourceType': cleanedSourceType,
        'rating': rating,
        'servings': servings,
        'recipeTitle': recipeTitle,
        'creatorUsername': creatorUsername,
        'platform': platform,
        'thumbnailUrl': thumbnailUrl ?? '',
        'photoUrl': primaryPhoto,
        'photoUrls': resolvedUrls,
        'comment': comment,
        'likeCount': 0, // Initialize like count
        'likedBy': [], // Array of user IDs who liked this review
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'cookedAt': Timestamp.fromDate(
          DateTime(
            (cookedAt ?? DateTime.now()).year,
            (cookedAt ?? DateTime.now()).month,
            (cookedAt ?? DateTime.now()).day,
            12,
          ),
        ),
      };

      final d = difficultyLabel?.trim();
      if (d != null && d.isNotEmpty) {
        reviewData['difficultyLabel'] = d;
      }
      final e = recipeExplanationLabel?.trim();
      if (e != null && e.isNotEmpty) {
        reviewData['recipeExplanationLabel'] = e;
      }
      if (benefitLabels != null && benefitLabels.isNotEmpty) {
        final cleaned = benefitLabels
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        if (cleaned.isNotEmpty) {
          reviewData['benefits'] = cleaned;
          reviewData['benefitLabels'] = cleaned;
        }
      }

      // Save review to Firestore
      print(
        '[ReviewService] Saving review to Firestore: reviewId=$reviewId, recipeId=$recipeId, userId=${user.uid}',
      );
      await _firestore.collection('reviews').doc(reviewId).set(reviewData);
      print('[ReviewService] Review document saved successfully: $reviewId');
      await _userService.recordCookingDay(user.uid);

      // Track per-user review count for aggregate analytics
      await _analyticsService.trackReviewWrittenForUser(user.uid);
      await _analyticsService.trackReviewCreated(
        recipeId: cleanedRecipeId,
        rating: rating,
        platform: platform,
        photoCount: resolvedUrls.length,
      );

      // Update recipe's review statistics
      if (cleanedRecipeId.isNotEmpty) {
        print(
          '[ReviewService] Updating recipe statistics: recipeId=$cleanedRecipeId, rating=$rating',
        );
        await _updateRecipeReviewStats(cleanedRecipeId, rating);
      }

      print('[ReviewService] Review submitted successfully: $reviewId');
      return reviewId;
    } catch (e, stackTrace) {
      print('[ReviewService] Error submitting review: $e');
      print('[ReviewService] Stack trace: $stackTrace');
      print(
        '[ReviewService] Review ID: $reviewId, Recipe ID: $recipeId, User ID: ${user.uid}',
      );
      rethrow;
    }
  }

  /// Update recipe review statistics
  Future<void> _updateRecipeReviewStats(String recipeId, int rating) async {
    try {
      final recipeRef = _firestore.collection('recipes').doc(recipeId);

      // Use transaction to ensure atomic updates
      await _firestore.runTransaction((transaction) async {
        final recipeDoc = await transaction.get(recipeRef);
        if (!recipeDoc.exists) {
          print('[ReviewService] Recipe document does not exist: $recipeId');
          return;
        }

        final data = recipeDoc.data()!;
        final currentReviewCount = (data['reviewCount'] as int?) ?? 0;
        final currentAverageRating = (data['averageRating'] as num?) ?? 0.0;

        // Calculate new average rating
        final totalRating = currentAverageRating * currentReviewCount + rating;
        final newReviewCount = currentReviewCount + 1;
        final newAverageRating = totalRating / newReviewCount;

        transaction.update(recipeRef, {
          'reviewCount': newReviewCount,
          'averageRating': newAverageRating,
          'lastReviewedAt': FieldValue.serverTimestamp(),
        });
      });

      print(
        '[ReviewService] Recipe stats updated successfully: recipeId=$recipeId, rating=$rating',
      );
    } catch (e, stackTrace) {
      // Log detailed error information
      print('[ReviewService] Error updating recipe stats: $e');
      print('[ReviewService] Stack trace: $stackTrace');
      print('[ReviewService] Recipe ID: $recipeId, Rating: $rating');
      // Don't throw - review submission should still succeed even if stats update fails
      // This ensures users can still submit reviews even if there's a permission issue
    }
  }

  /// Get reviews for a recipe by recipe ID.
  ///
  /// Public reviews first. Own hidden/legacy review is fetched only when
  /// the public list does not already include the signed-in user (`limit(1)`).
  Future<List<Map<String, dynamic>>> getRecipeReviews(String recipeId) async {
    final id = recipeId.trim();
    if (id.isEmpty) return [];
    try {
      final uid = _auth.currentUser?.uid;
      final publicSnap = await _firestore
          .collection('reviews')
          .where('recipeId', isEqualTo: id)
          .where('isHidden', isEqualTo: false)
          .limit(50)
          .get();

      final seen = <String>{};
      final list = <Map<String, dynamic>>[];
      var hasOwnPublic = false;
      for (final doc in publicSnap.docs) {
        if (!seen.add(doc.id)) continue;
        final data = <String, dynamic>{'id': doc.id, ...doc.data()};
        if (uid != null && uid.isNotEmpty && data['userId'] == uid) {
          hasOwnPublic = true;
        }
        list.add(data);
      }

      if (uid != null && uid.isNotEmpty && !hasOwnPublic) {
        final ownSnap = await _firestore
            .collection('reviews')
            .where('recipeId', isEqualTo: id)
            .where('userId', isEqualTo: uid)
            .limit(1)
            .get();
        for (final doc in ownSnap.docs) {
          if (!seen.add(doc.id)) continue;
          final data = <String, dynamic>{'id': doc.id, ...doc.data()};
          if (data['isHidden'] == true && data['userId'] != uid) continue;
          list.add(data);
        }
      }

      list.sort(_compareReviewNewestFirst);
      return list;
    } catch (e) {
      print('[ReviewService] Error fetching reviews: $e');
      return [];
    }
  }

  /// Get reviews for multiple recipe IDs with batched whereIn queries.
  ///
  /// Public reviews only. Own hidden reviews live on the viewer's recipeId
  /// and are handled by [getRecipeReviews], not this URL-copy fallback.
  Future<List<Map<String, dynamic>>> getReviewsByRecipeIds(
    List<String> recipeIds,
  ) async {
    final ids = recipeIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (ids.isEmpty) return [];
    try {
      final allDocs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      for (var i = 0; i < ids.length; i += 10) {
        final chunk = ids.sublist(i, math.min(i + 10, ids.length));
        final snap = await _firestore
            .collection('reviews')
            .where('recipeId', whereIn: chunk)
            .where('isHidden', isEqualTo: false)
            .limit(200)
            .get();
        allDocs.addAll(snap.docs);
      }

      final seen = <String>{};
      final list = <Map<String, dynamic>>[];
      for (final doc in allDocs) {
        if (!seen.add(doc.id)) continue;
        list.add({'id': doc.id, ...doc.data()});
      }
      list.sort(_compareReviewNewestFirst);
      return list;
    } catch (e) {
      print('[ReviewService] Error fetching reviews by recipe IDs: $e');
      return [];
    }
  }

  /// Get reviews for a recipe by title (fallback when recipeId/sourceUrl don't match)
  Future<List<Map<String, dynamic>>> getReviewsByRecipeTitle(
    String recipeTitle,
  ) async {
    if (recipeTitle.isEmpty) return [];
    try {
      final querySnapshot = await _firestore
          .collection('reviews')
          .where('recipeTitle', isEqualTo: recipeTitle)
          .where('isHidden', isEqualTo: false)
          .limit(50)
          .get();

      final list = querySnapshot.docs
          .map((doc) => {'id': doc.id, ...doc.data()})
          .toList();
      list.sort((a, b) {
        final aTs = a['createdAt'];
        final bTs = b['createdAt'];
        if (aTs == null && bTs == null) return 0;
        if (aTs == null) return 1;
        if (bTs == null) return -1;
        final aMs = (aTs is DateTime)
            ? aTs.millisecondsSinceEpoch
            : (aTs as dynamic).millisecondsSinceEpoch as int? ?? 0;
        final bMs = (bTs is DateTime)
            ? bTs.millisecondsSinceEpoch
            : (bTs as dynamic).millisecondsSinceEpoch as int? ?? 0;
        return bMs.compareTo(aMs);
      });
      return list;
    } catch (e) {
      print('[ReviewService] Error fetching reviews by title: $e');
      return [];
    }
  }

  /// Get user's reviews
  Future<List<Map<String, dynamic>>> getUserReviews([String? userId]) async {
    final targetUserId = userId ?? _auth.currentUser?.uid;
    if (targetUserId == null) {
      return [];
    }

    final currentUid = _auth.currentUser?.uid;
    final isViewingOwn = currentUid != null && currentUid == targetUserId;

    try {
      Query<Map<String, dynamic>> query = _firestore
          .collection('reviews')
          .where('userId', isEqualTo: targetUserId);
      // Firestore rules: non-owner reads must filter isHidden==false
      // explicitly, otherwise the list query is rejected wholesale.
      if (!isViewingOwn) {
        query = query.where('isHidden', isEqualTo: false);
      }

      QuerySnapshot<Map<String, dynamic>> querySnapshot;
      try {
        querySnapshot =
            await query.orderBy('createdAt', descending: true).get();
      } catch (e) {
        // Missing composite index (userId[+isHidden]+createdAt) → empty UI.
        // Fall back to unordered fetch + in-memory newest-first.
        print(
          '[ReviewService] User reviews orderBy failed, sorting in memory: $e',
        );
        querySnapshot = await query.get();
      }

      final reviews = querySnapshot.docs
          .map((doc) => {'id': doc.id, ...doc.data()})
          .toList();
      reviews.sort((a, b) {
        final dateA = _reviewCreatedAt(a['createdAt']);
        final dateB = _reviewCreatedAt(b['createdAt']);
        if (dateA == null && dateB == null) return 0;
        if (dateA == null) return 1;
        if (dateB == null) return -1;
        return dateB.compareTo(dateA);
      });
      return reviews;
    } catch (e) {
      print('[ReviewService] Error fetching user reviews: $e');
      return [];
    }
  }

  /// 최근 요리 기록 [limit]개. 챌린지 인증 피커용.
  Future<List<Map<String, dynamic>>> getRecentUserReviews({int limit = 20}) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return [];
    try {
      final snap = await _firestore
          .collection('reviews')
          .where('userId', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .get();
      return snap.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList();
    } catch (e) {
      print('[ReviewService] Error fetching recent user reviews: $e');
      return [];
    }
  }

  /// Get a user's reviews using multiple identifiers as fallback.
  ///
  /// Legacy/inconsistent data may store the author by:
  /// - `userId` matching the Firebase Auth uid (current convention)
  /// - `userId` matching the `users/{docId}` value, which can differ from
  ///   the doc's internal `uid` field
  /// - `creatorUsername` matching the user's handle (with or without `@`)
  ///
  /// Firestore security rules for `/reviews` require the query to filter
  /// `isHidden == false` for non-owner reads, otherwise the entire list
  /// query is rejected. We add that filter here so other users' profiles
  /// actually return data.
  ///
  /// Pass [includeHidden] `true` for the owner's own diary so 「나만 보기」
  /// (`isHidden == true`) cooking records appear. Also auto-enables when
  /// [userIds] contains the signed-in uid (same contract as [getUserReviews]).
  Future<List<Map<String, dynamic>>> getUserReviewsByAnyIdentifier({
    required List<String> userIds,
    String? handle,
    bool includeHidden = false,
  }) async {
    final ids = userIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    final seen = <String>{};
    final merged = <Map<String, dynamic>>[];

    final currentUid = _auth.currentUser?.uid;
    final effectiveIncludeHidden = shouldIncludeHiddenUserReviews(
      includeHiddenFlag: includeHidden,
      currentUserId: currentUid,
      queriedUserIds: ids,
    );

    Query<Map<String, dynamic>> base = _firestore.collection('reviews');
    if (!effectiveIncludeHidden) {
      base = base.where('isHidden', isEqualTo: false);
    }

    Future<void> runQuery(
      Query<Map<String, dynamic>> query,
      String label,
    ) async {
      try {
        final snap = await query.get();
        print(
          '[ReviewService] getUserReviewsByAnyIdentifier($label) -> ${snap.docs.length} docs',
        );
        for (final doc in snap.docs) {
          if (!seen.add(doc.id)) continue;
          merged.add({'id': doc.id, ...doc.data()});
        }
      } catch (e) {
        print('[ReviewService] Query failed ($label): $e');
      }
    }

    final pending = <Future<void>>[
      for (final id in ids)
        runQuery(base.where('userId', isEqualTo: id), 'userId=$id'),
    ];

    final trimmedHandle = handle?.trim() ?? '';
    if (trimmedHandle.isNotEmpty) {
      final withAt = trimmedHandle.startsWith('@')
          ? trimmedHandle
          : '@$trimmedHandle';
      final withoutAt = trimmedHandle.startsWith('@')
          ? trimmedHandle.substring(1)
          : trimmedHandle;
      for (final variant in {withAt, withoutAt}) {
        if (variant.isEmpty) continue;
        pending.add(
          runQuery(
            base.where('creatorUsername', isEqualTo: variant),
            'creatorUsername=$variant',
          ),
        );
      }
    }

    if (pending.isNotEmpty) {
      await Future.wait(pending);
    }

    merged.sort((a, b) {
      final aTs = a['createdAt'];
      final bTs = b['createdAt'];
      if (aTs == null && bTs == null) return 0;
      if (aTs == null) return 1;
      if (bTs == null) return -1;
      final aMs = (aTs is Timestamp)
          ? aTs.millisecondsSinceEpoch
          : (aTs is DateTime)
          ? aTs.millisecondsSinceEpoch
          : 0;
      final bMs = (bTs is Timestamp)
          ? bTs.millisecondsSinceEpoch
          : (bTs is DateTime)
          ? bTs.millisecondsSinceEpoch
          : 0;
      return bMs.compareTo(aMs);
    });
    return merged;
  }

  /// Toggle like on a review
  Future<bool> toggleLike(String reviewId) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User must be logged in to like reviews');
    }

    try {
      final reviewRef = _firestore.collection('reviews').doc(reviewId);

      String? recipeId;
      String? authorId;
      final liked = await _firestore.runTransaction<bool>((transaction) async {
        final reviewDoc = await transaction.get(reviewRef);
        if (!reviewDoc.exists) {
          throw Exception('Review not found');
        }

        final data = reviewDoc.data()!;
        recipeId = data['recipeId']?.toString();
        authorId = data['userId']?.toString();
        final likedBy = List<String>.from(data['likedBy'] as List? ?? []);
        final currentLikeCount = (data['likeCount'] as num?)?.toInt() ?? 0;
        final isLiked = likedBy.contains(user.uid);

        if (isLiked) {
          // Unlike: remove user from likedBy and decrement count
          likedBy.remove(user.uid);
          transaction.update(reviewRef, {
            'likedBy': likedBy,
            'likeCount': currentLikeCount - 1,
            'updatedAt': FieldValue.serverTimestamp(),
          });
          return false;
        } else {
          // Like: add user to likedBy and increment count
          likedBy.add(user.uid);
          transaction.update(reviewRef, {
            'likedBy': likedBy,
            'likeCount': currentLikeCount + 1,
            'updatedAt': FieldValue.serverTimestamp(),
          });
          return true;
        }
      });
      try {
        await _analyticsService.trackContentLiked(
          contentType: 'review',
          contentId: reviewId,
          liked: liked,
          recipeId: recipeId,
          authorId: authorId,
        );
      } catch (e) {
        print('[ReviewService] Error tracking review like: $e');
      }
      if (liked) {
        unawaited(
          RewardsService.instance.claimLikeExp(
            contentId: reviewId,
            authorId: authorId,
          ),
        );
      }
      return liked;
    } catch (e) {
      print('[ReviewService] Error toggling like: $e');
      rethrow;
    }
  }

  /// Check if current user has liked a review
  bool isLiked(Map<String, dynamic> review) {
    final user = _auth.currentUser;
    if (user == null) return false;

    final likedBy = List<String>.from(review['likedBy'] as List? ?? []);
    return likedBy.contains(user.uid);
  }

  DateTime? _reviewCreatedAt(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    if (value is int) {
      // Heuristic: seconds vs milliseconds.
      final ms = value < 100000000000 ? value * 1000 : value;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    return null;
  }

  String _extractPrimaryPhotoUrl(Map<String, dynamic> review) {
    final direct = (review['photoUrl'] as String?)?.trim();
    if (direct != null && direct.isNotEmpty) return direct;

    final legacy = (review['photo_url'] as String?)?.trim();
    if (legacy != null && legacy.isNotEmpty) return legacy;

    final urlsRaw = review['photoUrls'];
    if (urlsRaw is List) {
      for (final u in urlsRaw) {
        final s = u?.toString().trim() ?? '';
        if (s.isNotEmpty) return s;
      }
    }
    return '';
  }

  Map<String, dynamic>? _mapCommunityPhotoReview(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final review = <String, dynamic>{'id': doc.id, ...doc.data()};
    final photoUrl = _extractPrimaryPhotoUrl(review);
    if (photoUrl.isEmpty) return null;
    review['photoUrl'] = photoUrl;
    return review;
  }

  int _compareReviewNewestFirst(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    final dateA = _reviewCreatedAt(a['createdAt']);
    final dateB = _reviewCreatedAt(b['createdAt']);
    if (dateA == null && dateB == null) return 0;
    if (dateA == null) return 1;
    if (dateB == null) return -1;
    return dateB.compareTo(dateA);
  }

  /// 최신순으로 원본 후기를 읽고, 사진 후기가 [photoTarget] 개가 될 때까지
  /// 같은 커서로 이어 붙인다. 이미 읽은 배치의 사진 후기는 버리지 않는다.
  Future<CommunityReviewsPageResult> fetchCommunityReviewsPage({
    DocumentSnapshot? startAfter,
    int photoTarget = 10,
    int rawBatchSize = 30,
    int maxRawReads = 90,
    bool includeHiddenForAdmin = false,
  }) async {
    final target = photoTarget.clamp(1, 200);
    final batchSize = rawBatchSize.clamp(1, 100);
    final maxReads = maxRawReads.clamp(batchSize, 300);

    Query<Map<String, dynamic>> base = _firestore.collection('reviews');
    if (!includeHiddenForAdmin) {
      base = base.where('isHidden', isEqualTo: false);
    }

    DocumentSnapshot? cursor = startAfter;
    final collected = <Map<String, dynamic>>[];
    var rawReads = 0;
    var hasMore = true;
    var useOrderBy = true;

    try {
      while (collected.length < target && rawReads < maxReads && hasMore) {
        final limit = math.min(batchSize, maxReads - rawReads);
        Query<Map<String, dynamic>> query = base;
        if (useOrderBy) {
          query = query.orderBy('createdAt', descending: true);
        }
        if (cursor != null) {
          query = query.startAfterDocument(cursor);
        }
        query = query.limit(limit);

        QuerySnapshot<Map<String, dynamic>> snap;
        try {
          snap = await query.get();
        } catch (e) {
          if (useOrderBy && cursor == null) {
            print(
              '[ReviewService] Community reviews orderBy failed, '
              'falling back to unordered fetch: $e',
            );
            useOrderBy = false;
            continue;
          }
          rethrow;
        }

        if (snap.docs.isEmpty) {
          hasMore = false;
          break;
        }

        cursor = snap.docs.last;
        rawReads += snap.docs.length;
        for (final doc in snap.docs) {
          final mapped = _mapCommunityPhotoReview(doc);
          if (mapped != null) collected.add(mapped);
        }
        if (snap.docs.length < limit) {
          hasMore = false;
        }
        if (!useOrderBy) {
          collected.sort(_compareReviewNewestFirst);
          hasMore = false;
          break;
        }
      }

      return CommunityReviewsPageResult(
        reviews: collected,
        lastRawDocument: cursor,
        hasMore: hasMore,
      );
    } catch (e) {
      print('[ReviewService] Error fetching community reviews page: $e');
      return const CommunityReviewsPageResult(
        reviews: [],
        lastRawDocument: null,
        hasMore: false,
      );
    }
  }

  /// Get all reviews with photos for community feed
  /// Returns photo reviews sorted by createdAt descending (newest first).
  Future<List<Map<String, dynamic>>> getCommunityReviews({
    bool includeHiddenForAdmin = false,
  }) async {
    try {
      final all = <Map<String, dynamic>>[];
      DocumentSnapshot? cursor;
      var hasMore = true;
      var pages = 0;
      while (hasMore && all.length < 500 && pages < 8) {
        final page = await fetchCommunityReviewsPage(
          startAfter: cursor,
          photoTarget: math.min(80, 500 - all.length),
          rawBatchSize: 80,
          maxRawReads: 80,
          includeHiddenForAdmin: includeHiddenForAdmin,
        );
        if (page.reviews.isEmpty) break;
        all.addAll(page.reviews);
        cursor = page.lastRawDocument;
        hasMore = page.hasMore;
        pages++;
      }
      return all.length <= 500 ? all : all.sublist(0, 500);
    } catch (e) {
      print('[ReviewService] Error fetching community reviews: $e');
      return [];
    }
  }

  // ========== Comment CRUD Methods ==========

  /// Generate a unique comment ID
  String generateCommentId() {
    return _firestore
        .collection('reviews')
        .doc()
        .collection('comments')
        .doc()
        .id;
  }

  /// Create a comment on a review
  Future<String> createComment({
    required String reviewId,
    required String text,
    String? parentCommentId,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User must be logged in to create comments');
    }

    // Validate text
    final trimmedText = text.trim();
    if (trimmedText.isEmpty) {
      throw Exception('Comment text cannot be empty');
    }
    if (trimmedText.length > 1000) {
      throw Exception('Comment text cannot exceed 1000 characters');
    }

    try {
      final commentId = _firestore
          .collection('reviews')
          .doc(reviewId)
          .collection('comments')
          .doc()
          .id;

      String userName = user.displayName?.trim() ?? '';
      String handle = '';
      String photoUrl = '';
      try {
        final userDoc = await _userService.getUserDocument(user.uid);
        final userData = userDoc.data() as Map<String, dynamic>?;
        if (userData != null) {
          final named = (userData['name'] as String?)?.trim() ?? '';
          if (named.isNotEmpty) userName = named;
          handle = (userData['handle'] as String?)?.trim() ?? '';
          photoUrl = resolveUserPhotoUrl(userData) ?? '';
        }
      } catch (e) {
        print('[ReviewService] Error reading comment author profile: $e');
      }

      final commentData = {
        'commentId': commentId,
        'userId': user.uid,
        'userName': userName,
        'handle': handle,
        'userPhotoUrl': photoUrl,
        'isHidden': false,
        'parentCommentId': (parentCommentId ?? '').trim().isEmpty
            ? null
            : parentCommentId!.trim(),
        'text': trimmedText,
        'likeCount': 0,
        'likedBy': <String>[],
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      // Create comment document
      await _firestore
          .collection('reviews')
          .doc(reviewId)
          .collection('comments')
          .doc(commentId)
          .set(commentData);

      // Update review's comment count
      await _updateReviewCommentCount(reviewId, 1);

      print('[ReviewService] Comment created successfully: $commentId');
      unawaited(_trackReviewCommentCreated(reviewId, commentId));
      unawaited(
        RewardsService.instance.claimCommentExp(
          commentId: commentId,
          sourceRef: reviewId,
          textLength: trimmedText.length,
        ),
      );
      return commentId;
    } catch (e) {
      print('[ReviewService] Error creating comment: $e');
      rethrow;
    }
  }

  Future<void> _trackReviewCommentCreated(
    String reviewId,
    String commentId,
  ) async {
    String? recipeId;
    try {
      final reviewSnap = await _firestore.collection('reviews').doc(reviewId).get();
      recipeId = reviewSnap.data()?['recipeId']?.toString();
    } catch (e) {
      print('[ReviewService] Error reading recipeId for comment analytics: $e');
    }
    try {
      await _analyticsService.trackContentCreated(
        contentType: 'review_comment',
        contentId: commentId,
        parentId: reviewId,
        recipeId: recipeId,
      );
    } catch (e) {
      print('[ReviewService] Error tracking comment creation: $e');
    }
  }

  /// Get comments stream for a review (real-time updates)
  Stream<List<Map<String, dynamic>>> getCommentsStream(
    String reviewId, {
    int limit = 50,
    bool includeHiddenForAdmin = false,
  }) {
    try {
      Query<Map<String, dynamic>> query = _firestore
          .collection('reviews')
          .doc(reviewId)
          .collection('comments');

      if (!includeHiddenForAdmin) {
        query = query.where('isHidden', isEqualTo: false);
      }

      return query
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .snapshots()
          .map((snapshot) {
            return snapshot.docs
                .map((doc) => {'id': doc.id, ...doc.data()})
                .toList();
          });
    } catch (e) {
      print('[ReviewService] Error getting comments stream: $e');
      return Stream.value([]);
    }
  }

  /// Get comments for a review (Future version with pagination)
  Future<List<Map<String, dynamic>>> getComments(
    String reviewId, {
    int limit = 50,
    DocumentSnapshot? startAfter,
    bool includeHiddenForAdmin = false,
  }) async {
    try {
      Query query = _firestore
          .collection('reviews')
          .doc(reviewId)
          .collection('comments');

      if (!includeHiddenForAdmin) {
        query = query.where('isHidden', isEqualTo: false);
      }

      query = query.orderBy('createdAt', descending: true).limit(limit);

      if (startAfter != null) {
        query = query.startAfterDocument(startAfter);
      }

      final querySnapshot = await query.get();

      return querySnapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>? ?? {};
        return {'id': doc.id, ...data};
      }).toList();
    } catch (e) {
      print('[ReviewService] Error fetching comments: $e');
      return [];
    }
  }

  /// Update a comment
  Future<void> updateComment({
    required String reviewId,
    required String commentId,
    required String newText,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User must be logged in to update comments');
    }

    // Validate text
    final trimmedText = newText.trim();
    if (trimmedText.isEmpty) {
      throw Exception('Comment text cannot be empty');
    }
    if (trimmedText.length > 1000) {
      throw Exception('Comment text cannot exceed 1000 characters');
    }

    try {
      final commentRef = _firestore
          .collection('reviews')
          .doc(reviewId)
          .collection('comments')
          .doc(commentId);

      // Verify ownership and update
      return await _firestore.runTransaction((transaction) async {
        final commentDoc = await transaction.get(commentRef);
        if (!commentDoc.exists) {
          throw Exception('Comment not found');
        }

        final data = commentDoc.data()!;
        if (data['userId'] != user.uid) {
          throw Exception('You can only update your own comments');
        }

        transaction.update(commentRef, {
          'text': trimmedText,
          'updatedAt': FieldValue.serverTimestamp(),
          'isEdited': true,
        });
      });
    } catch (e) {
      print('[ReviewService] Error updating comment: $e');
      rethrow;
    }
  }

  /// Delete a comment
  Future<void> deleteComment({
    required String reviewId,
    required String commentId,
    bool allowAdminOverride = false,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User must be logged in to delete comments');
    }

    try {
      final commentRef = _firestore
          .collection('reviews')
          .doc(reviewId)
          .collection('comments')
          .doc(commentId);

      // Pre-read once so we can stamp `deletedBy` before the delete txn.
      // The onDelete Cloud Function needs this marker to skip self-delete
      // notifications. Final ownership check still runs inside the txn.
      final preSnap = await commentRef.get();
      if (!preSnap.exists) {
        throw Exception('Comment not found');
      }
      final preData = preSnap.data()!;
      final preIsOwner = preData['userId'] == user.uid;
      if (!preIsOwner && !allowAdminOverride) {
        throw Exception('You can only delete your own comments');
      }
      try {
        await commentRef.update({'deletedBy': preIsOwner ? 'self' : 'admin'});
      } catch (e) {
        print(
          '[ReviewService] Error tagging deletedBy on comment before delete: $e',
        );
      }

      // Verify ownership and delete
      await _firestore.runTransaction((transaction) async {
        final commentDoc = await transaction.get(commentRef);
        if (!commentDoc.exists) {
          throw Exception('Comment not found');
        }

        final data = commentDoc.data()!;
        final isOwner = data['userId'] == user.uid;
        if (!isOwner && !allowAdminOverride) {
          throw Exception('You can only delete your own comments');
        }

        transaction.delete(commentRef);
      });

      // Update review's comment count
      await _updateReviewCommentCount(reviewId, -1);
    } catch (e) {
      print('[ReviewService] Error deleting comment: $e');
      rethrow;
    }
  }

  /// Toggle like on a comment
  Future<bool> toggleCommentLike({
    required String reviewId,
    required String commentId,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User must be logged in to like comments');
    }

    try {
      final commentRef = _firestore
          .collection('reviews')
          .doc(reviewId)
          .collection('comments')
          .doc(commentId);

      String? authorId;
      final liked = await _firestore.runTransaction<bool>((transaction) async {
        final commentDoc = await transaction.get(commentRef);
        if (!commentDoc.exists) {
          throw Exception('Comment not found');
        }

        final data = commentDoc.data()!;
        authorId = data['userId']?.toString();
        final likedBy = List<String>.from(data['likedBy'] as List? ?? []);
        final currentLikeCount = (data['likeCount'] as num?)?.toInt() ?? 0;
        final isLiked = likedBy.contains(user.uid);

        if (isLiked) {
          likedBy.remove(user.uid);
          transaction.update(commentRef, {
            'likedBy': likedBy,
            'likeCount': currentLikeCount - 1,
          });
          return false;
        } else {
          likedBy.add(user.uid);
          transaction.update(commentRef, {
            'likedBy': likedBy,
            'likeCount': currentLikeCount + 1,
          });
          return true;
        }
      });
      try {
        await _analyticsService.trackContentLiked(
          contentType: 'comment',
          contentId: commentId,
          liked: liked,
          recipeId: reviewId,
          authorId: authorId,
        );
      } catch (e) {
        print('[ReviewService] Error tracking comment like: $e');
      }
      return liked;
    } catch (e) {
      print('[ReviewService] Error toggling comment like: $e');
      rethrow;
    }
  }

  /// Check if current user has liked a comment
  bool isCommentLiked(Map<String, dynamic> comment) {
    final user = _auth.currentUser;
    if (user == null) return false;

    final likedBy = List<String>.from(comment['likedBy'] as List? ?? []);
    return likedBy.contains(user.uid);
  }

  /// Update review's comment count (helper method)
  Future<void> _updateReviewCommentCount(String reviewId, int delta) async {
    try {
      final reviewRef = _firestore.collection('reviews').doc(reviewId);

      await _firestore.runTransaction((transaction) async {
        final reviewDoc = await transaction.get(reviewRef);
        if (!reviewDoc.exists) {
          return;
        }

        final data = reviewDoc.data()!;
        final currentCommentCount = (data['commentCount'] as int?) ?? 0;
        final newCommentCount = (currentCommentCount + delta)
            .clamp(0, double.infinity)
            .toInt();

        transaction.update(reviewRef, {
          'commentCount': newCommentCount,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });
    } catch (e) {
      print('[ReviewService] Error updating review comment count: $e');
      // Don't throw - comment operation should still succeed
    }
  }

  /// Get comment count for a review
  Future<int> getCommentCount(String reviewId) async {
    try {
      final reviewDoc = await _firestore
          .collection('reviews')
          .doc(reviewId)
          .get();
      if (!reviewDoc.exists) {
        return 0;
      }
      final data = reviewDoc.data()!;
      return (data['commentCount'] as int?) ?? 0;
    } catch (e) {
      print('[ReviewService] Error getting comment count: $e');
      return 0;
    }
  }

  /// Delete a review (only the author can delete their own review)
  Future<void> deleteReview(
    String reviewId, {
    bool allowAdminOverride = false,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('로그인이 필요합니다');
    }

    try {
      final reviewRef = _firestore.collection('reviews').doc(reviewId);
      final reviewDoc = await reviewRef.get();

      if (!reviewDoc.exists) {
        throw Exception('리뷰를 찾을 수 없습니다');
      }

      final data = reviewDoc.data()!;
      final reviewUserId = data['userId'] as String?;

      final isOwner = reviewUserId == user.uid;
      if (!isOwner && !allowAdminOverride) {
        throw Exception('본인의 리뷰만 삭제할 수 있습니다');
      }

      final recipeId = data['recipeId'] as String?;
      final rating = (data['rating'] as num?)?.toInt() ?? 0;
      final photoUrl = data['photoUrl'] as String?;

      // Delete photo from Firebase Storage if exists
      if (photoUrl != null && photoUrl.isNotEmpty) {
        try {
          final photoRef = _storage.refFromURL(photoUrl);
          await photoRef.delete();
          print('[ReviewService] Review photo deleted from Storage');
        } catch (e) {
          print('[ReviewService] Error deleting photo from Storage: $e');
        }
      }

      // Delete all comments in the subcollection
      final commentsSnapshot = await reviewRef.collection('comments').get();
      for (var commentDoc in commentsSnapshot.docs) {
        await commentDoc.reference.delete();
      }
      print('[ReviewService] Deleted ${commentsSnapshot.docs.length} comments');

      // Mark who triggered the delete so the onDelete Cloud Function can
      // skip the "운영팀이 삭제했어요" notification for self-deletes.
      try {
        await reviewRef.update({'deletedBy': isOwner ? 'self' : 'admin'});
      } catch (e) {
        print('[ReviewService] Error tagging deletedBy before delete: $e');
      }

      // Delete the review document
      await reviewRef.delete();
      print('[ReviewService] Review deleted: $reviewId');

      // Update recipe review statistics
      if (recipeId != null && recipeId.isNotEmpty) {
        await _updateRecipeReviewStatsOnDelete(recipeId, rating);
      }
    } catch (e) {
      print('[ReviewService] Error deleting review: $e');
      rethrow;
    }
  }

  /// Fetch a single review document by id (returns null when missing/hidden).
  /// Includes the doc id under the `id` key for parity with list queries.
  Future<Map<String, dynamic>?> getReviewById(String reviewId) async {
    try {
      final doc = await _firestore.collection('reviews').doc(reviewId).get();
      if (!doc.exists) return null;
      final data = doc.data();
      if (data == null) return null;
      return {...data, 'id': doc.id};
    } catch (e) {
      print('[ReviewService] Error fetching review $reviewId: $e');
      return null;
    }
  }

  /// Update an existing review (own review only).
  ///
  /// Editable fields: rating, comment, difficultyLabel, recipeExplanationLabel,
  /// benefitLabels, photoUrls. When [photoUrls] is provided it fully replaces
  /// the existing list; any URL that was previously saved but is no longer in
  /// the new list is best-effort deleted from Firebase Storage. The first URL
  /// in the new list also becomes the primary `photoUrl`. Pass `null` to keep
  /// existing photos as-is. If the rating changes the recipe's averageRating
  /// is recalculated atomically.
  Future<void> updateReview({
    required String reviewId,
    required int rating,
    String? recipeTitle,
    String? comment,
    String? difficultyLabel,
    String? recipeExplanationLabel,
    List<String>? benefitLabels,
    List<String>? photoUrls,
    bool? isHidden,
    DateTime? cookedAt,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('로그인이 필요합니다');
    }
    if (rating < 1 || rating > 5) {
      throw Exception('Rating must be between 1 and 5');
    }

    final reviewRef = _firestore.collection('reviews').doc(reviewId);
    final reviewDoc = await reviewRef.get();
    if (!reviewDoc.exists) {
      throw Exception('리뷰를 찾을 수 없습니다');
    }
    final data = reviewDoc.data()!;
    final reviewUserId = data['userId'] as String?;
    if (reviewUserId != user.uid) {
      throw Exception('본인의 리뷰만 수정할 수 있습니다');
    }

    final oldRating = (data['rating'] as num?)?.toInt() ?? 0;
    final recipeId = data['recipeId'] as String?;

    final Map<String, Object?> update = {
      'rating': rating,
      'comment': comment == null || comment.trim().isEmpty
          ? null
          : comment.trim(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (cookedAt != null) {
      update['cookedAt'] = Timestamp.fromDate(
        DateTime(cookedAt.year, cookedAt.month, cookedAt.day, 12),
      );
    }

    final title = recipeTitle?.trim();
    if (title != null && title.isNotEmpty) {
      update['recipeTitle'] = title;
    }

    if (isHidden != null) {
      update['isHidden'] = isHidden;
      update['visibility'] = isHidden ? 'private' : 'public';
    }

    final d = difficultyLabel?.trim();
    if (d == null || d.isEmpty) {
      update['difficultyLabel'] = FieldValue.delete();
    } else {
      update['difficultyLabel'] = d;
    }

    final e = recipeExplanationLabel?.trim();
    if (e == null || e.isEmpty) {
      update['recipeExplanationLabel'] = FieldValue.delete();
    } else {
      update['recipeExplanationLabel'] = e;
    }

    if (benefitLabels == null) {
      update['benefits'] = FieldValue.delete();
      update['benefitLabels'] = FieldValue.delete();
    } else {
      final cleaned = benefitLabels
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (cleaned.isEmpty) {
        update['benefits'] = FieldValue.delete();
        update['benefitLabels'] = FieldValue.delete();
      } else {
        update['benefits'] = cleaned;
        update['benefitLabels'] = cleaned;
      }
    }

    // Photo replacement: only when caller passes [photoUrls]. Null = no change.
    List<String>? removedPhotoUrls;
    if (photoUrls != null) {
      final cleanedPhotos = photoUrls
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      final oldPhotoUrls = <String>[];
      final rawOld = data['photoUrls'];
      if (rawOld is List) {
        for (final u in rawOld) {
          final s = u?.toString().trim() ?? '';
          if (s.isNotEmpty) oldPhotoUrls.add(s);
        }
      }
      if (oldPhotoUrls.isEmpty) {
        final legacy = (data['photoUrl'] as String?)?.trim() ?? '';
        if (legacy.isNotEmpty) oldPhotoUrls.add(legacy);
      }
      final newSet = cleanedPhotos.toSet();
      removedPhotoUrls = oldPhotoUrls
          .where((u) => !newSet.contains(u))
          .toList();

      update['photoUrls'] = cleanedPhotos;
      update['photoUrl'] = cleanedPhotos.isEmpty ? null : cleanedPhotos.first;
    }

    await reviewRef.update(update);
    print('[ReviewService] Review updated: $reviewId');

    // Best-effort: delete photos that are no longer referenced.
    // Failure here must not bubble up — the doc is already saved.
    if (removedPhotoUrls != null && removedPhotoUrls.isNotEmpty) {
      for (final url in removedPhotoUrls) {
        try {
          await _storage.refFromURL(url).delete();
        } catch (err) {
          print(
            '[ReviewService] Failed to delete removed review photo $url: $err',
          );
        }
      }
    }

    // If the rating changed, recompute the recipe's averageRating atomically
    // (count is unchanged because we're editing, not adding/removing).
    if (recipeId != null && recipeId.isNotEmpty && oldRating != rating) {
      try {
        final recipeRef = _firestore.collection('recipes').doc(recipeId);
        await _firestore.runTransaction((transaction) async {
          final recipeDoc = await transaction.get(recipeRef);
          if (!recipeDoc.exists) return;
          final rData = recipeDoc.data()!;
          final count = (rData['reviewCount'] as int?) ?? 0;
          final currentAvg =
              (rData['averageRating'] as num?)?.toDouble() ?? 0.0;
          if (count <= 0) return;
          final totalRating = currentAvg * count - oldRating + rating;
          final newAvg = totalRating / count;
          transaction.update(recipeRef, {
            'averageRating': newAvg,
            'lastReviewedAt': FieldValue.serverTimestamp(),
          });
        });
      } catch (err) {
        print('[ReviewService] Error recomputing recipe avg after edit: $err');
      }
    }
  }

  /// Admin/moderation: hide/unhide a review.
  ///
  /// Soft-moderation fields:
  /// - `isHidden`
  /// - `hiddenAt`
  /// - `hiddenReason`
  /// - `updatedAt`
  Future<void> setReviewHidden({
    required String reviewId,
    required bool hidden,
    required String reason,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('로그인이 필요합니다');
    }

    final trimmedReason = reason.trim();
    if (trimmedReason.isEmpty) {
      throw Exception('숨김 사유가 필요합니다');
    }

    try {
      final reviewRef = _firestore.collection('reviews').doc(reviewId);

      await _firestore.runTransaction((transaction) async {
        final snapshot = await transaction.get(reviewRef);
        if (!snapshot.exists) {
          throw Exception('리뷰를 찾을 수 없습니다');
        }

        if (hidden) {
          transaction.update(reviewRef, {
            'isHidden': true,
            'hiddenAt': FieldValue.serverTimestamp(),
            'hiddenReason': trimmedReason,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        } else {
          transaction.update(reviewRef, {
            'isHidden': false,
            'hiddenAt': FieldValue.delete(),
            'hiddenReason': FieldValue.delete(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      });
    } catch (e) {
      print('[ReviewService] Error setting review hidden: $e');
      rethrow;
    }
  }

  /// Admin/moderation: hide/unhide a comment on a review.
  Future<void> setCommentHidden({
    required String reviewId,
    required String commentId,
    required bool hidden,
    required String reason,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('로그인이 필요합니다');
    }

    final trimmedReason = reason.trim();
    if (trimmedReason.isEmpty) {
      throw Exception('숨김 사유가 필요합니다');
    }

    try {
      final commentRef = _firestore
          .collection('reviews')
          .doc(reviewId)
          .collection('comments')
          .doc(commentId);

      await _firestore.runTransaction((transaction) async {
        final snapshot = await transaction.get(commentRef);
        if (!snapshot.exists) {
          throw Exception('댓글을 찾을 수 없습니다');
        }

        if (hidden) {
          transaction.update(commentRef, {
            'isHidden': true,
            'hiddenAt': FieldValue.serverTimestamp(),
            'hiddenReason': trimmedReason,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        } else {
          transaction.update(commentRef, {
            'isHidden': false,
            'hiddenAt': FieldValue.delete(),
            'hiddenReason': FieldValue.delete(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      });
    } catch (e) {
      print('[ReviewService] Error setting comment hidden: $e');
      rethrow;
    }
  }

  /// Update recipe review statistics when a review is deleted
  Future<void> _updateRecipeReviewStatsOnDelete(
    String recipeId,
    int rating,
  ) async {
    try {
      final recipeRef = _firestore.collection('recipes').doc(recipeId);

      await _firestore.runTransaction((transaction) async {
        final recipeDoc = await transaction.get(recipeRef);
        if (!recipeDoc.exists) {
          print('[ReviewService] Recipe document does not exist: $recipeId');
          return;
        }

        final data = recipeDoc.data()!;
        final currentReviewCount = (data['reviewCount'] as int?) ?? 0;
        final currentAverageRating = (data['averageRating'] as num?) ?? 0.0;

        if (currentReviewCount <= 1) {
          // Last review being deleted, reset stats
          transaction.update(recipeRef, {
            'reviewCount': 0,
            'averageRating': 0.0,
          });
        } else {
          // Recalculate average rating
          final totalRating =
              currentAverageRating * currentReviewCount - rating;
          final newReviewCount = currentReviewCount - 1;
          final newAverageRating = totalRating / newReviewCount;

          transaction.update(recipeRef, {
            'reviewCount': newReviewCount,
            'averageRating': newAverageRating,
          });
        }
      });

      print(
        '[ReviewService] Recipe stats updated after review deletion: recipeId=$recipeId',
      );
    } catch (e) {
      print('[ReviewService] Error updating recipe stats on delete: $e');
    }
  }
}

class _YorigoSquareCropDialog extends StatefulWidget {
  const _YorigoSquareCropDialog({
    required this.imageBytes,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.viewportSide,
  });

  final Uint8List imageBytes;
  final int sourceWidth;
  final int sourceHeight;
  final double viewportSide;

  @override
  State<_YorigoSquareCropDialog> createState() => _YorigoSquareCropDialogState();
}

class _YorigoSquareCropDialogState extends State<_YorigoSquareCropDialog> {
  final GlobalKey _viewportKey = GlobalKey();
  late final double _coverScale;
  late double _userScale;
  late Offset _offset;
  late double _startScale;
  late Offset _startOffset;
  late Offset _startFocal;
  bool _isCropping = false;

  @override
  void initState() {
    super.initState();
    _coverScale = math.max(
      widget.viewportSide / widget.sourceWidth,
      widget.viewportSide / widget.sourceHeight,
    );
    _userScale = 1;
    _offset = _centerOffsetFor(_userScale);
  }

  Future<void> _crop() async {
    if (_isCropping) return;
    setState(() => _isCropping = true);
    try {
      final decoded = img.decodeImage(widget.imageBytes);
      if (decoded == null) {
        if (mounted) Navigator.of(context).pop<Uint8List?>(null);
        return;
      }

      final displayScale = _coverScale * _userScale;
      final cropSize = widget.viewportSide / displayScale;
      final cropX = (-_offset.dx / displayScale)
          .clamp(0.0, widget.sourceWidth - cropSize);
      final cropY = (-_offset.dy / displayScale)
          .clamp(0.0, widget.sourceHeight - cropSize);
      final cropped = img.copyCrop(
        decoded,
        x: cropX.round(),
        y: cropY.round(),
        width: cropSize.round().clamp(1, widget.sourceWidth),
        height: cropSize.round().clamp(1, widget.sourceHeight),
      );
      final jpg = Uint8List.fromList(img.encodeJpg(cropped, quality: 85));
      if (mounted) Navigator.of(context).pop(jpg);
    } catch (e) {
      if (mounted) setState(() => _isCropping = false);
    }
  }

  Offset _centerOffsetFor(double userScale) {
    final displayWidth = widget.sourceWidth * _coverScale * userScale;
    final displayHeight = widget.sourceHeight * _coverScale * userScale;
    return _constrainOffset(
      Offset(
        (widget.viewportSide - displayWidth) / 2,
        (widget.viewportSide - displayHeight) / 2,
      ),
      userScale,
    );
  }

  Offset _constrainOffset(Offset offset, double userScale) {
    final displayWidth = widget.sourceWidth * _coverScale * userScale;
    final displayHeight = widget.sourceHeight * _coverScale * userScale;
    final minX = widget.viewportSide - displayWidth;
    final minY = widget.viewportSide - displayHeight;
    final dx = displayWidth <= widget.viewportSide
        ? (widget.viewportSide - displayWidth) / 2
        : offset.dx.clamp(minX, 0.0);
    final dy = displayHeight <= widget.viewportSide
        ? (widget.viewportSide - displayHeight) / 2
        : offset.dy.clamp(minY, 0.0);
    return Offset(dx.toDouble(), dy.toDouble());
  }

  void _handleScaleStart(ScaleStartDetails details) {
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    _startFocal = box?.globalToLocal(details.focalPoint) ?? Offset.zero;
    _startScale = _userScale;
    _startOffset = _offset;
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    final focal = box?.globalToLocal(details.focalPoint) ?? _startFocal;
    final nextScale = (_startScale * details.scale).clamp(1.0, 4.0);
    final scaleDelta = nextScale / _startScale;
    final nextOffset =
        focal - ((_startFocal - _startOffset) * scaleDelta);

    setState(() {
      _userScale = nextScale;
      _offset = _constrainOffset(nextOffset, _userScale);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 28,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '사진 영역 맞추기',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF111827),
                              letterSpacing: -0.4,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            '사진을 움직여 보일 영역을 맞춰주세요',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF8B95A1),
                              letterSpacing: -0.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: _isCropping
                          ? null
                          : () => Navigator.of(context).pop(),
                      icon: const Icon(
                        Icons.close_rounded,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: GestureDetector(
                      onScaleStart: _isCropping ? null : _handleScaleStart,
                      onScaleUpdate: _isCropping ? null : _handleScaleUpdate,
                      child: SizedBox(
                        key: _viewportKey,
                        width: widget.viewportSide,
                        height: widget.viewportSide,
                        child: ColoredBox(
                          color: const Color(0xFFF3F4F6),
                          child: ClipRect(
                            child: Stack(
                              children: [
                                Positioned(
                                  left: _offset.dx,
                                  top: _offset.dy,
                                  width: widget.sourceWidth *
                                      _coverScale *
                                      _userScale,
                                  height: widget.sourceHeight *
                                      _coverScale *
                                      _userScale,
                                  child: Image.memory(
                                    widget.imageBytes,
                                    fit: BoxFit.fill,
                                    gaplessPlayback: true,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _isCropping
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: const Text(
                        '취소',
                        style: TextStyle(
                          fontFamily: 'Pretendard',
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF6B7280),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _isCropping ? null : _crop,
                      style: ElevatedButton.styleFrom(
                        elevation: 0,
                        backgroundColor: const Color(0xFFFF6B00),
                        disabledBackgroundColor: const Color(0xFFFFB57A),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 13,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      child: _isCropping
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              '적용',
                              style: TextStyle(
                                fontFamily: 'Pretendard',
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
