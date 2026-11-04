import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Simple result wrapper so screens can check success/failure
/// without dealing with exceptions directly.
class AuthResult {
  final bool success;
  final String? errorMessage;

  /// True when this attempt was rejected purely because the account is
  /// temporarily locked out (too many recent failed attempts), as opposed
  /// to wrong credentials. Screens use this to show a countdown instead
  /// of a generic error.
  final bool isLocked;

  /// How many seconds remain before another attempt is allowed.
  /// Only meaningful when [isLocked] is true.
  final int lockoutSecondsRemaining;

  /// True when the user simply closed the Google account picker. Screens
  /// should NOT show an error dialog in that case.
  final bool cancelled;

  AuthResult({
    required this.success,
    this.errorMessage,
    this.isLocked = false,
    this.lockoutSecondsRemaining = 0,
    this.cancelled = false,
  });
}

class AuthService {
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static final GoogleSignIn _googleSignIn = GoogleSignIn();

  // ---------------- Brute-force / rate limiting ----------------
  // 3 wrong passwords in a row for the same username -> 60s lockout, during
  // which we never even call Firebase. Stored in SharedPreferences (device
  // local storage) instead of a plain in-memory variable, so a killed/
  // restarted app can't be used to reset the counter and keep guessing.
  //
  // Caveat, stated honestly: this is *client-side* throttling. A
  // determined attacker who reinstalls the app or clears app storage can
  // still reset it, and someone could bypass the UI entirely and call the
  // Firebase Auth REST API directly. Client-side lockout raises the bar
  // for casual/scripted guessing, but the real backstop against brute
  // force has to live server-side:
  //   - Firebase Auth already applies its own escalating delay/throttle
  //     per project after repeated failures (surfaces as the
  //     'too-many-requests' error code below).
  //   - Turn on Firebase App Check so only your real app can call
  //     Firebase Auth/Firestore at all (blocks scripted/replayed requests).
  //   - Firestore Security Rules must restrict every read/write to
  //     `request.auth.uid` — that's what stops a stolen session or a
  //     crafted request from reaching other users' data even if auth
  //     itself were bypassed.
  static const int maxFailedAttempts = 3;
  static const Duration lockoutDuration = Duration(seconds: 60);

  static String _attemptsKey(String username) => 'login_attempts::$username';
  static String _lockedUntilKey(String username) =>
      'login_locked_until::$username';

  /// Basic defense-in-depth input cleanup. Firebase Auth and Firestore are
  /// not SQL databases, so classic SQL injection (`' OR 1=1 --`) cannot
  /// reach a database engine through them: the SDK always sends structured,
  /// parameterized requests, never a raw query string built by concatenating
  /// user input. Still, we trim/limit length here so obviously-malformed or
  /// oversized input never reaches Firebase, and the real enforcement lives
  /// in Firestore Security Rules on the server side.
  static String _sanitize(String input, {int maxLength = 254}) {
    var value = input.trim();
    if (value.length > maxLength) value = value.substring(0, maxLength);
    return value;
  }

  /// Returns the current lockout state for [username] without making any
  /// network call. Screens can call this (e.g. when the username field
  /// loses focus) to show the countdown immediately, before the user even
  /// taps Login.
  static Future<AuthResult?> checkLockoutStatus(String username) async {
    final usernameKey = _sanitize(username, maxLength: 50).toLowerCase();
    if (usernameKey.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final lockedUntilMs = prefs.getInt(_lockedUntilKey(usernameKey));
    if (lockedUntilMs == null) return null;

    final remaining = DateTime.fromMillisecondsSinceEpoch(
      lockedUntilMs,
    ).difference(DateTime.now());
    if (remaining <= Duration.zero) return null;

    return AuthResult(
      success: false,
      isLocked: true,
      lockoutSecondsRemaining: remaining.inSeconds + 1,
      errorMessage: 'Too many failed attempts. Please wait and try again.',
    );
  }

  /// Currently logged-in Firebase user (null if nobody is logged in).
  static User? get currentUser => _auth.currentUser;

  // ---------------- Guest mode ----------------
  //
  // Guest = Firebase *Anonymous* Authentication. The person gets a real
  // uid without typing anything, so every existing feature (folders, voice
  // tasks, alarms, Firestore `user_id` rules) works exactly as for a
  // registered user. Later, registering (or Google sign-in) while still a
  // guest LINKS the new login to the same uid, so no task is lost.
  //
  // Needs: Firebase Console > Authentication > Sign-in method > Anonymous
  // = Enabled.

  /// True when the current user is a guest (no email / password / Google).
  static bool get isGuest => _auth.currentUser?.isAnonymous ?? false;

  /// Starts (or resumes) a guest session.
  static Future<AuthResult> signInAsGuest() async {
    try {
      final existing = _auth.currentUser;
      if (existing != null && !existing.isAnonymous) {
        // A real account is signed in: sign it out before starting a guest.
        await _auth.signOut();
      }
      if (_auth.currentUser == null) {
        await _auth.signInAnonymously();
      }
      return AuthResult(success: true);
    } on FirebaseAuthException catch (e) {
      debugPrint('Guest sign-in FirebaseAuthException: ${e.code}');
      switch (e.code) {
        case 'operation-not-allowed':
        case 'admin-restricted-operation':
          return AuthResult(
            success: false,
            errorMessage:
                'Guest mode is not switched on yet. In Firebase Console go to '
                'Authentication > Sign-in method and enable "Anonymous".',
          );
        case 'network-request-failed':
          return AuthResult(
            success: false,
            errorMessage: 'No internet connection. Please check your network.',
          );
        default:
          return AuthResult(
            success: false,
            errorMessage: 'Could not start guest mode. Please try again.',
          );
      }
    } catch (e) {
      debugPrint('Guest sign-in error: $e');
      return AuthResult(
        success: false,
        errorMessage: 'Could not start guest mode. Please try again.',
      );
    }
  }

  /// ERD: User entity -> users/{uid}
  /// Creates the Firebase Auth account, reserves the username in the
  /// `usernames` collection, and writes the matching Firestore profile doc.
  ///
  /// If the person is currently a GUEST, the email/password is linked to the
  /// guest's existing uid instead of creating a new account, so all their
  /// guest tasks, folders and alarms stay theirs.
  ///
  /// Username uniqueness is enforced by Firestore itself (see
  /// firestore.rules: only one `usernames/{key}` doc can ever be created
  /// per key), not just by the client-side check in [isUsernameTaken] —
  /// that check is only a fast pre-flight to avoid creating an Auth
  /// account you'd immediately have to delete; the rules are what
  /// actually prevent two accounts sharing a username in a race.
  static Future<AuthResult> registerUser(
    String username,
    String email,
    String password,
  ) async {
    final cleanUsername = _sanitize(username, maxLength: 50);
    final usernameKey = cleanUsername.toLowerCase();
    final cleanEmail = _sanitize(email).toLowerCase();

    final current = _auth.currentUser;
    final upgrading = current != null && current.isAnonymous;

    UserCredential? credential;
    try {
      if (upgrading) {
        // Guest -> real account, SAME uid (tasks are kept).
        credential = await current.linkWithCredential(
          EmailAuthProvider.credential(email: cleanEmail, password: password),
        );
      } else {
        credential = await _auth.createUserWithEmailAndPassword(
          email: cleanEmail,
          password: password,
        );
      }
      final uid = credential.user!.uid;

      // Reserve the username. If someone else grabbed this exact key in
      // the split second between our pre-check and this write, Firestore
      // Security Rules reject it (the doc already exists), and we throw
      // to hit the catch block below, which rolls back the Auth account.
      //
      // `email` is stored here (not just `uid`) because login now happens
      // by username: Firebase Auth itself only knows how to sign in with
      // an email, so we need a public, pre-auth way to turn a username
      // into the email to pass to signInWithEmailAndPassword. See
      // firestore.rules — this mapping doc is intentionally the only
      // place email is exposed pre-login, and it holds nothing else
      // sensitive (no password, no other profile fields).
      await _db.collection('usernames').doc(usernameKey).set({
        'uid': uid,
        'email': cleanEmail,
      });

      await _db.collection('users').doc(uid).set({
        'username': cleanUsername,
        'email': cleanEmail,
        'create_at': FieldValue.serverTimestamp(),
      });

      return AuthResult(success: true);
    } on FirebaseAuthException catch (e) {
      return AuthResult(success: false, errorMessage: _mapAuthError(e.code));
    } catch (e) {
      // Most likely cause: the username was taken by someone else a
      // moment ago (permission-denied on the usernames/{key} create).
      // Roll back so we don't leave an orphaned login with no matching
      // profile/username:
      //  - new account  -> delete it
      //  - guest upgrade -> only remove the email/password link, so the
      //                     guest session (and its tasks) stays usable.
      if (credential != null) {
        try {
          if (upgrading) {
            await credential.user?.unlink('password');
          } else {
            await credential.user?.delete();
          }
        } catch (_) {
          // Best-effort rollback; nothing more we can safely do client-side.
        }
      }
      return AuthResult(
        success: false,
        errorMessage: 'This username was just taken. Please choose another.',
      );
    }
  }

  /// Optional extra check (ERD doesn't require it, but your old UI did).
  /// Firebase Auth already guarantees unique EMAIL; this checks unique
  /// USERNAME against the `usernames/{usernameKey}` mapping doc, which is
  /// readable by anyone (it only exposes the email tied to a username, so
  /// this works even before the user is signed in — see the note on
  /// [registerUser] about that trade-off).
  static Future<bool> isUsernameTaken(String username) async {
    final key = _sanitize(username, maxLength: 50).toLowerCase();
    if (key.isEmpty) return false;
    final doc = await _db.collection('usernames').doc(key).get();
    return doc.exists;
  }

  /// Logs a user in with username + password.
  ///
  /// Firebase Auth itself only signs in by email, so this first resolves
  /// [username] to its email via the public `usernames/{usernameKey}`
  /// mapping doc (written at registration time — see [registerUser]),
  /// then calls signInWithEmailAndPassword under the hood. The screen
  /// never needs to know an email is involved at all.
  ///
  /// Rate limiting: after [maxFailedAttempts] consecutive failures for the
  /// same username, further attempts are rejected locally (no network call
  /// to Firebase) for [lockoutDuration], and the result comes back with
  /// [AuthResult.isLocked] set so the UI can show a countdown instead of
  /// "wrong password".
  static Future<AuthResult> loginUser(String username, String password) async {
    final usernameKey = _sanitize(username, maxLength: 50).toLowerCase();
    final prefs = await SharedPreferences.getInstance();

    // Already locked out — don't even hit Firebase.
    final existingLock = await checkLockoutStatus(usernameKey);
    if (existingLock != null) return existingLock;

    // Lockout window (if any) has fully expired — clear stale counters.
    await prefs.remove(_lockedUntilKey(usernameKey));

    // Resolve username -> email. A missing mapping doc (unknown username)
    // is treated exactly like a wrong password below — same generic
    // message and the same failed-attempt counter — so a caller can't
    // tell "no such username" apart from "wrong password" by response
    // shape or timing.
    String? email;
    try {
      final mappingDoc = await _db
          .collection('usernames')
          .doc(usernameKey)
          .get();
      email = mappingDoc.data()?['email'] as String?;
    } catch (e) {
      return AuthResult(
        success: false,
        errorMessage: 'Something went wrong. Please try again.',
      );
    }

    if (email == null) {
      return _recordFailedAttempt(
        prefs,
        usernameKey,
        'Incorrect username or password.',
      );
    }

    try {
      await _auth.signInWithEmailAndPassword(email: email, password: password);
      // Success — clear this username's failure history.
      await prefs.remove(_attemptsKey(usernameKey));
      await prefs.remove(_lockedUntilKey(usernameKey));
      return AuthResult(success: true);
    } on FirebaseAuthException catch (e) {
      return _recordFailedAttempt(prefs, usernameKey, _mapAuthError(e.code));
    } catch (e) {
      return AuthResult(
        success: false,
        errorMessage: 'Something went wrong. Please try again.',
      );
    }
  }

  /// Shared failure-counting logic used by [loginUser] for both "unknown
  /// username" and "wrong password" cases, so both count toward the same
  /// lockout for a given username.
  static Future<AuthResult> _recordFailedAttempt(
    SharedPreferences prefs,
    String usernameKey,
    String errorMessage,
  ) async {
    final attempts = (prefs.getInt(_attemptsKey(usernameKey)) ?? 0) + 1;

    if (attempts >= maxFailedAttempts) {
      final lockedUntil = DateTime.now().add(lockoutDuration);
      await prefs.setInt(
        _lockedUntilKey(usernameKey),
        lockedUntil.millisecondsSinceEpoch,
      );
      await prefs.setInt(
        _attemptsKey(usernameKey),
        0,
      ); // fresh count next window
      return AuthResult(
        success: false,
        isLocked: true,
        lockoutSecondsRemaining: lockoutDuration.inSeconds,
        errorMessage:
            'Too many failed attempts. Please wait ${lockoutDuration.inSeconds}s and try again.',
      );
    }

    await prefs.setInt(_attemptsKey(usernameKey), attempts);
    return AuthResult(success: false, errorMessage: errorMessage);
  }

  // ---------------- Sign-in provider helpers ----------------

  /// True if the current user can log in with an email + password.
  static bool get hasPasswordProvider =>
      _auth.currentUser?.providerData.any((p) => p.providerId == 'password') ??
      false;

  /// True if the current user signed in with Google.
  static bool get hasGoogleProvider =>
      _auth.currentUser?.providerData.any(
        (p) => p.providerId == 'google.com',
      ) ??
      false;

  // ---------------- Google sign-in ----------------

  /// Signs in (or registers, the first time) with a Google account.
  ///
  /// Google users have no password and no `usernames/{key}` reservation
  /// (that mapping only exists so username+password login can find an
  /// email). They only get a `users/{uid}` profile so the Dashboard can
  /// show a name.
  ///
  /// If the person is currently a GUEST, the Google login is linked to the
  /// guest's uid so their tasks are kept. If that Google account already
  /// belongs to another Firebase user, it falls back to a normal sign-in.
  static Future<AuthResult> signInWithGoogle() async {
    try {
      // Always show the account picker (not silently reuse the last account).
      await _googleSignIn.signOut();
      final account = await _googleSignIn.signIn();
      if (account == null) {
        return AuthResult(success: false, cancelled: true);
      }

      final googleAuth = await account.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      UserCredential userCred;
      final current = _auth.currentUser;
      if (current != null && current.isAnonymous) {
        try {
          userCred = await current.linkWithCredential(credential);
        } on FirebaseAuthException catch (e) {
          if (e.code == 'credential-already-in-use' ||
              e.code == 'email-already-in-use') {
            userCred = await _auth.signInWithCredential(credential);
          } else {
            rethrow;
          }
        }
      } else {
        userCred = await _auth.signInWithCredential(credential);
      }

      final user = userCred.user;
      if (user == null) {
        return AuthResult(
          success: false,
          errorMessage: 'Google sign-in failed. Please try again.',
        );
      }

      await _ensureGoogleProfile(
        user,
        googleName: account.displayName,
        googleEmail: account.email,
      );
      return AuthResult(success: true);
    } on FirebaseAuthException catch (e) {
      debugPrint('Google sign-in FirebaseAuthException: ${e.code}');
      await _googleSignIn.signOut();
      return AuthResult(success: false, errorMessage: _mapGoogleError(e.code));
    } catch (e) {
      // Most common cause during development: the app's SHA-1 / SHA-256
      // fingerprints are not added in the Firebase console (ApiException 10).
      debugPrint('Google sign-in error: $e');
      await _googleSignIn.signOut();
      return AuthResult(
        success: false,
        errorMessage:
            'Google sign-in failed. Check your internet connection and try again.',
      );
    }
  }

  /// Creates users/{uid} the first time a Google account logs in.
  /// Non-fatal: the Dashboard falls back to "User" if this write fails.
  static Future<void> _ensureGoogleProfile(
    User user, {
    String? googleName,
    String? googleEmail,
  }) async {
    try {
      final ref = _db.collection('users').doc(user.uid);
      final snap = await ref.get();
      if (snap.exists) return;

      final email = (user.email ?? googleEmail ?? '').toLowerCase();
      final fallback = (email.isEmpty ? 'user' : email).split('@').first;
      String name;
      if (user.displayName?.trim().isNotEmpty ?? false) {
        name = user.displayName!;
      } else if (googleName?.trim().isNotEmpty ?? false) {
        name = googleName!;
      } else {
        name = fallback;
      }
      await ref.set({
        'username': _sanitize(name, maxLength: 50),
        'email': email,
        'provider': 'google',
        'create_at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('Could not create Google profile: $e');
    }
  }

  static String _mapGoogleError(String code) {
    switch (code) {
      case 'account-exists-with-different-credential':
        return 'This email is already registered with a password. '
            'Log in with your username and password instead.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'network-request-failed':
        return 'No internet connection. Please check your network.';
      case 'too-many-requests':
        return 'Too many attempts. Please try again later.';
      default:
        return 'Google sign-in failed. Please try again.';
    }
  }

  // ---------------- Forgot password ----------------

  /// Sends a password-reset email. [usernameOrEmail] may be either.
  ///
  /// To avoid revealing which usernames/emails have accounts, an unknown
  /// username or email still returns success (the screen says "if an
  /// account exists, we sent a link").
  static Future<AuthResult> sendPasswordReset(String usernameOrEmail) async {
    final input = _sanitize(usernameOrEmail).toLowerCase();
    if (input.isEmpty) {
      return AuthResult(
        success: false,
        errorMessage: 'Enter your username or email.',
      );
    }

    String? email;
    try {
      if (input.contains('@')) {
        email = input;
      } else {
        final doc = await _db.collection('usernames').doc(input).get();
        email = doc.data()?['email'] as String?;
      }
    } catch (_) {
      return AuthResult(
        success: false,
        errorMessage: 'Something went wrong. Please try again.',
      );
    }

    if (email != null) {
      try {
        await _auth.sendPasswordResetEmail(email: email);
      } on FirebaseAuthException catch (e) {
        switch (e.code) {
          case 'invalid-email':
            return AuthResult(
              success: false,
              errorMessage: 'Enter a valid email address.',
            );
          case 'network-request-failed':
            return AuthResult(
              success: false,
              errorMessage:
                  'No internet connection. Please check your network.',
            );
          case 'too-many-requests':
            return AuthResult(
              success: false,
              errorMessage: 'Too many requests. Please try again later.',
            );
          default:
            break; // e.g. user-not-found -> pretend success
        }
      } catch (_) {
        return AuthResult(
          success: false,
          errorMessage: 'Something went wrong. Please try again.',
        );
      }
    }
    return AuthResult(success: true);
  }

  static Future<void> logout() async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
    await _auth.signOut();
  }

  static String _mapAuthError(String code) {
    switch (code) {
      case 'email-already-in-use':
      case 'credential-already-in-use':
        return 'This email is already registered. Please log in instead.';
      case 'invalid-email':
        return 'Enter a valid email address.';
      case 'weak-password':
        return 'Password is too weak.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        // Deliberately the same message for "no such account" and "wrong
        // password" (and, in loginUser, for "no such username" too):
        // returning a different message for each lets an attacker
        // enumerate which usernames/emails have accounts. Firebase Auth's
        // own "Email Enumeration Protection" project setting reinforces
        // this at the API level too — worth turning on in the console.
        return 'Incorrect username or password.';
      case 'too-many-requests':
        return 'Too many failed attempts. Please try again later.';
      case 'network-request-failed':
        return 'No internet connection. Please check your network.';
      default:
        return 'Authentication failed. Please try again.';
    }
  }
}
