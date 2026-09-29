import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Admin role helper based on Firestore `/admin_emails/{email}`.
///
/// Note: final security must be enforced by `firestore.rules`.
class AdminService {
  AdminService._();
  static final AdminService instance = AdminService._();

  FirebaseFirestore get _firestore => FirebaseFirestore.instance;
  FirebaseAuth get _auth => FirebaseAuth.instance;

  /// Simple in-memory cache to avoid repeated reads per screen.
  String? _cachedUid;
  bool? _cachedIsAdmin;

  /// 현재 로그인 유저에 대한 캐시된 관리자 여부.
  /// 캐시가 없거나 uid가 다르면 null.
  bool? cachedIsAdminForCurrentUser() {
    try {
      final user = _auth.currentUser;
      if (user == null) return null;
      if (_cachedUid != user.uid) return null;
      return _cachedIsAdmin;
    } catch (_) {
      return null;
    }
  }

  Future<bool> isAdmin() async {
    final user = _auth.currentUser;
    if (user == null) return false;

    if (_cachedUid == user.uid && _cachedIsAdmin != null) {
      return _cachedIsAdmin!;
    }

    try {
      final result = await _fetchIsAdmin(user);
      _cachedUid = user.uid;
      _cachedIsAdmin = result;
      return result;
    } catch (_) {
      return false;
    }
  }

  /// Firestore를 다시 조회해 캐시를 갱신한다.
  /// 네트워크 실패 시 기존 캐시 값을 유지한다 (관리자 메뉴가 잠깐 사라지는 것 방지).
  Future<bool> refreshIsAdmin() async {
    final user = _auth.currentUser;
    if (user == null) {
      clearCache();
      return false;
    }

    final previous =
        (_cachedUid == user.uid) ? _cachedIsAdmin : null;

    try {
      final result = await _fetchIsAdmin(user);
      _cachedUid = user.uid;
      _cachedIsAdmin = result;
      return result;
    } catch (_) {
      if (previous != null) {
        _cachedUid = user.uid;
        _cachedIsAdmin = previous;
        return previous;
      }
      return false;
    }
  }

  Future<bool> _fetchIsAdmin(User user) async {
    final email = user.email?.trim().toLowerCase();
    if (email == null || email.isEmpty || user.emailVerified != true) {
      return false;
    }

    final doc = await _firestore.collection('admin_emails').doc(email).get();
    final data = doc.data();
    final isActive = data?['active'] == true;
    return doc.exists && isActive;
  }

  void clearCache() {
    _cachedUid = null;
    _cachedIsAdmin = null;
  }

  /// 테스트용: 캐시 상태를 직접 주입한다.
  void debugSetCache({required String uid, required bool isAdmin}) {
    _cachedUid = uid;
    _cachedIsAdmin = isAdmin;
  }
}
