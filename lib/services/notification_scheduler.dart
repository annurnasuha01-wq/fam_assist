import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import '../firebase_options.dart';
import 'auth_service.dart';

// ---------------------------------------------------------------------------
// Notification buttons: [Done] and [Dismiss]
//
// The buttons are handled WITHOUT opening the app or showing the login screen.
// Android starts a tiny background process, which restores the saved Firebase
// login (the user only has to have logged in once and not logged out) and marks
// the task as completed in Firestore.
// ---------------------------------------------------------------------------
const String _actionDone = 'fam_action_done';
const String _actionDismiss = 'fam_action_dismiss';

/// Runs when a button is pressed while the app is closed / in the background.
/// MUST be a top-level function with this pragma.
@pragma('vm:entry-point')
Future<void> notificationBackgroundHandler(
  NotificationResponse response,
) async {
  DartPluginRegistrant.ensureInitialized();
  await _handleNotificationAction(response);
}

const String _pendingKey = 'pending_alarm_actions';

/// Firestore fields written for each button.
///   Done    -> status 'completed'
///   Dismiss -> status 'overdue'
Map<String, dynamic> _statusFields(String status) {
  if (status == 'completed') {
    return {
      'status': 'completed',
      'completed_at': FieldValue.serverTimestamp(),
      'updated_at': FieldValue.serverTimestamp(),
    };
  }
  return {
    'status': 'overdue',
    'alarm_dismissed_at': FieldValue.serverTimestamp(),
    'updated_at': FieldValue.serverTimestamp(),
  };
}

/// Called when Done / Dismiss is pressed (app open OR closed).
Future<void> _handleNotificationAction(NotificationResponse response) async {
  final taskId = response.payload;
  if (taskId == null || taskId.isEmpty || taskId == 'test') return;

  final action = response.actionId;
  if (action != _actionDone && action != _actionDismiss) return;

  // Notification ids: due ALARM = even number, 24-hour heads-up = odd number
  // (see _dueId / _advanceId). Dismissing the 24-hour heads-up must NOT mark
  // the task overdue — it isn't due yet.
  final isDueAlarm = (response.id ?? 0) % 2 == 0;
  if (action == _actionDismiss && !isDueAlarm) return;

  final newStatus = action == _actionDone ? 'completed' : 'overdue';

  // 1) Remember the choice on the phone FIRST, so it can never be lost
  //    (no internet, login not restored yet, process killed ...).
  await _queueAction(taskId, newStatus);

  // 2) Try to write it to Firestore right now.
  final saved = await _writeStatusToFirestore(taskId, newStatus);
  if (saved) await _unqueueAction(taskId, newStatus);

  if (newStatus == 'completed') {
    try {
      await NotificationScheduler.cancelReminder(taskId);
    } catch (_) {}
  }
}

Future<bool> _writeStatusToFirestore(String taskId, String status) async {
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
    final auth = FirebaseAuth.instance;
    // The saved login is restored asynchronously in a fresh background process.
    final user =
        auth.currentUser ??
        await auth.authStateChanges().first.timeout(const Duration(seconds: 6));
    if (user == null) return false; // logged out -> stays queued

    var written = false;
    await FirebaseFirestore.instance
        .collection('tasks')
        .doc(taskId)
        .update(_statusFields(status))
        .then((_) {
          written = true;
        })
        .timeout(const Duration(seconds: 8), onTimeout: () {});
    return written;
  } catch (_) {
    return false;
  }
}

Future<void> _queueAction(String taskId, String status) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final list = prefs.getStringList(_pendingKey) ?? <String>[];
    list.add('$taskId|$status|${DateTime.now().millisecondsSinceEpoch}');
    await prefs.setStringList(_pendingKey, list);
  } catch (_) {}
}

Future<void> _unqueueAction(String taskId, String status) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final list = prefs.getStringList(_pendingKey) ?? <String>[];
    list.removeWhere((e) => e.startsWith('$taskId|$status|'));
    await prefs.setStringList(_pendingKey, list);
  } catch (_) {}
}

/// ERD: Notifications entity -> notifications/{notificationId}
///
/// Every task now gets TWO on-device reminders:
///
///   1. ALARM at the task's exact date/time (e.g. "Rabu 9:00 AM") — loud,
///      uses the phone's ALARM sound stream, vibrates, keeps ringing
///      (insistent) for up to 60 s or until you tap/dismiss it, and shows
///      over the lock screen where Android allows it.
///   2. A normal heads-up reminder 24 hours before.
///
/// Both are scheduled locally (flutter_local_notifications), so they fire even
/// with no internet, and survive a phone reboot (needs the boot receiver in
/// AndroidManifest.xml — see the setup notes).
///
/// IMPORTANT: Android notification-channel sound/importance settings are
/// frozen once a channel is created. The old channel id
/// 'fam_assist_reminders' therefore can't be upgraded to "alarm" — that is
/// why this file uses NEW channel ids (…_v2).
class NotificationScheduler {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static bool _initialized = false;

  static const String _alarmChannelId = 'fam_assist_due_alarm_v2';
  static const String _advanceChannelId = 'fam_assist_advance_v2';
  static const int _testNotificationId = 2000000001;
  static const String _exactPromptedKey = 'exact_alarm_prompted';

  static final Int64List _vibration = Int64List.fromList(<int>[
    0,
    900,
    400,
    900,
    400,
    900,
  ]);

  /// Call once, early in main() before runApp().
  static Future<void> init() async {
    if (_initialized) return;
    tzdata.initializeTimeZones();

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings();
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    await _plugin.initialize(
      settings,
      // App is open: button pressed.
      onDidReceiveNotificationResponse: (r) => _handleNotificationAction(r),
      // App closed / in background: button pressed.
      onDidReceiveBackgroundNotificationResponse: notificationBackgroundHandler,
    );

    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();

    // Create the channels up-front so their alarm settings are definitely used.
    await android?.createNotificationChannel(
      AndroidNotificationChannel(
        _alarmChannelId,
        'Task Alarms',
        description: 'Rings at the exact time of each family task',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
        vibrationPattern: _vibration,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        showBadge: true,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _advanceChannelId,
        'Task Reminders (24h before)',
        description: 'Heads-up one day before a family task is due',
        importance: Importance.high,
      ),
    );

    // Android 13+ runtime permission.
    await android?.requestNotificationsPermission();

    // Android 12+ "Alarms & reminders" permission — needed for the alarm to
    // fire at the EXACT minute. Asked once automatically (opens a system
    // settings page); the "Test Reminder Alarm" menu item can ask again.
    try {
      final prefs = await SharedPreferences.getInstance();
      final canExact = await android?.canScheduleExactNotifications() ?? true;
      if (!canExact && !(prefs.getBool(_exactPromptedKey) ?? false)) {
        await prefs.setBool(_exactPromptedKey, true);
        await android?.requestExactAlarmsPermission();
      }
    } catch (_) {}

    await _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);

    _initialized = true;
  }

  // ---------------------------------------------------------------- ids

  /// Stable (run-to-run, version-to-version) hash — String.hashCode is NOT
  /// guaranteed stable, which could break cancelling after an app update.
  static int _stableHash(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h;
  }

  static int _dueId(String taskId) => (_stableHash(taskId) & 0x3FFFFFFF) * 2;
  static int _advanceId(String taskId) => _dueId(taskId) + 1;

  /// id scheme used by the previous version — still cancelled for safety.
  static int _legacyId(String taskId) => taskId.hashCode & 0x7FFFFFFF;

  // ---------------------------------------------------------------- details

  /// Buttons shown under the notification. showsUserInterface:false means the
  /// app is NOT opened (no login screen).
  static List<AndroidNotificationAction> _actions() => [
    AndroidNotificationAction(
      _actionDone,
      '✔ Done',
      showsUserInterface: false,
      cancelNotification: true,
    ),
    AndroidNotificationAction(
      _actionDismiss,
      'Dismiss',
      showsUserInterface: false,
      cancelNotification: true,
    ),
  ];

  static NotificationDetails _alarmDetails(String body) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        _alarmChannelId,
        'Task Alarms',
        channelDescription: 'Rings at the exact time of each family task',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.alarm,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        playSound: true,
        enableVibration: true,
        vibrationPattern: _vibration,
        // false on purpose: a full-screen intent would open the app (login
        // screen) over the lock screen. Instead the alarm appears as a
        // heads-up / lock-screen notification with Done + Dismiss buttons.
        fullScreenIntent: false,
        visibility: NotificationVisibility.public,
        // 4 = Notification.FLAG_INSISTENT -> sound repeats until dismissed.
        additionalFlags: Int32List.fromList(<int>[4]),
        timeoutAfter: 60000, // stop ringing after 60 s
        autoCancel: true,
        ticker: 'Task alarm',
        actions: _actions(),
        styleInformation: BigTextStyleInformation(body),
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.timeSensitive,
      ),
    );
  }

  static NotificationDetails _advanceDetails(String body) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        _advanceChannelId,
        'Task Reminders (24h before)',
        channelDescription: 'Heads-up one day before a family task is due',
        importance: Importance.high,
        priority: Priority.high,
        actions: _actions(),
        styleInformation: BigTextStyleInformation(body),
      ),
      iOS: const DarwinNotificationDetails(),
    );
  }

  /// Exact alarms need the "Alarms & reminders" permission on Android 12+.
  /// If the user hasn't granted it, fall back to the closest allowed mode so
  /// the reminder still fires (possibly a few minutes late) instead of not
  /// at all.
  static Future<AndroidScheduleMode> _scheduleMode() async {
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      final canExact = await android?.canScheduleExactNotifications() ?? true;
      return canExact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle;
    } catch (_) {
      return AndroidScheduleMode.inexactAllowWhileIdle;
    }
  }

  // ---------------------------------------------------------------- local scheduling

  /// Schedules the two on-device notifications only (no Firestore writes).
  static Future<({bool advance, bool due})> _scheduleLocal({
    required String taskId,
    required String folderName,
    required String taskTitle,
    required DateTime taskDatetime,
  }) async {
    final now = DateTime.now();
    final mode = await _scheduleMode();
    final advanceTime = taskDatetime.subtract(const Duration(hours: 24));

    var advanceScheduled = false;
    var dueScheduled = false;

    if (advanceTime.isAfter(now)) {
      await _plugin.zonedSchedule(
        _advanceId(taskId),
        'Tomorrow • $folderName',
        taskTitle,
        tz.TZDateTime.from(advanceTime, tz.local),
        _advanceDetails(taskTitle),
        payload: taskId,
        androidScheduleMode: mode,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
      advanceScheduled = true;
    }

    if (taskDatetime.isAfter(now)) {
      await _plugin.zonedSchedule(
        _dueId(taskId),
        '⏰ $folderName — it\'s time!',
        taskTitle,
        tz.TZDateTime.from(taskDatetime, tz.local),
        _alarmDetails(taskTitle),
        payload: taskId,
        androidScheduleMode: mode,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
      dueScheduled = true;
    }

    return (advance: advanceScheduled, due: dueScheduled);
  }

  /// Schedules both reminders for a task. Call right after a task is created.
  /// [recordInFirestore] = false skips writing the `notifications` documents
  /// (used when silently re-arming alarms, e.g. after un-completing a task).
  static Future<void> scheduleReminder({
    required String taskId,
    required String folderName,
    required String taskTitle,
    required DateTime taskDatetime,
    bool recordInFirestore = true,
  }) async {
    final user = AuthService.currentUser;
    if (user == null) return;

    final result = await _scheduleLocal(
      taskId: taskId,
      folderName: folderName,
      taskTitle: taskTitle,
      taskDatetime: taskDatetime,
    );

    if (!recordInFirestore) return;

    Future<void> record(String type, DateTime time, String status) {
      return _db.collection('notifications').add({
        'task_id': taskId,
        'user_id': user.uid,
        'type': type,
        'notification_time': Timestamp.fromDate(time),
        'sent_time': null,
        'notify_status': status,
        'created_at': FieldValue.serverTimestamp(),
      });
    }

    await record(
      'advance_24h',
      taskDatetime.subtract(const Duration(hours: 24)),
      result.advance ? 'scheduled' : 'skipped_past_due',
    );
    await record(
      'due_alarm',
      taskDatetime,
      result.due ? 'scheduled' : 'skipped_past_due',
    );
  }

  /// Cancels every scheduled notification for a task.
  static Future<void> cancelReminder(String taskId) async {
    await _plugin.cancel(_dueId(taskId));
    await _plugin.cancel(_advanceId(taskId));
    await _plugin.cancel(_legacyId(taskId));
  }

  /// Removes EVERY scheduled alarm on this device. Call on logout so the next
  /// person never gets someone else's alarms.
  static Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }

  /// Cancel + reschedule (use when a task's date/time is edited).
  static Future<void> rescheduleReminder({
    required String taskId,
    required String folderName,
    required String taskTitle,
    required DateTime newTaskDatetime,
    bool recordInFirestore = true,
  }) async {
    await cancelReminder(taskId);
    await scheduleReminder(
      taskId: taskId,
      folderName: folderName,
      taskTitle: taskTitle,
      taskDatetime: newTaskDatetime,
      recordInFirestore: recordInFirestore,
    );
  }

  /// Re-arms the alarms for ALL of the user's pending, future tasks on THIS
  /// device. Call once after login / when the dashboard opens. This covers
  /// tasks created before the alarm upgrade, a reinstalled app, or a second
  /// phone logged into the same account.
  static Future<void> syncAll() async {
    final user = AuthService.currentUser;
    if (user == null) return;
    try {
      final snap = await _db
          .collection('tasks')
          .where('user_id', isEqualTo: user.uid)
          .where('status', isEqualTo: 'pending')
          .get();
      final now = DateTime.now();
      for (final doc in snap.docs) {
        final data = doc.data();
        final ts = data['task_datetime'] as Timestamp?;
        if (ts == null) continue;
        final due = ts.toDate();
        if (!due.isAfter(now)) continue;
        await cancelReminder(doc.id);
        await _scheduleLocal(
          taskId: doc.id,
          folderName: (data['folder_name'] as String?) ?? '',
          taskTitle: (data['title'] as String?) ?? '',
          taskDatetime: due,
        );
      }
    } catch (_) {
      // Best-effort; never block the UI.
    }
  }

  /// Applies any Done / Dismiss presses that could not be saved at the time
  /// (phone was offline, etc.). Called when the Dashboard opens or resumes.
  static Future<void> applyPendingActions() async {
    final user = AuthService.currentUser;
    if (user == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final list = prefs.getStringList(_pendingKey) ?? <String>[];
      if (list.isEmpty) return;

      final remaining = <String>[];
      for (final entry in list) {
        final parts = entry.split('|');
        if (parts.length < 2) continue;
        final taskId = parts[0];
        final status = parts[1];
        try {
          final ref = _db.collection('tasks').doc(taskId);
          final snap = await ref.get();
          if (!snap.exists) continue; // task was deleted meanwhile
          // Never overwrite "completed" with a late "overdue".
          if (status == 'overdue' && snap.data()?['status'] == 'completed') {
            continue;
          }
          await ref.update(_statusFields(status));
          if (status == 'completed') await cancelReminder(taskId);
        } catch (_) {
          remaining.add(entry); // try again next time
        }
      }
      await prefs.setStringList(_pendingKey, remaining);
    } catch (_) {}
  }

  /// Asks for notification + "Alarms & reminders" permission.
  /// Returns true when exact alarms are allowed.
  static Future<bool> ensureAlarmPermissions() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.requestNotificationsPermission();
    try {
      var ok = await android?.canScheduleExactNotifications() ?? true;
      if (!ok) {
        await android?.requestExactAlarmsPermission();
        ok = await android?.canScheduleExactNotifications() ?? false;
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------- testing

  /// Fires a real alarm-style notification [seconds] from now so you can
  /// confirm sound/vibration works on THIS phone. Returns a message to show.
  static Future<String> scheduleTestAlarm({int seconds = 10}) async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();

    await android?.requestNotificationsPermission();

    var exactOk = true;
    try {
      exactOk = await android?.canScheduleExactNotifications() ?? true;
      if (!exactOk) {
        await android?.requestExactAlarmsPermission();
        exactOk = await android?.canScheduleExactNotifications() ?? false;
      }
    } catch (_) {}

    final mode = exactOk
        ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle;

    await _plugin.zonedSchedule(
      _testNotificationId,
      '⏰ Fam-Assist test alarm',
      'If you can hear this, your task alarms will work.',
      tz.TZDateTime.now(tz.local).add(Duration(seconds: seconds)),
      _alarmDetails('If you can hear this, your task alarms will work.'),
      androidScheduleMode: mode,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );

    return exactOk
        ? 'Test alarm will ring in $seconds seconds. Lock your phone and wait.'
        : 'Test alarm set, but "Alarms & reminders" permission is OFF, so real '
              'alarms may be a few minutes late. Turn it on in Settings > Apps > '
              'Fam-Assist.';
  }
}
