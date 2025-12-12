import 'package:flutter/foundation.dart';

import 'prescription_engine.dart';

/// A simple contract for turning an audio file into raw text.
abstract class SpeechTranscriber {
  Future<String> transcribeFile(String audioFilePath);
}

/// Minimal Whisper adapter that expects a function that runs the model.
/// You can wire this to `whisper_dart`, `flutter_whisper` or a method channel
/// binding to `whisper.cpp`.
class WhisperTranscriber implements SpeechTranscriber {
  const WhisperTranscriber({
    required Future<String> Function(String audioFilePath) runWhisper,
    this.languageCode = 'fr',
    this.shouldTranslateToEnglish = false,
  }) : _runWhisper = runWhisper;

  final Future<String> Function(String audioFilePath) _runWhisper;
  final String languageCode;
  final bool shouldTranslateToEnglish;

  @override
  Future<String> transcribeFile(String audioFilePath) async {
    // Keep the adapter tiny: the heavy lifting happens inside the provided
    // Whisper runner (FFI/plugin).
    return _runWhisper(audioFilePath);
  }
}

/// Safe fallback so the app can compile even when no speech backend is wired.
class NoOpSpeechTranscriber implements SpeechTranscriber {
  const NoOpSpeechTranscriber();

  @override
  Future<String> transcribeFile(String audioFilePath) async {
    debugPrint(
      'NoOpSpeechTranscriber called with $audioFilePath. Plug a real backend.',
    );
    return '';
  }
}

/// Result container for the full pipeline.
class SpeechPipelineResult {
  final String transcript;
  final String normalizedTranscript;
  final List<Prescription> prescriptions;
  final PatientProfile? patient;

  SpeechPipelineResult({
    required this.transcript,
    required this.normalizedTranscript,
    required this.prescriptions,
    required this.patient,
  });
}

/// Connects speech-to-text, normalization, and extraction.
class SpeechToPrescriptionPipeline {
  SpeechToPrescriptionPipeline({
    required this.transcriber,
    TextNormalizer? normalizer,
    RuleBasedExtractor? extractor,
    PatientProfileExtractor? patientExtractor,
  })  : normalizer = normalizer ?? const TextNormalizer(),
        extractor = extractor ?? RuleBasedExtractor(),
        patientExtractor = patientExtractor ?? const PatientProfileExtractor();

  final SpeechTranscriber transcriber;
  final TextNormalizer normalizer;
  final RuleBasedExtractor extractor;
  final PatientProfileExtractor patientExtractor;

  /// Convenience helper to go from audio file -> transcript -> normalized
  /// string -> list of [Prescription].
  Future<SpeechPipelineResult> transcribeAndExtract(String audioFilePath) async {
    final transcript = await transcriber.transcribeFile(audioFilePath);
    final normalized = normalizer.normalize(transcript);
    final patient =
        patientExtractor.extract(transcript, normalizedText: normalized);
    final prescriptions = extractor.extract(normalized);

    return SpeechPipelineResult(
      transcript: transcript,
      normalizedTranscript: normalized,
      prescriptions: prescriptions,
      patient: patient,
    );
  }
}
