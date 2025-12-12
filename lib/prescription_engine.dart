/// Core prescription parsing engine with normalization, rule-based extraction,
/// and an optional local NER interface that can be plugged later.
/// Everything is deterministic/offline for now.
library;

import 'dart:math';

import 'package:dart_phonetics/dart_phonetics.dart';

/// =======================
/// Data models
/// =======================

class Prescription {
  final String? libelle; // normalized drug name ("Ceftriaxone")
  final String? dci; // International Nonproprietary Name if available
  final String? dosage; // e.g. "1 g"
  final String? posologie; // e.g. "x3/j", "matin et soir"
  final String? voie; // e.g. "Intraveineuse (PICC line)"
  final String? dispositif; // e.g. "VVP", "PICC line", "PAC"
  final String? forme; // e.g. "comprimé" (reserved for later)
  final String? duree; // e.g. "7j"
  final String? notes; // free text such as "(rétrocession hospitalière)"
  final String segmentSource; // normalized raw segment of the prescription
  final String segmentSourcePhonetic; // phonetic projection of the same segment

  Prescription({
    required this.libelle,
    required this.dci,
    required this.dosage,
    required this.posologie,
    required this.voie,
    required this.dispositif,
    required this.forme,
    required this.duree,
    required this.notes,
    required this.segmentSource,
    required this.segmentSourcePhonetic,
  });

  Map<String, dynamic> toJson() => {
        'libelle': libelle,
        'dci': dci,
        'dosage': dosage,
        'posologie': posologie,
        'voie': voie,
        'dispositif': dispositif,
        'forme': forme,
        'duree': duree,
        'notes': notes,
        'segment_source': segmentSource,
        'segment_source_phonetic': segmentSourcePhonetic,
      };
}

/// Basic patient profile extracted from the free text.
class PatientProfile {
  final String? firstName;
  final String? lastName;
  final String? gender; // e.g. "male", "female"
  final String? civility; // e.g. "M.", "Mme"
  final String? city;
  final String? email;
  final String? phone;
  final String? sourceText; // snippet used to build the profile

  const PatientProfile({
    required this.firstName,
    required this.lastName,
    required this.gender,
    required this.civility,
    required this.city,
    required this.email,
    required this.phone,
    required this.sourceText,
  });

  Map<String, dynamic> toJson() => {
        'first_name': firstName,
        'last_name': lastName,
        'gender': gender,
        'civility': civility,
        'city': city,
        'email': email,
        'phone': phone,
        'source_text': sourceText,
      };
}

/// Generic NER entity representation (kept simple for later integration).
class EntitySpan {
  final String type; // e.g. "MEDICAMENT", "DOSE", "DUREE"
  final int start; // inclusive
  final int end; // exclusive
  final String text;

  EntitySpan({
    required this.type,
    required this.start,
    required this.end,
    required this.text,
  });
}

/// Interface for a plug-and-play local NER engine (ONNX, tflite, etc.).
abstract class LocalNerEngine {
  List<EntitySpan> analyze(String text);
}

/// Default stub that does nothing (purely rule-based extraction).
class NoOpNerEngine implements LocalNerEngine {
  @override
  List<EntitySpan> analyze(String text) => const [];
}

/// =======================
/// Layer 1: Normalization
/// =======================

class TextNormalizer {
  const TextNormalizer();

  String normalize(String raw) {
    var text = raw.trim();

    // Normalize new lines
    text = text.replaceAll('\r\n', '\n');
    text = text.replaceAll('\r', '\n');

    // Collapse horizontal spaces
    text = text.replaceAll(RegExp(r'[ \t]+'), ' ');

    // Lowercase for simpler matching
    text = text.toLowerCase();

    // Simple number words -> digits (MVP set)
    final numberWords = <String, String>{
      'zéro': '0',
      'zero': '0',
      'un': '1',
      'une': '1',
      'deux': '2',
      'trois': '3',
      'quatre': '4',
      'cinq': '5',
      'six': '6',
      'sept': '7',
      'huit': '8',
      'neuf': '9',
      'dix': '10',
    };
    numberWords.forEach((word, digit) {
      text = text.replaceAll(RegExp(r'\b$word\b'), digit);
    });

    // Normalize dosage forms like "4gx3" -> "4 g x3"
    text = text.replaceAllMapped(
      RegExp(r'(\d+)\s*g\s*x\s*(\d+)'),
      (m) => '${m[1]} g x${m[2]}',
    );
    text = text.replaceAllMapped(
      RegExp(r'(\d+)g'),
      (m) => '${m[1]} g',
    );

    // Canonical units
    text = text.replaceAll(RegExp(r'\bgrammes?\b'), ' g');
    text = text.replaceAll(RegExp(r'\bmilligrammes?\b'), ' mg');
    text = text.replaceAll(RegExp(r'\bmicrogrammes?\b'), ' µg');

    // Frequencies "3 fois par jour" -> "3x/j"
    text = text.replaceAllMapped(
      RegExp(r'\b(\d+)\s*(fois|x)\s*(par\s*jour|/jour|par jour)\b'),
      (m) => '${m[1]}x/j',
    );

    // Final space cleanup
    text = text.replaceAll(RegExp(r' +'), ' ');

    return text.trim();
  }
}

/// =======================
/// Layer 2: Lexicon + rules
/// =======================

class DrugDef {
  final String key; // canonical label
  final String dci;
  final List<String> aliases; // variants, brand names, common typos

  DrugDef({
    required this.key,
    required this.dci,
    required this.aliases,
  });
}

/// Minimal lexicon sample (extend to ~200 entries later).
final List<DrugDef> drugLexicon = [
  DrugDef(
    key: 'Ceftriaxone',
    dci: 'Ceftriaxone',
    aliases: [
      'ceftriaxone',
      'rocephine',
      'rocéphine',
      'rocephin',
      'triaxon',
      'cf triaxon',
      'cftriaxon',
      'cef triaxon',
    ],
  ),
  DrugDef(
    key: 'Ceftazidime',
    dci: 'Ceftazidime',
    aliases: ['ceftazidime'],
  ),
  DrugDef(
    key: 'Piperacilline + Tazobactam',
    dci: 'Piperacilline + Tazobactam',
    aliases: [
      'tazocilline',
      'piperacilline + tazo',
      'piperacilline tazo',
      'piperacilline+tazo',
    ],
  ),
  DrugDef(
    key: 'Ganciclovir',
    dci: 'Ganciclovir',
    aliases: [
      'ganciclovir',
      'ciclovir',
      ],
  ),
  DrugDef(
    key: 'Amphotericine B',
    dci: 'Amphotericine B',
    aliases: ['ambisome', 'amphotericine b', 'amphotéricine b'],
  ),
  DrugDef(
    key: 'Amikacine',
    dci: 'Amikacine',
    aliases: ['amiklin', 'amikacine'],
  ),
  DrugDef(
    key: 'Amoxicilline + Acide Clavulanique',
    dci: 'Amoxicilline + Acide Clavulanique',
    aliases: [
      'augmentin',
      'levmentin',
      'amoxicilline + acide clavulanique',
      'amoxicilline acide clavulanique',
      'amoxicilline',
      'amoxiciline',
      'amoxicillin',
      'amoxicilin',
    ],
  ),
  DrugDef(
    key: 'Aztreonam',
    dci: 'Aztreonam',
    aliases: ['azactam', 'aztreonam'],
  ),
  DrugDef(
    key: 'Cefepime',
    dci: 'Cefepime',
    aliases: ['axepim', 'cefepime'],
  ),
  DrugDef(
    key: 'Sulfamethoxazole + Trimethoprime',
    dci: 'Sulfamethoxazole + Trimethoprime',
    aliases: ['bactrim', 'sulfamethoxazole trimethoprime', 'sulfamethoxazole + trimethoprime'],
  ),
  DrugDef(
    key: 'Oxacilline',
    dci: 'Oxacilline',
    aliases: ['oxacilline', 'bristopen', 'isotopen'],
  ),
  DrugDef(
    key: 'Caspofungine',
    dci: 'Caspofungine',
    aliases: ['caspofungine', 'cancidas'],
  ),
  DrugDef(
    key: 'Cefazoline',
    dci: 'Cefazoline',
    aliases: ['cefazoline', 'cefazolin', 'cefacidal', 'cefadical'],
  ),
  DrugDef(
    key: 'Cefotaxime',
    dci: 'Cefotaxime',
    aliases: ['cefotaxime', 'claforan'],
  ),
  DrugDef(
    key: 'Ciprofloxacine',
    dci: 'Ciprofloxacine',
    aliases: ['ciprofloxacine', 'ciprofloxacin', 'ciflox'],
  ),
  DrugDef(
    key: 'Daptomycine',
    dci: 'Daptomycine',
    aliases: ['daptomycine', 'cubicin'],
  ),
  DrugDef(
    key: 'Clindamycine',
    dci: 'Clindamycine',
    aliases: ['clindamycine', 'dalacine'],
  ),
  DrugDef(
    key: 'Erythromycine',
    dci: 'Erythromycine',
    aliases: ['erythromycine', 'erythro', 'erythrocine'],
  ),
  DrugDef(
    key: 'Metronidazole',
    dci: 'Metronidazole',
    aliases: ['metronidazole', 'flagyl'],
  ),
  DrugDef(
    key: 'Gentamicine',
    dci: 'Gentamicine',
    aliases: ['gentamicine', 'gentalline', 'gentamicin', 'gen tamissine'],
  ),
  DrugDef(
    key: 'Ertapenem',
    dci: 'Ertapenem',
    aliases: ['ertapenem', 'invanz'],
  ),
  DrugDef(
    key: 'Cefoxitine',
    dci: 'Cefoxitine',
    aliases: ['cefoxitine', 'mefoxin'],
  ),
  DrugDef(
    key: 'Meropenem',
    dci: 'Meropenem',
    aliases: ['meropenem', 'meronem'],
  ),
  DrugDef(
    key: 'Micafungine',
    dci: 'Micafungine',
    aliases: ['micafungine', 'mycamine'],
  ),
  DrugDef(
    key: 'Tobramycine',
    dci: 'Tobramycine',
    aliases: ['tobramycine', 'nebicine', 'tobramycin'],
  ),
  DrugDef(
    key: 'Temocilline',
    dci: 'Temocilline',
    aliases: ['temocilline', 'negaban'],
  ),
  DrugDef(
    key: 'Ofloxacine',
    dci: 'Ofloxacine',
    aliases: ['ofloxacine', 'oflocet', 'ofloxacin'],
  ),
  DrugDef(
    key: 'Cloxacilline',
    dci: 'Cloxacilline',
    aliases: ['cloxacilline', 'orbenine'],
  ),
  DrugDef(
    key: 'Penicilline G',
    dci: 'Penicilline G',
    aliases: ['penicilline g', 'penicillin g'],
  ),
  DrugDef(
    key: 'Piperacilline',
    dci: 'Piperacilline',
    aliases: ['piperacilline', 'piperacillin'],
  ),
  DrugDef(
    key: 'Rifampicine',
    dci: 'Rifampicine',
    aliases: ['rifampicine', 'rifampin', 'rifadine'],
  ),
  DrugDef(
    key: 'Teicoplanine',
    dci: 'Teicoplanine',
    aliases: ['teicoplanine', 'targocid'],
  ),
  DrugDef(
    key: 'Levofloxacine',
    dci: 'Levofloxacine',
    aliases: ['levofloxacine', 'tavanic', 'levofloxacin'],
  ),
  DrugDef(
    key: 'Imipeneme + Cilastatine',
    dci: 'Imipeneme + Cilastatine',
    aliases: [
      'imipeneme + cilastatine',
      'imipeneme cilastatine',
      'imipenem cilastatin',
      'tienam'
    ],
  ),
  DrugDef(
    key: 'Fluconazole',
    dci: 'Fluconazole',
    aliases: ['fluconazole', 'triflucan'],
  ),
  DrugDef(
    key: 'Vancomycine',
    dci: 'Vancomycine',
    aliases: ['vancomycine', 'vancomycin'],
  ),
  DrugDef(
    key: 'Dalbavancine',
    dci: 'Dalbavancine',
    aliases: ['dalbavancine', 'xydalba', 'dalbavancin'],
  ),
  DrugDef(
    key: 'Amoxicilline',
    dci: 'Amoxicilline',
    aliases: ['amoxicilline', 'clavamox', 'xylomac', 'clamoxyl'],
  ),
  DrugDef(
    key: 'Clarithromycine',
    dci: 'Clarithromycine',
    aliases: ['clarithromycine', 'clarithromycin', 'zeclar'],
  ),
  DrugDef(
    key: 'Aciclovir',
    dci: 'Aciclovir',
    aliases: ['aciclovir', 'acyclovir', 'zovirax'],
  ),
  DrugDef(
    key: 'Linezolide',
    dci: 'Linezolide',
    aliases: ['linezolide', 'linezolid', 'zyvoxid'],
  ),
];

/// =======================
/// Phonetic helpers (MVP)
/// =======================

String _stripDiacritics(String input) {
  const mapping = {
    'à': 'a',
    'â': 'a',
    'ä': 'a',
    'á': 'a',
    'ã': 'a',
    'å': 'a',
    'ç': 'c',
    'é': 'e',
    'è': 'e',
    'ê': 'e',
    'ë': 'e',
    'í': 'i',
    'ì': 'i',
    'î': 'i',
    'ï': 'i',
    'ñ': 'n',
    'ó': 'o',
    'ò': 'o',
    'ô': 'o',
    'ö': 'o',
    'õ': 'o',
    'ú': 'u',
    'ù': 'u',
    'û': 'u',
    'ü': 'u',
    'ý': 'y',
    'ÿ': 'y',
  };

  final sb = StringBuffer();
  for (final ch in input.runes) {
    final c = String.fromCharCode(ch);
    final lower = c.toLowerCase();
    sb.write(mapping[lower] ?? lower);
  }
  return sb.toString();
}

final _doubleMetaphone = DoubleMetaphone();

/// Returns both primary and alternate Double Metaphone codes (when available).
List<String> _phoneticCodes(String input) {
  final cleaned = _stripDiacritics(input).trim().toLowerCase();
  if (cleaned.isEmpty) return const [];

  final enc = _doubleMetaphone.encode(cleaned);
  if (enc == null) return const [];
  final codes = <String>[];

  void addIfValid(String? code) {
    if (code != null && code.isNotEmpty && !codes.contains(code)) {
      codes.add(code);
    }
  }

  addIfValid(enc.primary);
  if (enc.alternates != null) {
    for (final alt in enc.alternates!) {
      addIfValid(alt);
    }
  }

  return codes;
}

/// Encodes a word with Double Metaphone. When both primary and alternate
/// codes exist, we keep both to stay tolerant to pronunciation variants.
String phoneticEncode(String input) => _phoneticCodes(input).join('|');

String phoneticProjection(String segment) {
  final tokens = segment
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.isNotEmpty)
      .map(phoneticEncode)
      .where((w) => w.isNotEmpty)
      .toList();
  return tokens.join(' ');
}

/// Distance de Levenshtein simple (O(mn)) – suffisant pour des mots courts.
int levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;

  final m = a.length;
  final n = b.length;
  final dp = List.generate(m + 1, (_) => List<int>.filled(n + 1, 0));

  for (var i = 0; i <= m; i++) dp[i][0] = i;
  for (var j = 0; j <= n; j++) dp[0][j] = j;

  for (var i = 1; i <= m; i++) {
    for (var j = 1; j <= n; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      dp[i][j] = [
        dp[i - 1][j] + 1,
        dp[i][j - 1] + 1,
        dp[i - 1][j - 1] + cost,
      ].reduce((v, e) => v < e ? v : e);
    }
  }

  return dp[m][n];
}

double _bestPhoneticDistance(List<String> aliasCodes, List<String> wordCodes) {
  var best = double.infinity;
  for (final a in aliasCodes) {
    for (final b in wordCodes) {
      final dist = levenshtein(a, b);
      final maxLen = a.length > b.length ? a.length : b.length;
      if (maxLen == 0) continue;
      final score = dist / maxLen;
      if (score < best) best = score;
    }
  }
  return best;
}

/// Mots à ignorer pour la recherche phonétique (mots de liaison,
/// unités, etc.). On veut concentrer le score sur les mots "bizarres"
/// qui ressemblent aux noms de médicaments.
const Set<String> _phoneticStopWords = {
  'de',
  'des',
  'du',
  'la',
  'le',
  'les',
  'un',
  'une',
  'et',
  'ou',
  'en',
  'au',
  'aux',
  'à',
  'pour',
  'pendant',
  'sur',
  'par',
  'dans',
  'chez',
  'avec',
  'sans',
  'prescription',
  'prescriptions',
  'traitement',
  'traitements',
  'mg',
  'g',
  'µg',
  'ug',
  'gram',
  'gramme',
  'grammes',
  'jour',
  'jours',
  'heure',
  'heures',
  'fois',
};

/// Construit un seul "mot bizarre" local en prenant seulement les
/// derniers / premiers tokens significatifs près de la dose.
/// - fromEnd = true : on prend les derniers tokens (avant la dose)
/// - fromEnd = false : on prend les premiers tokens (après la dose)
/// Reconstruction agressive d'un token suspect d'être un médicament.
/// Exemple : "gen tamissine" -> "gentamissine"
String collapseDrugCandidate(String segment) {
  final tokens = segment
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) =>
          w.length >= 3 &&
          !_phoneticStopWords.contains(w) &&
          !RegExp(r'^\d+$').hasMatch(w))
      .toList();

  if (tokens.isEmpty) {
    return '';
  }

  // On colle les tokens : "gen" + "tamissine" -> "gentamissine"
  return tokens.join('');
}

List<String> _groupBizarreChunks(String segment) {
  final tokens = segment
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .map((w) => w.trim())
      .where((w) =>
          w.length >= 3 &&
          !_phoneticStopWords.contains(w) &&
          !RegExp(r'^\d+$').hasMatch(w))
      .toList();

  if (tokens.isEmpty) return const [];

  // On force l'agglutination de tous les tokens retenus
  // pour des prononciations éclatées ("gen tamissine" -> "gentamissine").
  return [tokens.join('')];
}

/// Matching phonétique "obligatoire" :
/// - on travaille par token d'alias (amoxicilline, augmentin, ...)
/// - on calcule une distance phonétique normalisée
/// - ET une distance texte normalisée
/// - on retourne systématiquement le drug avec le meilleur score global.
///
/// Hypothèse forte : la prescription est toujours faite avec un
/// médicament présent dans `drugLexicon`.
bool _isBetterScore(
  double candidatePhon,
  double candidateText,
  double bestPhon,
  double bestText,
  {int candidatePriority = 2, int bestPriority = 2}
) {
  final isBetterPhon = candidatePhon < bestPhon;
  final isEqualPhon = candidatePhon == bestPhon;
  final isBetterTextOnTie = isEqualPhon && candidateText < bestText;
  final isEqualText = candidateText == bestText;
  final isBetterPriorityOnTie =
      isEqualPhon && isEqualText && candidatePriority < bestPriority;
  return isBetterPhon || isBetterTextOnTie || isBetterPriorityOnTie;
}

class _DrugMatchResult {
  final DrugDef drug;
  final double phonScore;
  final double textScore;
  final int priority; // 0 = dci, 1 = key, 2 = alias

  _DrugMatchResult({
    required this.drug,
    required this.phonScore,
    required this.textScore,
    required this.priority,
  });
}

_DrugMatchResult? _bestDrugMatchFromWords(List<String> words) {
  if (words.isEmpty) return null;

  // Cache des projections phonétiques des mots du segment
  final Map<String, List<String>> wordPhons = {};
  for (final w in words) {
    wordPhons[w] = _phoneticCodes(w);
  }

  // Cache pour ne pas recalculer les métaphones d'un alias multi-usage.
  final Map<String, List<String>> aliasPhonCache = {};

  _DrugMatchResult? best;
  double bestPhonScore = double.infinity; // distance phonétique normalisée
  double bestTextScore = double.infinity; // distance texte normalisée
  int bestPriority = 3;

  // Parcours du lexique complet
  for (final drug in drugLexicon) {
    final targets = <MapEntry<String, int>>[
      MapEntry(drug.dci, 0),
      MapEntry(drug.key, 1),
      ...drug.aliases.map((a) => MapEntry(a, 2)),
    ];

    for (final target in targets) {
      final aliasTokens = target.key
          .toLowerCase()
          .split(RegExp(r'[^a-z0-9]+'))
          .where((t) => t.isNotEmpty)
          .toList();

      if (aliasTokens.isEmpty) continue;

      for (final aliasTok in aliasTokens) {
        if (aliasTok.length < 3) continue;

        final aliasTokPhons = aliasPhonCache.putIfAbsent(
          aliasTok,
          () => _phoneticCodes(aliasTok),
        );
        if (aliasTokPhons.isEmpty) continue;

        for (final w in words) {
          final wPhons = wordPhons[w]!;
          if (wPhons.isEmpty) continue;

          final phonScore = _bestPhoneticDistance(aliasTokPhons, wPhons);
          if (phonScore == double.infinity) continue;

          final textDist = levenshtein(aliasTok, w);
          final textMaxLen =
              aliasTok.length > w.length ? aliasTok.length : w.length;
          final textScore = textDist / textMaxLen;

          final isBetter = _isBetterScore(
            phonScore,
            textScore,
            bestPhonScore,
            bestTextScore,
            candidatePriority: target.value,
            bestPriority: bestPriority,
          );
          if (isBetter) {
            bestPhonScore = phonScore;
            bestTextScore = textScore;
            bestPriority = target.value;
            best = _DrugMatchResult(
              drug: drug,
              phonScore: phonScore,
              textScore: textScore,
              priority: target.value,
            );
          }
        }
      }
    }
  }

  return best;
}

_DrugMatchResult? _bestDrugMatch(String segment) {
  var words = segment
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.length >= 3 && !_phoneticStopWords.contains(w))
      .toList();

  if (words.isEmpty) {
    words = segment
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((w) => w.length >= 3)
        .toList();
  }

  if (words.isEmpty) return null;

  return _bestDrugMatchFromWords(words);
}

_DrugMatchResult? _bestDrugMatchForToken(String token) {
  final t = token.toLowerCase().trim();
  if (t.length < 3) return null;
  return _bestDrugMatchFromWords([t]);
}


DrugDef? findDrugByPronunciation(String segment) =>
    _bestDrugMatch(segment)?.drug;

DrugDef? findDrugInSegment(String segment) {
  final lowerSegment = segment.toLowerCase();

  // 1) Match exact sur les alias si possible
  for (final drug in drugLexicon) {
    for (final alias in drug.aliases) {
      final idx = lowerSegment.indexOf(alias.toLowerCase());
      if (idx != -1) {
        return drug;
      }
    }
  }

  // 2) On cherche la première dose dans le segment
  final doseRegex = RegExp(r'(\d+(?:[.,]\d+)?)\s*(mg|g|µg|ug)');
  final doseMatch = doseRegex.firstMatch(segment);

  _DrugMatchResult? bestCandidate;

  void considerToken(String token) {
    if (token.isEmpty) return;
    final res = _bestDrugMatchForToken(token);
    if (res == null) return;

    if (bestCandidate == null ||
        _isBetterScore(
          res.phonScore,
          res.textScore,
          bestCandidate!.phonScore,
          bestCandidate!.textScore,
          candidatePriority: res.priority,
          bestPriority: bestCandidate!.priority,
        )) {
      bestCandidate = res;
    }
  }

  if (doseMatch != null) {
    final beforeRaw = segment.substring(0, doseMatch.start);
    final beforeToken = collapseDrugCandidate(beforeRaw);
    considerToken(beforeToken);

    final afterRaw = segment.substring(doseMatch.end);
    final afterToken = collapseDrugCandidate(afterRaw);
    considerToken(afterToken);
  }

  // 3) Toujours tenter la version "collée" du segment complet pour capturer
  // les mots éclatés même sans dose explicite.
  considerToken(collapseDrugCandidate(segment));

  // 4) Si aucun candidat trouvé, on retombe sur la phrase complète
  if (bestCandidate == null) {
    bestCandidate = _bestDrugMatch(segment);
  } else {
    // On laisse une chance à la phrase complète si elle est encore meilleure
    final whole = _bestDrugMatch(segment);
    if (whole != null &&
        _isBetterScore(
          whole.phonScore,
          whole.textScore,
          bestCandidate!.phonScore,
          bestCandidate!.textScore,
          candidatePriority: whole.priority,
          bestPriority: bestCandidate!.priority,
        )) {
      bestCandidate = whole;
    }
  }

  return bestCandidate?.drug;
}


/// Routes/devices
class RouteMatch {
  final String voie;
  final String dispositif;
  final int start;

  RouteMatch({
    required this.voie,
    required this.dispositif,
    required this.start,
  });
}

RouteMatch? findRoute(String segment) {
  final candidates = <RouteMatch>[];

  void addIfFound(String pattern, String voie, String dispositif) {
    final idx = segment.indexOf(pattern);
    if (idx != -1) {
      candidates.add(RouteMatch(voie: voie, dispositif: dispositif, start: idx));
    }
  }

  addIfFound('vvp', 'Intraveineuse (périphérique)', 'VVP');
  addIfFound('iv','Intraveineuse', 'IV');
  addIfFound('midline', 'Intraveineuse (Midline)', 'Midline');
  addIfFound('picc line', 'Intraveineuse (PICC line)', 'PICC line');
  addIfFound('piccline', 'Intraveineuse (PICC line)', 'PICC line');
  addIfFound('picc', 'Intraveineuse (PICC line)', 'PICC line');
  addIfFound('pac', 'Intraveineuse (PAC)', 'PAC');
  addIfFound('per os', 'Orale', 'Per os');
  addIfFound('orale', 'Orale', 'Orale');

  if (candidates.isEmpty) return null;
  candidates.sort((a, b) => a.start.compareTo(b.start));
  return candidates.first;
}

/// Duration extraction: "pendant 7 jours" or "pour 7 jours" -> "7j"
String? findDuration(String segment) {
  final m =
      RegExp(r'\b(?:pendant|pour|sur)\s+(\d+)\s*(j|jour|jours|sem|semaines?|mois)\b')
      .firstMatch(segment);
  if (m == null) return null;
  final value = int.tryParse(m.group(1) ?? '');
  final unit = m.group(2) ?? '';
  if (value == null) return null;

  switch (unit) {
    case 'j':
    case 'jour':
    case 'jours':
      return '${value}j';
    case 'sem':
    case 'semaine':
    case 'semaines':
      return '${value * 7}j';
    case 'mois':
      return '${value * 30}j'; // simple approximation for MVP
    default:
      return null;
  }
}

/// =======================
/// Layer 2: Patient profile extraction
/// =======================

class PatientProfileExtractor {
  const PatientProfileExtractor();

  PatientProfile? extract(String rawText, {String? normalizedText}) {
    if (rawText.trim().isEmpty) return null;

    final lower = normalizedText ?? rawText.toLowerCase();
    final scopeEnd = _firstPrescriptionIndex(lower) ?? rawText.length;
    final scopeRaw = rawText.substring(0, scopeEnd).trim();
    if (scopeRaw.isEmpty) return null;

    final contact = _extractContactInfo(scopeRaw);

    final civilityProfile = _extractWithCivility(scopeRaw, contact);
    if (civilityProfile != null) return civilityProfile;

    return _extractWithKeyword(scopeRaw, contact);
  }

  int? _firstPrescriptionIndex(String lower) {
    final indices = <int>[];

    for (final keyword in const [
      'prescription',
      'prescriptions',
      'ordonnance',
      'ordo',
      'traitement',
      'ttt',
    ]) {
      final idx = lower.indexOf(keyword);
      if (idx != -1) indices.add(idx);
    }

    for (final drug in drugLexicon) {
      for (final alias in drug.aliases) {
        final idx = lower.indexOf(alias.toLowerCase());
        if (idx != -1) {
          indices.add(idx);
          break;
        }
      }
    }

    if (indices.isEmpty) return null;
    indices.sort();
    return indices.first;
  }

  PatientProfile? _extractWithCivility(
    String scopeRaw,
    ({String? city, String? email, String? phone}) contact,
  ) {
    final civilityRegex = RegExp(
      r'\b(m\.?|mr|monsieur|mme\.?|madame|mlle\.?|melle|mademoiselle)[\s,]+([A-Za-zÀ-ÖØ-öø-ÿ\-]+)\s+([A-Za-zÀ-ÖØ-öø-ÿ\-]+)',
      caseSensitive: false,
    );
    final match = civilityRegex.firstMatch(scopeRaw);
    if (match == null) return null;

    final civility = match.group(1);
    final firstName = match.group(2);
    final lastName = match.group(3);

    return _buildProfile(
      civility: civility,
      firstName: firstName,
      lastName: lastName,
      scopeRaw: scopeRaw,
      matchStart: match.start,
      matchEnd: match.end,
      contact: contact,
    );
  }

  PatientProfile? _extractWithKeyword(
    String scopeRaw,
    ({String? city, String? email, String? phone}) contact,
  ) {
    final keywordRegex = RegExp(
      r'\b(?:patient(?:e)?|sortie de|au nom de)[\s:]+([A-Za-zÀ-ÖØ-öø-ÿ\-]+)\s+([A-Za-zÀ-ÖØ-öø-ÿ\-]+)',
      caseSensitive: false,
    );
    final match = keywordRegex.firstMatch(scopeRaw);
    if (match == null) return null;

    final firstName = match.group(1);
    final lastName = match.group(2);

    return _buildProfile(
      civility: null,
      firstName: firstName,
      lastName: lastName,
      scopeRaw: scopeRaw,
      matchStart: match.start,
      matchEnd: match.end,
      contact: contact,
    );
  }

  PatientProfile _buildProfile({
    required String? civility,
    required String? firstName,
    required String? lastName,
    required String scopeRaw,
    required int matchStart,
    required int matchEnd,
    required ({String? city, String? email, String? phone}) contact,
  }) {
    final gender = _genderFromCivility(civility);
    final snippet = _captureSnippet(scopeRaw, matchStart, matchEnd);

    return PatientProfile(
      firstName: firstName,
      lastName: lastName,
      gender: gender,
      civility: civility,
      city: contact.city,
      email: contact.email,
      phone: contact.phone,
      sourceText: snippet.isEmpty ? scopeRaw : snippet,
    );
  }

  /// Extracts optional contact/location fields in a best-effort manner.
  ({String? city, String? email, String? phone}) _extractContactInfo(
      String scopeRaw) {
    String? email;
    String? phone;
    String? city;

    final emailMatch =
        RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}').firstMatch(scopeRaw);
    if (emailMatch != null) {
      email = emailMatch.group(0);
    }

    final phoneMatch =
        RegExp(r'(?:\+?33\s?|0)(?:[1-9](?:[ .-]?\d){8})').firstMatch(scopeRaw);
    if (phoneMatch != null) {
      phone = phoneMatch.group(0)?.replaceAll(RegExp(r'[^0-9+]'), '');
    }

    final cityMatch = RegExp(
      r'\b(?:ville|city|commune)\s*[:\-]?\s*([A-Za-zÀ-ÖØ-öø-ÿ\\- ]{2,})',
      caseSensitive: false,
    ).firstMatch(scopeRaw);
    if (cityMatch != null) {
      city = cityMatch.group(1)?.trim();
    }

    return (city: city, email: email, phone: phone);
  }

  String? _genderFromCivility(String? civility) {
    if (civility == null) return null;
    final lower = civility.toLowerCase();
    if (lower == 'm' || lower == 'm.' || lower == 'mr' || lower == 'monsieur') {
      return 'male';
    }
    if (lower.startsWith('mme') ||
        lower.startsWith('mad') ||
        lower.startsWith('mlle') ||
        lower.startsWith('melle') ||
        lower == 'mademoiselle') {
      return 'female';
    }
    return null;
  }

  String _captureSnippet(String text, int start, int end) {
    int leftBoundary = 0;
    for (var i = start - 1; i >= 0; i--) {
      final ch = text[i];
      if (ch == '.' || ch == '\n') {
        leftBoundary = i + 1;
        break;
      }
    }

    var rightBoundary = text.length;
    for (var i = end; i < text.length; i++) {
      final ch = text[i];
      if (ch == '.' || ch == '\n') {
        rightBoundary = i;
        break;
      }
    }

    return text.substring(leftBoundary, rightBoundary).trim();
  }
}

/// =======================
/// Layer 2-3: Extractor
/// =======================

class _AliasHit {
  final int start;
  final int end;
  final DrugDef drug;

  _AliasHit({required this.start, required this.end, required this.drug});
}

class _MatchRange {
  final int start;
  final int end;

  _MatchRange({required this.start, required this.end});
}

class RuleBasedExtractor {
  final LocalNerEngine ner; // plug your own NER; defaults to no-op

  RuleBasedExtractor({LocalNerEngine? nerEngine})
      : ner = nerEngine ?? NoOpNerEngine();

  /// Version basée sur les DOSES :
  /// - On identifie chaque dose (1 g, 4 g, 320 mg, ...)
  /// - Chaque dose définit un "sous-segment" qui correspond à un traitement
  ///   (dose + posologie + route + médicament associé).
  ///
  /// Exemple :
  /// "Ceftriaxone 1 g par jour en VVP et 4 g x2 par jour Piperacilline + Tazo sur PAC"
  /// =>
  ///   ["Ceftriaxone 1 g par jour en VVP",
  ///    "4 g x2 par jour Piperacilline + Tazo sur PAC"]
  @override
  List<String> splitMultiDrugSegment(String segment) {
    final doseRegex = RegExp(r'(\d+(?:[.,]\d+)?)\s*(mg|g|µg|ug)');
    final matches = doseRegex.allMatches(segment).toList();

    // 0 ou 1 dose : on garde le segment tel quel
    if (matches.length <= 1) {
      return [segment];
    }

    final connectorRegex = RegExp(r'\b(et|puis|plus)\b|,|;');
    final pieces = <String>[];

    for (var i = 0; i < matches.length; i++) {
      final current = matches[i];

      final prevDoseEnd = i == 0 ? 0 : matches[i - 1].end;
      final nextDoseStart =
          i == matches.length - 1 ? segment.length : matches[i + 1].start;

      // ==============
      // Borne gauche
      // ==============
      var start = prevDoseEnd;
      final leftWindow = segment.substring(prevDoseEnd, current.start);
      int? leftCutOffset;

      final leftMatches = connectorRegex.allMatches(leftWindow);
      for (final m in leftMatches) {
        leftCutOffset = m.end; // on garde le dernier connecteur
      }
      if (leftCutOffset != null) {
        start = prevDoseEnd + leftCutOffset;
      }

      // ==============
      // Borne droite
      // ==============
      var end = nextDoseStart;
      final rightWindow = segment.substring(current.end, nextDoseStart);
      final rightMatch = connectorRegex.firstMatch(rightWindow);
      if (rightMatch != null) {
        end = current.end + rightMatch.start;
      }

      final slice = segment.substring(start, end).trim();
      if (slice.isNotEmpty) {
        pieces.add(slice);
      }
    }

    // Déduplication simple au cas où les fenêtres se recoupent
    final unique = <String>[];
    for (final p in pieces) {
      if (!unique.contains(p)) unique.add(p);
    }
    return unique;
  }

  Prescription _extractOne(String segment) {
    var working = segment;
    final phoneticSegment = phoneticProjection(segment);

    // Notes enclosed in parentheses or introduced by "notes:"
    String? parenNote;
    final notesMatch = RegExp(r'\(([^)]*)\)').firstMatch(working);
    if (notesMatch != null) {
      parenNote = notesMatch.group(1)?.trim();
      working = working.replaceFirst(notesMatch.group(0)!, '').trim();
    }

    String? labeledNote;
    final labeledMatch = RegExp(r'notes?:\s*([^\n]+)').firstMatch(working);
    if (labeledMatch != null) {
      labeledNote = labeledMatch.group(1);
      labeledNote =
          labeledNote?.split(RegExp(r'\b(?:tel|tél)[ :]+')).first.trim();
      working = working.replaceFirst(labeledMatch.group(0)!, '').trim();
    }

    String? notes;
    final notePieces = <String>[];
    if (parenNote != null && parenNote.isNotEmpty) notePieces.add(parenNote);
    if (labeledNote != null && labeledNote.isNotEmpty) {
      notePieces.add(labeledNote);
    }
    if (notePieces.isNotEmpty) {
      notes = notePieces.join(' | ');
    }

    final drug = findDrugInSegment(working);

    // Dose (e.g. 1 g, 320 mg)
    final doseMatch =
        RegExp(r'(\d+(?:[.,]\d+)?)\s*(mg|g|µg|ug)').firstMatch(working);
    String? dosage;
    int? doseEndIndex;
    if (doseMatch != null) {
      final value = doseMatch.group(1)!.replaceAll(',', '.');
      final unit = doseMatch.group(2)!;
      dosage = '$value $unit';
      doseEndIndex = doseMatch.end;
    }

    // Duration (optional)
    final duree = findDuration(working);

    // Route / device
    final routeMatch = findRoute(working);

    // Posology: text between dose and route (or to end)
    String? posologie;
    if (doseEndIndex != null) {
      final end = routeMatch?.start ?? working.length;
      if (end > doseEndIndex) {
        posologie = working.substring(doseEndIndex, end).trim();
      }
    }

    // Optional NER hook (currently unused)
    final nerEntities = ner.analyze(working);
    if (nerEntities.isNotEmpty) {
      // Keep placeholder for future merging.
    }

    return Prescription(
      libelle: drug?.key,
      dci: drug?.dci,
      dosage: dosage,
      posologie: posologie,
      voie: routeMatch?.voie,
      dispositif: routeMatch?.dispositif,
      forme: null,
      duree: duree,
      notes: notes,
      segmentSource: segment,
      segmentSourcePhonetic: phoneticSegment,
    );
  }

  List<Prescription> extract(String normalizedText) {
    final segments = _segmentText(normalizedText);
    final results = <Prescription>[];

    for (final seg in segments) {
      if (seg.trim().isEmpty) continue;

      final subSegments = splitMultiDrugSegment(seg);
      for (final sub in subSegments) {
        results.add(_extractOne(sub));
      }
    }

    return results;
  }

  /// Split text into prescription blocks separated by blank lines.
  List<String> _segmentText(String normalizedText) {
    final lines = normalizedText.split('\n');
    final segments = <String>[];
    final buffer = <String>[];

    void flush() {
      if (buffer.isNotEmpty) {
        segments.add(buffer.join(' ').trim());
        buffer.clear();
      }
    }

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        flush();
      } else {
        buffer.add(trimmed);
      }
    }
    flush();

    return segments;
  }
}
