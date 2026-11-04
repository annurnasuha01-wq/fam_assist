import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'auth_service.dart';
import 'notification_scheduler.dart';

class AccountResult {
  final bool success;
  final String? errorMessage;
  AccountResult({required this.success, this.errorMessage});
}

/// Account management: change password + delete account.
///
/// Both actions first RE-AUTHENTICATE with the current (old) password. Firebase
/// requires a recent login for these sensitive operations, and it also makes
/// sure that someone who just picked up an unlocked phone can't change the
/// password or wipe the account without knowing the password.
class AccountService {
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Collections whose documents carry a `user_id` field of the owner.
  static const List<String> _ownedCollections = [
    'tasks',
    'folders',
    'voice_inputs',
    'nlp_processing',
    'notifications',
  ];

  // ------------------------------------------------------------------
  // Change password
  // ------------------------------------------------------------------
  static Future<AccountResult> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    final user = _auth.currentUser;
    final email = user?.email;
    if (user == null || email == null) {
      return AccountResult(
        success: false,
        errorMessage: 'You are not logged in.',
      );
    }
    if (!AuthService.hasPasswordProvider) {
      return AccountResult(
        success: false,
        errorMessage:
            'This account signs in with Google, so it has no password to change.',
      );
    }

    try {
      final credential = EmailAuthProvider.credential(
        email: email,
        password: oldPassword,
      );
      await user.reauthenticateWithCredential(credential);
      await user.updatePassword(newPassword);
      return AccountResult(success: true);
    } on FirebaseAuthException catch (e) {
      return AccountResult(success: false, errorMessage: _mapError(e.code));
    } catch (_) {
      return AccountResult(
        success: false,
        errorMessage: 'Could not change the password. Please try again.',
      );
    }
  }

  // ------------------------------------------------------------------
  // Delete account
  // ------------------------------------------------------------------
  /// Permanently deletes, in this order:
  ///   1. alarms on this phone
  ///   2. all of the user's tasks, folders, voice inputs, NLP records and
  ///      notification records
  ///   3. the username reservation (usernames/{key}) and profile (users/{uid})
  ///   4. the Firebase Authentication account itself
  /// The Authentication account goes LAST because Firestore rules need the
  /// user to still be signed in to allow the deletes above.
  /// [password] is required for email/password accounts. Google accounts
  /// pass null: they re-authenticate through the Google account picker.
  static Future<AccountResult> deleteAccount({String? password}) async {
    final user = _auth.currentUser;
    final email = user?.email;
    if (user == null || email == null) {
      return AccountResult(
        success: false,
        errorMessage: 'You are not logged in.',
      );
    }
    final uid = user.uid;

    // Step 0: prove it's really the owner.
    try {
      final usePassword =
          AuthService.hasPasswordProvider &&
          password != null &&
          password.isNotEmpty;
      if (usePassword) {
        final credential = EmailAuthProvider.credential(
          email: email,
          password: password,
        );
        await user.reauthenticateWithCredential(credential);
      } else if (AuthService.hasGoogleProvider) {
        final googleSignIn = GoogleSignIn();
        await googleSignIn.signOut();
        final account = await googleSignIn.signIn();
        if (account == null) {
          return AccountResult(
            success: false,
            errorMessage: 'Google verification was cancelled.',
          );
        }
        final auth = await account.authentication;
        await user.reauthenticateWithCredential(
          GoogleAuthProvider.credential(
            accessToken: auth.accessToken,
            idToken: auth.idToken,
          ),
        );
      } else {
        return AccountResult(
          success: false,
          errorMessage: 'Please enter your password.',
        );
      }
    } on FirebaseAuthException catch (e) {
      return AccountResult(success: false, errorMessage: _mapError(e.code));
    } catch (_) {
      return AccountResult(
        success: false,
        errorMessage: 'Could not verify your identity. Please try again.',
      );
    }

    // Steps 1-3: wipe the data.
    try {
      final profile = await _db.collection('users').doc(uid).get();
      // Google accounts never reserved a usernames/{key} doc (their
      // "username" is just their Google display name), so skip it for them.
      // Otherwise the delete would be denied by the Firestore rules and
      // block the whole account deletion.
      final isGoogleProfile = profile.data()?['provider'] == 'google';
      final usernameKey = isGoogleProfile
          ? null
          : (profile.data()?['username'] as String?)?.trim().toLowerCase();

      try {
        await NotificationScheduler.cancelAll();
      } catch (_) {}

      for (final collection in _ownedCollections) {
        await _deleteAllOwnedBy(collection, uid);
      }

      if (usernameKey != null && usernameKey.isNotEmpty) {
        try {
          await _db.collection('usernames').doc(usernameKey).delete();
        } catch (_) {
          // Reservation already gone (or not ours): don't block deletion.
        }
      }
      await _db.collection('users').doc(uid).delete();
    } catch (_) {
      return AccountResult(
        success: false,
        errorMessage:
            'Could not delete your data. Check your internet connection and try again.',
      );
    }

    // Step 4: delete the login itself (one retry for flaky networks).
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await user.delete();
        try {
          await GoogleSignIn().signOut();
        } catch (_) {}
        return AccountResult(success: true);
      } on FirebaseAuthException catch (e) {
        if (attempt == 1 || e.code != 'network-request-failed') {
          return AccountResult(success: false, errorMessage: _mapError(e.code));
        }
      } catch (_) {
        if (attempt == 1) {
          return AccountResult(
            success: false,
            errorMessage: 'Could not delete the account. Please try again.',
          );
        }
      }
    }
    return AccountResult(
      success: false,
      errorMessage: 'Could not delete the account. Please try again.',
    );
  }

  /// Deletes every document in [collection] whose user_id == [uid],
  /// 400 at a time (Firestore batches are limited to 500 writes).
  static Future<void> _deleteAllOwnedBy(String collection, String uid) async {
    while (true) {
      final snap = await _db
          .collection(collection)
          .where('user_id', isEqualTo: uid)
          .limit(400)
          .get();
      if (snap.docs.isEmpty) return;

      final batch = _db.batch();
      for (final doc in snap.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();

      if (snap.docs.length < 400) return;
    }
  }

  static String _mapError(String code) {
    switch (code) {
      case 'wrong-password':
      case 'invalid-credential':
      case 'invalid-login-credentials':
        return 'Your current password is incorrect.';
      case 'weak-password':
        return 'The new password is too weak.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait a while and try again.';
      case 'network-request-failed':
        return 'No internet connection. Please check your network.';
      case 'requires-recent-login':
        return 'For security, please log out, log in again, then retry.';
      case 'user-mismatch':
      case 'user-not-found':
        return 'This account could not be verified. Please log in again.';
      default:
        return 'Something went wrong. Please try again.';
    }
  }
}
