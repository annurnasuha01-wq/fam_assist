import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/folder_service.dart';
import '../services/task_service.dart';

/// "Add task" bottom sheet for creating a task by TYPING (no microphone).
/// Same look as the Dashboard's other sheets: white, rounded top, accent pill
/// button. Works for guests and registered users.
///
/// Folder: pick an existing one, or choose "+ New folder" and type a name.
/// The name is checked with FolderService.findOrCreateFolder, so typing
/// "maryam" when "Maryam" exists reuses it instead of making a duplicate.
///
/// Rules match the Edit Task screen: no past date/time, title required.
///
/// Usage:
///   final msg = await AddTaskSheet.show(context, folders: _folders);
///   if (msg != null) _showSnack(msg);
class AddTaskSheet extends StatefulWidget {
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> folders;

  const AddTaskSheet({super.key, required this.folders});

  /// Returns the success message (e.g. "Task saved! Alarm set."), or null if
  /// the sheet was closed without saving.
  static Future<String?> show(
    BuildContext context, {
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> folders,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddTaskSheet(folders: folders),
    );
  }

  @override
  State<AddTaskSheet> createState() => _AddTaskSheetState();
}

class _AddTaskSheetState extends State<AddTaskSheet> {
  static const Color _accent = Color(0xFFE8543D);
  static const String _newFolderKey = '__new_folder__';

  final _titleController = TextEditingController();
  final _descController = TextEditingController();
  final _newFolderController = TextEditingController();

  late List<String> _folderNames;
  String? _folder; // an existing name, or _newFolderKey
  late DateTime _date;
  late TimeOfDay _time;
  bool _saving = false;
  String? _error;

  bool get _typingNewFolder => _folder == _newFolderKey;

  @override
  void initState() {
    super.initState();
    _folderNames = widget.folders
        .map((d) => (d.data()['folder_name'] as String?) ?? '')
        .where((n) => n.isNotEmpty)
        .toList();
    // No folders yet (e.g. a new guest): go straight to "type a name".
    if (_folderNames.isEmpty) _folder = _newFolderKey;

    // Default: the next full hour.
    final base = DateTime.now().add(const Duration(hours: 1));
    _date = DateTime(base.year, base.month, base.day);
    _time = TimeOfDay(hour: base.hour, minute: 0);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descController.dispose();
    _newFolderController.dispose();
    super.dispose();
  }

  DateTime get _combined =>
      DateTime(_date.year, _date.month, _date.day, _time.hour, _time.minute);

  ThemeData _pickerTheme(BuildContext context) => Theme.of(context).copyWith(
    colorScheme: Theme.of(context).colorScheme.copyWith(primary: _accent),
  );

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: _date.isBefore(today) ? today : _date,
      firstDate: today,
      lastDate: today.add(const Duration(days: 365 * 5)),
      builder: (context, child) =>
          Theme(data: _pickerTheme(context), child: child!),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time,
      builder: (context, child) =>
          Theme(data: _pickerTheme(context), child: child!),
    );
    if (picked != null) setState(() => _time = picked);
  }

  void _setQuickDate(int daysFromToday) {
    final now = DateTime.now();
    final d = DateTime(now.year, now.month, now.day + daysFromToday);
    setState(() => _date = d);
  }

  bool _isDate(int daysFromToday) {
    final now = DateTime.now();
    final d = DateTime(now.year, now.month, now.day + daysFromToday);
    return _date.year == d.year && _date.month == d.month && _date.day == d.day;
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    final folderName = _typingNewFolder
        ? _newFolderController.text.trim()
        : (_folder ?? '');

    String? problem;
    if (title.isEmpty) {
      problem = 'Please enter what the task is.';
    } else if (folderName.isEmpty) {
      problem = _typingNewFolder
          ? 'Please type the family member name for the new folder.'
          : 'Please choose a folder.';
    } else if (_combined.isBefore(DateTime.now())) {
      problem = 'That date/time has already passed. Pick a future time.';
    }
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });

    final folder = await FolderService.findOrCreateFolder(folderName);
    if (!mounted) return;
    if (!folder.success || folder.folderId == null) {
      setState(() {
        _saving = false;
        _error = folder.errorMessage ?? 'Could not prepare the folder.';
      });
      return;
    }

    final desc = _descController.text.trim();
    final result = await TaskService.createTask(
      folderId: folder.folderId!,
      folderName: folder.folderName ?? folderName,
      title: title,
      taskDatetime: _combined,
      description: desc.isEmpty ? null : desc,
    );
    if (!mounted) return;

    if (!result.success) {
      setState(() {
        _saving = false;
        _error = result.errorMessage ?? 'Failed to save task.';
      });
      return;
    }

    final shownName = folder.folderName ?? folderName;
    Navigator.pop(
      context,
      folder.created
          ? 'Task saved in new folder "$shownName". Alarm set.'
          : 'Task saved to "$shownName". Alarm set.',
    );
  }

  InputDecoration _fieldDecoration(String hint) => InputDecoration(
    hintText: hint,
    filled: true,
    fillColor: Colors.grey[100],
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide.none,
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  );

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.w500)),
  );

  Widget _pickerTile({
    required IconData icon,
    required String text,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: _saving ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.grey[100],
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: _accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _quickChip(String label, int days) {
    final selected = _isDate(days);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        onSelected: _saving ? null : (_) => _setQuickDate(days),
        selectedColor: _accent,
        backgroundColor: Colors.grey[100],
        labelStyle: TextStyle(
          color: selected ? Colors.white : Colors.black87,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide.none,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Add Task',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                'Type a task instead of using the microphone.',
                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
              ),
              const SizedBox(height: 16),

              _label('Task:'),
              TextField(
                controller: _titleController,
                enabled: !_saving,
                textCapitalization: TextCapitalization.sentences,
                decoration: _fieldDecoration('e.g. Book hotel'),
              ),
              const SizedBox(height: 14),

              _label('Folder:'),
              if (_folderNames.isNotEmpty)
                DropdownButtonFormField<String>(
                  value: _folder,
                  isExpanded: true,
                  decoration: _fieldDecoration('Choose folder'),
                  items: [
                    for (final n in _folderNames)
                      DropdownMenuItem(value: n, child: Text(n)),
                    const DropdownMenuItem(
                      value: _newFolderKey,
                      child: Text(
                        '+ New folder',
                        style: TextStyle(color: _accent),
                      ),
                    ),
                  ],
                  onChanged: _saving
                      ? null
                      : (v) => setState(() => _folder = v),
                ),
              if (_typingNewFolder) ...[
                if (_folderNames.isNotEmpty) const SizedBox(height: 8),
                TextField(
                  controller: _newFolderController,
                  enabled: !_saving,
                  textCapitalization: TextCapitalization.words,
                  decoration: _fieldDecoration(
                    'Family member name, e.g. Maryam',
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'If this folder already exists it is reused, '
                    'otherwise it is created for you.',
                    style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                  ),
                ),
              ],
              const SizedBox(height: 14),

              _label('When:'),
              Row(
                children: [_quickChip('Today', 0), _quickChip('Tomorrow', 1)],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: _pickerTile(
                      icon: Icons.calendar_today_outlined,
                      text: DateFormat('EEE, d MMM yyyy').format(_date),
                      onTap: _pickDate,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _pickerTile(
                      icon: Icons.access_time,
                      text: _time.format(context),
                      onTap: _pickTime,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              _label('Notes (optional):'),
              TextField(
                controller: _descController,
                enabled: !_saving,
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: _fieldDecoration('Add details'),
              ),

              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ],
              const SizedBox(height: 20),

              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: _saving ? null : () => Navigator.pop(context),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: Text(
                        'Cancel',
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _saving ? null : _save,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _accent,
                        disabledBackgroundColor: Colors.grey[400],
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                      ),
                      child: _saving
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : const Text(
                              'Save',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.white,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
