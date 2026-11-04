import 'package:cloud_firestore/cloud_firestore.dart';
import 'auth_service.dart';

class VoiceInputResult {
  final bool success;
  final String? errorMessage;
  final String? voiceId;
  VoiceInputResult({required this.success, this.errorMessage, this.voiceId});
}

/// ERD: Voice_Input entity -> voice_inputs/{voiceId}
///
/// Saves the raw transcribed text right after Speech-to-Text finishes,
/// closing Activity Diagram step 7.1 ("Save Voice_Input"). `audio_path`
/// stays null on purpose: the `speech_to_text` package converts speech live,
/// on-device, and never produces a saved audio file — that's a documented
/// limitation, not a bug (mention it in your report's limitations section).
class VoiceInputService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static Future<VoiceInputResult> saveVoiceInput({
    required String transcribedText,
    String processingStatus = 'transcribed',
  }) async {
    final user = AuthService.currentUser;
    if (user == null) {
      return VoiceInputResult(success: false, errorMessage: 'Not logged in.');
    }
    try {
      final docRef = await _db.collection('voice_inputs').add({
        'user_id': user.uid,
        'audio_path': null,
        'transcribed_text': transcribedText,
        'processing_status': processingStatus,
        'create_at': FieldValue.serverTimestamp(),
      });
      return VoiceInputResult(success: true, voiceId: docRef.id);
    } catch (e) {
      return VoiceInputResult(
        success: false,
        errorMessage: 'Failed to save voice input.',
      );
    }
  }

  /// Updates the status once NLP processing and task creation finish (e.g.
  /// 'processed', 'task_created', or 'failed').
  static Future<void> updateProcessingStatus(
    String voiceId,
    String status,
  ) async {
    try {
      await _db.collection('voice_inputs').doc(voiceId).update({
        'processing_status': status,
      });
    } catch (_) {
      // Best-effort status update; not worth failing the whole flow over.
    }
  }
}
