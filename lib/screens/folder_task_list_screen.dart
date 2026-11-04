import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/task_service.dart';
import '../utils/task_state.dart';
import '../widgets/task_card.dart';
import 'edit_task_screen.dart';

/// Full-screen task list for one folder — Figure 5.5 "View Task by Folder".
///
/// Filters:
///   ALL          every task
///   Not Complete everything not ticked done (includes overdue)
///   Due          not done and due within the next 24 hours
///   Overdue      not done and the date/time has already passed  (red)
///   Complete     ticked done
///
/// Overdue tasks are pulled into a red "OVERDUE" section at the top, like
/// real reminder apps; everything else is grouped by date.
class FolderTaskListScreen extends StatefulWidget {
  final String folderId;
  final String folderName;
  final String folderIcon;

  const FolderTaskListScreen({
    super.key,
    required this.folderId,
    required this.folderName,
    required this.folderIcon,
  });

  @override
  State<FolderTaskListScreen> createState() => _FolderTaskListScreenState();
}

enum _TaskFilter { all, notComplete, due, overdue, complete }

class _FolderTaskListScreenState extends State<FolderTaskListScreen> {
  static const String _overdueKey = 'OVERDUE';

  _TaskFilter _filter = _TaskFilter.all;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Re-evaluate Overdue / Due as the clock moves, without needing new data.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  TaskState _stateOf(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    final data = d.data();
    return TaskStateHelper.of(
      isCompleted: data['status'] == 'completed',
      due: (data['task_datetime'] as Timestamp?)?.toDate(),
    );
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _applyFilter(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    switch (_filter) {
      case _TaskFilter.all:
        return docs;
      case _TaskFilter.notComplete:
        return docs.where((d) => _stateOf(d) != TaskState.completed).toList();
      case _TaskFilter.due:
        return docs.where((d) => _stateOf(d) == TaskState.dueSoon).toList();
      case _TaskFilter.overdue:
        return docs.where((d) => _stateOf(d) == TaskState.overdue).toList();
      case _TaskFilter.complete:
        return docs.where((d) => _stateOf(d) == TaskState.completed).toList();
    }
  }

  /// Overdue tasks first (one red section), then the rest grouped by date.
  Map<String, List<QueryDocumentSnapshot<Map<String, dynamic>>>> _group(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final grouped =
        <String, List<QueryDocumentSnapshot<Map<String, dynamic>>>>{};

    final overdue = docs
        .where((d) => _stateOf(d) == TaskState.overdue)
        .toList();
    if (overdue.isNotEmpty) grouped[_overdueKey] = overdue;

    for (final doc in docs) {
      if (_stateOf(doc) == TaskState.overdue) continue;
      final ts = doc.data()['task_datetime'] as Timestamp?;
      final label = ts == null
          ? 'No date'
          : DateFormat('EEEE, d MMM yyyy').format(ts.toDate());
      grouped.putIfAbsent(label, () => []).add(doc);
    }
    return grouped;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset('assets/bg.png', fit: BoxFit.cover),
          SafeArea(
            child: Column(
              children: [
                _buildHeader(),
                const SizedBox(height: 12),
                _buildFilterTabs(),
                const SizedBox(height: 12),
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    padding: const EdgeInsets.all(16),
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(20),
                      ),
                    ),
                    child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: TaskService.streamTasksByFolder(widget.folderId),
                      builder: (context, snapshot) {
                        if (!snapshot.hasData) {
                          return const Center(
                            child: CircularProgressIndicator(
                              color: Color(0xFFE8543D),
                            ),
                          );
                        }
                        final filtered = _applyFilter(snapshot.data!.docs);
                        if (filtered.isEmpty) {
                          return Center(
                            child: Text(
                              _emptyMessage(),
                              style: TextStyle(color: Colors.grey[500]),
                            ),
                          );
                        }
                        final grouped = _group(filtered);
                        return ListView(
                          children: grouped.entries.expand((entry) {
                            final isOverdueSection = entry.key == _overdueKey;
                            return [
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: 12,
                                  bottom: 6,
                                ),
                                child: Row(
                                  children: [
                                    if (isOverdueSection)
                                      const Padding(
                                        padding: EdgeInsets.only(right: 6),
                                        child: Icon(
                                          Icons.error_outline,
                                          size: 14,
                                          color: TaskStateHelper.overdueColor,
                                        ),
                                      ),
                                    Text(
                                      isOverdueSection
                                          ? 'OVERDUE (${entry.value.length})'
                                          : entry.key.toUpperCase(),
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: isOverdueSection
                                            ? TaskStateHelper.overdueColor
                                            : Colors.grey[500],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              ...entry.value.map(_buildTaskCard),
                            ];
                          }).toList(),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _emptyMessage() {
    switch (_filter) {
      case _TaskFilter.due:
        return 'Nothing due in the next 24 hours.';
      case _TaskFilter.overdue:
        return 'No overdue tasks. Nice!';
      case _TaskFilter.complete:
        return 'No completed tasks yet.';
      default:
        return 'No tasks here.';
    }
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.pop(context),
          ),
          const SizedBox(width: 4),
          CircleAvatar(
            radius: 22,
            backgroundColor: Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Image.asset(widget.folderIcon, fit: BoxFit.contain),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.folderName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: TaskService.streamTasksByFolder(widget.folderId),
                  builder: (context, snapshot) {
                    final docs = snapshot.data?.docs ?? [];
                    final total = docs.length;
                    final notDone = docs
                        .where((d) => _stateOf(d) != TaskState.completed)
                        .length;
                    final overdue = docs
                        .where((d) => _stateOf(d) == TaskState.overdue)
                        .length;
                    return Text(
                      '$total task${total == 1 ? '' : 's'} • '
                      '$notDone not complete'
                      '${overdue > 0 ? ' • $overdue overdue' : ''}',
                      style: TextStyle(
                        color: overdue > 0
                            ? const Color(0xFFFFCDD2)
                            : Colors.white70,
                        fontSize: 12,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterTabs() {
    final options = {
      _TaskFilter.all: 'ALL',
      _TaskFilter.notComplete: 'Pending',
      _TaskFilter.due: 'Due',
      _TaskFilter.overdue: 'Overdue',
      _TaskFilter.complete: 'Done',
    };
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: options.entries.map((entry) {
          final isSelected = _filter == entry.key;
          final selectedColor = entry.key == _TaskFilter.overdue
              ? TaskStateHelper.overdueColor
              : entry.key == _TaskFilter.due
              ? TaskStateHelper.dueColor
              : const Color(0xFFE8543D);
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(entry.value),
              selected: isSelected,
              showCheckmark: false,
              onSelected: (_) => setState(() => _filter = entry.key),
              selectedColor: selectedColor,
              backgroundColor: Colors.white,
              labelStyle: TextStyle(
                color: isSelected ? Colors.white : Colors.black87,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide.none,
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildTaskCard(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    final isDone = data['status'] == 'completed';
    final ts = data['task_datetime'] as Timestamp?;

    return TaskCard(
      title: data['title'] ?? '',
      folderName: widget.folderName,
      due: ts?.toDate(),
      isDone: isDone,
      showFolder: false,
      onToggle: (v) => TaskService.toggleTaskStatus(doc.id, v ?? false),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => EditTaskScreen(
              taskId: doc.id,
              folderName: widget.folderName,
              title: data['title'] ?? '',
              description: data['description'] as String?,
              taskDatetime: ts?.toDate() ?? DateTime.now(),
              isCompleted: isDone,
            ),
          ),
        );
      },
    );
  }
}
