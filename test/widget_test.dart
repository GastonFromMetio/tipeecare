import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:prescription_normalizer/main.dart';
import 'package:prescription_normalizer/prescription_engine.dart';

void main() {
  testWidgets('normalizes and extracts a prescription', (tester) async {
    await tester.pumpWidget(const PrescriptionNormalizerApp());

    const input =
        'Piperacilline tazo 4g 3 fois par jour per os pendant 10 jours';

    await tester.enterText(find.byKey(const Key('input-text')), input);
    await tester.tap(find.byKey(const Key('process-button')));
    await tester.pumpAndSettle();

    final normalizedWidget =
        tester.widget<SelectableText>(find.byKey(const Key('normalized-text')));
    final jsonWidget =
        tester.widget<SelectableText>(find.byKey(const Key('json-output')));

    expect(
      normalizedWidget.data ?? '',
      contains('piperacilline tazo 4 g 3x/j per os pendant 10 jours'),
    );
    expect(
      jsonWidget.data ?? '',
      contains('"libelle": "Piperacilline + Tazobactam"'),
    );
    expect(jsonWidget.data ?? '', contains('"duree": "10j"'));
  });

  test('splits multi-drug segment into distinct prescriptions', () {
    const input =
        'prescriptions de ceftriaxone 1 g par jour en vvp et 4 g x2 par jour de piperacilline tazo sur pac';

    final normalized = const TextNormalizer().normalize(input);
    final prescriptions = RuleBasedExtractor().extract(normalized);

    expect(prescriptions.length, 2);
    expect(prescriptions.first.libelle, 'Ceftriaxone');
    expect(prescriptions.last.libelle, 'Piperacilline + Tazobactam');
    expect(prescriptions.last.posologie, contains('x2'));
    expect(prescriptions.last.dispositif, 'PAC');
  });
}
