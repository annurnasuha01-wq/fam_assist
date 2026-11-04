import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/task_service.dart';
import '../utils/task_state.dart';
import '../widgets/task_card.dart';
import 'edit_task_screen.dart';

/// Opened from the Dashboard's "Latest Task -> All" link.
///
/// LAYOUT
///   - Header (back / title / Select)          -> fixed
///   - Filter panel (search, date, status)     -> fixed, never scrolls away
///   - Task list                               -> the ONLY part that scrolls
///   - Delete bar (only in Select mode)        -> fixed at the bottom
///
/// FILTERS
///   Date    : All dates / Today / Week / Month / Pick (from – until)
///   Status  : All / Due / Overdue / Pending / Done
///   Search  : task name or folder name
///
/// DELETE MANY
///   Tap "Select" (or long-press any task) -> tick the tasks -> Delete.
class AllTasksScreen extends StatefulWidget {
  const AllTasksScreen({super.key});

  @override
  State<AllTasksScreen> createState() => _AllTasksScreenState();
}

enum _StatusFilter { all, due, overdue, pending, done }

enum _QuickRange { allDates, today, thisWeek, thisMonth, custom }

class _AllTasksScreenState extends State<AllTasksScreen> {
  static const Color _accent = Color(0xFFE8543D);
  static const String _overdueKey = 'OVERDUE';

  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  _StatusFilter _status = _StatusFilter.all;
  _QuickRange _quick = _QuickRange.allDates;
  DateTimeRange? _range; // inclusive start & end DAYS

  // ---- select / delete ----
  bool _selectMode = false;
  bool _deleting = false;
  final Set<String> _selectedIds = {};
  List<String> _visibleIds = [];

  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Re-evaluate Overdue / Due as the clock moves.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  TaskState _stateOf(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    final data = d.data();
    return TaskStateHelper.of(
      isCompleted: data['status'] == 'completed',
      due: (data['task_datetime'] as Timestamp?)?.toDate(),
    );
  }

  // ---------------- date range ----------------

  DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  void _applyQuick(_QuickRange quick) {
    final today = _day(DateTime.now());
    setState(() {
      _quick = quick;
      switch (quick) {
        case _QuickRange.allDates:
          _range = null;
        case _QuickRange.today:
          _range = DateTimeRange(start: today, end: today);
        case _QuickRange.thisWeek:
          final monday = today.subtract(Duration(days: today.weekday - 1));
          _range = DateTimeRange(
            start: monday,
            end: monday.add(const Duration(days: 6)),
          );
        case _QuickRange.thisMonth:
          _range = DateTimeRange(
            start: DateTime(today.year, today.month, 1),
            end: DateTime(today.year, today.month + 1, 0),
          );
        case _QuickRange.custom:
          break;
      }
    });
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2, 1, 1),
      lastDate: DateTime(now.year + 5, 12, 31),
      initialDateRange: _range,
      helpText: 'Select period (from – until)',
      saveText: 'Apply',
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(
              context,
            ).colorScheme.copyWith(primary: _accent),
          ),
          child: child!,
        );
      },
    );
    if (picked == null) return;
    setState(() {
      _quick = _QuickRange.custom;
      _range = DateTimeRange(start: _day(picked.start), end: _day(picked.end));
    });
  }

  // ---------------- filtering / grouping ----------------

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _filterAndSort(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final q = _query.trim().toLowerCase();

    final filtered = docs.where((d) {
      final data = d.data();
      final state = _stateOf(d);

      switch (_status) {
        case _StatusFilter.all:
          break;
        case _StatusFilter.due:
          if (state != TaskState.dueSoon) return false;
        case _StatusFilter.overdue:
          if (state != TaskState.overdue) return false;
        case _StatusFilter.pending:
          if (state == TaskState.completed) return false;
        case _StatusFilter.done:
          if (state != TaskState.completed) return false;
      }

      if (_range != null) {
        final ts = data['task_datetime'] as Timestamp?;
        if (ts == null) return false;
        final dt = ts.toDate();
        final start = _range!.start;
        final endExclusive = DateTime(
          _range!.end.year,
          _range!.end.month,
          _range!.end.day + 1,
        );
        if (dt.isBefore(start) || !dt.isBefore(endExclusive)) return false;
      }

      if (q.isNotEmpty) {
        final title = (data['title'] as String? ?? '').toLowerCase();
        final folder = (data['folder_name'] as String? ?? '').toLowerCase();
        if (!title.contains(q) && !folder.contains(q)) return false;
      }
      return true;
    }).toList();

    filtered.sort((a, b) {
      final ta = (a.data()['task_datetime'] as Timestamp?)?.toDate();
      final tb = (b.data()['task_datetime'] as Timestamp?)?.toDate();
      if (ta == null && tb == null) return 0;
      if (ta == null) return 1;
      if (tb == null) return -1;
      return ta.compareTo(tb);
    });
    return filtered;
  }

  /// Overdue tasks first (one red section), then the rest grouped by date.
  Map<String, List<QueryDocumentSnapshot<Map<String, dynamic>>>> _groupByDate(
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

  // ---------------- select / delete ----------------

  void _enterSelectMode([String? firstId]) {
    setState(() {
      _selectMode = true;
      _selectedIds.clear();
      if (firstId != null) _selectedIds.add(firstId);
    });
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelect(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
    });
  }

  bool get _allVisibleSelected =>
      _visibleIds.isNotEmpty && _visibleIds.every(_selectedIds.contains);

  void _toggleSelectAll() {
    setState(() {
      if (_allVisibleSelected) {
        _selectedIds.removeAll(_visibleIds);
      } else {
        _selectedIds.addAll(_visibleIds);
      }
    });
  }

  Future<void> _confirmDelete() async {
    final count = _selectedIds.length;
    if (count == 0) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Delete $count task${count == 1 ? '' : 's'}?',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'The selected tasks and their alarms will be permanently deleted. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel', style: TextStyle(color: Colors.grey[700])),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _deleting = true);
    final result = await TaskService.deleteTasks(_selectedIds.toList());
    if (!mounted) return;
    setState(() => _deleting = false);

    if (result.success) {
      _exitSelectMode();
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.success
              ? '$count task${count == 1 ? '' : 's'} deleted.'
              : (result.errorMessage ?? 'Failed to delete.'),
        ),
      ),
    );
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_selectMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitSelectMode(); // back button leaves Select mode first
      },
      child: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset('assets/bg.png', fit: BoxFit.cover),
            SafeArea(
              child: Column(
                children: [
                  _buildHeader(),
                  const SizedBox(height: 10),
                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      clipBehavior: Clip.antiAlias,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(20),
                        ),
                      ),
                      child: Column(
                        children: [
                          _buildFilterPanel(), // fixed
                          Divider(height: 1, color: Colors.grey[200]),
                          Expanded(child: _buildList()), // scrolls
                          if (_selectMode) _buildDeleteBar(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_deleting)
              Container(
                color: Colors.black26,
                child: const Center(
                  child: CircularProgressIndicator(color: _accent),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              _selectMode ? Icons.close : Icons.arrow_back,
              color: Colors.white,
            ),
            onPressed: _selectMode
                ? _exitSelectMode
                : () => Navigator.pop(context),
          ),
          Expanded(
            child: Text(
              _selectMode ? '${_selectedIds.length} selected' : 'All Tasks',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (_selectMode)
            TextButton(
              onPressed: _toggleSelectAll,
              child: Text(
                _allVisibleSelected ? 'Unselect all' : 'Select all',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            )
          else
            TextButton.icon(
              onPressed: () => _enterSelectMode(),
              icon: const Icon(Icons.checklist, color: Colors.white, size: 20),
              label: const Text(
                'Select',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---- fixed filter panel ----

  Widget _buildFilterPanel() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: Column(
        children: [
          _buildSearchField(),
          const SizedBox(height: 10),
          // Date row — 5 equal pills that always fit the width.
          _pillRow([
            _PillData(
              label: 'All dates',
              selected: _quick == _QuickRange.allDates,
              onTap: () => _applyQuick(_QuickRange.allDates),
            ),
            _PillData(
              label: 'Today',
              selected: _quick == _QuickRange.today,
              onTap: () => _applyQuick(_QuickRange.today),
            ),
            _PillData(
              label: 'Week',
              selected: _quick == _QuickRange.thisWeek,
              onTap: () => _applyQuick(_QuickRange.thisWeek),
            ),
            _PillData(
              label: 'Month',
              selected: _quick == _QuickRange.thisMonth,
              onTap: () => _applyQuick(_QuickRange.thisMonth),
            ),
            _PillData(
              label: 'Pick',
              icon: Icons.date_range,
              selected: _quick == _QuickRange.custom,
              onTap: _pickCustomRange,
            ),
          ]),
          if (_range != null) ...[const SizedBox(height: 8), _buildRangeInfo()],
          const SizedBox(height: 8),
          // Status row — 5 equal pills.
          _pillRow([
            _PillData(
              label: 'All',
              selected: _status == _StatusFilter.all,
              onTap: () => setState(() => _status = _StatusFilter.all),
            ),
            _PillData(
              label: 'Due',
              selected: _status == _StatusFilter.due,
              color: TaskStateHelper.dueColor,
              onTap: () => setState(() => _status = _StatusFilter.due),
            ),
            _PillData(
              label: 'Overdue',
              selected: _status == _StatusFilter.overdue,
              color: TaskStateHelper.overdueColor,
              onTap: () => setState(() => _status = _StatusFilter.overdue),
            ),
            _PillData(
              label: 'Pending',
              selected: _status == _StatusFilter.pending,
              onTap: () => setState(() => _status = _StatusFilter.pending),
            ),
            _PillData(
              label: 'Done',
              selected: _status == _StatusFilter.done,
              color: TaskStateHelper.completedColor,
              onTap: () => setState(() => _status = _StatusFilter.done),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _buildSearchField() {
    return SizedBox(
      height: 42,
      child: TextField(
        controller: _searchController,
        onChanged: (v) => setState(() => _query = v),
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          hintText: 'Search task or folder name',
          hintStyle: TextStyle(fontSize: 13, color: Colors.grey[500]),
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _query = '');
                  },
                ),
          filled: true,
          fillColor: Colors.grey[100],
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 0),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _pillRow(List<_PillData> pills) {
    return Row(
      children: [
        for (int i = 0; i < pills.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(child: _pill(pills[i])),
        ],
      ],
    );
  }

  Widget _pill(_PillData p) {
    final fg = p.selected ? Colors.white : Colors.black87;
    return GestureDetector(
      onTap: p.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: p.selected ? p.color : Colors.grey[100],
          borderRadius: BorderRadius.circular(17),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (p.icon != null) ...[
                  Icon(
                    p.icon,
                    size: 14,
                    color: p.selected ? Colors.white : p.color,
                  ),
                  const SizedBox(width: 3),
                ],
                Text(
                  p.label,
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRangeInfo() {
    final fmt = DateFormat('d MMM yyyy');
    final r = _range!;
    final text = r.start == r.end
        ? fmt.format(r.start)
        : '${fmt.format(r.start)}  →  ${fmt.format(r.end)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF1EE),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.event, size: 16, color: _accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          InkWell(
            onTap: _pickCustomRange,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                'Change',
                style: TextStyle(fontSize: 12, color: _accent),
              ),
            ),
          ),
          InkWell(
            onTap: () => _applyQuick(_QuickRange.allDates),
            child: const Icon(Icons.close, size: 16, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  // ---- scrolling list ----

  Widget _buildList() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: TaskService.streamAllUserTasks(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text(
              'Could not load tasks.',
              style: TextStyle(color: Colors.grey[500]),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator(color: _accent));
        }

        final filtered = _filterAndSort(snapshot.data!.docs);
        _visibleIds = filtered.map((d) => d.id).toList();

        if (filtered.isEmpty) {
          return Center(
            child: Text(
              'No tasks found.',
              style: TextStyle(color: Colors.grey[500]),
            ),
          );
        }

        final grouped = _groupByDate(filtered);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Text(
                '${filtered.length} task${filtered.length == 1 ? '' : 's'}',
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                children: grouped.entries.expand((entry) {
                  final isOverdueSection = entry.key == _overdueKey;
                  return [
                    Padding(
                      padding: const EdgeInsets.only(top: 12, bottom: 6),
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
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTaskCard(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    final isDone = data['status'] == 'completed';
    final ts = data['task_datetime'] as Timestamp?;
    final folderName = (data['folder_name'] as String?) ?? '';

    return TaskCard(
      title: data['title'] ?? '',
      folderName: folderName,
      due: ts?.toDate(),
      isDone: isDone,
      selectMode: _selectMode,
      selected: _selectedIds.contains(doc.id),
      onToggle: _selectMode
          ? null
          : (v) => TaskService.toggleTaskStatus(doc.id, v ?? false),
      onLongPress: _selectMode ? null : () => _enterSelectMode(doc.id),
      onTap: () {
        if (_selectMode) {
          _toggleSelect(doc.id);
          return;
        }
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => EditTaskScreen(
              taskId: doc.id,
              folderName: folderName,
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

  // ---- delete bar (Select mode) ----

  Widget _buildDeleteBar() {
    final count = _selectedIds.length;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 8,
            offset: Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: (count == 0 || _deleting) ? null : _confirmDelete,
              icon: const Icon(Icons.delete, color: Colors.white),
              label: Text(
                count == 0
                    ? 'Tick tasks to delete'
                    : 'Delete $count task${count == 1 ? '' : 's'}',
                style: const TextStyle(color: Colors.white),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                disabledBackgroundColor: Colors.red.withOpacity(0.35),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PillData {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final Color color;

  const _PillData({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.color = const Color(0xFFE8543D),
  });
}
