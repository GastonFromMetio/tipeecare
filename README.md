# Prescription Normalizer

Normalisation et extraction offline d'ordonnances dictées.

## Pipeline vocale (speech to text -> normalisation -> extraction)

- `lib/speech_to_text_pipeline.dart` expose une interface `SpeechTranscriber` et
  un pipeline `SpeechToPrescriptionPipeline` qui enchaîne la transcription, la
  normalisation puis l'extraction des prescriptions.
- Un adaptateur `WhisperTranscriber` est prévu : il attend une fonction
  `Future<String> Function(String audioPath)` qui appelle votre binding
  Whisper (FFI `whisper.cpp`, `whisper_dart`, etc.).

### Exemple d'intégration Whisper
#### Variante avec `whisper_flutter_new`

1) Dépendances  
   - `flutter pub add whisper_flutter_new` (déjà ajouté).  
   - Optionnel : `record` pour capturer l'audio en WAV 16 kHz mono.
2) Enregistrement audio (ex. plugin `record`)  
   - Capturer en PCM mono 16 kHz, enregistrer dans un fichier `.wav`.
3) Transcription + pipeline (`lib/whisper_flutter_adapter.dart`)  
   ```dart
   import 'package:whisper_flutter_new/whisper_flutter_new.dart';
   import 'speech_to_text_pipeline.dart';
   import 'whisper_flutter_adapter.dart';

   // A appeler après avoir obtenu le chemin du WAV
   Future<void> runPipeline(String audioPath) async {
     final transcriber = WhisperFlutterNewTranscriber(
       model: WhisperModel.base, // tiny/base/small/medium/large-v2
       language: 'fr',           // "auto" si langue inconnue
       translate: false,         // true si tu veux forcer la traduction en anglais
     );

     final pipeline = SpeechToPrescriptionPipeline(transcriber: transcriber);
     final result = await pipeline.transcribeAndExtract(audioPath);

     debugPrint('Transcript brut: ${result.transcript}');
     debugPrint('Texte normalisé: ${result.normalizedTranscript}');
     debugPrint('Prescriptions: ${result.prescriptions}');
   }
   ```
   - Le plugin télécharge le modèle (base par défaut) au premier appel. Sans
     réseau, fournis un `modelDir` contenant déjà le `.bin` et passe
     `downloadHost: null` si besoin.
   - Un modèle médical converti (`assets/models/whisper-small-medical.bin`)
     est fourni et chargé sans téléchargement via l’option « Whisper Small
     (médical embarqué) ».
4) Permissions plateforme  
   - Android : `RECORD_AUDIO` dans `AndroidManifest.xml`.  
   - iOS : clé `NSMicrophoneUsageDescription` dans `Info.plist`.  
   - MacOS : clé micro équivalente.

### UI actuelle
- Boutons « Dicter » / « Stop + Transcrire » dans l'écran principal déclenchent
  l'enregistrement (`record`), la transcription Whisper (`whisper_flutter_new`)
  puis affichent transcript/texte normalisé/JSON.

### Capture audio avec `record`

```dart
import 'package:record/record.dart';

final recorder = AudioRecorder();

Future<String?> captureWav16k() async {
  if (!await recorder.hasPermission()) return null;

  await recorder.start(
    const RecordConfig(
      encoder: AudioEncoder.wav,
      sampleRate: 16000, // Whisper attend 16 kHz
      numChannels: 1,
      bitRate: 256000, // 16kHz * 16 bits * 1 ch
    ),
    path: '/tmp/audio.wav', // utilise path_provider en prod
  );

  // ... attendre la fin de dictée (timer/bouton stop) ...
  final path = await recorder.stop(); // chemin du .wav à passer au pipeline
  return path;
}
```

Une fois `path` récupéré, passe-le à `SpeechToPrescriptionPipeline.transcribeAndExtract(path)`.
