import 'package:cloud_firestore/cloud_firestore.dart';
import 'auth_service.dart';

class FolderResult {
  final bool success;
  final String? errorMessage;
  final String? folderId;

  /// The folder's real name (as stored). Set by [FolderService.findOrCreateFolder].
  final String? folderName;

  /// True when [FolderService.findOrCreateFolder] had to create the folder.
  final bool created;

  FolderResult({
    required this.success,
    this.errorMessage,
    this.folderId,
    this.folderName,
    this.created = false,
  });
}

class FolderService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Icons given to folders that are created automatically (by voice, by the
  /// "type a task" sheet, or when guest tasks are moved into an account).
  /// Same assets as the Create Folder screen.
  static const List<String> defaultIcons = [
    'assets/emoji1.png',
    'assets/emoji3.png',
    'assets/emoji5.png',
    'assets/emoji7.png',
    'assets/emoji2.png',
    'assets/emoji4.png',
    'assets/emoji6.png',
  ];

  /// "  maryam  " -> "Maryam", "siti aminah" -> "Siti Aminah" (max 30 chars).
  static String tidyName(String raw) {
    final words = raw.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final text = words
        .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join(' ');
    return text.length > 30 ? text.substring(0, 30).trim() : text;
  }

  /// Comparison key: "Maryam", "maryam " and "MARYAM" are the same folder.
  static String nameKey(String name) =>
      name.toLowerCase().replaceAll(RegExp(r'\s+'), '');

  /// ERD: Folder entity -> folders/{folderId}
  /// Creates a new family-member folder owned by the currently logged-in user.
  static Future<FolderResult> createFolder({
    required String folderName,
    required String folderIcon,
  }) async {
    final user = AuthService.currentUser;
    if (user == null) {
      return FolderResult(
        success: false,
        errorMessage: 'You must be logged in to create a folder.',
      );
    }

    try {
      final docRef = await _db.collection('folders').add({
        'user_id': user.uid,
        'folder_name': folderName,
        'folder_icon': folderIcon,
        'create_at': FieldValue.serverTimestamp(),
        'updated_at': FieldValue.serverTimestamp(),
      });

      return FolderResult(success: true, folderId: docRef.id);
    } catch (e) {
      return FolderResult(
        success: false,
        errorMessage: 'Failed to create folder. Please try again.',
      );
    }
  }

  /// THE one place that answers "does this folder name already exist?".
  ///
  /// Looks through the current user's folders (case / spacing ignored). If
  /// one matches, its id is returned (created = false). If not, a new folder
  /// is created with [icon] (or the next default icon) and created = true.
  ///
  /// Works the same for a guest (anonymous) user and a registered user, and it
  /// always asks Firestore fresh, so two tasks saved one after another for the
  /// same new name never create the folder twice.
  static Future<FolderResult> findOrCreateFolder(
    String rawName, {
    String? icon,
  }) async {
    final user = AuthService.currentUser;
    if (user == null) {
      return FolderResult(
        success: false,
        errorMessage: 'You must be logged in to create a folder.',
      );
    }
    final name = tidyName(rawName);
    if (name.isEmpty) {
      return FolderResult(
        success: false,
        errorMessage: 'Folder name is empty.',
      );
    }

    try {
      final snap = await _db
          .collection('folders')
          .where('user_id', isEqualTo: user.uid)
          .get();

      final key = nameKey(name);
      for (final doc in snap.docs) {
        final existing = (doc.data()['folder_name'] as String?) ?? '';
        if (nameKey(existing) == key) {
          return FolderResult(
            success: true,
            folderId: doc.id,
            folderName: existing,
            created: false,
          );
        }
      }

      final chosenIcon =
          icon ?? defaultIcons[snap.docs.length % defaultIcons.length];
      final res = await createFolder(folderName: name, folderIcon: chosenIcon);
      return FolderResult(
        success: res.success,
        errorMessage: res.errorMessage,
        folderId: res.folderId,
        folderName: name,
        created: res.success,
      );
    } catch (e) {
      return FolderResult(
        success: false,
        errorMessage: 'Could not check or create the folder. Please try again.',
      );
    }
  }

  /// Real-time stream of all folders belonging to the current user.
  /// Use this later on the Dashboard screen (ERD activity diagram step 3).
  static Stream<QuerySnapshot<Map<String, dynamic>>> streamUserFolders() {
    final user = AuthService.currentUser;
    if (user == null) {
      return const Stream.empty();
    }
    return _db
        .collection('folders')
        .where('user_id', isEqualTo: user.uid)
        .orderBy('create_at', descending: true)
        .snapshots();
  }

  /// Returns true if the currently logged-in user already owns at least
  /// one folder. Used right after login to decide whether to send the
  /// user straight to the Dashboard or to the onboarding "create folder"
  /// screen first.
  static Future<bool> userHasFolders() async {
    final user = AuthService.currentUser;
    if (user == null) return false;

    try {
      final result = await _db
          .collection('folders')
          .where('user_id', isEqualTo: user.uid)
          .limit(1)
          .get();
      return result.docs.isNotEmpty;
    } catch (e) {
      // If the check fails for some reason, fall back to onboarding
      // instead of blocking the user from logging in.
      return false;
    }
  }

  /// Updates a folder's name/icon.
  static Future<FolderResult> updateFolder({
    required String folderId,
    String? folderName,
    String? folderIcon,
  }) async {
    try {
      final data = <String, dynamic>{
        'updated_at': FieldValue.serverTimestamp(),
      };
      if (folderName != null) data['folder_name'] = folderName;
      if (folderIcon != null) data['folder_icon'] = folderIcon;

      await _db.collection('folders').doc(folderId).update(data);
      return FolderResult(success: true);
    } catch (e) {
      return FolderResult(
        success: false,
        errorMessage: 'Failed to update folder. Please try again.',
      );
    }
  }

  /// Deletes a folder.
  static Future<FolderResult> deleteFolder(String folderId) async {
    try {
      await _db.collection('folders').doc(folderId).delete();
      return FolderResult(success: true);
    } catch (e) {
      return FolderResult(
        success: false,
        errorMessage: 'Failed to delete folder. Please try again.',
      );
    }
  }
}
