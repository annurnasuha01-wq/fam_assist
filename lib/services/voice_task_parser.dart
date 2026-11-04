/// ============================================================================
/// Fam-Assist NLP & Processing Pipeline  (Malay + English)
///
///   6.0 Normalisation           -> TextPreprocessor.normalize (spoken variants
///                                   such as "hari ni", "besok", "jumat",
///                                   "pukul lapan", "9 a.m." become one form)
///   6.0a Task Segmentation      -> TaskSegmenter (commas / pause words)
///   6.0b Date-Boundary Split    -> EntityRecognizer.splitByDateBoundaries
///   6.0c Compound Clause Split  -> CompoundClauseSplitter ("X dan Y [date]")
///   6.0d Verb-Boundary Split    -> VerbBoundarySplitter ("ali basuh baju
///                                   sental tandas" -> 2 tasks, no comma needed)
///   6.0e Share Trailing Date    -> VoiceTaskParser._shareTrailingSchedule
///                                   ("basuh baju, sental tandas harini"
///                                    -> BOTH tasks get "harini")
///   6.1 Text Preprocessing      -> TextPreprocessor.run
///   6.2 Intent Detection        -> IntentDetector (verb list + word-root
///                                   stemming + strict fuzzy: "blei" -> "beli")
///   6.3 Folder Resolution       -> FolderResolver (spelling + SOUND-ALIKE
///                                   matching, so "eva" still finds "Iwa" and
///                                   "laura"/"nora" still find "Naura")
///   6.4 Entity Recognition      -> EntityRecognizer (BM + EN dates & times)
///   6.5 Context Validation      -> ContextValidator
///   6.6 Date Normalization      -> DateNormalizer
///   6.7 Build Structured Data   -> VoiceTaskParser.parseMultiple()
///
/// VoiceTaskParser.parseMultiple() ALWAYS returns a LIST (one ParsedVoiceTask
/// per task clause found, max [VoiceTaskParser.maxTasksPerRecording]).
/// ============================================================================
library;

/// Final structured result for ONE task — Stage 6.7's output.
class ParsedVoiceTask {
  final String? folderName;
  final String taskDescription;
  final DateTime? dateTime;
  final bool isValid;
  final String? errorReason;
  final String intent;
  final String? rawDatePhrase;
  final double confidence;
  final String heardText;

  ParsedVoiceTask({
    this.folderName,
    required this.taskDescription,
    this.dateTime,
    required this.isValid,
    this.errorReason,
    this.intent = 'unknown',
    this.rawDatePhrase,
    this.confidence = 0,
    this.heardText = '',
  });

  /// True when the ONLY thing missing is the folder (task text and date were
  /// understood). The confirm dialog lets the user pick the folder by hand.
  bool get needsFolderOnly =>
      !isValid &&
      folderName == null &&
      taskDescription.isNotEmpty &&
      dateTime != null;
}

class TimeOfDayValue {
  final int hour;
  final int minute;
  TimeOfDayValue(this.hour, this.minute);
}

/// ---------------------------------------------------------------------------
/// STAGE 6.0a — Task Segmentation
/// ---------------------------------------------------------------------------
class TaskSegmenter {
  static final RegExp _connectorPattern = RegExp(
    r'\s*(?:,|;|\.\.\.|\u2026|\.(?=\s|$)|\bthen\b|\bnext task\b|\bafter that\b'
    r'|\blepas tu\b|\blepas itu\b|\bselepas itu\b|\bkemudian\b|\bseterusnya\b'
    r'|\bpastu\b|\bselain itu\b|\bmanakala\b|\bsementara\b)\s*',
    caseSensitive: false,
  );

  static List<String> splitByConnectors(String text) {
    return text
        .split(_connectorPattern)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }
}

/// ---------------------------------------------------------------------------
/// STAGE 6.0c — Compound Clause Splitting
///
/// "Noah beli buku dan basuh kasut hari rabu pukul 9 pagi"
///   -> "Noah beli buku hari rabu pukul 9 pagi"
///    + "basuh kasut hari rabu pukul 9 pagi"
///
/// Only splits when BOTH sides contain an action verb, so a shopping list
/// like "beli roti dan susu" stays ONE task.
/// ---------------------------------------------------------------------------
class CompoundClauseSplitter {
  static final RegExp _danAnd = RegExp(
    r'\b(?:dan|and)\b',
    caseSensitive: false,
  );

  static List<String> maybeSplit(String text, {int depth = 0}) {
    if (depth >= 4) return [text];

    for (final match in _danAnd.allMatches(text)) {
      final partA = text.substring(0, match.start).trim();
      final partB = text.substring(match.end).trim();
      if (partA.isEmpty || partB.isEmpty) continue;
      if (!IntentDetector.containsActionWord(partA) ||
          !IntentDetector.containsActionWord(partB)) {
        continue;
      }

      final datePhrase = EntityRecognizer.findDatePhrase(text);
      final timePhrase = EntityRecognizer.findTimePhrase(text);

      String withSchedule(String part) {
        var p = part;
        if (datePhrase != null && EntityRecognizer.findDatePhrase(p) == null) {
          p = '$p $datePhrase';
        }
        if (timePhrase != null && EntityRecognizer.findTimePhrase(p) == null) {
          p = '$p $timePhrase';
        }
        return p;
      }

      return [
        ...maybeSplit(withSchedule(partA), depth: depth + 1),
        ...maybeSplit(withSchedule(partB), depth: depth + 1),
      ];
    }
    return [text];
  }
}

/// ---------------------------------------------------------------------------
/// STAGE 6.0d — Verb-Boundary Splitting (tak perlu koma)
///
/// Bila dengar kata kerja BARU selepas satu kata kerja + objeknya, tugasan
/// dipisahkan:
///   "ali basuh baju sental tandas harini"
///     -> "ali basuh baju"  +  "sental tandas harini"
///
/// Tidak dipisahkan jika kata kerja kedua ialah perkataan "ambiguous"
/// (pergi, balik, tulis ...) atau tiada objek di antara dua kata kerja:
///   "hantar anak pergi sekolah"  -> 1 tugasan
///   "masak makan malam"          -> 1 tugasan
/// ---------------------------------------------------------------------------
class VerbBoundarySplitter {
  static const Set<String> _notObject = {
    'dan',
    'and',
    'di',
    'pada',
    'on',
    'at',
    'untuk',
    'for',
    'pukul',
    'jam',
    'hari',
    'ini',
    'esok',
    'lusa',
    'today',
    'tomorrow',
    'tonight',
    'depan',
    'minggu',
    'bulan',
    'dalam',
    'lagi',
    'tarikh',
    'the',
    'a',
    'to',
    'of',
    'in',
    'next',
    'this',
    'pagi',
    'petang',
    'malam',
    'morning',
    'afternoon',
    'evening',
    'night',
    'tengah',
    'lalu',
    'kemudian',
  };

  static final Set<String> _dateWords = EntityRecognizer.dateWords;

  static bool _isObjectWord(String t) {
    if (t.length < 2) return false;
    if (RegExp(r'\d').hasMatch(t)) return false;
    return !_notObject.contains(t) && !_dateWords.contains(t);
  }

  static String _join(List<String> tokens) {
    final t = List<String>.from(tokens);
    while (t.isNotEmpty && (t.last == 'dan' || t.last == 'and')) {
      t.removeLast();
    }
    return t.join(' ');
  }

  static List<String> split(String text) {
    final tokens = text
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.length < 3) return [text];

    final segments = <String>[];
    int start = 0;
    bool seenVerb = false;
    int objects = 0;

    for (int i = 0; i < tokens.length; i++) {
      final t = tokens[i];
      if (IntentDetector.isSplitVerb(t)) {
        if (seenVerb && objects >= 1) {
          final seg = _join(tokens.sublist(start, i));
          if (seg.isNotEmpty) segments.add(seg);
          start = i;
        }
        seenVerb = true;
        objects = 0;
      } else if (seenVerb && _isObjectWord(t)) {
        objects++;
      }
    }

    if (segments.isEmpty) return [text];
    segments.add(tokens.sublist(start).join(' '));
    return segments;
  }
}

/// ---------------------------------------------------------------------------
/// STAGE 6.0 / 6.1 — Text Normalisation & Preprocessing
/// ---------------------------------------------------------------------------
class PreprocessedText {
  final String cleanedText;
  final List<String> tokens;
  PreprocessedText(this.cleanedText, this.tokens);
}

class TextPreprocessor {
  static const List<String> _fillerWords = [
    'um',
    'uh',
    'please',
    'like',
    'just',
    'so',
    'okay',
    'ok',
    'yeah',
    'lah',
    'eh',
    'erm',
    'hmm',
    'err',
  ];

  /// Spoken number words (only used right after pukul / jam / at).
  static const Map<String, int> _numberWords = {
    'dua belas': 12,
    'sebelas': 11,
    'sepuluh': 10,
    'sembilan': 9,
    'lapan': 8,
    'tujuh': 7,
    'enam': 6,
    'lima': 5,
    'empat': 4,
    'tiga': 3,
    'dua': 2,
    'satu': 1,
    'twelve': 12,
    'eleven': 11,
    'ten': 10,
    'nine': 9,
    'eight': 8,
    'seven': 7,
    'six': 6,
    'five': 5,
    'four': 4,
    'three': 3,
    'two': 2,
    'one': 1,
  };

  static final RegExp _numberWordAfterKeyword = RegExp(
    r'\b(pukul|jam|at)\s+(' +
        (_numberWords.keys.toList()
              ..sort((a, b) => b.length.compareTo(a.length)))
            .join('|') +
        r')\b',
  );

  /// Lower-cases and unifies the many ways people SAY the same thing.
  /// Keeps commas, because they are used to separate tasks.
  static String normalize(String raw) {
    var t = raw.toLowerCase();
    t = t.replaceAll("'", '').replaceAll('\u2019', '');

    // 8.30 -> 8:30
    t = t.replaceAllMapped(
      RegExp(r'(\d)\.(\d{2})(?!\d)'),
      (m) => '${m[1]}:${m[2]}',
    );
    // "9 a.m." / "9 a m" / "9 AM" -> 9am
    t = t.replaceAllMapped(
      RegExp(r'\b(\d{1,2}(?::\d{2})?)\s*([ap])\s?\.?\s?m\b\.?'),
      (m) => '${m[1]}${m[2]}m',
    );

    t = t.replaceAll(RegExp(r'\bharini\b|\bhari ni\b'), 'hari ini');
    t = t.replaceAll(RegExp(r'\bbesok\b'), 'esok');
    t = t.replaceAll(RegExp(r'\bjumat\b'), 'jumaat');
    // Fix words the speech engine commonly mishears ("ahad" -> "ahay" ...).
    t = _fixMisheardWeekdays(t);
    t = t.replaceAll(RegExp(r'\bminggu hadapan\b'), 'minggu depan');
    t = t.replaceAll(RegExp(r'\bbulan hadapan\b'), 'bulan depan');
    t = t.replaceAll(RegExp(r'\btengahari\b'), 'tengah hari');
    t = t.replaceAll(RegExp(r'\bmalam ni\b'), 'malam ini');
    t = t.replaceAll(RegExp(r'\bminggu ni\b'), 'minggu ini');
    t = t.replaceAll(RegExp(r'\bpkl\b'), 'pukul');
    // "kesekolah" -> "ke sekolah" (STT kadang-kadang rapatkan)
    t = t.replaceAllMapped(
      RegExp(
        r'\bke(sekolah|rumah|kedai|klinik|hospital|pejabat|pasar|sana|sini)\b',
      ),
      (m) => 'ke ${m[1]}',
    );

    // "pukul lapan" -> "pukul 8", "at five" -> "at 5"
    t = t.replaceAllMapped(
      _numberWordAfterKeyword,
      (m) => '${m[1]} ${_numberWords[m[2]]}',
    );

    return t.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
  }

  // ------------------------------------------------------------------
  // Weekday mishearing fix
  // ------------------------------------------------------------------
  // Speech-to-text often turns "ahad" into "ahay" / "ahat" / "a had", so
  // the date recogniser never saw a weekday. These map the usual mistakes
  // back to the real word BEFORE any date detection runs.
  static const Map<String, String> _weekdayAliases = {
    // ahad (Sunday)
    'ahay': 'ahad',
    'ahat': 'ahad',
    'ahed': 'ahad',
    'ahaad': 'ahad',
    'ahadd': 'ahad',
    'ahaq': 'ahad',
    // isnin (Monday)
    'isnen': 'isnin',
    'esnin': 'isnin',
    'isnain': 'isnin',
    // selasa (Tuesday)
    'selasar': 'selasa',
    'selassa': 'selasa',
    // rabu (Wednesday)
    'rabo': 'rabu',
    'rabbu': 'rabu',
    // khamis (Thursday)
    'kamis': 'khamis',
    'hamis': 'khamis',
    'kamees': 'khamis',
    'khamees': 'khamis',
    // jumaat (Friday)
    'jumaah': 'jumaat',
    'jumaaat': 'jumaat',
    // sabtu (Saturday)
    'sabto': 'sabtu',
    'sapto': 'sabtu',
    'saptu': 'sabtu',
  };

  static final RegExp _weekdayAliasRe = RegExp(
    r'\b(' + _weekdayAliases.keys.join('|') + r')\b',
  );

  static const List<String> _malayWeekdays = [
    'isnin',
    'selasa',
    'rabu',
    'khamis',
    'jumaat',
    'sabtu',
    'ahad',
  ];

  /// Real words that are 1 letter away from a weekday but must be left alone.
  static const Set<String> _fuzzyStopWords = {'ahead'};

  static String _fixMisheardWeekdays(String input) {
    var t = input;

    // "hari a had" / "a had" -> "ahad"
    t = t.replaceAllMapped(
      RegExp(r'\bhari\s+a\s+(?:had|hat|hay)\b'),
      (_) => 'hari ahad',
    );
    t = t.replaceAll(RegExp(r'\ba\s+had\b'), 'ahad');

    // Known mishearings (ahay, kamis, sapto ...).
    t = t.replaceAllMapped(_weekdayAliasRe, (m) => _weekdayAliases[m[1]]!);

    // Safety net: right after "hari / next / this / coming / on", a word that
    // is ONE letter away from a Malay weekday is treated as that weekday.
    t = t.replaceAllMapped(
      RegExp(r'\b(hari|next|this|coming|on)\s+([a-z]{4,9})\b'),
      (m) {
        final word = m[2]!;
        if (_malayWeekdays.contains(word) || _fuzzyStopWords.contains(word)) {
          return m[0]!;
        }
        for (final day in _malayWeekdays) {
          if (_editDistance(word, day) <= 1) return '${m[1]} $day';
        }
        return m[0]!;
      },
    );
    return t;
  }

  /// Levenshtein distance; returns 2 early when the words differ too much.
  static int _editDistance(String a, String b) {
    if ((a.length - b.length).abs() > 1) return 2;
    var prev = List<int>.generate(b.length + 1, (j) => j);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0);
      cur[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        final best = [
          prev[j] + 1,
          cur[j - 1] + 1,
          prev[j - 1] + cost,
        ].reduce((x, y) => x < y ? x : y);
        cur[j] = best;
      }
      prev = cur;
    }
    return prev[b.length];
  }

  static PreprocessedText run(String rawText) {
    var text = normalize(rawText);
    text = text.replaceAll(RegExp(r'[^\p{L}\p{N}_\s:/]', unicode: true), ' ');
    var tokens = text.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    tokens = tokens.where((t) => !_fillerWords.contains(t)).toList();
    return PreprocessedText(tokens.join(' '), tokens);
  }
}

/// ---------------------------------------------------------------------------
/// STAGE 6.2 — Intent Detection (keyword + kata dasar + fuzzy yang ketat)
///
/// Satu perkataan dikira KATA KERJA TUGASAN jika:
///   1. ada dalam senarai [_taskActionWords]            (cth: beli)
///   2. kata dasarnya ada dalam senarai                 (cth: membeli, buying)
///   3. hampir sama (1 huruf silap/tertukar, huruf pertama SAMA) dengan
///      perkataan dalam senarai                         (cth: blei -> beli)
///
/// Nak tambah kata kerja baru? Tambah SAHAJA dalam [_taskActionWords].
/// Letak kata KERJA sahaja (bukan kata nama seperti baju/kereta/duit),
/// supaya "beli seluar dan baju" tidak dipecahkan salah.
/// ---------------------------------------------------------------------------
class IntentResult {
  final String intent;
  final double confidence;
  IntentResult(this.intent, this.confidence);
}

class IntentDetector {
  static const List<String> _taskActionWords = [
    // ===== ASAL (English) =====
    'buy', 'pay', 'clean', 'finish', 'submit', 'pick', 'send', 'call',
    'meet', 'bring', 'wash', 'feed', 'walk', 'do', 'complete', 'attend',
    'prepare', 'cook', 'book', 'renew', 'review', 'water', 'study',
    'practice', 'check', 'fix', 'return', 'drop', 'collect', 'remind',
    'homework', 'meeting', 'appointment', 'schedule', 'organize', 'go',
    'going', 'get', 'take', 'make', 'read', 'write', 'pack', 'wait',
    'throw', 'wipe', 'tidy', 'iron', 'mop', 'sweep', 'visit', 'fetch',
    // ===== ASAL (Melayu) =====
    'beli', 'bayar', 'hantar', 'ambil', 'pergi', 'balik', 'jumpa',
    'telefon', 'masak', 'basuh', 'bersih', 'siapkan', 'buat', 'jemput',
    'tempah', 'bawa', 'pulang', 'belajar', 'sekolah', 'kerja',
    'temujanji', 'mesyuarat', 'ke', 'tolong', 'ingatkan', 'buang',
    'cuci', 'sapu', 'lap', 'kemas', 'siram', 'lipat', 'sidai', 'gosok',
    'semak', 'daftar', 'tukar', 'jaga', 'teman', 'hantarkan', 'belikan',
    'ambilkan', 'bawakan', 'sediakan', 'kemaskan', 'makan', 'tuang',
    'hubungi', 'lawat', 'renew', 'perbaharui', 'isi',

    // ===== TAMBAHAN: English =====
    'bake', 'apply', 'register', 'deliver', 'email', 'message', 'print',
    'wake', 'exercise', 'jog', 'swim', 'pray', 'shower', 'brush',
    'arrange', 'confirm', 'cancel', 'reschedule', 'repair', 'replace',
    'invite', 'borrow', 'donate', 'transfer', 'upload', 'download',
    'update', 'install', 'vacuum', 'dust', 'scrub', 'fold', 'plant',
    'trim', 'mow', 'revise', 'remember', 'refill', 'scan', 'boil', 'fry',
    'groom', 'claim', 'refund', 'recharge',

    // ===== TAMBAHAN: Melayu umum =====
    'minum', 'mandi', 'tidur', 'bangun', 'solat', 'sembahyang', 'mengaji',
    'baca', 'tulis', 'ulangkaji', 'kaji', 'siap', 'cari', 'tanya',
    'beritahu', 'maklumkan', 'panggil', 'mesej', 'emel', 'cetak',
    'tandatangan', 'sertai', 'hadir', 'tunggu', 'singgah', 'keluar',
    'masuk', 'periksa', 'urus', 'selesaikan', 'habiskan', 'lengkapkan',
    'serahkan', 'pulangkan', 'kembalikan', 'pinjam', 'jual', 'sewa',
    'beri', 'bagi', 'simpan', 'letak', 'ajak', 'ajar', 'lupa', 'ingat',

    // ===== SINONIM: kerja rumah / gotong-royong =====
    'gotong', 'royong', 'bersihkan', 'rapi', 'sental', 'gilap', 'bilas',
    'kibas', 'kutip', 'susun', 'atur', 'vakum', 'kemaskan',

    // ===== SINONIM: dapur / lain-lain (jarang) =====
    'goreng', 'rebus', 'panaskan', 'bakar', 'kukus', 'hidang', 'potong',
    'gunting', 'pangkas', 'tanam', 'cabut', 'baiki', 'servis', 'tuntut',
    'mohon', 'hadiri', 'sambut', 'rancang', 'uruskan', 'hafal', 'praktis',
    'alih', 'pindah', 'angkat', 'gantung', 'pasang', 'tutup', 'buka',
    'borong', 'suap', 'kirim', 'sahkan', 'batal', 'ganti',
  ];

  static final Set<String> _actionSet = _taskActionWords.toSet();
  static Set<String> get actionWords => _actionSet;

  /// Perkataan yang TIDAK akan di-fuzzy (tarikh, masa, nombor, barang biasa)
  /// kerana mudah tersalah padan dengan kata kerja.
  static final Set<String> _fuzzyBlock = {
    ...EntityRecognizer.dateWords,
    ...TextPreprocessor._numberWords.keys,
    'hari',
    'esok',
    'lusa',
    'pagi',
    'petang',
    'malam',
    'pukul',
    'jam',
    'minggu',
    'bulan',
    'tahun',
    'depan',
    'ini',
    'tengah',
    'hujung',
    'masa',
    'today',
    'tomorrow',
    'tonight',
    'morning',
    'evening',
    'night',
    'week',
    'month',
    'next',
    'this',
    'weekend',
    'ibu',
    'ayah',
    'bapa',
    'mama',
    'papa',
    'abang',
    'kakak',
    'adik',
    'nenek',
    'atuk',
    'kasut',
    'buku',
    'baju',
    'roti',
    'susu',
    'telur',
    'beras',
    'nasi',
    'ikan',
    'ayam',
    'kucing',
    'sayur',
    'buah',
    'lagi',
    'pada',
    'untuk',
    'dalam',
    'dengan',
    'yang',
    'sana',
    'sini',
    'situ',
    'kita',
    'saya',
    'awak',
    'kami',
  };

  static const List<String> _malayPrefixes = [
    'meng',
    'meny',
    'peng',
    'peny',
    'mem',
    'men',
    'pem',
    'pen',
    'ber',
    'ter',
    'me',
    'pe',
    'di',
    'se',
  ];
  static const List<String> _malaySuffixes = ['kan', 'lah', 'kah', 'an', 'i'];

  // ---------------- padanan ----------------

  /// Adakah [token] kata kerja tugasan? (tepat -> kata dasar -> fuzzy)
  static bool isActionWord(String token) {
    final w = token.toLowerCase().trim();
    if (w.isEmpty) return false;
    if (_actionSet.contains(w)) return true;
    if (_stemMalay(w) != null) return true;
    if (_stemEnglish(w) != null) return true;
    return _fuzzyMatch(w);
  }

  /// membeli->beli, menyapu->sapu, mengemas->kemas, dibasuh->basuh,
  /// bergotong->gotong. Hanya diterima jika kata dasar ADA dalam senarai.
  static String? _stemMalay(String w) {
    if (w.length < 5) return null;
    final bases = <String>{w};
    for (final s in _malaySuffixes) {
      if (w.endsWith(s) && w.length - s.length >= 3) {
        bases.add(w.substring(0, w.length - s.length));
      }
    }
    for (final b in bases.toList()) {
      for (final p in _malayPrefixes) {
        if (!b.startsWith(p) || b.length - p.length < 3) continue;
        final rest = b.substring(p.length);
        // meng+kemas -> k, meny+sapu -> s, men+tulis -> t, mem+pinjam -> p
        bases.addAll([rest, 'k$rest', 's$rest', 't$rest', 'p$rest']);
      }
    }
    for (final c in bases) {
      if (c != w && c.length >= 3 && _actionSet.contains(c)) return c;
    }
    return null;
  }

  /// buying->buy, washed->wash, cleaning->clean, making->make, calls->call
  static String? _stemEnglish(String w) {
    const irregular = {
      'paid': 'pay',
      'bought': 'buy',
      'sent': 'send',
      'took': 'take',
      'brought': 'bring',
      'made': 'make',
      'went': 'go',
      'doing': 'do',
      'did': 'do',
      'got': 'get',
    };
    final irr = irregular[w];
    if (irr != null) return irr;

    final c = <String>{};
    void add(String b) {
      if (b.length < 3) return;
      c.addAll([b, '${b}e']);
      if (b.length >= 4 && b[b.length - 1] == b[b.length - 2]) {
        c.add(b.substring(0, b.length - 1)); // stopped -> stop
      }
    }

    if (w.endsWith('ing') && w.length >= 5) add(w.substring(0, w.length - 3));
    if (w.endsWith('ed') && w.length >= 4) add(w.substring(0, w.length - 2));
    if (w.endsWith('es') && w.length >= 4) add(w.substring(0, w.length - 2));
    if (w.endsWith('s') && w.length >= 4) add(w.substring(0, w.length - 1));
    for (final x in c) {
      if (x != w && _actionSet.contains(x)) return x;
    }
    return null;
  }

  /// Fuzzy ketat: minimum 4 huruf, huruf PERTAMA sama, beza maksimum 1
  /// (silap satu huruf / tertinggal / lebih / dua huruf bertukar tempat).
  /// blei->beli, bayr->bayar, basoh->basuh.
  static bool _fuzzyMatch(String w) {
    if (w.length < 4 || _fuzzyBlock.contains(w)) return false;
    if (RegExp(r'\d').hasMatch(w)) return false;
    for (final cand in _actionSet) {
      if (cand.length < 4 || cand[0] != w[0]) continue;
      if ((cand.length - w.length).abs() > 1) continue;
      if (_withinOneEdit(w, cand)) return true;
    }
    return false;
  }

  static bool _withinOneEdit(String a, String b) {
    if (a == b) return true;
    final la = a.length, lb = b.length;
    if ((la - lb).abs() > 1) return false;

    if (la == lb) {
      int first = -1, last = -1, diffs = 0;
      for (int i = 0; i < la; i++) {
        if (a[i] != b[i]) {
          diffs++;
          if (first < 0) first = i;
          last = i;
          if (diffs > 2) return false;
        }
      }
      if (diffs == 1) return true;
      // dua huruf bertukar tempat: blei <-> beli
      return diffs == 2 &&
          last == first + 1 &&
          a[first] == b[last] &&
          a[last] == b[first];
    }

    final s = la < lb ? a : b; // lebih pendek
    final l = la < lb ? b : a;
    int i = 0;
    while (i < s.length && s[i] == l[i]) {
      i++;
    }
    return s.substring(i) == l.substring(i + 1);
  }

  // ---------------- API awam ----------------

  static IntentResult run(List<String> tokens) {
    final matchCount = tokens.where(isActionWord).length;
    if (matchCount == 0) {
      return IntentResult('create_task', 0.4);
    }
    final confidence = (0.7 + (matchCount - 1) * 0.1).clamp(0.7, 0.98);
    return IntentResult('create_task', confidence);
  }

  static bool containsActionWord(String text) {
    final tokens = text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty);
    return tokens.any(isActionWord);
  }

  /// Kata kerja yang TIDAK dijadikan titik pisah tugasan secara automatik,
  /// kerana selalunya sebahagian ayat yang sama:
  ///   "hantar anak PERGI sekolah", "beli buku TULIS", "buat KERJA sekolah".
  /// (Tugasan masih boleh dipisah guna koma / titik / tarikh berbeza.)
  static const Set<String> _noSplitVerbs = {
    'pergi', 'balik', 'pulang', 'ke', 'go', 'going', 'tolong', 'remind',
    'ingatkan', 'get', 'take', 'make', 'do', 'bring', 'bawa', 'keluar',
    'masuk', 'naik', 'turun', 'tunggu', 'wait', 'tulis', 'baca', 'write',
    'read', 'isi', 'tambah', 'siap',
    // kata nama yang ada dalam senarai
    'sekolah', 'kerja', 'homework', 'meeting', 'appointment', 'schedule',
    'temujanji', 'mesyuarat',
  };

  /// Adakah [token] kata kerja yang SELAMAT dijadikan permulaan tugasan baru?
  /// Ketat: hanya padanan tepat atau kata dasar (TANPA fuzzy), supaya nama
  /// orang atau perkataan biasa tidak memecahkan tugasan secara salah.
  static bool isSplitVerb(String token) {
    final w = token.toLowerCase().trim();
    if (w.length < 3 || _fuzzyBlock.contains(w)) return false;
    String? root;
    if (_actionSet.contains(w)) {
      root = w;
    } else {
      root = _stemMalay(w) ?? _stemEnglish(w);
    }
    if (root == null) return false;
    return !_noSplitVerbs.contains(w) && !_noSplitVerbs.contains(root);
  }
}

/// ---------------------------------------------------------------------------
/// STAGE 6.3 — Folder Resolution (spelling + sound-alike matching)
///
/// Speech engines often "hear" a name as a more common word:
///   Iwa -> eva / ewa,   Naura -> laura / nora / norah.
/// So each candidate word is compared with the folder name in TWO ways:
///   1. plain spelling similarity (Levenshtein), and
///   2. a PHONETIC KEY where similar-sounding letters share one symbol
///      (v/w/f, b/p, d/t, g/k/c, e/i, o/u ...; silent "h" is dropped).
/// The better of the two scores is used.
/// ---------------------------------------------------------------------------
class FolderMatch {
  final String? folderName;
  final String remainingText;
  FolderMatch(this.folderName, this.remainingText);
}

class FolderResolver {
  static final Set<String> _stopWords = {
    ...IntentDetector.actionWords,
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
    ...EntityRecognizer.dateWords,
  };

  /// A match this good counts as "sure". Among SURE matches, the name spoken
  /// FIRST wins ("Mama bring Naura to school" -> Mama). Weak matches are only
  /// used when there is no sure match.
  static const double _strongScore = 0.85;

  static double _requiredScore(int compactLength) {
    if (compactLength <= 3) return 0.95; // short names: sound must be equal
    if (compactLength <= 5) return 0.74;
    return 0.72;
  }

  static FolderMatch run(String cleanedText, List<String> knownFolderNames) {
    final tokens = cleanedText.split(' ').where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty || knownFolderNames.isEmpty) {
      return FolderMatch(null, cleanedText);
    }

    String? bestFolder;
    int bestStart = 0;
    int bestLen = 0;
    double bestScore = 0;
    bool bestStrong = false;

    for (final folder in knownFolderNames) {
      final folderLower = folder.toLowerCase().trim();
      if (folderLower.isEmpty) continue;

      final folderTokenCount = folderLower.split(RegExp(r'\s+')).length;
      final compactLength = folderLower.replaceAll(' ', '').length;
      final needed = _requiredScore(compactLength);

      final minLen = folderTokenCount > 1 ? folderTokenCount - 1 : 1;
      final maxLen = folderTokenCount + 1;

      for (int len = minLen; len <= maxLen; len++) {
        if (len > tokens.length) continue;
        for (int i = 0; i + len <= tokens.length; i++) {
          final windowTokens = tokens.sublist(i, i + len);
          final window = windowTokens.join(' ');

          // Don't let ordinary words (verbs, date words) be mistaken for a
          // name — unless the window is EXACTLY the folder name.
          if (window != folderLower && windowTokens.any(_stopWords.contains)) {
            continue;
          }
          if (windowTokens.any((t) => RegExp(r'^\d+$').hasMatch(t))) continue;

          final score = _score(window, folderLower);
          if (score < needed) continue;
          // NAMA YANG DISEBUT DAHULU = pemilik tugasan:
          // "mama hantar naura ke sekolah" -> folder mama.
          final strong = score >= _strongScore;
          final bool better;
          if (bestFolder == null) {
            better = true;
          } else if (strong != bestStrong) {
            better = strong; // a sure match beats a weak one
          } else if (strong) {
            // both sure: earliest position wins; same spot -> best score
            better =
                i < bestStart ||
                (i == bestStart &&
                    (score > bestScore ||
                        (score == bestScore && len > bestLen)));
          } else {
            // both weak: best score wins, then longer, then earlier
            better =
                score > bestScore ||
                (score == bestScore && len > bestLen) ||
                (score == bestScore && len == bestLen && i < bestStart);
          }
          if (better) {
            bestScore = score;
            bestStrong = strong;
            bestFolder = folder;
            bestStart = i;
            bestLen = len;
          }
        }
      }
    }

    if (bestFolder == null) {
      return FolderMatch(null, cleanedText);
    }

    final before = tokens.sublist(0, bestStart);
    final after = tokens.sublist(bestStart + bestLen);
    final remaining = [...before, ...after].join(' ').trim();
    return FolderMatch(bestFolder, remaining);
  }

  static double _score(String a, String b) {
    final aClean = a.replaceAll(' ', '');
    final bClean = b.replaceAll(' ', '');
    if (aClean == bClean) return 1.0;

    final spelling = _similarity(aClean, bClean);

    final aKey = phoneticKey(aClean);
    final bKey = phoneticKey(bClean);
    final sound = (aKey.length >= 2 && bKey.length >= 2)
        ? _similarity(aKey, bKey) * 0.97
        : 0.0;

    return spelling > sound ? spelling : sound;
  }

  /// Sound-alike key. Exposed so it can be unit-tested.
  static String phoneticKey(String input) {
    var t = input.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    t = t
        .replaceAll('ph', 'f')
        .replaceAll('ck', 'k')
        .replaceAll('kh', 'k')
        .replaceAll('sh', 's')
        .replaceAll('sy', 's')
        .replaceAll('th', 't')
        .replaceAll('gh', 'g')
        .replaceAll('ch', 'c');

    final sb = StringBuffer();
    String last = '';
    for (final ch in t.split('')) {
      String out;
      switch (ch) {
        case 'a':
          out = 'a';
        case 'e':
        case 'i':
        case 'y':
          out = 'i';
        case 'o':
        case 'u':
          out = 'u';
        case 'b':
        case 'p':
          out = 'p';
        case 'd':
        case 't':
          out = 't';
        case 'g':
        case 'k':
        case 'c':
        case 'q':
          out = 'k';
        case 'f':
        case 'v':
        case 'w':
          out = 'w';
        case 'x':
          out = 'k';
        case 'h':
          out = ''; // often silent / dropped (Aisyah, Aisha, Noah)
        default:
          out = ch; // j l m n r s z
      }
      if (out.isEmpty || out == last) continue;
      sb.write(out);
      last = out;
    }
    return sb.toString();
  }

  static double _similarity(String a, String b) {
    final maxLen = a.length > b.length ? a.length : b.length;
    if (maxLen == 0) return 0;
    return 1 - (_levenshtein(a, b) / maxLen);
  }

  static int _levenshtein(String s, String t) {
    if (s == t) return 0;
    if (s.isEmpty) return t.length;
    if (t.isEmpty) return s.length;

    List<int> prev = List<int>.generate(t.length + 1, (i) => i);
    List<int> curr = List<int>.filled(t.length + 1, 0);

    for (int i = 1; i <= s.length; i++) {
      curr[0] = i;
      for (int j = 1; j <= t.length; j++) {
        final cost = s[i - 1] == t[j - 1] ? 0 : 1;
        final insert = curr[j - 1] + 1;
        final delete = prev[j] + 1;
        final replace = prev[j - 1] + cost;
        int best = insert < delete ? insert : delete;
        if (replace < best) best = replace;
        curr[j] = best;
      }
      prev = List<int>.from(curr);
    }
    return prev[t.length];
  }
}

/// ---------------------------------------------------------------------------
/// STAGE 6.4 — Entity Recognition (dates + times, Malay and English)
/// ---------------------------------------------------------------------------
class ExtractedEntities {
  final TimeOfDayValue? time;
  final String? rawDatePhrase;
  final DateTime? dateTime;
  final String taskDescription;

  ExtractedEntities({
    this.time,
    this.rawDatePhrase,
    this.dateTime,
    required this.taskDescription,
  });
}

class DateHit {
  final DateTime date; // midnight of the resolved day
  final String matchedText;
  final int start;
  final int end;
  final bool rolloverIfPast; // plain weekday said on that same weekday
  final TimeOfDayValue? impliedTime; // e.g. "malam ini" -> 8 PM

  /// Time used when the user said NO time (e.g. "today"/"tomorrow" -> 5 PM).
  /// Unlike [impliedTime], this is NOT treated as a time the user said.
  final TimeOfDayValue? defaultTime;

  DateHit({
    required this.date,
    required this.matchedText,
    required this.start,
    required this.end,
    this.rolloverIfPast = false,
    this.impliedTime,
    this.defaultTime,
  });
}

class TimeHit {
  final TimeOfDayValue time;
  final String matchedText;
  final int start;
  final int end;
  TimeHit(this.time, this.matchedText, this.start, this.end);
}

class EntityRecognizer {
  static const Map<String, int> _weekdayNumbers = {
    'monday': 1,
    'tuesday': 2,
    'wednesday': 3,
    'thursday': 4,
    'friday': 5,
    'saturday': 6,
    'sunday': 7,
    'isnin': 1,
    'selasa': 2,
    'rabu': 3,
    'khamis': 4,
    'jumaat': 5,
    'sabtu': 6,
    'ahad': 7,
  };

  static const Map<String, int> _months = {
    'jan': 1,
    'january': 1,
    'januari': 1,
    'feb': 2,
    'february': 2,
    'februari': 2,
    'mar': 3,
    'march': 3,
    'mac': 3,
    'apr': 4,
    'april': 4,
    'may': 5,
    'mei': 5,
    'jun': 6,
    'june': 6,
    'jul': 7,
    'july': 7,
    'julai': 7,
    'aug': 8,
    'august': 8,
    'ogos': 8,
    'sep': 9,
    'sept': 9,
    'september': 9,
    'oct': 10,
    'october': 10,
    'okt': 10,
    'oktober': 10,
    'nov': 11,
    'november': 11,
    'dec': 12,
    'december': 12,
    'dis': 12,
    'disember': 12,
  };

  /// All weekday + month words (used by FolderResolver's stop-word list).
  static Set<String> get dateWords => {
    ..._weekdayNumbers.keys,
    ..._months.keys,
  };

  static const String _period =
      r'pagi|tengah\s+hari|petang|malam|morning|afternoon|evening|night';

  static final String _monthPattern =
      (_months.keys.toList()..sort((a, b) => b.length.compareTo(a.length)))
          .join('|');
  static final String _weekdayPattern =
      (_weekdayNumbers.keys.toList()
            ..sort((a, b) => b.length.compareTo(a.length)))
          .join('|');

  // ---------------- regexes ----------------

  static final RegExp _reDayMonth = RegExp(
    r'\b(?:tarikh\s+)?(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+|haribulan\s+)?(' +
        _monthPattern +
        r')\b(?:\s+(\d{4}))?',
  );
  static final RegExp _reMonthDay = RegExp(
    r'\b(' + _monthPattern + r')\s+(\d{1,2})(?:st|nd|rd|th)?\b',
  );
  static final RegExp _reNumericDate = RegExp(
    r'\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b',
  );
  static final RegExp _reInOffset = RegExp(
    r'\b(?:dalam|in)\s+(\d{1,2})\s+(hari|days?|minggu|weeks?)\b',
  );
  static final RegExp _reOffsetLagi = RegExp(
    r'\b(\d{1,2})\s+(hari|minggu)\s+lagi\b',
  );
  static final RegExp _reWeekday = RegExp(
    r'\b(?:hari\s+)?(?:(next|this|coming)\s+)?(' +
        _weekdayPattern +
        r')\b(?:\s+(?:(minggu\s+)?(depan|ini)|(next|this)\s+week))?',
  );
  static final RegExp _reWeekend = RegExp(
    r'\b(?:(next|this)\s+)?(?:hujung\s+minggu|weekend)(\s+depan|\s+ini)?\b',
  );
  static final RegExp _reNextWeek = RegExp(
    r'\b(?:minggu\s+depan|next\s+week)\b',
  );
  static final RegExp _reNextMonth = RegExp(
    r'\b(?:bulan\s+depan|next\s+month)\b',
  );
  static final RegExp _reDayAfterTomorrow = RegExp(
    r'\b(?:day\s+after\s+tomorrow|lusa)\b',
  );
  static final RegExp _reTonight = RegExp(r'\b(?:tonight|malam\s+ini)\b');
  static final RegExp _reToday = RegExp(r'\b(?:today|hari\s+ini)\b');
  static final RegExp _reTomorrow = RegExp(r'\b(?:tomorrow|esok)\b');

  // time
  static final RegExp _reTimeAmPm = RegExp(
    r'(?:\b(?:pada\s+)?(?:pukul|jam|at)\s+)?(?<!\d)(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b',
  );
  static final RegExp _reTimeKeyword = RegExp(
    r'\b(?:pada\s+)?(?:pukul|jam|at)\s+(\d{1,2})(?::(\d{2}))?(?:\s*(' +
        _period +
        r'))?(?!\d)(?!\s*(?:st|nd|rd|th)\b)(?!\s+(?:' +
        _monthPattern +
        r')\b)',
  );
  static final RegExp _reTimePeriod = RegExp(
    r'(?<!\d)(\d{1,2})(?::(\d{2}))?\s*(' + _period + r')\b',
  );
  static final RegExp _reTime24 = RegExp(
    r'(?<![\d:])(\d{1,2}):(\d{2})(?![\d:])',
  );
  static final RegExp _afterDatePeriod = RegExp(
    r'^\s+(' + _period + r')(?=\s|$)',
  );
  static final RegExp _trailingTime = RegExp(
    r'^\s*(?:(?:pada\s+)?(?:pukul|jam|at)\s+\d{1,2}(?::\d{2})?(?:\s*(?:am|pm|' +
        _period +
        r'))?'
            r'|\d{1,2}(?::\d{2})?\s*(?:am|pm|' +
        _period +
        r')'
            r'|\d{1,2}:\d{2}'
            r'|(?:' +
        _period +
        r'))(?=\s|$|,)',
  );

  // ---------------- main entry ----------------

  static ExtractedEntities run(String textAfterFolderRemoved, {DateTime? now}) {
    final clock = now ?? DateTime.now();
    final text = textAfterFolderRemoved.toLowerCase();

    final dateHit = _findDate(text, clock);
    var remaining = text;
    TimeOfDayValue? periodTime;

    if (dateHit != null) {
      var end = dateHit.end;
      // "esok pagi", "rabu malam" -> the part of day right after the date.
      final after = _afterDatePeriod.firstMatch(text.substring(end));
      if (after != null) {
        periodTime = _periodDefault(after.group(1)!);
        end += after.end;
      }
      remaining = '${text.substring(0, dateHit.start)} ${text.substring(end)}';
    }

    final timeHit = _findTime(remaining);
    if (timeHit != null) {
      remaining =
          '${remaining.substring(0, timeHit.start)} ${remaining.substring(timeHit.end)}';
    }

    final time = timeHit?.time ?? periodTime ?? dateHit?.impliedTime;
    final (dateTime, rawPhrase) = DateNormalizer.combine(
      hit: dateHit,
      time: time,
      now: clock,
    );

    return ExtractedEntities(
      time: time,
      rawDatePhrase: rawPhrase,
      dateTime: dateTime,
      taskDescription: _capitalize(_cleanDescription(remaining)),
    );
  }

  // ---------------- date finding ----------------

  static DateTime _addDays(DateTime d, int n) =>
      DateTime(d.year, d.month, d.day + n);

  static DateTime? _validDate(int year, int month, int day) {
    final d = DateTime(year, month, day);
    return (d.year == year && d.month == month && d.day == day) ? d : null;
  }

  static DateTime? _resolveYear(int month, int day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    for (int y = now.year; y <= now.year + 4; y++) {
      final candidate = _validDate(y, month, day);
      if (candidate != null && !candidate.isBefore(today)) return candidate;
    }
    return null;
  }

  static DateHit? _findDate(String text, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);

    DateHit hit(
      RegExpMatch m,
      DateTime date, {
      bool rollover = false,
      TimeOfDayValue? implied,
      TimeOfDayValue? defaultTime,
    }) => DateHit(
      date: date,
      matchedText: m.group(0)!.trim(),
      start: m.start,
      end: m.end,
      rolloverIfPast: rollover,
      impliedTime: implied,
      defaultTime: defaultTime,
    );

    RegExpMatch? m;

    // 17 jun / 17th of june / tarikh 17 haribulan jun [2027]
    m = _reDayMonth.firstMatch(text);
    if (m != null) {
      final day = int.parse(m.group(1)!);
      final month = _months[m.group(2)!]!;
      final year = m.group(3);
      final d = year != null
          ? _validDate(int.parse(year), month, day)
          : _resolveYear(month, day);
      if (d != null) return hit(m, d);
    }

    // june 17
    m = _reMonthDay.firstMatch(text);
    if (m != null) {
      final month = _months[m.group(1)!]!;
      final day = int.parse(m.group(2)!);
      final d = _resolveYear(month, day);
      if (d != null) return hit(m, d);
    }

    // 17/6 or 17/6/2026  (day/month — Malaysian order)
    m = _reNumericDate.firstMatch(text);
    if (m != null) {
      final day = int.parse(m.group(1)!);
      final month = int.parse(m.group(2)!);
      var yearStr = m.group(3);
      DateTime? d;
      if (yearStr != null) {
        var y = int.parse(yearStr);
        if (y < 100) y += 2000;
        d = _validDate(y, month, day);
      } else if (month >= 1 && month <= 12) {
        d = _resolveYear(month, day);
      }
      if (d != null) return hit(m, d);
    }

    // dalam 3 hari / 3 hari lagi / in 2 weeks
    m = _reInOffset.firstMatch(text) ?? _reOffsetLagi.firstMatch(text);
    if (m != null) {
      final n = int.parse(m.group(1)!);
      final unit = m.group(2)!;
      final isWeeks = unit.startsWith('minggu') || unit.startsWith('week');
      return hit(m, _addDays(today, isWeeks ? n * 7 : n));
    }

    // weekdays: rabu / hari rabu / rabu depan / rabu minggu depan /
    //           next wednesday / this friday / wednesday next week
    m = _reWeekday.firstMatch(text);
    if (m != null) {
      final target = _weekdayNumbers[m.group(2)!]!;
      final prefix = m.group(1);
      final tail = m.group(4); // depan | ini
      final weekScoped = m.group(3) != null || m.group(5) != null;

      if (weekScoped) {
        final isNext = tail == 'depan' || m.group(5) == 'next';
        final monday = _addDays(today, -(today.weekday - 1));
        var d = _addDays(monday, (isNext ? 7 : 0) + target - 1);
        if (d.isBefore(today)) d = _addDays(d, 7);
        return hit(m, d);
      }

      final strictNext = prefix == 'next' || tail == 'depan';
      final diff = (target - today.weekday) % 7;
      if (strictNext) {
        return hit(m, _addDays(today, diff == 0 ? 7 : diff));
      }
      return hit(m, _addDays(today, diff), rollover: diff == 0);
    }

    // hujung minggu / weekend
    m = _reWeekend.firstMatch(text);
    if (m != null) {
      final isNext =
          m.group(1) == 'next' || (m.group(2) ?? '').trim() == 'depan';
      if (isNext) {
        final monday = _addDays(today, -(today.weekday - 1));
        return hit(m, _addDays(monday, 7 + 5));
      }
      final diff = (6 - today.weekday) % 7;
      return hit(m, _addDays(today, diff), rollover: diff == 0);
    }

    // minggu depan / next week (no weekday said) -> same day next week
    m = _reNextWeek.firstMatch(text);
    if (m != null) return hit(m, _addDays(today, 7));

    // bulan depan / next month -> same day number next month
    m = _reNextMonth.firstMatch(text);
    if (m != null) {
      final firstNext = DateTime(today.year, today.month + 1, 1);
      final lastDay = DateTime(firstNext.year, firstNext.month + 1, 0).day;
      final day = today.day > lastDay ? lastDay : today.day;
      return hit(m, DateTime(firstNext.year, firstNext.month, day));
    }

    m = _reDayAfterTomorrow.firstMatch(text);
    if (m != null) return hit(m, _addDays(today, 2));

    m = _reTonight.firstMatch(text);
    if (m != null) return hit(m, today, implied: TimeOfDayValue(20, 0));

    m = _reToday.firstMatch(text);
    if (m != null) {
      return hit(m, today, defaultTime: DateNormalizer.todayTomorrowDefault);
    }

    m = _reTomorrow.firstMatch(text);
    if (m != null) {
      return hit(
        m,
        _addDays(today, 1),
        defaultTime: DateNormalizer.todayTomorrowDefault,
      );
    }

    return null;
  }

  // ---------------- time finding ----------------

  static TimeOfDayValue _periodDefault(String period) {
    switch (period.replaceAll(RegExp(r'\s+'), ' ')) {
      case 'pagi':
      case 'morning':
        return TimeOfDayValue(9, 0);
      case 'tengah hari':
        return TimeOfDayValue(12, 0);
      case 'petang':
        return TimeOfDayValue(17, 0);
      case 'afternoon':
        return TimeOfDayValue(15, 0);
      case 'evening':
        return TimeOfDayValue(18, 0);
      case 'malam':
      case 'night':
        return TimeOfDayValue(20, 0);
      default:
        return TimeOfDayValue(9, 0);
    }
  }

  static TimeOfDayValue? _buildTime(String hStr, String? mStr, String? period) {
    final h = int.parse(hStr);
    final minute = mStr == null ? 0 : int.parse(mStr);
    if (minute > 59 || h > 23) return null;

    final p = period?.replaceAll(RegExp(r'\s+'), ' ');
    if (p != null && p != 'h24' && h > 12) return null;

    int hour;
    switch (p) {
      case 'h24':
        hour = h;
      case 'am':
      case 'pagi':
      case 'morning':
        hour = h == 12 ? 0 : h;
      case 'pm':
        hour = h == 12 ? 12 : h + 12;
      case 'tengah hari':
        hour = h < 7 ? h + 12 : h;
      case 'petang':
      case 'afternoon':
      case 'evening':
        hour = h < 12 ? h + 12 : h;
      case 'malam':
      case 'night':
        hour = h == 12 ? 0 : (h < 12 ? h + 12 : h);
      default:
        // No am/pm said ("pukul 5"): 1-6 -> afternoon, 7-11 -> morning.
        if (h >= 12) {
          hour = h;
        } else if (h >= 7) {
          hour = h;
        } else {
          hour = h + 12;
        }
    }
    if (hour > 23) return null;
    return TimeOfDayValue(hour, minute);
  }

  static TimeHit? _findTime(String text) {
    for (final m in _reTimeAmPm.allMatches(text)) {
      final t = _buildTime(m.group(1)!, m.group(2), m.group(3));
      if (t != null) return TimeHit(t, m.group(0)!.trim(), m.start, m.end);
    }
    for (final m in _reTimeKeyword.allMatches(text)) {
      final t = _buildTime(m.group(1)!, m.group(2), m.group(3));
      if (t != null) return TimeHit(t, m.group(0)!.trim(), m.start, m.end);
    }
    for (final m in _reTimePeriod.allMatches(text)) {
      final t = _buildTime(m.group(1)!, m.group(2), m.group(3));
      if (t != null) return TimeHit(t, m.group(0)!.trim(), m.start, m.end);
    }
    for (final m in _reTime24.allMatches(text)) {
      final t = _buildTime(m.group(1)!, m.group(2), 'h24');
      if (t != null) return TimeHit(t, m.group(0)!.trim(), m.start, m.end);
    }
    return null;
  }

  // ---------------- description cleanup ----------------

  static const Set<String> _edgeWords = {
    'on',
    'at',
    'this',
    'next',
    'pada',
    'dan',
    'and',
    'di',
    'untuk',
    'for',
    'bagi',
    'kepada',
    'pukul',
    'jam',
    'tarikh',
  };

  static String _cleanDescription(String s) {
    final tokens = s
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .split(' ')
        .where((t) => t.isNotEmpty)
        .toList();
    while (tokens.isNotEmpty && _edgeWords.contains(tokens.first)) {
      tokens.removeAt(0);
    }
    while (tokens.isNotEmpty && _edgeWords.contains(tokens.last)) {
      tokens.removeLast();
    }
    return tokens.join(' ');
  }

  static String _capitalize(String text) {
    if (text.isEmpty) return text;
    return text[0].toUpperCase() + text.substring(1);
  }

  // ---------------- multi-task helpers (Stage 6.0b / 6.0c) ----------------

  static final List<RegExp> _boundaryPatterns = [
    RegExp(
      r'\b(?:tarikh\s+)?\d{1,2}(?:st|nd|rd|th)?\s+(?:of\s+|haribulan\s+)?(?:' +
          _monthPattern +
          r')\b(?:\s+\d{4})?',
    ),
    RegExp(r'\b(?:' + _monthPattern + r')\s+\d{1,2}(?:st|nd|rd|th)?\b'),
    RegExp(r'\b\d{1,2}/\d{1,2}(?:/\d{2,4})?\b'),
    RegExp(r'\b(?:dalam|in)\s+\d{1,2}\s+(?:hari|days?|minggu|weeks?)\b'),
    RegExp(r'\b\d{1,2}\s+(?:hari|minggu)\s+lagi\b'),
    RegExp(
      r'\b(?:hari\s+)?(?:(?:next|this|coming)\s+)?(?:' +
          _weekdayPattern +
          r')\b(?:\s+(?:(?:minggu\s+)?(?:depan|ini)|(?:next|this)\s+week))?',
    ),
    RegExp(
      r'\b(?:(?:next|this)\s+)?(?:hujung\s+minggu|weekend)(?:\s+depan|\s+ini)?\b',
    ),
    RegExp(r'\b(?:minggu\s+depan|next\s+week|bulan\s+depan|next\s+month)\b'),
    RegExp(
      r'\b(?:day\s+after\s+tomorrow|lusa|tomorrow|esok|tonight|malam\s+ini|today|hari\s+ini)\b',
    ),
  ];

  static const Set<String> _gapFillers = {
    '',
    'hari',
    'pada',
    'on',
    'tarikh',
    'the',
    'of',
  };

  static List<MapEntry<int, int>> _dateRanges(String text) {
    final lower = text.toLowerCase();
    final ranges = <MapEntry<int, int>>[];
    for (final p in _boundaryPatterns) {
      for (final m in p.allMatches(lower)) {
        ranges.add(MapEntry(m.start, m.end));
      }
    }
    ranges.sort((a, b) => a.key.compareTo(b.key));

    // Merge overlapping / directly-adjacent ranges ("hari rabu 17 jun").
    final merged = <MapEntry<int, int>>[];
    for (final r in ranges) {
      if (merged.isEmpty) {
        merged.add(r);
        continue;
      }
      final last = merged.last;
      if (r.key < last.value) {
        if (r.value > last.value) {
          merged[merged.length - 1] = MapEntry(last.key, r.value);
        }
      } else {
        final gap = lower.substring(last.value, r.key).trim();
        if (_gapFillers.contains(gap)) {
          merged[merged.length - 1] = MapEntry(last.key, r.value);
        } else {
          merged.add(r);
        }
      }
    }

    // Pull a time said right after the date into the same range
    // ("rabu pukul 9 pagi", "esok 3 petang").
    return merged.map((r) {
      final tail = _trailingTime.firstMatch(lower.substring(r.value));
      return tail == null ? r : MapEntry(r.key, r.value + tail.end);
    }).toList();
  }

  /// Cuts [text] right after each date (and its time). Used when a
  /// recording contains 2+ dates but no commas.
  static List<String> splitByDateBoundaries(String text) {
    final ranges = _dateRanges(text);
    if (ranges.length < 2) return [text];

    final segments = <String>[];
    int start = 0;
    for (final r in ranges) {
      segments.add(text.substring(start, r.value).trim());
      start = r.value;
    }
    final tail = text.substring(start).trim();
    if (tail.isNotEmpty) segments.add(tail);

    return segments.where((s) => s.isNotEmpty).toList();
  }

  /// First date phrase (including a time said right after it), or null.
  static String? findDatePhrase(String text) {
    final ranges = _dateRanges(text);
    if (ranges.isEmpty) return null;
    return text.substring(ranges.first.key, ranges.first.value).trim();
  }

  /// First time phrase ("pukul 9 pagi", "5pm"), or null.
  static String? findTimePhrase(String text) =>
      _findTime(text.toLowerCase())?.matchedText;
}

/// ---------------------------------------------------------------------------
/// STAGE 6.6 — Date Normalization
/// ---------------------------------------------------------------------------
class DateNormalizer {
  /// Default time when the user says "today" / "tomorrow" with NO time.
  /// Change the numbers here if you want a different default (24-hour).
  static final TimeOfDayValue todayTomorrowDefault = TimeOfDayValue(17, 0);

  /// Combines the recognised date + time into one DateTime.
  ///  - No time said            -> 9:00 AM
  ///                               ("today"/"tomorrow" -> 5:00 PM)
  ///  - "today" and default time passed -> next full hour (alarm can still ring)
  ///  - Weekday said on that same weekday, time passed -> next week
  ///  - Only a time said        -> today (or tomorrow if already passed)
  static (DateTime?, String?) combine({
    DateHit? hit,
    TimeOfDayValue? time,
    DateTime? now,
  }) {
    final clock = now ?? DateTime.now();
    final today = DateTime(clock.year, clock.month, clock.day);

    if (hit == null) {
      if (time == null) return (null, null);
      var d = DateTime(
        today.year,
        today.month,
        today.day,
        time.hour,
        time.minute,
      );
      var raw = 'today (assumed)';
      if (!d.isAfter(clock)) {
        d = DateTime(
          today.year,
          today.month,
          today.day + 1,
          time.hour,
          time.minute,
        );
        raw = 'tomorrow (assumed)';
      }
      return (d, raw);
    }

    final explicit = time != null;
    final t = time ?? hit.defaultTime ?? TimeOfDayValue(9, 0);
    var d = DateTime(
      hit.date.year,
      hit.date.month,
      hit.date.day,
      t.hour,
      t.minute,
    );

    if (d.isBefore(clock)) {
      if (!explicit && hit.date == today) {
        d = DateTime(clock.year, clock.month, clock.day, clock.hour + 1);
      } else if (hit.rolloverIfPast) {
        d = DateTime(d.year, d.month, d.day + 7, t.hour, t.minute);
      }
    }
    return (d, hit.matchedText);
  }
}

/// ---------------------------------------------------------------------------
/// STAGE 6.5 — Context Validation
/// ---------------------------------------------------------------------------
class ValidationResult {
  final bool isValid;
  final String? errorReason;
  final double confidence;
  ValidationResult(this.isValid, this.errorReason, this.confidence);
}

class ContextValidator {
  static ValidationResult run({
    required String? folderName,
    required String taskDescription,
    required DateTime? dateTime,
    required double intentConfidence,
  }) {
    double completeness = 0;
    if (folderName != null) completeness += 1 / 3;
    if (taskDescription.isNotEmpty) completeness += 1 / 3;
    if (dateTime != null) completeness += 1 / 3;
    final overallConfidence = double.parse(
      ((completeness + intentConfidence) / 2).toStringAsFixed(2),
    );

    if (folderName == null) {
      return ValidationResult(
        false,
        "Couldn't match a family folder name. You can pick the folder yourself below.",
        overallConfidence,
      );
    }
    if (taskDescription.isEmpty) {
      return ValidationResult(
        false,
        "Couldn't detect the task description.",
        overallConfidence,
      );
    }
    if (dateTime == null) {
      return ValidationResult(
        false,
        "Couldn't detect a date (e.g. 'hari ini', 'esok', 'hari rabu', '17 Jun').",
        overallConfidence,
      );
    }
    return ValidationResult(true, null, overallConfidence);
  }
}

/// ---------------------------------------------------------------------------
/// PUBLIC ENTRY POINT
/// ---------------------------------------------------------------------------
class VoiceTaskParser {
  /// Maximum number of tasks created from ONE recording.
  static const int maxTasksPerRecording = 10;

  static List<ParsedVoiceTask> parseMultiple(
    String rawText,
    List<String> knownFolderNames,
  ) {
    if (rawText.trim().isEmpty) {
      return [
        ParsedVoiceTask(
          taskDescription: '',
          isValid: false,
          errorReason: 'No speech was detected. Please try again.',
          intent: 'unknown',
        ),
      ];
    }

    final normalized = TextPreprocessor.normalize(rawText);

    // 6.0a — commas / pause words
    final connectorChunks = TaskSegmenter.splitByConnectors(normalized);

    // 6.0b + 6.0d + 6.0c — repeated dates, new verb, then "verb dan verb"
    final splitChunks = <String>[];
    for (final chunk in connectorChunks) {
      for (final sub in EntityRecognizer.splitByDateBoundaries(chunk)) {
        for (final clause in VerbBoundarySplitter.split(sub)) {
          splitChunks.addAll(CompoundClauseSplitter.maybeSplit(clause));
        }
      }
    }

    // 6.0e — "basuh baju, sental tandas harini": tarikh di hujung dikongsi
    final allChunks = _shareTrailingSchedule(splitChunks, knownFolderNames);

    final limitedChunks = allChunks.take(maxTasksPerRecording).toList();
    final overflowChunks = allChunks.skip(maxTasksPerRecording).toList();

    final results = <ParsedVoiceTask>[];
    String? currentFolder;

    for (final chunk in limitedChunks) {
      if (chunk.trim().isEmpty) continue;
      final result = _parseSegment(chunk, knownFolderNames, currentFolder);
      if (result.folderName != null) currentFolder = result.folderName;
      results.add(result);
    }

    if (overflowChunks.isNotEmpty) {
      results.add(
        ParsedVoiceTask(
          taskDescription: '',
          isValid: false,
          errorReason:
              'Only the first $maxTasksPerRecording tasks are processed per '
              'recording. Please record the rest again.',
          intent: 'unknown',
          heardText: overflowChunks.join(', '),
        ),
      );
    }

    if (results.isEmpty) {
      return [
        ParsedVoiceTask(
          taskDescription: '',
          isValid: false,
          errorReason: 'No speech was detected. Please try again.',
          intent: 'unknown',
        ),
      ];
    }

    return results;
  }

  /// Tugasan TANPA tarikh mengambil tarikh (dan masa) daripada tugasan
  /// SETERUSNYA yang ada tarikh, selagi pemilik folder (ali / mama ...) sama.
  ///
  ///   "ali basuh baju, sental lantai harini, pergi sekolah jumaat"
  ///     basuh baju -> harini | sental lantai -> harini | pergi sekolah -> jumaat
  ///
  /// Jika pemilik folder bertukar di tengah, perkongsian dihentikan
  /// ("ali basuh baju, mama beli barang harini" -> basuh baju tiada tarikh).
  static List<String> _shareTrailingSchedule(
    List<String> chunks,
    List<String> knownFolderNames,
  ) {
    if (chunks.length < 2) return chunks;

    // pemilik folder bagi setiap chunk (diwarisi ke hadapan)
    final owners = <String?>[];
    String? current;
    for (final c in chunks) {
      final f = FolderResolver.run(
        TextPreprocessor.run(c).cleanedText,
        knownFolderNames,
      ).folderName;
      if (f != null) current = f;
      owners.add(current);
    }

    final result = List<String>.from(chunks);
    String? pendingPhrase;
    String? pendingOwner;

    for (int i = chunks.length - 1; i >= 0; i--) {
      final ownDate = EntityRecognizer.findDatePhrase(chunks[i]);
      if (ownDate != null) {
        pendingPhrase = ownDate;
        pendingOwner = owners[i];
        continue;
      }
      if (pendingPhrase == null || owners[i] != pendingOwner) {
        pendingPhrase = null;
        continue;
      }

      var phrase = pendingPhrase;
      // Jika tugasan ini ada masa sendiri, jangan pinjam masa tugasan lain.
      if (EntityRecognizer.findTimePhrase(chunks[i]) != null) {
        final borrowedTime = EntityRecognizer.findTimePhrase(phrase);
        if (borrowedTime != null) {
          phrase = phrase.replaceFirst(borrowedTime, '').trim();
        }
      }
      result[i] = '${chunks[i]} $phrase';
    }
    return result;
  }

  static ParsedVoiceTask parse(String rawText, List<String> knownFolderNames) {
    return parseMultiple(rawText, knownFolderNames).first;
  }

  static ParsedVoiceTask _parseSegment(
    String rawSegment,
    List<String> knownFolderNames,
    String? inheritedFolder,
  ) {
    final preprocessed = TextPreprocessor.run(rawSegment);
    final intentResult = IntentDetector.run(preprocessed.tokens);
    final folderMatch = FolderResolver.run(
      preprocessed.cleanedText,
      knownFolderNames,
    );
    final String? resolvedFolder = folderMatch.folderName ?? inheritedFolder;
    final String remainingAfterFolder = folderMatch.folderName != null
        ? folderMatch.remainingText
        : preprocessed.cleanedText;

    final entities = EntityRecognizer.run(remainingAfterFolder);

    final validation = ContextValidator.run(
      folderName: resolvedFolder,
      taskDescription: entities.taskDescription,
      dateTime: entities.dateTime,
      intentConfidence: intentResult.confidence,
    );

    return ParsedVoiceTask(
      folderName: resolvedFolder,
      taskDescription: entities.taskDescription,
      dateTime: entities.dateTime,
      isValid: validation.isValid,
      errorReason: validation.errorReason,
      intent: intentResult.intent,
      rawDatePhrase: entities.rawDatePhrase,
      confidence: validation.confidence,
      heardText: rawSegment.trim(),
    );
  }
}
