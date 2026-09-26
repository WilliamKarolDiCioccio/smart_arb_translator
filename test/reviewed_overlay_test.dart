import 'dart:convert';
import 'dart:io';

import 'package:smart_arb_translator/src/models/translation_resource.dart';
import 'package:smart_arb_translator/src/reviewed_overlay.dart';
import 'package:smart_arb_translator/src/single_file_processor.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late File source;
  late File ledger;
  const resource = TranslationResource(id: 'back', sourceText: 'Back', sourceTopic: 'ui.arb');

  Map<String, dynamic> record() => {
        'source': resource.sourceText,
        'translation': 'Retour',
        'sourceFingerprint': TranslationFingerprint.source(resource),
        'contextFingerprint': TranslationFingerprint.reviewContext(resource),
      };

  void writeRecord(Map<String, dynamic> value) => ledger.writeAsStringSync(jsonEncode({'back': value}));

  ReviewedOverlay load() => ReviewedOverlay.load(
        rootDirectory: '${root.path}/reviewed',
        locale: 'fr',
        sourceFile: source.path,
        resources: [resource],
        translationContext: null,
      );

  List<TranslationResource> plan({Set<String>? keys}) => SingleFileProcessor.pendingProviderResources(
        sourceArbPath: source.path,
        languageCode: 'fr',
        outputDirectory: '${root.path}/cache',
        outputFileName: 'intl_fr.arb',
        translationService: 'openai',
        reviewedTranslationsDir: '${root.path}/reviewed',
        resourceKeyFilter: keys,
      );

  setUp(() {
    root = Directory.systemTemp.createTempSync('reviewed-overlay-test-');
    source = File('${root.path}/ui.arb')..writeAsStringSync(jsonEncode({'@@locale': 'en', 'back': 'Back'}));
    final locale = Directory('${root.path}/reviewed/fr')..createSync(recursive: true);
    File('${locale.path}/ui.arb').writeAsStringSync(jsonEncode({'@@locale': 'fr', 'back': 'Retour'}));
    ledger = File('${locale.path}/ui.review.json');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('generic ledgers still provide reviewed coverage without workflow fields', () {
    writeRecord(record());
    expect(load().translations, {'back': 'Retour'});
  });

  for (final verdicts in <List<String?>>[
    [null, null],
    ['keep', null],
    [null, 'pass'],
    ['pending', 'pending'],
    ['keep', 'pending'],
  ]) {
    test('unfinished verdicts $verdicts are valid but need provider coverage', () {
      writeRecord(record()
        ..addAll({
          'reviewVersion': 1,
          'primaryVerdict': verdicts[0],
          'verificationVerdict': verdicts[1],
        }));
      final before = ledger.readAsStringSync();
      expect(load().translations, isEmpty);
      expect(plan().map((item) => item.id), ['back']);
      expect(ledger.readAsStringSync(), before);
    });
  }

  test('completed review provides coverage without adjudication', () {
    writeRecord(record()..addAll({'reviewVersion': 1, 'primaryVerdict': 'keep', 'verificationVerdict': 'pass'}));
    expect(load().translations, {'back': 'Retour'});
    expect(plan(), isEmpty);
  });

  test('disputed review provides coverage only after adjudication', () {
    final value = record()..addAll({'primaryVerdict': 'replace', 'verificationVerdict': 'disputed'});
    writeRecord(value);
    expect(load().translations, isEmpty);
    writeRecord(value..['adjudicationVerdict'] = 'resolved');
    expect(load().translations, {'back': 'Retour'});
  });

  for (final malformed in <Map<String, dynamic>>[
    {'reviewVersion': 1},
    {'primaryVerdict': null},
    {'primaryVerdict': null, 'verificationVerdict': 5},
    {'primaryVerdict': '', 'verificationVerdict': null},
  ]) {
    test('malformed workflow fields still fail: $malformed', () {
      writeRecord(record()..addAll(malformed));
      expect(load, throwsFormatException);
    });
  }

  for (final mismatch in <Map<String, dynamic>>[
    {'source': 'Wrong source'},
    {'translation': 'Wrong target'},
    {'sourceFingerprint': ''},
    {'contextFingerprint': null},
  ]) {
    test('pending reviews still validate source and translation integrity: $mismatch', () {
      writeRecord(record()
        ..addAll({'primaryVerdict': null, 'verificationVerdict': null})
        ..addAll(mismatch));
      expect(load, throwsFormatException);
    });
  }

  test('pending review does not invalidate current provider cache', () {
    writeRecord(record()..addAll({'primaryVerdict': null, 'verificationVerdict': null}));
    final cache = File('${root.path}/cache/intl_fr.arb');
    cache.parent.createSync();
    cache.writeAsStringSync(jsonEncode({'@@locale': 'fr', 'back': 'Revenir'}));
    File('${cache.path}.provenance.json').writeAsStringSync(jsonEncode({
      'back': {
        'sourceFingerprint': TranslationFingerprint.source(resource),
        'contextFingerprint': TranslationFingerprint.cacheContext(
          resource,
          provider: 'openai',
          endpointClass: 'https://api.openai.com',
          model: 'gpt-4o-mini',
          promptVersion: TranslationFingerprint.algorithmVersion,
        ),
      },
    }));
    expect(plan(), isEmpty);
  });

  test('offline pending review reports missing coverage instead of a malformed ledger', () async {
    writeRecord(record()..addAll({'primaryVerdict': null, 'verificationVerdict': null}));
    await expectLater(
      SingleFileProcessor.processSingleFileWithChanges(
        source.path,
        ['fr'],
        '',
        '${root.path}/cache',
        'intl_fr.arb',
        null,
        null,
        reviewedTranslationsDir: '${root.path}/reviewed',
        manualOnly: true,
      ),
      throwsA(isA<ManualCoverageException>()
          .having((error) => error.missing.map((item) => item.key), 'missing keys', ['back'])),
    );
  });

  test('key-scoped planning accepts unselected keys in the full overlay', () {
    source.writeAsStringSync(jsonEncode({'@@locale': 'en', 'back': 'Back', 'next': 'Next'}));
    writeRecord(record()..addAll({'primaryVerdict': null, 'verificationVerdict': null}));
    expect(plan(keys: {'next'}).map((item) => item.id), ['next']);
  });
}
