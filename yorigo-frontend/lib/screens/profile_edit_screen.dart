import 'dart:io';
import 'package:flutter/material.dart';
import '../widgets/app_toast.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import '../theme/app_colors.dart';
import '../services/user_service.dart';
import '../widgets/app_media_query_merge_nav_insets.dart';
import '../widgets/default_profile_avatar.dart';

/// Figma-style profile edit screen (node 274-800).
/// Shows 닉네임 + 아이디 in "기본 정보" card. No 체형 및 목표 설정.
/// 완료 saves; back discards unsaved changes.
class ProfileEditScreen extends StatefulWidget {
  final User user;
  final VoidCallback? onSaved;

  const ProfileEditScreen({super.key, required this.user, this.onSaved});

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  final UserService _userService = UserService();
  final ImagePicker _imagePicker = ImagePicker();

  late TextEditingController _nameController;
  late TextEditingController _handleController;

  String? _photoUrl;
  File? _selectedImage;
  bool _isUploading = false;
  bool _isLoading = true;

  // Figma tokens
  static const Color _bgColor = Color(0xFFF9FAFB);
  static const Color _cardBg = Colors.white;
  static const Color _textPrimary = Color(0xFF111111);
  static const Color _textMuted = Color(0xFF6B7280);
  static const Color _profileBorderColor = Color(0xFFFFF0E6);

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _handleController = TextEditingController();
    _loadUserData();
  }

  Future<void> _loadUserData() async {
    final doc = await _userService.getUserDocument(widget.user.uid);
    final data = doc.data() as Map<String, dynamic>?;
    if (mounted) {
      setState(() {
        _photoUrl =
            (data != null ? resolveUserPhotoUrl(data) : null) ??
            widget.user.photoURL;
        _nameController.text = widget.user.displayName ?? data?['name'] ?? '';
        _handleController.text = data?['handle'] ?? '';
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _handleController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    if (_isUploading) return;
    final image = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 800,
      maxHeight: 800,
    );
    if (image != null && mounted) {
      setState(() => _selectedImage = File(image.path));
    }
  }

  Future<void> _saveAndPop() async {
    if (_isUploading) return;

    var newHandle = _handleController.text.trim().toLowerCase();
    if (newHandle.startsWith('@') && newHandle.length > 1) {
      newHandle = newHandle.substring(1);
    }

    if (newHandle.isNotEmpty) {
      if (newHandle.length < 3 || newHandle.length > 24) {
        if (mounted) {
          showAppSnackBar(context, 
            const SnackBar(
              content: Text('아이디는 3-24자 사이여야 합니다'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
      if (!RegExp(r'^[a-z0-9_]+$').hasMatch(newHandle)) {
        if (mounted) {
          showAppSnackBar(context, 
            const SnackBar(
              content: Text('아이디는 영문, 숫자, 언더스코어(_)만 사용할 수 있습니다'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
      final isAvailable = await _userService.isHandleAvailable(
        newHandle,
        exceptUserId: widget.user.uid,
      );
      if (!isAvailable) {
        if (mounted) {
          showAppSnackBar(context, 
            const SnackBar(
              content: Text('이미 사용 중인 아이디입니다'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
    }

    setState(() => _isUploading = true);

    try {
      String? newPhotoUrl = _photoUrl;
      if (_selectedImage != null) {
        newPhotoUrl = await _uploadProfileImage(
          widget.user.uid,
          _selectedImage!,
          oldPhotoUrl: _photoUrl,
        );
      }

      final newName = _nameController.text.trim();
      await _userService.updateUserProfile(
        uid: widget.user.uid,
        name: newName.isNotEmpty ? newName : null,
        handle: newHandle.isNotEmpty ? newHandle : null,
        photoUrl: newPhotoUrl,
      );

      if (newName.isNotEmpty && newName != widget.user.displayName) {
        await widget.user.updateDisplayName(newName);
        await widget.user.reload();
      }

      widget.onSaved?.call();

      if (mounted) {
        Navigator.of(context).pop(true);
        showAppSnackBar(context, 
          const SnackBar(
            content: Text('프로필이 업데이트되었습니다'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 
          SnackBar(content: Text('오류: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<String> _uploadProfileImage(
    String uid,
    File imageFile, {
    String? oldPhotoUrl,
  }) async {
    final storageRef = FirebaseStorage.instance
        .ref()
        .child('profile_images')
        .child('$uid.jpg');
    await storageRef.putFile(imageFile);
    final downloadUrl = await storageRef.getDownloadURL();

    if (oldPhotoUrl != null &&
        oldPhotoUrl.isNotEmpty &&
        oldPhotoUrl != downloadUrl) {
      try {
        final oldRef = FirebaseStorage.instance.refFromURL(oldPhotoUrl);
        await oldRef.delete();
      } catch (_) {}
    }
    return downloadUrl;
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;

    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        backgroundColor: _cardBg,
        elevation: 0,
        titleSpacing: 0,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back,
            color: AppColors.getTextPrimary(brightness),
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        centerTitle: false,
        title: Text(
          '프로필 편집',
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: _textPrimary,
          ),
        ),
        actions: [
          if (_isUploading)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.primary,
                  ),
                ),
              ),
            )
          else
            TextButton(
              onPressed: _saveAndPop,
              child: Text(
                '완료',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                ),
              ),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            )
          : SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                20,
                0,
                20,
                24 + appSystemNavBottomInset(context),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: 24),
                  _buildProfilePicture(brightness),
                  const SizedBox(height: 8),
                  Text(
                    '사진을 변경하려면 탭하세요',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: _textMuted,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 28),
                  _buildBasicInfoCard(brightness),
                  const SizedBox(height: 24),
                ],
              ),
            ),
    );
  }

  Widget _buildProfilePicture(Brightness brightness) {
    return GestureDetector(
      onTap: _pickImage,
      child: SizedBox(
        width: 100,
        height: 100,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: _profileBorderColor, width: 3),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.06),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipOval(
                child: _selectedImage != null
                    ? Image.file(_selectedImage!, fit: BoxFit.cover)
                    : (_photoUrl != null && _photoUrl!.isNotEmpty)
                    ? Image.network(
                        _photoUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => DefaultProfileAvatar(
                          size: 100,
                          seed: widget.user.uid,
                          name: _nameController.text.trim().isNotEmpty
                              ? _nameController.text.trim()
                              : (_handleController.text.trim().isNotEmpty
                                    ? _handleController.text.trim()
                                    : '나'),
                        ),
                      )
                    : DefaultProfileAvatar(
                        size: 100,
                        seed: widget.user.uid,
                        name: _nameController.text.trim().isNotEmpty
                            ? _nameController.text.trim()
                            : (_handleController.text.trim().isNotEmpty
                                  ? _handleController.text.trim()
                                  : '나'),
                      ),
              ),
            ),
            Positioned(
              bottom: -2,
              right: -2,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: const BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.camera_alt,
                  size: 18,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBasicInfoCard(Brightness brightness) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFF3F4F6), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildLabel('닉네임'),
          const SizedBox(height: 10),
          _buildTextField(controller: _nameController, hintText: '닉네임을 입력해주세요'),
          const SizedBox(height: 22),
          _buildLabel('아이디'),
          const SizedBox(height: 10),
          _buildTextField(
            controller: _handleController,
            hintText: 'cute_potato427',
            prefixText: '@',
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 12, color: _textMuted),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '영문, 숫자, 밑줄(_)만 사용하여 3자 이상 입력해주세요',
                  style: TextStyle(
                    fontFamily: 'Pretendard',
                    fontSize: 11.5,
                    fontWeight: FontWeight.w400,
                    color: _textMuted,
                    letterSpacing: -0.2,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hintText,
    String? prefixText,
    void Function(String)? onChanged,
  }) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: const TextStyle(
          fontFamily: 'Pretendard',
          color: Color(0xFF9CA3AF),
          fontSize: 15,
          fontWeight: FontWeight.w400,
          letterSpacing: -0.3,
        ),
        prefixText: prefixText,
        prefixStyle: const TextStyle(
          fontFamily: 'Pretendard',
          color: _textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.3,
        ),
        filled: true,
        fillColor: const Color(0xFFF9FAFB),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFFF6B00), width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
      style: const TextStyle(
        fontFamily: 'Pretendard',
        fontSize: 15,
        fontWeight: FontWeight.w500,
        color: _textPrimary,
        letterSpacing: -0.3,
      ),
      onChanged: onChanged,
    );
  }

  Widget _buildLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontFamily: 'Pretendard',
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: _textPrimary,
        letterSpacing: -0.3,
      ),
    );
  }
}
