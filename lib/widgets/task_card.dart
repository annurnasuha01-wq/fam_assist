import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../utils/task_state.dart';

/// One task row, styled like a real reminder app:
///   - Overdue  -> red card, red "OVERDUE" badge, "Overdue by 2 days"
///   - Due      -> orange badge, "Due in 3 h 20 min"
///   - Upcoming -> normal card, "Due in 4 days"
///   - Completed-> grey card, green "Completed", title struck through
class TaskCard extends StatelessWidget {
  final String title;
  final String folderName;
  final DateTime? due;
  final bool isDone;
  final bool showFolder;
  final bool showDate;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final ValueChanged<bool?>? onToggle;

  /// Multi-select (delete) mode: shows a selection tick instead of the
  /// done-checkbox and highlights selected cards.
  final bool selectMode;
  final bool selected;

  const TaskCard({
    super.key,
    required this.title,
    required this.folderName,
    required this.due,
    required this.isDone,
    required this.onTap,
    this.onToggle,
    this.onLongPress,
    this.selectMode = false,
    this.selected = false,
    this.showFolder = true,
    this.showDate = false,
  });

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.bold,
          color: color,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final state = TaskStateHelper.of(isCompleted: isDone, due: due, now: now);
    final color = TaskStateHelper.color(state);
    final isOverdue = state == TaskState.overdue;

    final timeLabel = due == null
        ? ''
        : (isOverdue || showDate)
        ? DateFormat('EEE, d MMM • h:mm a').format(due!)
        : DateFormat('h:mm a').format(due!);

    final statusText = TaskStateHelper.statusText(state, due, now: now);

    final Widget leading = selectMode
        ? Checkbox(
            value: selected,
            activeColor: TaskStateHelper.accent,
            shape: const CircleBorder(),
            side: const BorderSide(color: Colors.grey, width: 2),
            onChanged: (_) => onTap(),
          )
        : onToggle != null
        ? Checkbox(
            value: isDone,
            activeColor: TaskStateHelper.completedColor,
            side: BorderSide(
              color: isOverdue ? TaskStateHelper.overdueColor : Colors.grey,
              width: 2,
            ),
            onChanged: onToggle,
          )
        : Padding(
            padding: const EdgeInsets.all(12),
            child: Icon(
              isDone
                  ? Icons.check_circle
                  : isOverdue
                  ? Icons.error_outline
                  : Icons.radio_button_unchecked,
              color: color,
            ),
          );

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(2, 6, 10, 6),
        decoration: BoxDecoration(
          color: TaskStateHelper.background(state),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? TaskStateHelper.accent
                : isOverdue
                ? TaskStateHelper.overdueColor.withOpacity(0.35)
                : Colors.transparent,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            leading,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      decoration: isDone ? TextDecoration.lineThrough : null,
                      color: isDone
                          ? Colors.grey[500]
                          : isOverdue
                          ? const Color(0xFFB71C1C)
                          : Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      if (showFolder && folderName.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.purple[50],
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            folderName,
                            style: const TextStyle(fontSize: 10),
                          ),
                        ),
                      if (timeLabel.isNotEmpty)
                        Text(
                          timeLabel,
                          style: TextStyle(
                            fontSize: 12,
                            color: isOverdue
                                ? TaskStateHelper.overdueColor
                                : Colors.grey[600],
                          ),
                        ),
                    ],
                  ),
                  if (statusText.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      statusText,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (state == TaskState.overdue)
              _badge('OVERDUE', TaskStateHelper.overdueColor)
            else if (state == TaskState.dueSoon)
              _badge('DUE', TaskStateHelper.dueColor),
            if (!selectMode)
              const Icon(Icons.chevron_right, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}
