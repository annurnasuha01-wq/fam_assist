import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../services/auth_service.dart';
import '../services/folder_service.dart';
import '../services/task_service.dart';
import '../services/voice_task_parser.dart';
import '../services/voice_input_service.dart';
import '../services/voice_folder_guesser.dart';
import '../services/guest_carry_over.dart';
import '../services/nlp_pipeline.dart';
import '../services/notification_scheduler.dart';
import '../utils/task_state.dart';
import '../widgets/task_card.dart';
import '../widgets/add_task_sheet.dart';
import 'all_tasks_screen.dart';
import 'edit_task_screen.dart';
import 'create_folder_screen.dart';
import 'edit_profile_screen.dart';
import 'folder_task_list_screen.dart';
import 'login_screen.dart';
import 'register_screen.dart';

/// One continuous run of the phone's speech recogniser. Android ends a run on
/// its own after a short silence, so ONE recording can consist of several
/// runs that are stitched together (see _scheduleRestart).
class _SpeechSession {
  String primary = '';
  List<String> alts = [];
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with WidgetsBindingObserver {
  static const Color _accent = Color(0xFFE8543D);
  static const String _newFolderSentinel = '__new_folder__';

  final stt.SpeechToText _speech = stt.SpeechToText();

  // ---- recording state ----
  bool _isListening = false; // UI state
  bool _userWantsListening = false; // true from first tap until second tap
  bool _isStopping = false;
  bool _isStarting = false;
  bool _restartPending = false;
  bool _speechReady = false;
  int _consecutiveEmpty = 0;

  static const int _maxRecordingSeconds = 120;
  Timer? _maxTimer;

  final List<_SpeechSession> _sessions = [];
  final ValueNotifier<String> _liveText = ValueNotifier('');
  final ValueNotifier<double> _level = ValueNotifier(0);
  final ValueNotifier<bool> _quietWarning = ValueNotifier(false);
  DateTime _lastLoudAt = DateTime.now();

  /// 'auto' | 'ms' | 'en' — chosen in Profile > Voice language.
  String _voicePref = 'auto';
  String? _localeId;

  /// Language of the "Voice Guide" panel: 'en' | 'ms'
  String _instrLang = 'en';

  /// Hands-free: when every task in a recording is understood, save it right
  /// away (no confirm screen) and offer UNDO. Profile > Hands-free save.
  bool _autoSave = false;

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _folders = [];
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _folderStream;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _folderSubscription;

  String _username = '';
  bool _showAllFolders = false;
  bool _loggingOut = false; // blocks double taps while logging out
  Timer? _tick;
  int _tickCount = 0;

  @override
  void initState() {
    super.initState();
    _folderStream = FolderService.streamUserFolders();
    _folderSubscription = _folderStream.listen(
      (snapshot) {
        if (mounted) setState(() => _folders = snapshot.docs);
      },
      onError: (error) {
        debugPrint('Folder stream error: $error');
        if (mounted) {
          _showSnack(
            'Could not refresh folders. Pull down or restart to retry.',
          );
        }
      },
    );
    _loadUsername();
    _loadVoicePref();
    // Re-arm alarms on this device for every pending future task.
    WidgetsBinding.instance.addObserver(this);
    unawaited(_importCarryOverThenSync());
    // Keep Overdue / Due labels fresh as time passes.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      setState(() {});
      _tickCount++;
      if (_tickCount % 4 == 0) unawaited(_syncAlarmsAndStatuses()); // ~2 min
    });
  }

  /// 1) applies Done / Dismiss presses made on the alarm while the app was
  ///    closed, 2) marks past-due pending tasks as 'overdue' in the database,
  ///    3) re-arms alarms for upcoming tasks on this device.
  Future<void> _syncAlarmsAndStatuses() async {
    await NotificationScheduler.applyPendingActions();
    await TaskService.markOverdueTasks();
    await NotificationScheduler.syncAll();
  }

  /// A guest who logged in to an EXISTING account has their guest folders and
  /// tasks copied into it here (see GuestCarryOver), then alarms are synced.
  Future<void> _importCarryOverThenSync() async {
    final imported = await GuestCarryOver.importIfAny();
    if (imported > 0) {
      _showSnack(
        imported == 1
            ? '1 guest task was added to your account.'
            : '$imported guest tasks were added to your account.',
      );
    }
    await _syncAlarmsAndStatuses();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_syncAlarmsAndStatuses());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _userWantsListening = false;
    _maxTimer?.cancel();
    _tick?.cancel();
    if (_isListening) {
      _speech.cancel();
    }
    _folderSubscription?.cancel();
    _liveText.dispose();
    _level.dispose();
    _quietWarning.dispose();
    super.dispose();
  }

  Future<void> _loadUsername() async {
    final user = AuthService.currentUser;
    if (user == null) return;
    // Guest (anonymous) sessions have no profile document.
    if (user.isAnonymous) {
      if (mounted) setState(() => _username = 'Guest');
      return;
    }
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    if (mounted) {
      setState(() {
        _username = doc.data()?['username'] ?? 'User';
      });
    }
  }

  Future<void> _loadVoicePref() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('voice_lang_pref') ?? 'auto';
    final instr = prefs.getString('instr_lang') ?? 'en';
    final auto = prefs.getBool('auto_save_voice') ?? false;
    if (mounted) {
      setState(() {
        _voicePref = saved;
        _instrLang = instr;
        _autoSave = auto;
      });
    }
  }

  Future<void> _setInstrLang(String lang) async {
    setState(() => _instrLang = lang);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('instr_lang', lang);
  }

  Future<void> _setVoicePref(String pref) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('voice_lang_pref', pref);
    if (!mounted) return;
    setState(() {
      _voicePref = pref;
      _localeId = null; // re-resolve on next recording
    });
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good Morning';
    if (hour < 17) return 'Good Afternoon';
    if (hour < 21) return 'Good Evening';
    return 'Good Night';
  }

  // ======================= Voice recording =======================
  //
  // TAP once = start, TAP again = stop.
  //
  // Why recordings used to "miss" speech: Android's recogniser quietly ends
  // after a short silence (or noise burst), and the old code treated that as
  // "the user finished" and processed whatever little it had. Now the app
  // keeps listening — it restarts the recogniser automatically and joins all
  // the pieces — until YOU tap stop (or 2 minutes / ~30 s of pure silence).

  void _onSpeechStatus(String status) {
    if (!mounted) return;
    if ((status == 'done' || status == 'notListening') &&
        _userWantsListening &&
        !_isStopping) {
      _scheduleRestart();
    }
  }

  void _onSpeechError(dynamic error) {
    if (!mounted) return;
    var msg = '';
    var permanent = false;
    try {
      msg = '${error.errorMsg}';
      permanent = error.permanent == true;
    } catch (_) {}
    debugPrint('Speech error: $msg (permanent: $permanent)');

    if (!_userWantsListening || _isStopping) return;

    const recoverable = {
      'error_no_match',
      'error_speech_timeout',
      'error_busy',
      'error_client',
    };
    if (recoverable.contains(msg) || !permanent) {
      _scheduleRestart(
        delay: Duration(milliseconds: msg == 'error_busy' ? 800 : 350),
      );
      return;
    }
    _abortRecording('Speech recognition problem ($msg). Please try again.');
  }

  Future<void> _scheduleRestart({
    Duration delay = const Duration(milliseconds: 300),
  }) async {
    if (_restartPending || !_userWantsListening || _isStopping) return;
    _restartPending = true;
    _consecutiveEmpty++;

    // ~8 restarts in a row with nothing heard = long silence -> finish.
    if (_consecutiveEmpty > 8) {
      _restartPending = false;
      await _stopListening();
      return;
    }

    await Future.delayed(delay);
    _restartPending = false;
    if (!mounted || !_userWantsListening || _isStopping) return;
    await _beginSession();
  }

  Future<void> _abortRecording(String message) async {
    _userWantsListening = false;
    _maxTimer?.cancel();
    await _speech.cancel();
    if (!mounted) return;
    setState(() => _isListening = false);
    _level.value = 0;
    final candidates = _buildCandidates();
    if (candidates.isNotEmpty) {
      await _processVoiceCommand(candidates);
    } else {
      _showSnack(message);
    }
  }

  void _onSoundLevel(double level) {
    // Android reports roughly -2 .. 10.
    final normalized = ((level + 2) / 12).clamp(0.0, 1.0);
    _level.value = normalized;
    final now = DateTime.now();
    if (normalized > 0.2) _lastLoudAt = now;
    _quietWarning.value = now.difference(_lastLoudAt).inSeconds >= 5;

    // Hands-free: once something was said and it has been quiet for ~4 s,
    // finish the recording by itself (no second tap needed).
    if (_autoSave &&
        _isListening &&
        !_isStopping &&
        _fullTranscript().isNotEmpty &&
        now.difference(_lastLoudAt).inSeconds >= 4) {
      unawaited(_stopListening());
    }
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    if (!mounted || _sessions.isEmpty) return;
    final session = _sessions.last;
    final words = result.recognizedWords;
    session.primary = words;
    if (words.trim().isNotEmpty) _consecutiveEmpty = 0;

    if (result.finalResult) {
      // Other things the engine thought it might have heard — used later to
      // rescue names it got wrong (e.g. "eva" instead of "Iwa").
      session.alts = result.alternates
          .map((a) => a.recognizedWords.trim())
          .where((t) => t.isNotEmpty && t != words.trim())
          .toSet()
          .take(4)
          .toList();

      if (result.confidence > 0 && result.confidence < 0.4) {
        _showSnack("Didn't catch that clearly — try again somewhere quieter.");
      }
    }
    _liveText.value = _fullTranscript();
  }

  String _fullTranscript() => _sessions
      .map((s) => s.primary.trim())
      .where((t) => t.isNotEmpty)
      .join(', ');

  /// The main transcript plus variants where ONE session is swapped for one
  /// of the engine's alternative hearings. The parser later picks whichever
  /// variant produces the most valid tasks.
  List<String> _buildCandidates() {
    final sessions = _sessions
        .where((s) => s.primary.trim().isNotEmpty)
        .toList();
    if (sessions.isEmpty) return [];

    String join(List<String> parts) =>
        parts.map((p) => p.trim()).where((p) => p.isNotEmpty).join(', ');

    final primaries = sessions.map((s) => s.primary).toList();
    final result = <String>[join(primaries)];
    for (int i = 0; i < sessions.length; i++) {
      for (final alt in sessions[i].alts) {
        final copy = [...primaries];
        copy[i] = alt;
        final text = join(copy);
        if (!result.contains(text)) result.add(text);
      }
    }
    return result.take(12).toList();
  }

  Future<void> _toggleRecording() async {
    if (_isStarting || _isStopping) return;
    if (_isListening) {
      await _stopListening();
    } else {
      await _startListening();
    }
  }

  /// Picks the speech locale. 'auto' follows the phone's language; 'ms' / 'en'
  /// come from Profile > Voice language.
  Future<String?> _resolveLocale() async {
    final locales = await _speech.locales();
    if (locales.isEmpty) return null;

    String norm(String id) => id.toLowerCase().replaceAll('-', '_');

    String? findBy(bool Function(String id) test) {
      for (final l in locales) {
        if (test(norm(l.localeId))) return l.localeId;
      }
      return null;
    }

    String? pickMalay() =>
        findBy((id) => id.startsWith('ms_my')) ??
        findBy((id) => id.startsWith('ms_')) ??
        // No Malay voice pack installed -> Indonesian is the closest.
        findBy((id) => id.startsWith('id_'));

    String? pickEnglish() =>
        findBy((id) => id.startsWith('en_my')) ??
        findBy((id) => id.startsWith('en_sg')) ??
        findBy((id) => id.startsWith('en_gb')) ??
        findBy((id) => id.startsWith('en_us')) ??
        findBy((id) => id.startsWith('en_'));

    String? match;
    if (_voicePref == 'ms') {
      match = pickMalay();
    } else if (_voicePref == 'en') {
      match = pickEnglish();
    } else {
      final deviceLocale = WidgetsBinding.instance.platformDispatcher.locale;
      final deviceLang = deviceLocale.languageCode.toLowerCase();
      final deviceRegion = (deviceLocale.countryCode ?? '').toLowerCase();

      if (deviceRegion.isNotEmpty) {
        match = findBy((id) => id.startsWith('${deviceLang}_$deviceRegion'));
      }
      match ??= findBy((id) => id.startsWith('${deviceLang}_'));
      if (match == null && deviceLang == 'ms') match = pickMalay();
    }
    match ??= pickMalay();
    match ??= pickEnglish();
    match ??= locales.first.localeId;
    return match;
  }

  Future<void> _startListening() async {
    if (_isListening || _isStarting) return;
    _isStarting = true;
    try {
      if (!_speechReady) {
        _speechReady = await _speech.initialize(
          onStatus: _onSpeechStatus,
          onError: _onSpeechError,
        );
      }
      if (!mounted) return;
      if (!_speechReady) {
        _showSnack(
          'Speech recognition is not available. Check the microphone '
          'permission and that "Speech Recognition & Synthesis by Google" '
          'is installed.',
        );
        return;
      }

      _localeId ??= await _resolveLocale();
      if (!mounted) return;
      debugPrint('Using speech locale: $_localeId');

      _sessions.clear();
      _consecutiveEmpty = 0;
      _liveText.value = '';
      _level.value = 0;
      _lastLoudAt = DateTime.now();
      _quietWarning.value = false;

      setState(() {
        _isListening = true;
        _isStopping = false;
      });
      _userWantsListening = true;

      _maxTimer?.cancel();
      _maxTimer = Timer(const Duration(seconds: _maxRecordingSeconds), () {
        if (_isListening) _stopListening();
      });

      await _beginSession();
    } finally {
      _isStarting = false;
    }
  }

  Future<void> _beginSession() async {
    if (!mounted || !_userWantsListening) return;
    if (_speech.isListening) return;

    // Reuse the last (still empty) session instead of piling up blanks.
    if (_sessions.isEmpty || _sessions.last.primary.trim().isNotEmpty) {
      _sessions.add(_SpeechSession());
    }

    try {
      await _speech.listen(
        onResult: _onSpeechResult,
        onSoundLevelChange: _onSoundLevel,
        localeId: _localeId,
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.dictation,
          cancelOnError: false,
          partialResults: true,
          // Lets the engine insert commas on natural pauses — the multi-task
          // splitter uses them to separate tasks.
          autoPunctuation: true,
        ),
        pauseFor: const Duration(seconds: 12),
        listenFor: const Duration(seconds: 60),
      );
    } catch (e) {
      debugPrint('listen() failed: $e');
      _scheduleRestart(delay: const Duration(milliseconds: 800));
    }
  }

  Future<void> _stopListening() async {
    if (!_isListening || _isStopping) return;
    _isStopping = true;
    _userWantsListening = false; // stops the auto-restart
    _maxTimer?.cancel();

    await _speech.stop();
    // Give the engine a moment to deliver the FINAL result (it contains the
    // alternative hearings used for name rescue).
    await Future.delayed(const Duration(milliseconds: 700));

    if (!mounted) return;
    setState(() => _isListening = false);
    _isStopping = false;
    _level.value = 0;

    final candidates = _buildCandidates();
    if (candidates.isEmpty) {
      _showSnack('No speech detected. Please try again.');
      return;
    }
    await _processVoiceCommand(candidates);
  }

  /// Parses every candidate transcript and keeps the one that yields the most
  /// valid tasks (ties go to the engine's main transcript).
  String _pickBestTranscript(
    List<String> candidates,
    List<String> folderNames,
  ) {
    var best = candidates.first;
    var bestScore = -1.0;
    for (final c in candidates) {
      final parsed = VoiceFolderGuesser.parse(c, folderNames).tasks;
      final valid = parsed.where((p) => p.isValid).length;
      final folderOnly = parsed.where((p) => p.needsFolderOnly).length;
      final conf = parsed.fold<double>(0, (s, p) => s + p.confidence);
      final score = valid * 1000 + folderOnly * 100 + conf;
      if (score > bestScore) {
        bestScore = score;
        best = c;
      }
    }
    return best;
  }

  /// A voice task whose date/time has already passed can't be saved (you
  /// can't set a reminder in the past). 1-minute grace for speech delay.
  bool _isPastTime(DateTime? d) =>
      d != null &&
      d.isBefore(DateTime.now().subtract(const Duration(minutes: 1)));

  Future<void> _processVoiceCommand(List<String> candidates) async {
    final folderNames = _folders
        .map((doc) => doc.data()['folder_name'] as String)
        .toList();

    final text = _pickBestTranscript(candidates, folderNames);
    // Existing folders first; names that match no folder become "new folder"
    // suggestions (created only when the user confirms and saves).
    final outcome = VoiceFolderGuesser.parse(text, folderNames);

    final voiceResult = await VoiceInputService.saveVoiceInput(
      transcribedText: text,
    );
    final voiceId = voiceResult.voiceId;

    final List<ParsedVoiceTask> parsedList;
    final List<String?> nlpIds;
    if (voiceId != null) {
      final result = await NlpPipeline.process(
        voiceId: voiceId,
        rawText: text,
        knownFolderNames: outcome.knownNames,
      );
      parsedList = result.$1;
      nlpIds = result.$2;
    } else {
      parsedList = outcome.tasks;
      nlpIds = List<String?>.filled(parsedList.length, null);
    }

    if (!mounted) return;

    final anyUsable = parsedList.any(
      (p) => (p.isValid || p.needsFolderOnly) && !_isPastTime(p.dateTime),
    );
    if (!anyUsable) {
      if (voiceId != null) {
        await VoiceInputService.updateProcessingStatus(voiceId, 'invalid');
      }
      _showParseErrorDialog(text, parsedList);
      return;
    }

    // Hands-free: everything understood (name, task, future date) -> save
    // straight away. Anything doubtful still opens the confirm screen.
    final allReady = parsedList.every(
      (p) => p.isValid && p.folderName != null && !_isPastTime(p.dateTime),
    );
    if (_autoSave && allReady) {
      await _saveSelectedTasks(
        parsedList,
        nlpIds,
        List<bool>.filled(parsedList.length, true),
        parsedList.map((p) => p.folderName).toList(),
        voiceId,
        withUndo: true,
      );
      return;
    }

    _showMultiConfirmDialog(
      parsedList,
      nlpIds,
      voiceId,
      outcome.newFolderNames,
    );
  }

  void _showParseErrorDialog(String heard, List<ParsedVoiceTask> parsedList) {
    final anyPast = parsedList.any(
      (p) => p.taskDescription.isNotEmpty && _isPastTime(p.dateTime),
    );
    final reason = anyPast
        ? 'The date/time you said has already passed. Please say a future '
              'date or time.'
        : (parsedList.isNotEmpty
              ? (parsedList.first.errorReason ?? 'Could not understand.')
              : 'Could not understand.');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Could Not Create Task'),
        content: Text(
          'Heard: "$heard"\n\n$reason\n\n'
          'Tip: say the name, the task, then the date — e.g. '
          '"Noah beli roti hari rabu".',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// Lists every task detected in the recording. For each usable task you can
  /// tick/untick it AND change its folder (handy when the engine mis-heard a
  /// name). Tasks whose text/date could not be understood are greyed out.
  void _showMultiConfirmDialog(
    List<ParsedVoiceTask> parsedList,
    List<String?> nlpIds,
    String? voiceId,
    List<String> newFolderNames,
  ) {
    final existingNames = _folders
        .map((d) => d.data()['folder_name'] as String)
        .toList();
    // Names that do not exist yet. They are created when you save.
    final newNames = <String>[...newFolderNames];
    List<String> allNames() => [...existingNames, ...newNames];

    // Folder currently chosen for each task (null = none yet).
    final chosenFolder = List<String?>.generate(parsedList.length, (i) {
      final p = parsedList[i];
      return allNames().contains(p.folderName) ? p.folderName : null;
    });

    bool fixable(ParsedVoiceTask p) =>
        p.dateTime != null &&
        p.taskDescription.isNotEmpty &&
        !_isPastTime(p.dateTime);

    String skipReason(ParsedVoiceTask p) {
      if (p.dateTime != null &&
          p.taskDescription.isNotEmpty &&
          _isPastTime(p.dateTime)) {
        return 'that date/time has already passed. Say a future date.';
      }
      return p.errorReason ?? 'could not understand this part.';
    }

    final included = List<bool>.generate(parsedList.length, (i) {
      return fixable(parsedList[i]) && chosenFolder[i] != null;
    });

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final selectedCount = included.where((v) => v).length;

            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: Text(
                parsedList.length > 1
                    ? '${parsedList.length} Tasks Detected'
                    : 'Confirm New Task',
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: parsedList.length,
                  separatorBuilder: (_, _) => const Divider(height: 20),
                  itemBuilder: (context, i) {
                    final p = parsedList[i];

                    if (!fixable(p)) {
                      return Opacity(
                        opacity: 0.6,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Heard: "${p.heardText}"',
                              style: TextStyle(
                                color: Colors.grey[600],
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Skipped — ${skipReason(p)}',
                              style: const TextStyle(
                                color: Colors.red,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Checkbox(
                          value: included[i],
                          activeColor: _accent,
                          onChanged: chosenFolder[i] == null
                              ? null
                              : (v) => setDialogState(
                                  () => included[i] = v ?? false,
                                ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              DropdownButton<String>(
                                isExpanded: true,
                                isDense: true,
                                value: chosenFolder[i],
                                hint: const Text(
                                  'Choose folder',
                                  style: TextStyle(color: Colors.red),
                                ),
                                items: [
                                  for (final n in allNames())
                                    DropdownMenuItem(
                                      value: n,
                                      child: Text(
                                        existingNames.contains(n)
                                            ? 'Folder: $n'
                                            : 'New folder: $n',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                  const DropdownMenuItem(
                                    value: _newFolderSentinel,
                                    child: Text(
                                      '+ Type a new folder name',
                                      style: TextStyle(
                                        color: _accent,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ],
                                onChanged: (v) async {
                                  if (v == _newFolderSentinel) {
                                    final typed = await _askNewFolderName(
                                      context,
                                    );
                                    if (typed == null) return;
                                    // Typed an existing name? Reuse it.
                                    final chosen = allNames().firstWhere(
                                      (n) =>
                                          FolderService.nameKey(n) ==
                                          FolderService.nameKey(typed),
                                      orElse: () => typed,
                                    );
                                    setDialogState(() {
                                      if (!allNames().contains(chosen)) {
                                        newNames.add(chosen);
                                      }
                                      chosenFolder[i] = chosen;
                                      included[i] = true;
                                    });
                                    return;
                                  }
                                  setDialogState(() {
                                    chosenFolder[i] = v;
                                    included[i] = v != null;
                                  });
                                },
                              ),
                              const SizedBox(height: 4),
                              Text('Task: ${p.taskDescription}'),
                              Text(
                                'When: ${DateFormat('EEE, d MMM yyyy • h:mm a').format(p.dateTime!)}',
                              ),
                              Text(
                                'Heard: "${p.heardText}"',
                                style: TextStyle(
                                  color: Colors.grey[500],
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: _accent),
                  onPressed: selectedCount == 0
                      ? null
                      : () async {
                          Navigator.pop(context);
                          await _saveSelectedTasks(
                            parsedList,
                            nlpIds,
                            included,
                            chosenFolder,
                            voiceId,
                          );
                        },
                  child: Text(
                    selectedCount > 1
                        ? 'Save $selectedCount Tasks'
                        : 'Confirm & Save',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _saveSelectedTasks(
    List<ParsedVoiceTask> parsedList,
    List<String?> nlpIds,
    List<bool> included,
    List<String?> chosenFolder,
    String? voiceId, {
    bool withUndo = false,
  }) async {
    final savedIds = <String>[];
    final savedSummaries = <String>[];
    int savedCount = 0;
    int failedCount = 0;
    final createdFolders = <String>[];

    for (int i = 0; i < parsedList.length; i++) {
      if (!included[i]) continue;
      final p = parsedList[i];
      final folderName = chosenFolder[i];

      if (folderName == null || p.dateTime == null) {
        failedCount++;
        continue;
      }
      // Find the folder by name, or create it (e.g. "Maryam") if it does not
      // exist yet. Same logic for guests and registered users.
      final folderRes = await FolderService.findOrCreateFolder(folderName);
      if (!folderRes.success || folderRes.folderId == null) {
        failedCount++;
        continue;
      }
      if (folderRes.created) {
        createdFolders.add(folderRes.folderName ?? folderName);
      }

      final result = await TaskService.createTask(
        folderId: folderRes.folderId!,
        folderName: folderRes.folderName ?? folderName,
        title: p.taskDescription,
        taskDatetime: p.dateTime!,
        voiceId: voiceId,
      );

      if (result.success) {
        savedCount++;
        if (result.taskId != null) savedIds.add(result.taskId!);
        savedSummaries.add(
          '${folderRes.folderName ?? folderName}: ${p.taskDescription}',
        );
      } else {
        failedCount++;
      }
    }

    if (voiceId != null) {
      await VoiceInputService.updateProcessingStatus(
        voiceId,
        failedCount == 0 ? 'task_created' : 'partial_failure',
      );
    }

    if (!mounted) return;
    if (failedCount == 0) {
      final extra = createdFolders.isEmpty
          ? ''
          : ' New folder${createdFolders.length == 1 ? '' : 's'}: '
                '${createdFolders.join(', ')}.';
      final message = withUndo
          ? 'Saved ✓  ${savedSummaries.join('  •  ')}$extra'
          : (savedCount == 1
                ? 'Task saved! Alarm set.$extra'
                : '$savedCount tasks saved! Alarms set.$extra');
      if (withUndo && savedIds.isNotEmpty) {
        _showUndoSnack(message, savedIds);
      } else {
        _showSnack(message);
      }
    } else {
      _showSnack('$savedCount saved, $failedCount failed.');
    }
  }

  /// Manual task entry (no microphone). Same save logic as voice.
  Future<void> _openAddTask() async {
    if (_isListening) return;
    final message = await AddTaskSheet.show(context, folders: _folders);
    if (message != null) _showSnack(message);
  }

  /// Small dialog to type a folder name (used when the microphone heard a
  /// name wrongly). Returns the tidied name, or null if cancelled.
  Future<String?> _askNewFolderName(BuildContext dialogContext) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: dialogContext,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'New folder name',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            hintText: 'Family member name',
            filled: true,
            fillColor: Colors.grey[100],
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: Colors.grey[700])),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _accent),
            onPressed: () {
              final name = FolderService.tidyName(controller.text);
              Navigator.pop(context, name.isEmpty ? null : name);
            },
            child: const Text('OK', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  /// Hands-free confirmation: shows what was saved with TWO choices:
  ///   OK   -> keep the tasks (closes the bar right away)
  ///   UNDO -> delete the tasks just created and cancel their alarms
  /// If the user does nothing the tasks are simply kept.
  void _showUndoSnack(String message, List<String> taskIds) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 10),
        content: Row(
          children: [
            Expanded(child: Text(message)),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                minimumSize: const Size(48, 36),
              ),
              onPressed: () => messenger.hideCurrentSnackBar(),
              child: const Text(
                'OK',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'UNDO',
          textColor: Colors.orangeAccent,
          onPressed: () async {
            await TaskService.deleteTasks(taskIds);
            _showSnack('Undone.');
          },
        ),
      ),
    );
  }

  Future<void> _toggleAutoSave() async {
    final prefs = await SharedPreferences.getInstance();
    final next = !_autoSave;
    await prefs.setBool('auto_save_voice', next);
    if (!mounted) return;
    setState(() => _autoSave = next);
    _showSnack(
      next
          ? 'Hands-free ON: tap the mic, speak, and it saves by itself.'
          : 'Hands-free OFF: you will confirm each recording.',
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------- Profile menu ----------------

  String get _voicePrefLabel {
    switch (_voicePref) {
      case 'ms':
        return 'Bahasa Melayu';
      case 'en':
        return 'English';
      default:
        return 'Auto (follow phone)';
    }
  }

  void _showProfileMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
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
              const SizedBox(height: 20),
              Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: _accent,
                    child: Text(
                      _username.isNotEmpty ? _username[0].toUpperCase() : 'U',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _username.isNotEmpty ? _username : 'User',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Divider(color: Colors.grey[200], height: 1),
              const SizedBox(height: 8),
              if (!AuthService.isGuest)
                _profileMenuTile(
                  icon: Icons.edit_outlined,
                  label: 'Edit Profile',
                  iconBgColor: _accent.withOpacity(0.1),
                  iconColor: _accent,
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      this.context,
                      MaterialPageRoute(
                        builder: (_) => const EditProfileScreen(),
                      ),
                    );
                  },
                ),
              _profileMenuTile(
                icon: Icons.translate,
                label: 'Voice language: $_voicePrefLabel',
                iconBgColor: _accent.withOpacity(0.1),
                iconColor: _accent,
                onTap: () {
                  Navigator.pop(context);
                  _showVoiceLanguageDialog();
                },
              ),
              _profileMenuTile(
                icon: Icons.bolt,
                label: 'Hands-free save: ${_autoSave ? 'ON' : 'OFF'}',
                iconBgColor: _accent.withOpacity(0.1),
                iconColor: _accent,
                onTap: () {
                  Navigator.pop(context);
                  _toggleAutoSave();
                },
              ),
              _profileMenuTile(
                icon: Icons.alarm,
                label: 'Test alarm (creates a test task)',
                iconBgColor: _accent.withOpacity(0.1),
                iconColor: _accent,
                onTap: () async {
                  Navigator.pop(context);
                  await _createTestAlarmTask();
                },
              ),
              if (AuthService.isGuest) ...[
                _profileMenuTile(
                  icon: Icons.person_add_alt_1_outlined,
                  label: 'Create account (keep my tasks)',
                  iconBgColor: _accent.withOpacity(0.1),
                  iconColor: _accent,
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      this.context,
                      MaterialPageRoute(builder: (_) => const RegisterScreen()),
                    );
                  },
                ),
                _profileMenuTile(
                  icon: Icons.login_rounded,
                  label: 'Log in to an existing account',
                  iconBgColor: Colors.red.withOpacity(0.1),
                  iconColor: Colors.red,
                  labelColor: Colors.red,
                  onTap: () {
                    Navigator.pop(context);
                    _showGuestLoginDialog();
                  },
                ),
              ] else
                _profileMenuTile(
                  icon: Icons.logout_rounded,
                  label: 'Logout',
                  iconBgColor: Colors.red.withOpacity(0.1),
                  iconColor: Colors.red,
                  labelColor: Colors.red,
                  onTap: () {
                    Navigator.pop(context);
                    _showLogoutConfirmDialog();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  /// Creates a REAL task due in 30 seconds so you can test the whole alarm
  /// flow: ring -> tap Done (task becomes Completed) or Dismiss (task becomes
  /// Overdue). Delete the test task afterwards.
  Future<void> _createTestAlarmTask() async {
    if (_folders.isEmpty) {
      _showSnack('Create a family folder first, then run the test.');
      return;
    }
    final exactOk = await NotificationScheduler.ensureAlarmPermissions();
    final folder = _folders.first;
    final result = await TaskService.createTask(
      folderId: folder.id,
      folderName: (folder.data()['folder_name'] as String?) ?? '',
      title: 'Test alarm - tap Done or Dismiss',
      taskDatetime: DateTime.now().add(const Duration(seconds: 30)),
    );
    if (!mounted) return;
    if (!result.success) {
      _showSnack(result.errorMessage ?? 'Could not create the test task.');
      return;
    }
    _showSnack(
      exactOk
          ? 'Test task created. Lock your phone — the alarm rings in 30 seconds.'
          : 'Test task created, but "Alarms & reminders" permission is OFF, so '
                'it may ring late. Turn it on in Settings > Apps > fam_assist.',
    );
  }

  void _showVoiceLanguageDialog() {
    showDialog(
      context: context,
      builder: (context) {
        Widget option(String value, String title, String subtitle) {
          final selected = _voicePref == value;
          return ListTile(
            leading: Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: selected ? _accent : Colors.grey,
            ),
            title: Text(title),
            subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
            onTap: () {
              Navigator.pop(context);
              _setVoicePref(value);
            },
          );
        }

        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Text('Voice language'),
          contentPadding: const EdgeInsets.only(top: 12),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              option('auto', 'Auto', 'Follows your phone language'),
              option('ms', 'Bahasa Melayu', 'Best when you mostly speak Malay'),
              option('en', 'English', 'Best when you mostly speak English'),
            ],
          ),
        );
      },
    );
  }

  /// One safe logout used by every "log out" button. Each step is guarded so
  /// a failure in one (e.g. the notification plugin, or Google sign-out being
  /// slow) can never stop the logout or leave the user stuck on this screen,
  /// which is what made you have to tap Logout twice. Double taps are ignored.
  Future<void> _logoutAndGoToLogin() async {
    if (_loggingOut) return;
    _loggingOut = true;
    try {
      await NotificationScheduler.cancelAll();
    } catch (e) {
      debugPrint('cancelAll failed: $e');
    }
    try {
      await AuthService.logout().timeout(const Duration(seconds: 6));
    } catch (e) {
      debugPrint('logout failed: $e');
    }
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  void _showLogoutConfirmDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Log Out',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: const Text('Are you sure you want to log out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: Colors.grey[700])),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(context);
              await _logoutAndGoToLogin();
            },
            child: const Text(
              'Yes, Log Out',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  /// Guest wants to switch to an existing account. The guest session's tasks
  /// can't be opened again afterwards, so ask first.
  void _showGuestLoginDialog() {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Log in to another account?',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'Your guest folders and tasks will be copied into the account you '
          'log in to. A folder with the same name is reused; otherwise it is '
          'created for you.\n\n'
          'Or choose "Create account" to turn this guest session into a new '
          'account.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('Cancel', style: TextStyle(color: Colors.grey[700])),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(dialogContext);
              // Copy the guest's data to this phone first; the Dashboard
              // moves it into whichever account logs in next.
              final stashed = await GuestCarryOver.stash();
              if (stashed < 0) {
                // Could not save the guest data on this phone: do NOT log
                // out, otherwise the guest tasks would be lost.
                _showSnack(
                  'Could not save your guest tasks. Please try again.',
                );
                return;
              }
              await _logoutAndGoToLogin();
            },
            child: const Text(
              'Continue',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _profileMenuTile({
    required IconData icon,
    required String label,
    required Color iconBgColor,
    required Color iconColor,
    Color? labelColor,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: iconBgColor,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: labelColor ?? Colors.black87,
                ),
              ),
            ),
            Icon(Icons.chevron_right, color: Colors.grey[400], size: 20),
          ],
        ),
      ),
    );
  }

  // ---------------- Folder options (open / delete) ----------------

  void _showFolderOptions({
    required String folderId,
    required String folderName,
    required String folderIcon,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
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
              const SizedBox(height: 20),
              Text(
                folderName,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 12),
              Divider(color: Colors.grey[200], height: 1),
              const SizedBox(height: 8),
              _profileMenuTile(
                icon: Icons.folder_open_outlined,
                label: 'Open Folder',
                iconBgColor: _accent.withOpacity(0.1),
                iconColor: _accent,
                onTap: () {
                  Navigator.pop(context);
                  _openFolderTasks(
                    folderId: folderId,
                    folderName: folderName,
                    folderIcon: folderIcon,
                  );
                },
              ),
              _profileMenuTile(
                icon: Icons.delete_outline_rounded,
                label: 'Delete Folder',
                iconBgColor: Colors.red.withOpacity(0.1),
                iconColor: Colors.red,
                labelColor: Colors.red,
                onTap: () {
                  Navigator.pop(context);
                  _confirmDeleteFolder(
                    folderId: folderId,
                    folderName: folderName,
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _confirmDeleteFolder({
    required String folderId,
    required String folderName,
  }) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Delete Folder',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: Text(
          'Delete "$folderName"? All tasks inside this folder will be '
          'permanently deleted too. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: Colors.grey[700])),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(context);
              await TaskService.deleteTasksByFolder(folderId);
              final result = await FolderService.deleteFolder(folderId);

              if (!mounted) return;
              _showSnack(
                result.success
                    ? '"$folderName" deleted.'
                    : (result.errorMessage ?? 'Failed to delete folder.'),
              );
            },
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _openFolderTasks({
    required String folderId,
    required String folderName,
    required String folderIcon,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => FolderTaskListScreen(
          folderId: folderId,
          folderName: folderName,
          folderIcon: folderIcon,
        ),
      ),
    );
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: SizedBox.expand(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset('assets/bg.png', fit: BoxFit.cover),
            SafeArea(
              child: Stack(
                children: [
                  SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 190),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildHeader(),
                        if (AuthService.isGuest) ...[
                          const SizedBox(height: 12),
                          _buildGuestBanner(),
                        ],
                        const SizedBox(height: 16),
                        _buildStatsRow(),
                        const SizedBox(height: 16),
                        _buildWhiteCard(),
                      ],
                    ),
                  ),
                  Positioned(
                    bottom: 12,
                    left: 0,
                    right: 0,
                    child: _buildMicArea(),
                  ),
                  // Keyboard button beside the mic: add a task by typing.
                  Positioned(bottom: 40, right: 24, child: _buildTypeButton()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMicArea() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_isListening) _buildLiveBubble(),
        // TAP once = start recording, TAP again = stop.
        GestureDetector(
          onTap: _toggleRecording,
          child: SizedBox(
            width: 100,
            height: 100,
            child: Center(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Pulsing ring that grows with how loud you are speaking.
                  ValueListenableBuilder<double>(
                    valueListenable: _level,
                    builder: (context, level, _) {
                      final size = _isListening ? 64 + level * 34 : 64.0;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        width: size,
                        height: size,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _isListening
                              ? Colors.red.withOpacity(0.25)
                              : Colors.transparent,
                        ),
                      );
                    },
                  ),
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isListening
                          ? Colors.red
                          : const Color(0xFF6C63FF),
                      boxShadow: const [
                        BoxShadow(color: Colors.black26, blurRadius: 8),
                      ],
                    ),
                    child: Icon(
                      _isListening ? Icons.stop : Icons.mic_none,
                      color: Colors.white,
                      size: 30,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Text(
          _isListening ? 'Listening... tap to stop' : 'Tap to record',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildTypeButton() {
    return GestureDetector(
      onTap: _openAddTask,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
              boxShadow: const [
                BoxShadow(color: Colors.black26, blurRadius: 8),
              ],
            ),
            child: const Icon(
              Icons.keyboard_alt_outlined,
              color: _accent,
              size: 24,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Type task',
            style: TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveBubble() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(24, 0, 24, 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.72),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ValueListenableBuilder<String>(
            valueListenable: _liveText,
            builder: (context, text, _) {
              return Text(
                text.isEmpty ? 'Speak now…' : text,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: text.isEmpty ? Colors.white60 : Colors.white,
                  fontSize: 13,
                ),
              );
            },
          ),
          ValueListenableBuilder<bool>(
            valueListenable: _quietWarning,
            builder: (context, quiet, _) {
              if (!quiet) return const SizedBox.shrink();
              return const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  "Can't hear you — move the phone closer or speak louder.",
                  style: TextStyle(color: Colors.orangeAccent, fontSize: 11),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final now = DateTime.now();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                DateFormat('EEEE, d MMM\nyyyy').format(now),
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 4),
              Text(
                '${_greeting()}, $_username',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        GestureDetector(
          onTap: () => _showProfileMenu(context),
          child: CircleAvatar(
            radius: 22,
            backgroundColor: _accent,
            child: Text(
              _username.isNotEmpty ? _username[0].toUpperCase() : 'U',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Shown only in guest mode.
  Widget _buildGuestBanner() {
    return GestureDetector(
      // Log in: guest tasks are copied first, then moved into the account.
      onTap: _showGuestLoginDialog,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.18),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Guest mode: tasks are saved to this guest session. Log in or '
                'create an account and they move into your account.',
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _accent,
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Text(
                'Log in',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsRow() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: TaskService.streamAllUserTasks(),
      builder: (context, snapshot) {
        int todayCount = 0;
        int completedCount = 0;
        int overdueCount = 0;

        if (snapshot.hasData) {
          final now = DateTime.now();
          for (final doc in snapshot.data!.docs) {
            final data = doc.data();
            final isDone = data['status'] == 'completed';
            final ts = data['task_datetime'] as Timestamp?;
            final due = ts?.toDate();
            if (isDone) completedCount++;
            if (due != null) {
              if (due.year == now.year &&
                  due.month == now.month &&
                  due.day == now.day) {
                todayCount++;
              }
              if (TaskStateHelper.of(isCompleted: isDone, due: due, now: now) ==
                  TaskState.overdue) {
                overdueCount++;
              }
            }
          }
        }

        return Row(
          children: [
            Expanded(child: _statCard('$todayCount', 'Today')),
            const SizedBox(width: 10),
            Expanded(
              child: _statCard(
                '$overdueCount',
                'Overdue',
                alert: overdueCount > 0,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: _statCard('$completedCount', 'Completed')),
          ],
        );
      },
    );
  }

  Widget _statCard(String number, String label, {bool alert = false}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: alert
            ? TaskStateHelper.overdueColor.withOpacity(0.85)
            : Colors.white.withOpacity(0.15),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            number,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildWhiteCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Family Folder',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              GestureDetector(
                onTap: () => setState(() => _showAllFolders = !_showAllFolders),
                child: Text(
                  _showAllFolders ? 'Show less' : 'Show all',
                  style: const TextStyle(color: _accent),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _showAllFolders ? _buildFolderGrid() : _buildFolderCarousel(),
          const SizedBox(height: 20),
          _buildVoiceInstructions(),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Latest Task',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onTap: _openAddTask,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: _accent,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add, color: Colors.white, size: 14),
                          SizedBox(width: 2),
                          Text(
                            'Add',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const AllTasksScreen(),
                        ),
                      );
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      child: Text('All', style: TextStyle(color: _accent)),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildLatestTasks(),
        ],
      ),
    );
  }

  Widget _buildFolderCarousel() {
    final hasOverflow = _folders.length > 3;
    final visibleFolders = hasOverflow ? _folders.take(3).toList() : _folders;

    return SizedBox(
      height: 90,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: visibleFolders.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          if (index == visibleFolders.length) {
            return hasOverflow ? _buildOverflowTile() : _buildAddFolderTile();
          }
          return _buildFolderTile(visibleFolders[index]);
        },
      ),
    );
  }

  Widget _buildOverflowTile() {
    return GestureDetector(
      onTap: () => setState(() => _showAllFolders = true),
      child: Container(
        width: 80,
        height: 90,
        decoration: BoxDecoration(
          color: Colors.grey[100],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey[300]!),
        ),
        child: const Center(
          child: Icon(Icons.more_horiz, color: _accent, size: 28),
        ),
      ),
    );
  }

  Widget _buildFolderGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 10.0;
        const minTileWidth = 80.0;

        final maxWidth = constraints.maxWidth;

        int columns = ((maxWidth + spacing) / (minTileWidth + spacing)).floor();
        if (columns < 1) columns = 1;

        final tileWidth = (maxWidth - spacing * (columns - 1)) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final folder in _folders)
              _buildFolderTile(folder, width: tileWidth),
            _buildAddFolderTile(width: tileWidth),
          ],
        );
      },
    );
  }

  Widget _buildFolderTile(
    QueryDocumentSnapshot<Map<String, dynamic>> folder, {
    double width = 80,
  }) {
    final data = folder.data();
    final folderId = folder.id;
    final folderName = data['folder_name'] ?? '';
    final folderIcon = data['folder_icon'] ?? 'assets/emoji1.png';

    return GestureDetector(
      onTap: () => _showFolderOptions(
        folderId: folderId,
        folderName: folderName,
        folderIcon: folderIcon,
      ),
      child: Container(
        width: width,
        height: 90,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: Colors.grey[100],
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              data['folder_icon'] ?? 'assets/emoji1.png',
              height: 28,
              width: 28,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.folder, color: _accent),
            ),
            const SizedBox(height: 4),
            Text(
              folderName,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: TaskService.streamTasksByFolder(folderId),
              builder: (context, snap) {
                final count = snap.data?.docs.length ?? 0;
                return Text(
                  '$count task',
                  style: TextStyle(fontSize: 9, color: Colors.grey[600]),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddFolderTile({double width = 80}) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const CreateFolderScreen(isOnboarding: false),
          ),
        );
      },
      child: Container(
        width: width,
        height: 90,
        decoration: BoxDecoration(
          color: Colors.grey[100],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey[300]!),
        ),
        child: const Center(child: Icon(Icons.add, color: _accent)),
      ),
    );
  }

  // ---------------- Voice instructions ----------------

  Widget _tip(String title, String body, {String? example}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          ),
          const SizedBox(height: 2),
          Text(body, style: const TextStyle(fontSize: 12)),
          if (example != null) ...[
            const SizedBox(height: 3),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                example,
                style: const TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: Color(0xFF3949AB),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _langChip(String code, String flag, String label) {
    final selected = _instrLang == code;
    return GestureDetector(
      onTap: () => _setInstrLang(code),
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF3949AB) : Colors.white,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          '$flag $label',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : Colors.black87,
          ),
        ),
      ),
    );
  }

  Widget _buildVoiceInstructions() {
    const maxTasks = VoiceTaskParser.maxTasksPerRecording;
    final ms = _instrLang == 'ms';

    return Container(
      decoration: BoxDecoration(
        color: Colors.blue[50],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          leading: const Icon(Icons.mic, color: Color(0xFF3949AB), size: 20),
          title: Text(
            ms ? 'Panduan Suara' : 'Voice Guide',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
          subtitle: Text(
            ms ? 'Ketik untuk lihat cara bercakap' : 'Tap to see how to speak',
            style: const TextStyle(fontSize: 11),
          ),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  _langChip('en', '🇬🇧', 'EN'),
                  _langChip('ms', '🇲🇾', 'MY'),
                ],
              ),
            ),
            _tip(
              ms ? '1. Rakam' : '1. Record',
              ms
                  ? 'Ketik mik, bercakap, ketik lagi untuk berhenti.'
                  : 'Tap the mic, speak, tap again to stop.',
            ),
            _tip(
              ms
                  ? '2. Sebut: Nama → Tugas → Tarikh'
                  : '2. Say: Name → Task → Date',
              ms
                  ? 'Masa pun boleh. Tiada masa = 9:00 pagi (hari ini / esok = 5:00 petang).'
                  : 'Time is optional. No time = 9:00 AM (today / tomorrow = 5:00 PM).',
              example: ms
                  ? '"Noah beli roti hari rabu pukul 9 pagi"'
                  : '"Noah buy bread Wednesday at 9 am"',
            ),
            _tip(
              ms ? '3. Banyak tugas' : '3. Many tasks',
              ms
                  ? 'Berhenti sekejap antara tugas. Sebut nama sekali = folder '
                        'sama. Sebut nama lain = folder lain. '
                        'Guna "dan" untuk kongsi tarikh.'
                  : 'Pause between tasks. Say a name once = same folder. Say a '
                        'new name = new folder. Use "and" to share one date.',
              example: ms
                  ? '"Noah beli roti rabu, Maryam basuh kasut jumaat"'
                  : '"Noah buy bread Wednesday, Maryam wash shoes Friday"',
            ),
            _tip(
              ms ? 'Tarikh & masa' : 'Dates & times',
              ms
                  ? 'hari ini, esok, lusa, rabu depan, dalam 3 hari, 17 Jun, '
                        'pukul 9 pagi, jam 3 petang, 5pm.'
                  : 'today, tomorrow, next Friday, in 3 days, 17 Jun, '
                        '9 am, 3 pm, 5pm.',
            ),
            _tip(
              ms ? 'Had' : 'Limits',
              ms
                  ? 'Maksimum $maxTasks tugas dan 2 minit setiap rakaman.'
                  : 'Up to $maxTasks tasks and 2 minutes per recording.',
            ),
            _tip(
              ms ? 'Salah nama / folder?' : 'Wrong name or folder?',
              ms
                  ? 'Tukar folder di skrin pengesahan sebelum simpan.'
                  : 'Change the folder on the confirm screen before saving.',
            ),
            _tip(
              ms ? 'Nama baru?' : 'New name?',
              ms
                  ? 'Jika nama belum ada folder, folder baharu dicipta '
                        'automatik apabila anda simpan.'
                  : 'If the name has no folder yet, one is created '
                        'automatically when you save.',
              example: ms
                  ? '\"Maryam tempah hotel malam jumaat\"'
                  : '\"Maryam book hotel Friday night\"',
            ),
            _tip(
              ms ? 'Bebas tangan' : 'Hands-free',
              ms
                  ? 'Profil > Hands-free save. Ketik mik, bercakap, berhenti '
                        'sekejap ~4 saat: tugas disimpan sendiri. Tekan UNDO '
                        'jika salah.'
                  : 'Profile > Hands-free save. Tap the mic, speak, pause '
                        '~4 s: it saves by itself. Tap UNDO if it was wrong.',
            ),
            _tip(
              ms ? 'Taip sendiri' : 'Type it instead',
              ms
                  ? 'Ketik butang papan kekunci atau "Add" untuk tambah '
                        'tugas tanpa suara.'
                  : 'Tap the keyboard button or "Add" to create a task by '
                        'typing.',
            ),
            _tip(
              ms ? 'Penggera' : 'Alarm',
              ms
                  ? 'Berbunyi pada masa tugas + peringatan 24 jam awal. '
                        '"Done" = selesai, "Dismiss" = ditanda Overdue.'
                  : 'Rings at the task time + a reminder 24 h before. '
                        '"Done" = completed, "Dismiss" = marked Overdue.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLatestTasks() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: TaskService.streamRecentTasks(limit: 5),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final docs = snapshot.data!.docs;
        if (docs.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'No tasks yet. Tap the mic, or the keyboard button, to add one!',
              style: TextStyle(color: Colors.grey[500], fontSize: 13),
            ),
          );
        }

        return Column(children: docs.map((doc) => _taskTile(doc)).toList());
      },
    );
  }

  Widget _taskTile(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    final isDone = data['status'] == 'completed';
    final ts = data['task_datetime'] as Timestamp?;
    final folderName = (data['folder_name'] as String?) ?? '';

    return TaskCard(
      title: data['title'] ?? '',
      folderName: folderName,
      due: ts?.toDate(),
      isDone: isDone,
      showDate: true,
      onToggle: (v) => TaskService.toggleTaskStatus(doc.id, v ?? false),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => EditTaskScreen(
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
}
