import 'folder_service.dart';
import 'voice_task_parser.dart';

/// Result of parsing one recording, including folder names that do NOT exist
/// yet (e.g. a guest with zero folders says "Maryam booking hotel Friday").
class VoiceParseOutcome {
  /// One entry per task clause (same as VoiceTaskParser.parseMultiple).
  final List<ParsedVoiceTask> tasks;

  /// Names heard in the recording that match NO existing folder. They are
  /// created (find-or-create) only when the user confirms and saves.
  final List<String> newFolderNames;

  /// existing folder names + [newFolderNames]. Pass this to NlpPipeline /
  /// VoiceTaskParser so every stage sees the same list.
  final List<String> knownNames;

  VoiceParseOutcome(this.tasks, this.newFolderNames, this.knownNames);
}

/// Folder detection for names that are not folders yet.
///
/// VoiceTaskParser can only recognise names it is GIVEN (FolderResolver does
/// spelling + sound-alike matching against [knownFolderNames]). With an empty
/// or unrelated folder list it returns folder == null, and the name stays
/// inside the task text.
///
/// This helper adds a second chance:
///   1. Parse with the real folders (existing names always win, including
///      sound-alike matches such as "mariam" -> "Maryam").
///   2. For every task that is complete EXCEPT the folder (needsFolderOnly),
///      guess the name from how people speak in this app: Name -> Task ->
///      Date, i.e. the word(s) in front of the first action verb.
///   3. Parse again with the guessed names added, so the parser strips the
///      name from the task text, shares dates, and carries the name forward
///      to the next tasks exactly as it does for real folders.
class VoiceFolderGuesser {
  /// Words that can never be somebody's name.
  static const Set<String> _notNames = {
    'hari',
    'ini',
    'esok',
    'lusa',
    'today',
    'tomorrow',
    'tonight',
    'pukul',
    'jam',
    'pagi',
    'petang',
    'malam',
    'dan',
    'and',
    'di',
    'pada',
    'on',
    'at',
    'untuk',
    'for',
    'bagi',
    'kepada',
    'minggu',
    'depan',
    'next',
    'this',
    'dalam',
    'lagi',
    'tarikh',
    'the',
    'a',
    'to',
    'of',
    'in',
    'weekend',
    'hujung',
    'bulan',
    'tengah',
    'morning',
    'afternoon',
    'evening',
    'night',
    'tolong',
    'please',
    'remind',
    'reminder',
    'task',
    'tugas',
    'ingatkan',
    'saya',
    'i',
    'me',
    'my',
    'nak',
    'mahu',
    'want',
    'need',
    'perlu',
    'kena',
    'sila',
    'ada',
    'then',
    'kemudian',
  };

  static bool _isNotName(String t) {
    if (t.length < 2) return true;
    if (RegExp(r'\d').hasMatch(t)) return true;
    if (_notNames.contains(t)) return true;
    if (EntityRecognizer.dateWords.contains(t)) return true;
    return IntentDetector.isActionWord(t);
  }

  static bool _hasKey(Iterable<String> names, String name) {
    final k = FolderService.nameKey(name);
    return names.any((n) => FolderService.nameKey(n) == k);
  }

  /// "maryam booking hotel on friday night" -> "Maryam"
  /// "siti aminah beli roti esok"            -> "Siti Aminah"
  /// "beli roti esok"                        -> null (no name spoken)
  static String? guessName(String heardText) {
    final tokens = TextPreprocessor.normalize(
      heardText,
    ).split(RegExp(r'[\s,]+')).where((t) => t.isNotEmpty).toList();
    if (tokens.length < 2) return null;

    final lead = <String>[];
    for (var i = 0; i < tokens.length && lead.length < 2; i++) {
      if (_isNotName(tokens[i])) break;
      lead.add(tokens[i]);
    }
    if (lead.isEmpty) return null;

    // Two-word names ("Siti Aminah") only when a verb follows right after;
    // otherwise "maryam hotel friday" would become the name "Maryam Hotel".
    if (lead.length == 2) {
      final next = tokens.length > 2 ? tokens[2] : '';
      if (next.isEmpty || !IntentDetector.isActionWord(next)) {
        lead.removeLast();
      }
    }

    final name = FolderService.tidyName(lead.join(' '));
    return name.isEmpty ? null : name;
  }

  static VoiceParseOutcome parse(String rawText, List<String> existingNames) {
    var tasks = VoiceTaskParser.parseMultiple(rawText, existingNames);

    final guesses = <String>[];
    for (final t in tasks) {
      if (!t.needsFolderOnly) continue;
      final g = guessName(t.heardText);
      if (g == null) continue;
      if (_hasKey(existingNames, g) || _hasKey(guesses, g)) continue;
      guesses.add(g);
    }
    if (guesses.isEmpty) {
      return VoiceParseOutcome(tasks, const [], existingNames);
    }

    final withGuesses = [...existingNames, ...guesses];
    final reparsed = VoiceTaskParser.parseMultiple(rawText, withGuesses);

    // Keep only guesses the parser really used as a folder.
    final used = guesses
        .where((g) => reparsed.any((t) => t.folderName == g))
        .toList();
    if (used.isEmpty) {
      return VoiceParseOutcome(tasks, const [], existingNames);
    }
    tasks = reparsed;
    return VoiceParseOutcome(tasks, used, [...existingNames, ...used]);
  }
}
