import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_service.dart';
import 'folder_service.dart';
import 'task_service.dart';

/// Moves a GUEST's folders + tasks into the account they log in to.
///
/// Why this is needed: a guest is a Firebase anonymous user with its own uid.
///  - "Create account" LINKS the new login to that same uid, so nothing has to
///    move (Dashboard just keeps working).
///  - "Log in to an existing account" switches to a DIFFERENT uid, and the
///    Firestore rules (user_id == auth.uid) correctly stop that account from
///    reading the guest's documents.
///
/// So, just before the guest signs out, [stash] copies the guest's data to
/// this phone (SharedPreferences). When the next session opens the Dashboard,
/// [importIfAny] re-creates it under the new uid:
///   - folder with the same name already exists  -> reuse it
///   - folder does not exist                     -> create it (e.g. "Maryam")
///   - same task already there                   -> skipped (no duplicates)
class GuestCarryOver {
  static const String _key = 'guest_carry_over_v1';

  /// Call while the guest is STILL signed in (before logout).
  /// Returns how many tasks were stashed, or -1 if the data could NOT be
  /// saved (the caller must then NOT log the guest out). Never throws.
  static Future<int> stash() async {
    try {
      final user = AuthService.currentUser;
      if (user == null || !user.isAnonymous) return 0;
      final db = FirebaseFirestore.instance;

      final folderSnap = await db
          .collection('folders')
          .where('user_id', isEqualTo: user.uid)
          .get();
      final taskSnap = await db
          .collection('tasks')
          .where('user_id', isEqualTo: user.uid)
          .get();

      final folderById = <String, Map<String, String>>{};
      for (final d in folderSnap.docs) {
        folderById[d.id] = {
          'name': (d.data()['folder_name'] as String?) ?? '',
          'icon': (d.data()['folder_icon'] as String?) ?? '',
        };
      }

      final tasks = <Map<String, dynamic>>[];
      for (final d in taskSnap.docs) {
        final data = d.data();
        final ts = data['task_datetime'] as Timestamp?;
        if (ts == null) continue;
        final folder = folderById[data['folder_id']];
        final folderName =
            folder?['name'] ?? (data['folder_name'] as String?) ?? '';
        if (folderName.isEmpty) continue;
        tasks.add({
          'folder_name': folderName,
          'title': data['title'] ?? '',
          'description': data['description'],
          'task_datetime': ts.millisecondsSinceEpoch,
          'completed': data['status'] == 'completed',
        });
      }

      if (tasks.isEmpty && folderById.isEmpty) return 0;

      // MERGE with anything still waiting from an earlier guest session that
      // was never imported, so a second guest can never wipe the first one.
      final prefs = await SharedPreferences.getInstance();
      final folders = <Map<String, dynamic>>[...folderById.values];
      final allTasks = <Map<String, dynamic>>[...tasks];
      final oldRaw = prefs.getString(_key);
      if (oldRaw != null) {
        try {
          final old = jsonDecode(oldRaw) as Map<String, dynamic>;
          final oldFolders = (old['folders'] as List? ?? const []);
          final oldTasks = (old['tasks'] as List? ?? const []);
          final haveFolder = <String>{
            for (final f in folders)
              FolderService.nameKey((f['name'] as String?) ?? ''),
          };
          for (final f in oldFolders) {
            final m = Map<String, dynamic>.from(f as Map);
            if (haveFolder.add(
              FolderService.nameKey((m['name'] as String?) ?? ''),
            )) {
              folders.add(m);
            }
          }
          String sig(Map t) =>
              '${FolderService.nameKey((t['folder_name'] as String?) ?? '')}'
              '|${((t['title'] as String?) ?? '').trim().toLowerCase()}'
              '|${t['task_datetime']}';
          final haveTask = <String>{for (final t in allTasks) sig(t)};
          for (final t in oldTasks) {
            final m = Map<String, dynamic>.from(t as Map);
            if (haveTask.add(sig(m))) allTasks.add(m);
          }
        } catch (_) {}
      }

      final saved = await prefs.setString(
        _key,
        jsonEncode({'folders': folders, 'tasks': allTasks}),
      );
      if (!saved) return -1;
      return tasks.length;
    } catch (e) {
      debugPrint('GuestCarryOver.stash failed: $e');
      return -1;
    }
  }

  /// Call when the Dashboard opens. Returns the number of tasks imported.
  /// Does nothing when there is nothing stashed. Never throws.
  static Future<int> importIfAny() async {
    try {
      final user = AuthService.currentUser;
      if (user == null) return 0;
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return 0;

      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final folders = (decoded['folders'] as List? ?? const []);
      final tasks = (decoded['tasks'] as List? ?? const []);

      // 1) folders first (keeps the guest's chosen icon).
      for (final f in folders) {
        final name = (f['name'] as String?) ?? '';
        if (name.isEmpty) continue;
        final icon = (f['icon'] as String?) ?? '';
        await FolderService.findOrCreateFolder(
          name,
          icon: icon.isEmpty ? null : icon,
        );
      }

      // 2) tasks already in this account (to avoid duplicates on a retry).
      final existing = await FirebaseFirestore.instance
          .collection('tasks')
          .where('user_id', isEqualTo: user.uid)
          .get();
      String sig(String folder, String title, int ms) =>
          '${FolderService.nameKey(folder)}|${title.trim().toLowerCase()}|$ms';
      final have = <String>{
        for (final d in existing.docs)
          sig(
            (d.data()['folder_name'] as String?) ?? '',
            (d.data()['title'] as String?) ?? '',
            ((d.data()['task_datetime'] as Timestamp?)
                    ?.millisecondsSinceEpoch) ??
                0,
          ),
      };

      var imported = 0;
      var failed = 0;
      for (final t in tasks) {
        final folderName = t['folder_name'] as String;
        final title = (t['title'] as String?) ?? '';
        final ms = t['task_datetime'] as int;
        if (have.contains(sig(folderName, title, ms))) continue;

        final folder = await FolderService.findOrCreateFolder(folderName);
        if (!folder.success || folder.folderId == null) {
          failed++;
          continue;
        }
        final res = await TaskService.createTask(
          folderId: folder.folderId!,
          folderName: folder.folderName ?? folderName,
          title: title,
          description: t['description'] as String?,
          taskDatetime: DateTime.fromMillisecondsSinceEpoch(ms),
        );
        if (!res.success || res.taskId == null) {
          failed++;
          continue;
        }
        if (t['completed'] == true) {
          await TaskService.toggleTaskStatus(res.taskId!, true);
        }
        imported++;
      }

      // Keep the stash if something failed so the next launch can retry.
      if (failed == 0) await prefs.remove(_key);
      return imported;
    } catch (e) {
      debugPrint('GuestCarryOver.importIfAny failed: $e');
      return 0;
    }
  }
}
