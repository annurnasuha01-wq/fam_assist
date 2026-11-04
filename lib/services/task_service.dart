import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'auth_service.dart';
import 'notification_scheduler.dart';

class TaskResult {
  final bool success;
  final String? errorMessage;
  final String? taskId;
  TaskResult({required this.success, this.errorMessage, this.taskId});
}

class TaskService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// ERD: Task entity -> tasks/{taskId}
  /// After the task is saved, the alarm (at the exact task time) and the
  /// 24-hour advance reminder are scheduled via NotificationScheduler.
  static Future<TaskResult> createTask({
    required String folderId,
    required String folderName,
    required String title,
    required DateTime taskDatetime,
    String? voiceId,
    String? description,
  }) async {
    final user = AuthService.currentUser;
    if (user == null) {
      return TaskResult(success: false, errorMessage: 'Not logged in.');
    }
    try {
      final docRef = await _db.collection('tasks').add({
        'user_id': user.uid,
        'folder_id': folderId,
        'folder_name': folderName,
        'voice_id': voiceId,
        'title': title,
        'description': description,
        'task_datetime': Timestamp.fromDate(taskDatetime),
        'status': 'pending',
        'create_at': FieldValue.serverTimestamp(),
        'updated_at': FieldValue.serverTimestamp(),
        'completed_at': null,
      });

      // Best-effort: a reminder failing to schedule shouldn't make the
      // whole "save task" action look like it failed to the user.
      try {
        await NotificationScheduler.scheduleReminder(
          taskId: docRef.id,
          folderName: folderName,
          taskTitle: title,
          taskDatetime: taskDatetime,
        );
      } catch (e, st) {
        debugPrint('scheduleReminder failed: $e\n$st');
      }

      return TaskResult(success: true, taskId: docRef.id);
    } catch (e) {
      return TaskResult(
        success: false,
        errorMessage: 'Failed to save task. Please try again.',
      );
    }
  }

  /// The current user's tasks, most recently created first.
  static Stream<QuerySnapshot<Map<String, dynamic>>> streamRecentTasks({
    int limit = 5,
  }) {
    final user = AuthService.currentUser;
    if (user == null) return const Stream.empty();
    return _db
        .collection('tasks')
        .where('user_id', isEqualTo: user.uid)
        .orderBy('create_at', descending: true)
        .limit(limit)
        .snapshots();
  }

  /// All of the current user's tasks (dashboard stats + the "All" screen).
  /// Only filters on user_id, so no extra Firestore index is needed.
  static Stream<QuerySnapshot<Map<String, dynamic>>> streamAllUserTasks() {
    final user = AuthService.currentUser;
    if (user == null) return const Stream.empty();
    return _db
        .collection('tasks')
        .where('user_id', isEqualTo: user.uid)
        .snapshots();
  }

  /// Tasks belonging to one specific folder.
  static Stream<QuerySnapshot<Map<String, dynamic>>> streamTasksByFolder(
    String folderId,
  ) {
    final user = AuthService.currentUser;
    if (user == null) return const Stream.empty();
    return _db
        .collection('tasks')
        .where('user_id', isEqualTo: user.uid)
        .where('folder_id', isEqualTo: folderId)
        .orderBy('task_datetime')
        .snapshots();
  }

  /// Writes status 'overdue' to every task that is still 'pending' although
  /// its date/time has passed, so the database matches what the app shows.
  /// (Completed tasks are never touched.)
  static Future<void> markOverdueTasks() async {
    final user = AuthService.currentUser;
    if (user == null) return;
    try {
      final snap = await _db
          .collection('tasks')
          .where('user_id', isEqualTo: user.uid)
          .where('status', isEqualTo: 'pending')
          .get();
      final now = DateTime.now();
      final batch = _db.batch();
      var count = 0;
      for (final doc in snap.docs) {
        final ts = doc.data()['task_datetime'] as Timestamp?;
        if (ts != null && ts.toDate().isBefore(now)) {
          batch.update(doc.reference, {'status': 'overdue'});
          count++;
        }
      }
      if (count > 0) await batch.commit();
    } catch (_) {
      // Best-effort housekeeping.
    }
  }

  static Future<TaskResult> toggleTaskStatus(
    String taskId,
    bool markCompleted,
  ) async {
    try {
      final ref = _db.collection('tasks').doc(taskId);
      await ref.update({
        'status': markCompleted ? 'completed' : 'pending',
        'completed_at': markCompleted ? FieldValue.serverTimestamp() : null,
        'updated_at': FieldValue.serverTimestamp(),
      });

      if (markCompleted) {
        // Done -> the alarm is no longer relevant.
        await NotificationScheduler.cancelReminder(taskId);
      } else {
        // Un-completed -> put the alarm back (if the time is still ahead).
        try {
          final data = (await ref.get()).data();
          final ts = data?['task_datetime'] as Timestamp?;
          if (data != null && ts != null) {
            await NotificationScheduler.rescheduleReminder(
              taskId: taskId,
              folderName: (data['folder_name'] as String?) ?? '',
              taskTitle: (data['title'] as String?) ?? '',
              newTaskDatetime: ts.toDate(),
              recordInFirestore: false,
            );
          }
        } catch (_) {}
      }
      return TaskResult(success: true, taskId: taskId);
    } catch (e) {
      return TaskResult(success: false, errorMessage: 'Failed to update task.');
    }
  }

  /// Updates a task's editable fields. If [newTaskDatetime] is provided the
  /// alarms are re-scheduled — unless the task is already completed, in which
  /// case no alarm is (re)armed.
  static Future<TaskResult> updateTask({
    required String taskId,
    required String folderName,
    String? title,
    String? description,
    DateTime? newTaskDatetime,
  }) async {
    try {
      final ref = _db.collection('tasks').doc(taskId);
      final data = <String, dynamic>{
        'updated_at': FieldValue.serverTimestamp(),
      };
      if (title != null) data['title'] = title;
      if (description != null) data['description'] = description;
      if (newTaskDatetime != null) {
        data['task_datetime'] = Timestamp.fromDate(newTaskDatetime);
      }

      await ref.update(data);

      if (newTaskDatetime != null) {
        try {
          final current = (await ref.get()).data();
          final isCompleted = current?['status'] == 'completed';
          if (isCompleted) {
            await NotificationScheduler.cancelReminder(taskId);
          } else {
            await NotificationScheduler.rescheduleReminder(
              taskId: taskId,
              folderName: folderName,
              taskTitle: title ?? (current?['title'] as String?) ?? '',
              newTaskDatetime: newTaskDatetime,
            );
          }
        } catch (_) {}
      }

      return TaskResult(success: true, taskId: taskId);
    } catch (e) {
      return TaskResult(
        success: false,
        errorMessage: 'Failed to update task. Please try again.',
      );
    }
  }

  static Future<TaskResult> deleteTask(String taskId) async {
    try {
      // Cancel first so a deleted task can never still ping the user.
      await NotificationScheduler.cancelReminder(taskId);
      await _db.collection('tasks').doc(taskId).delete();
      return TaskResult(success: true);
    } catch (e) {
      return TaskResult(success: false, errorMessage: 'Failed to delete task.');
    }
  }

  /// Deletes several tasks at once (multi-select delete) and cancels their
  /// alarms. Done in batches of 400 (Firestore allows 500 writes per batch).
  static Future<TaskResult> deleteTasks(List<String> taskIds) async {
    if (taskIds.isEmpty) return TaskResult(success: true);
    try {
      for (final id in taskIds) {
        try {
          await NotificationScheduler.cancelReminder(id);
        } catch (_) {}
      }
      for (int i = 0; i < taskIds.length; i += 400) {
        final chunk = taskIds.sublist(
          i,
          i + 400 > taskIds.length ? taskIds.length : i + 400,
        );
        final batch = _db.batch();
        for (final id in chunk) {
          batch.delete(_db.collection('tasks').doc(id));
        }
        await batch.commit();
      }
      return TaskResult(success: true);
    } catch (e) {
      return TaskResult(
        success: false,
        errorMessage: 'Failed to delete the selected tasks.',
      );
    }
  }

  /// Deletes every task that belongs to a given folder (and their alarms).
  static Future<TaskResult> deleteTasksByFolder(String folderId) async {
    try {
      final user = AuthService.currentUser;
      if (user == null) {
        return TaskResult(success: false, errorMessage: 'Not logged in.');
      }
      final snapshot = await _db
          .collection('tasks')
          .where('user_id', isEqualTo: user.uid)
          .where('folder_id', isEqualTo: folderId)
          .get();

      if (snapshot.docs.isEmpty) {
        return TaskResult(success: true);
      }

      final batch = _db.batch();
      for (final doc in snapshot.docs) {
        await NotificationScheduler.cancelReminder(doc.id);
        batch.delete(doc.reference);
      }
      await batch.commit();

      return TaskResult(success: true);
    } catch (e) {
      return TaskResult(
        success: false,
        errorMessage: 'Failed to delete tasks in this folder.',
      );
    }
  }
}
