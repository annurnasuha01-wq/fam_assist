import 'package:flutter/material.dart';

/// The four states a task can be in — decided from its due date/time and
/// whether it is ticked as done. Every screen uses this ONE helper so the
/// colours, labels and filters always agree.
///
///   completed -> ticked as done                               (GREEN)
///   overdue   -> NOT done and the due date/time has passed    (RED)
///   dueSoon   -> NOT done and due within the next 24 hours    (YELLOW)
///   upcoming  -> NOT done and due later than 24 hours from now  (WHITE)
enum TaskState { completed, overdue, dueSoon, upcoming }

class TaskStateHelper {
  /// A task is "Due" when it falls inside this window from now.
  static const Duration dueSoonWindow = Duration(hours: 24);

  static const Color accent = Color(0xFFE8543D);
  static const Color overdueColor = Color(0xFFD32F2F);
  static const Color overdueBg = Color(0xFFFFEBEE);
  static const Color dueColor = Color(0xFFF9A825); // yellow / amber
  static const Color dueBg = Color(0xFFFFF8D6); // light yellow
  static const Color upcomingBg = Color(0xFFFFFFFF); // white
  static const Color completedColor = Color(0xFF2E7D32);
  static const Color completedBg = Color(0xFFE3F4E5); // light green

  static TaskState of({
    required bool isCompleted,
    required DateTime? due,
    DateTime? now,
  }) {
    if (isCompleted) return TaskState.completed;
    if (due == null) return TaskState.upcoming;
    final n = now ?? DateTime.now();
    if (due.isBefore(n)) return TaskState.overdue;
    if (due.difference(n) <= dueSoonWindow) return TaskState.dueSoon;
    return TaskState.upcoming;
  }

  /// True when the date/time has already passed (task is "history").
  static bool isPast(DateTime? due, [DateTime? now]) =>
      due != null && due.isBefore(now ?? DateTime.now());

  static String label(TaskState s) => switch (s) {
    TaskState.completed => 'Completed',
    TaskState.overdue => 'Overdue',
    TaskState.dueSoon => 'Due',
    TaskState.upcoming => 'Upcoming',
  };

  static Color color(TaskState s) => switch (s) {
    TaskState.completed => completedColor,
    TaskState.overdue => overdueColor,
    TaskState.dueSoon => dueColor,
    TaskState.upcoming => accent,
  };

  static Color background(TaskState s) => switch (s) {
    TaskState.completed => completedBg,
    TaskState.overdue => overdueBg,
    TaskState.dueSoon => dueBg,
    TaskState.upcoming => upcomingBg,
  };

  /// "45 min", "3 h 20 min", "2 days", "1 day 4 h"
  static String span(Duration d) {
    final dur = d.abs();
    if (dur.inMinutes < 1) return 'less than a minute';
    if (dur.inMinutes < 60) return '${dur.inMinutes} min';
    if (dur.inHours < 24) {
      final m = dur.inMinutes % 60;
      return m == 0 ? '${dur.inHours} h' : '${dur.inHours} h $m min';
    }
    final days = dur.inDays;
    final h = dur.inHours % 24;
    final dayText = '$days day${days == 1 ? '' : 's'}';
    return (days < 3 && h > 0) ? '$dayText $h h' : dayText;
  }

  /// One-line status shown on cards: "Overdue by 2 days", "Due in 3 h 20 min".
  static String statusText(TaskState s, DateTime? due, {DateTime? now}) {
    if (s == TaskState.completed) return 'Completed';
    if (due == null) return '';
    final n = now ?? DateTime.now();
    final diff = due.difference(n);
    return s == TaskState.overdue
        ? 'Overdue by ${span(diff)}'
        : 'Due in ${span(diff)}';
  }
}
