import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/task_service.dart';
import '../utils/task_state.dart';

/// Matches Figure 5.6 "Manage Task".
///
/// Real-reminder-app rules:
///  - The calendar only lets you pick TODAY or a FUTURE date (past days are
///    greyed out), and a time earlier than "now" is rejected.
///  - A task whose date/time has ALREADY PASSED is history: it opens in
///    read-only mode (red "Overdue" banner if it was never done). You can
///    still tick it done / un-tick it, or delete it — but not change its text,
///    date or time.
class EditTaskScreen extends StatefulWidget {
  final String taskId;
  final String folderName;
  final String title;
  final String? description;
  final DateTime taskDatetime;
  final bool isCompleted;

  const EditTaskScreen({
    super.key,
    required this.taskId,
    required this.folderName,
    required this.title,
    required this.taskDatetime,
    required this.isCompleted,
    this.description,
  });

  @override
  State<EditTaskScreen> createState() => _EditTaskScreenState();
}

class _EditTaskScreenState extends State<EditTaskScreen> {
  static const Color _accent = Color(0xFFE8543D);

  late final TextEditingController _titleController;
  late DateTime _date;
  late TimeOfDay _time;
  late bool _isDone;

  /// Decided once, when the screen opens: has this task's time already passed?
  late final bool _isPast;
  bool _isSaving = false;

  bool get _readOnly => _isPast;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.title);
    _date = widget.taskDatetime;
    _time = TimeOfDay(
      hour: widget.taskDatetime.hour,
      minute: widget.taskDatetime.minute,
    );
    _isDone = widget.isCompleted;
    _isPast = TaskStateHelper.isPast(widget.taskDatetime);
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  DateTime get _combinedDateTime =>
      DateTime(_date.year, _date.month, _date.day, _time.hour, _time.minute);

  bool get _timeInPast =>
      !_readOnly && _combinedDateTime.isBefore(DateTime.now());

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final initial = _date.isBefore(today) ? today : _date;

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: today, // past days are disabled
      lastDate: today.add(const Duration(days: 365 * 2)),
      helpText: 'Select a date (past dates are disabled)',
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: _time);
    if (picked == null) return;

    final candidate = DateTime(
      _date.year,
      _date.month,
      _date.day,
      picked.hour,
      picked.minute,
    );
    if (candidate.isBefore(DateTime.now())) {
      _showSnack('That time has already passed. Please choose a later time.');
      return;
    }
    setState(() => _time = picked);
  }

  Future<void> _handleUpdate() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      _showSnack('Task description cannot be empty.');
      return;
    }
    if (_combinedDateTime.isBefore(DateTime.now())) {
      _showSnack('The date and time must be in the future.');
      return;
    }

    setState(() => _isSaving = true);

    final result = await TaskService.updateTask(
      taskId: widget.taskId,
      folderName: widget.folderName,
      title: title,
      newTaskDatetime: _combinedDateTime,
    );

    if (_isDone != widget.isCompleted) {
      await TaskService.toggleTaskStatus(widget.taskId, _isDone);
    }

    if (!mounted) return;
    setState(() => _isSaving = false);

    if (result.success) {
      Navigator.pop(context);
    } else {
      _showSnack(result.errorMessage ?? 'Failed to update task.');
    }
  }

  /// Read-only (history) mode: ticking done applies immediately.
  Future<void> _toggleDoneNow(bool value) async {
    setState(() => _isSaving = true);
    final result = await TaskService.toggleTaskStatus(widget.taskId, value);
    if (!mounted) return;
    setState(() {
      _isSaving = false;
      if (result.success) _isDone = value;
    });
    _showSnack(
      result.success
          ? (value ? 'Marked as done.' : 'Marked as not done.')
          : (result.errorMessage ?? 'Failed to update task.'),
    );
  }

  Future<void> _handleDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Task?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isSaving = true);
    final result = await TaskService.deleteTask(widget.taskId);
    if (!mounted) return;
    setState(() => _isSaving = false);

    if (result.success) {
      Navigator.pop(context);
    } else {
      _showSnack(result.errorMessage ?? 'Failed to delete task.');
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------- UI ----------------

  Widget _buildStatusBanner() {
    final due = _readOnly ? widget.taskDatetime : _combinedDateTime;
    final state = TaskStateHelper.of(isCompleted: _isDone, due: due);
    final color = TaskStateHelper.color(state);
    final alarmAt = DateFormat('EEE, d MMM • h:mm a').format(due);

    late final IconData icon;
    late final String headline;
    late final String detail;

    switch (state) {
      case TaskState.completed:
        icon = Icons.check_circle;
        headline = 'Completed';
        detail = _readOnly
            ? 'Kept in your history. The date has passed, so it can no longer be edited.'
            : 'You can still change it or un-tick "Mark Done".';
      case TaskState.overdue:
        icon = Icons.error;
        headline = TaskStateHelper.statusText(state, due);
        detail =
            'This date has already passed, so the task can\'t be edited. '
            'You can still mark it done or delete it.';
      case TaskState.dueSoon:
        icon = Icons.alarm;
        headline = TaskStateHelper.statusText(state, due);
        detail = 'Alarm rings at $alarmAt.';
      case TaskState.upcoming:
        icon = Icons.alarm;
        headline = TaskStateHelper.statusText(state, due);
        detail = 'Alarm rings at $alarmAt, with a heads-up 24 hours before.';
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TaskStateHelper.background(state),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  headline,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(detail, style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset('assets/bg.png', fit: BoxFit.cover),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const Text('Back', style: TextStyle(color: Colors.white)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      _readOnly ? 'Task Details' : 'Edit Task',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 8, bottom: 16),
                    child: Text(
                      _readOnly
                          ? 'This task is in the past (history)'
                          : 'Update or delete task information',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildStatusBanner(),

                        const Text(
                          'Task Description',
                          style: TextStyle(fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _titleController,
                          readOnly: _readOnly,
                          style: TextStyle(
                            color: _readOnly
                                ? Colors.grey[700]
                                : Colors.black87,
                          ),
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: Colors.grey[100],
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),

                        const Text(
                          'Date',
                          style: TextStyle(fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 6),
                        _pickerField(
                          text: DateFormat('EEE, d MMM yyyy').format(_date),
                          icon: Icons.calendar_today,
                          onTap: _readOnly ? null : _pickDate,
                        ),
                        const SizedBox(height: 16),

                        const Text(
                          'Time (alarm rings at this time)',
                          style: TextStyle(fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 6),
                        _pickerField(
                          text: _time.format(context),
                          icon: Icons.access_time,
                          onTap: _readOnly ? null : _pickTime,
                          isError: _timeInPast,
                        ),
                        if (_timeInPast)
                          const Padding(
                            padding: EdgeInsets.only(top: 4, left: 4),
                            child: Text(
                              'This time has already passed — pick a later time.',
                              style: TextStyle(color: Colors.red, fontSize: 11),
                            ),
                          ),
                        const SizedBox(height: 16),

                        const Text(
                          'Folder Name',
                          style: TextStyle(fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.grey[100],
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(widget.folderName),
                        ),
                        const SizedBox(height: 12),

                        CheckboxListTile(
                          value: _isDone,
                          onChanged: _isSaving
                              ? null
                              : (value) {
                                  final v = value ?? false;
                                  if (_readOnly) {
                                    _toggleDoneNow(v);
                                  } else {
                                    setState(() => _isDone = v);
                                  }
                                },
                          activeColor: _accent,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: const Text('Mark Done'),
                          subtitle: const Text(
                            'This task has been completed',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                        const SizedBox(height: 8),

                        Row(
                          children: [
                            if (!_readOnly) ...[
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: _isSaving ? null : _handleUpdate,
                                  icon: const Icon(
                                    Icons.save,
                                    color: Colors.white,
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: _accent,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 14,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(30),
                                    ),
                                  ),
                                  label: const Text(
                                    'Update',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                            ],
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _isSaving ? null : _handleDelete,
                                icon: const Icon(
                                  Icons.delete,
                                  color: Colors.red,
                                ),
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(color: Colors.red),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(30),
                                  ),
                                ),
                                label: const Text(
                                  'Delete',
                                  style: TextStyle(color: Colors.red),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_isSaving)
            Container(
              color: Colors.black26,
              child: const Center(
                child: CircularProgressIndicator(color: _accent),
              ),
            ),
        ],
      ),
    );
  }

  Widget _pickerField({
    required String text,
    required IconData icon,
    required VoidCallback? onTap,
    bool isError = false,
  }) {
    final locked = onTap == null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.grey[100],
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: isError ? Colors.red : Colors.transparent),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              text,
              style: TextStyle(
                color: isError
                    ? Colors.red
                    : locked
                    ? Colors.grey[700]
                    : Colors.black87,
              ),
            ),
            Icon(
              locked ? Icons.lock_outline : icon,
              size: 16,
              color: Colors.grey,
            ),
          ],
        ),
      ),
    );
  }
}
