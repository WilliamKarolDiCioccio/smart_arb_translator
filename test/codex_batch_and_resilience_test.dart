import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:smart_arb_translator/src/codex_translation_service.dart';
import 'package:smart_arb_translator/src/concurrency.dart';
import 'package:smart_arb_translator/src/directory_processor.dart';
import 'package:smart_arb_translator/src/models/codex_options.dart';
import 'package:smart_arb_translator/src/models/translation_resource.dart';
import 'package:smart_arb_translator/src/single_file_processor.dart';
import 'package:smart_arb_translator/src/translation_service.dart';
import 'package:test/test.dart';

/// Answers a batch prompt with `[locale] source` for every requested locale,
/// except that [brokenLocales] get their placeholder token dropped.
class _BatchRunner implements CodexRunner {
  final Set<String> brokenLocales;
  final invocations = <CodexInvocation>[];

  _BatchRunner({this.brokenLocales = const {}});

  @override
  Future<String> run(CodexInvocation invocation) async {
    invocations.add(invocation);
    final payload = _payload(invocation.prompt);
    return jsonEncode({
      'translations': [
        for (final locale in (payload['target_locales'] as List).cast<String>())
          for (final resource in (payload['resources'] as List).cast<Map<String, dynamic>>())
            {
              'locale': locale,
              'id': resource['id'],
              'translation':
                  brokenLocales.contains(locale) ? '[$locale] broken' : '[$locale] ${resource['source_text']}',
            },
      ],
    });
  }
}

class _TimingOutRunner implements CodexRunner {
  var calls = 0;

  @override
  Future<String> run(CodexInvocation invocation) async {
    calls++;
    throw TimeoutException('Codex translation exceeded 1 seconds.');
  }
}

Map<String, dynamic> _payload(String prompt) =>
    jsonDecode(prompt.substring(prompt.indexOf('INPUT PAYLOAD') + 'INPUT PAYLOAD'.length).trim())
        as Map<String, dynamic>;

/// A stand-in `codex` executable: logs each call's target locale(s), then
/// answers `[locale] source` for every resource. Locales listed in
/// [hangLocales] never answer, so the caller's timeout fires.
File _writeFakeCodex(Directory directory, {Set<String> hangLocales = const {}}) {
  final log = File(path.join(directory.path, 'codex_calls.log'));
  final script = File(path.join(directory.path, 'fake_codex.py'))..writeAsStringSync('''
#!/usr/bin/env python3
import json, sys, time
prompt = sys.stdin.read()
payload = json.loads(prompt.split("INPUT PAYLOAD", 1)[1].strip())
locales = payload.get("target_locales") or [payload["target_locale"]]
with open(${jsonEncode(log.path)}, "a") as log:
    log.write(",".join(locales) + "\\n")
if any(locale in ${jsonEncode(hangLocales.toList())} for locale in locales):
    time.sleep(30)
batch = "target_locales" in payload
entries = []
for locale in locales:
    for resource in payload["resources"]:
        entry = {"id": resource["id"], "translation": "[" + locale + "] " + resource["source_text"]}
        if batch:
            entry["locale"] = locale
        entries.append(entry)
print(json.dumps({"translations": entries}))
''');
  Process.runSync('chmod', ['+x', script.path]);
  return script;
}

List<String> _calls(Directory directory) {
  final log = File(path.join(directory.path, 'codex_calls.log'));
  return log.existsSync() ? log.readAsLinesSync() : const [];
}

Map<String, dynamic> _readJson(String filePath) =>
    jsonDecode(File(filePath).readAsStringSync()) as Map<String, dynamic>;

void main() {
  const resource = TranslationResource(
    id: 'welcome',
    sourceText: 'Welcome {name}',
    sourceTopic: 'home.arb',
    placeholders: {
      'name': {'type': 'String'},
    },
  );

  group('all-locale Codex batch', () {
    test('one run covers every locale and each locale is validated on its own', () async {
      final runner = _BatchRunner(brokenLocales: {'de'});
      final results = await TranslationService.translateCodexBatch(
        resources: const [resource],
        targetLocales: const ['sv', 'fr', 'de'],
        sourceLocale: 'en',
        translationContext: null,
        codexOptions: const CodexOptions(),
        codexRunner: runner,
      );

      expect(runner.invocations, hasLength(1));
      expect(results.keys, unorderedEquals(['sv', 'fr']), reason: 'de lost its placeholder and must be retried alone');
      expect(results['sv']!.single.translation, '[sv] Welcome {name}');
      final schema = runner.invocations.single.outputSchema['properties']['translations'] as Map<String, dynamic>;
      expect(schema['minItems'], 3);
    });

    test('incomplete or duplicated locales are dropped rather than trusted', () {
      final parsed = CodexTranslationService.parseBatchResponse(
        jsonEncode({
          'translations': [
            {'locale': 'sv', 'id': 'welcome', 'translation': 'Välkommen'},
            {'locale': 'fr', 'id': 'welcome', 'translation': 'Bienvenue'},
            {'locale': 'fr', 'id': 'welcome', 'translation': 'Salut'},
          ],
        }),
        resources: const [resource],
        targetLocales: const ['sv', 'fr', 'de'],
      );
      expect(parsed.keys, ['sv']);
    });

    test('a failed batch run falls back to per-locale translation', () async {
      final results = await TranslationService.translateCodexBatch(
        resources: const [resource],
        targetLocales: const ['sv', 'fr'],
        sourceLocale: 'en',
        translationContext: null,
        codexOptions: const CodexOptions(),
        codexRunner: _TimingOutRunner(),
      );
      expect(results, isEmpty);
    });
  });

  test('a per-locale timeout is retried once, then reported as an unavailable locale', () async {
    final runner = _TimingOutRunner();
    await expectLater(
      TranslationService.translateResources(
        resources: const [resource],
        parameters: const {'source': 'en', 'target': 'vi'},
        translationService: 'codex',
        codexOptions: const CodexOptions(),
        codexRunner: runner,
      ),
      throwsA(isA<CodexLocaleUnavailable>().having((error) => error.locale, 'locale', 'vi')),
    );
    expect(runner.calls, 2);
  });

  test('the worker pool never exceeds its limit and does not wait for a slow item', () async {
    var active = 0;
    var peak = 0;
    final finished = <int>[];
    await forEachPooled<int>([0, 1, 2, 3, 4], 2, (item) async {
      active++;
      peak = active > peak ? active : peak;
      await Future<void>.delayed(Duration(milliseconds: item == 0 ? 60 : 5));
      active--;
      finished.add(item);
    });
    expect(peak, 2);
    expect(finished.last, 0, reason: 'items 1-4 flow through the second slot while item 0 is slow');
  });

  group('directory translation through the Codex CLI', () {
    late Directory temp;
    late Directory source;
    late String cache;
    late String l10n;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('smart_arb_codex_batch_');
      source = Directory(path.join(temp.path, 'source'))..createSync();
      cache = path.join(temp.path, 'cache');
      l10n = path.join(temp.path, 'l10n');
      File(path.join(source.path, 'ui.arb')).writeAsStringSync(
        jsonEncode({'@@locale': 'en', 'play': 'Play', 'back': 'Back'}),
      );
    });
    tearDown(() => temp.deleteSync(recursive: true));

    Future<void> translate(File codex, {int batchMaxResources = 20}) => DirectoryProcessor.processDirectory(
          source.path,
          const ['en', 'sv', 'fr', 'de'],
          '',
          cache,
          'intl_',
          l10n,
          dartMainLocale: 'en',
          translationService: 'codex',
          codexOptions: CodexOptions(
            executable: codex.path,
            timeout: const Duration(seconds: 2),
            batchMaxResources: batchMaxResources,
          ),
          parallelTranslations: 8,
        );

    test('a small change is translated for every locale in a single Codex run', () async {
      final codex = _writeFakeCodex(temp);
      await translate(codex);

      expect(_calls(temp), ['sv,fr,de']);
      expect(_readJson(path.join(l10n, 'intl_de.arb'))['play'], '[de] Play');

      // Unchanged content is not sent again; a new key is batched on its own.
      File(path.join(source.path, 'ui.arb')).writeAsStringSync(
        jsonEncode({'@@locale': 'en', 'play': 'Play', 'back': 'Back', 'quit': 'Quit'}),
      );
      await translate(codex);
      expect(_calls(temp), ['sv,fr,de', 'sv,fr,de']);
      expect(_readJson(path.join(l10n, 'intl_sv.arb'))['quit'], '[sv] Quit');
    });

    test('a locale that keeps timing out is skipped, the run finishes, and the next run retries it', () async {
      await translate(_writeFakeCodex(temp, hangLocales: {'sv'}), batchMaxResources: 0);

      expect(_calls(temp).where((line) => line == 'sv'), hasLength(2), reason: 'retried once');
      expect(SkippedTranslations.isEmpty, isFalse);
      expect(_readJson(path.join(l10n, 'intl_fr.arb'))['play'], '[fr] Play');
      expect(_readJson(path.join(l10n, 'intl_sv.arb'))['play'], 'Play', reason: 'source text as placeholder');

      File(path.join(temp.path, 'codex_calls.log')).deleteSync();
      await translate(_writeFakeCodex(temp), batchMaxResources: 0);
      expect(_calls(temp), ['sv'], reason: 'only the skipped locale is translated again');
      expect(_readJson(path.join(l10n, 'intl_sv.arb'))['play'], '[sv] Play');
      expect(SkippedTranslations.isEmpty, isTrue);
    });

    test('a batch run that times out falls back to per-locale runs', () async {
      await translate(_writeFakeCodex(temp, hangLocales: {'de'}));

      final calls = _calls(temp);
      expect(calls.first, 'sv,fr,de');
      expect(calls.skip(1), containsAll(['sv', 'fr']));
      expect(_readJson(path.join(l10n, 'intl_fr.arb'))['back'], '[fr] Back');
      expect(_readJson(path.join(l10n, 'intl_de.arb'))['back'], 'Back');
    });
  });
}
