import 'package:cloud_firestore/cloud_firestore.dart';
import 'auth_service.dart';
import 'voice_task_parser.dart';

/// ERD: NLP_Processing entity -> nlp_processing/{nlpId}
///
/// UPDATED: one voice recording can now contain SEVERAL task clauses
/// ("Noah beli roti rabu, Maryam basuh kasut jumaat"), so this class now
/// saves ONE nlp_processing document PER detected task clause, all linked
/// back to the same voice_id. process() returns the full list of parsed
/// tasks plus their matching nlp_processing document ids (same order,
/// same length) so the caller can confirm/save them one by one or in bulk.
class NlpPipeline {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Runs VoiceTaskParser.parseMultiple() and immediately persists EACH
  /// resulting task as its own nlp_processing document.
  static Future<(List<ParsedVoiceTask> parsedList, List<String?> nlpIds)>
  process({
    required String voiceId,
    required String rawText,
    required List<String> knownFolderNames,
  }) async {
    final parsedList = VoiceTaskParser.parseMultiple(rawText, knownFolderNames);

    final nlpIds = <String?>[];
    for (final parsed in parsedList) {
      final id = await _saveResult(voiceId: voiceId, parsed: parsed);
      nlpIds.add(id);
    }

    return (parsedList, nlpIds);
  }

  static Future<String?> _saveResult({
    required String voiceId,
    required ParsedVoiceTask parsed,
  }) async {
    final user = AuthService.currentUser;
    if (user == null) return null;
    try {
      final docRef = await _db.collection('nlp_processing').add({
        'user_id': user.uid,
        'voice_id': voiceId,
        'intent': parsed.intent,
        'detected_folder': parsed.folderName,
        'extracted_task': parsed.taskDescription,
        'heard_text': parsed.heardText,
        'original_date': parsed.rawDatePhrase,
        'normalized_data': parsed.dateTime != null
            ? Timestamp.fromDate(parsed.dateTime!)
            : null,
        'confident_score': parsed.confidence,
        'validation_status': parsed.isValid ? 'valid' : 'invalid',
        'processed_at': FieldValue.serverTimestamp(),
      });
      return docRef.id;
    } catch (e) {
      return null;
    }
  }
}
