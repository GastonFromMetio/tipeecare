import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:whisper_flutter_new/download_model.dart' show downloadModel;
import 'package:whisper_flutter_new/whisper_flutter_new.dart';

import 'speech_to_text_pipeline.dart';

/// Adapter du plugin `whisper_flutter_new` vers l'interface [SpeechTranscriber].
/// Il télécharge le modèle au premier appel si absent (via Hugging Face).
class WhisperFlutterNewTranscriber implements SpeechTranscriber {
  static const defaultDownloadHost =
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main';

  WhisperFlutterNewTranscriber({
    WhisperModel model = WhisperModel.base,
    this.language = 'fr',
    this.translate = false,
    this.splitOnWord = true,
    this.modelDir,
    this.downloadHost = defaultDownloadHost,
  }) : _whisper = Whisper(
          model: model,
          modelDir: modelDir,
          downloadHost: downloadHost,
        );

  final Whisper _whisper;
  final String language;
  final bool translate;
  final bool splitOnWord;
  final String? modelDir;
  final String? downloadHost;

  /// Prépare le modèle (copie l'asset ou télécharge) et retourne l'instance prête.
  static Future<WhisperFlutterNewTranscriber> initialize({
    WhisperModel model = WhisperModel.base,
    String language = 'fr',
    bool translate = false,
    bool splitOnWord = true,
    String? downloadHost = defaultDownloadHost,
    String? assetModelPath,
    void Function(String status)? onStatus,
  }) async {
    onStatus?.call('Préparation du modèle Whisper...');

    final supportDir = await getApplicationSupportDirectory();
    final modelDir = '${supportDir.path}/whisper_models';
    await Directory(modelDir).create(recursive: true);
    const modelFilename = 'whisper-small-medical-q5_1.bin';
    final modelPath = '$modelDir/$modelFilename';
    final modelFile = File(modelPath);
    const minValidSizeBytes = 1024 * 1024; // protect against HTML/error downloads
    final assetCandidates = <String>{
      if (assetModelPath != null) assetModelPath,
      'assets/models/$modelFilename',
      // Permet de retrouver un fichier converti/renommé (ex: whisper-small-medical.bin)
      'assets/models/whisper-small-medical-q5_1.bin',
    }.toList();

    final hasModelFile = modelFile.existsSync();
    final isLikelyCorrupted =
        hasModelFile && modelFile.lengthSync() < minValidSizeBytes;

    if (!hasModelFile || isLikelyCorrupted) {
      if (isLikelyCorrupted) {
        onStatus?.call(
          'Modèle Whisper corrompu détecté, nouveau téléchargement...',
        );
        // Clean up the bad file so the plugin does not try to load it.
        await modelFile.delete().catchError((_) {});
      }
      final bundledAssetPath = await _firstExistingAsset(assetCandidates);
      final hasBundledAsset = bundledAssetPath != null;

      if (hasBundledAsset) {
        onStatus?.call(
          'Copie du modèle Whisper embarqué (${model.modelName})...',
        );
        final byteData = await rootBundle.load(bundledAssetPath);
        await modelFile.writeAsBytes(
          byteData.buffer.asUint8List(),
          flush: true,
        );
      } else if (downloadHost != null) {
        onStatus?.call(
          'Téléchargement du modèle Whisper (${model.modelName})...',
        );
        await downloadModel(
          model: model,
          destinationPath: modelDir,
          downloadHost: downloadHost,
        );
      } else {
        throw StateError(
          'Aucun modèle Whisper embarqué trouvé et téléchargement désactivé.',
        );
      }
    }

    return WhisperFlutterNewTranscriber(
      model: model,
      language: language,
      translate: translate,
      splitOnWord: splitOnWord,
      modelDir: modelDir,
      downloadHost: downloadHost,
    );
  }

  static Future<bool> _assetExists(String assetPath) async {
    try {
      // Flutter 3.16+ embarque l'AssetManifest en binaire ; on tente un load direct.
      await rootBundle.load(assetPath);
      return true;
    } on FlutterError {
      // Fallback : tenter via manifest JSON (pour compat ascendantes)
      try {
        final manifestContent =
            await rootBundle.loadString('AssetManifest.json');
        final manifestMap =
            json.decode(manifestContent) as Map<String, dynamic>? ?? {};
        return manifestMap.containsKey(assetPath);
      } catch (_) {
        return false;
      }
    } catch (_) {
      return false;
    }
  }

  static Future<String?> _firstExistingAsset(
    List<String> candidatePaths,
  ) async {
    for (final path in candidatePaths) {
      if (await _assetExists(path)) return path;
    }
    return null;
  }

  @override
  Future<String> transcribeFile(String audioFilePath) async {
    final response = await _whisper.transcribe(
      transcribeRequest: TranscribeRequest(
        audio: audioFilePath,
        language: language,
        isTranslate: translate,
        splitOnWord: splitOnWord,
      ),
    );
    return response.text;
  }
}
