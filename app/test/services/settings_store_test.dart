import 'package:codeforge/services/settings/settings_model.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('settings envelope', () {
    test('roundtrips every field', () {
      const settings = AppSettings(
        themeMode: ThemeMode.light,
        editorFontSize: 18,
        reducedMotion: true,
        toolbarPreset: ToolbarPreset.compact,
        toolbarKeys: '; => {}',
        welcomeSeen: true,
        showHiddenFiles: true,
        saveBeforeRun: false,
        pythonServer: false,
        typescriptServer: false,
      );
      final decoded = decodeSettings(encodeSettings(settings));
      expect(decoded, settings);
    });

    test('the language servers stay on unless the user turned one off, in '
        'settings stored before they existed too (Phase 6 W5)', () {
      const before = '{"schemaVersion":1,"data":{"saveBeforeRun":false}}';
      expect(decodeSettings(before).pythonServer, isTrue);
      expect(decodeSettings(before).typescriptServer, isTrue);
      const off = '{"schemaVersion":1,"data":{"pythonServer":false}}';
      expect(decodeSettings(off).pythonServer, isFalse);
      expect(decodeSettings(off).typescriptServer, isTrue);
      const wrong = '{"schemaVersion":1,"data":{"typescriptServer":0}}';
      expect(decodeSettings(wrong).typescriptServer, isTrue);
    });

    test('Run saves first unless the user turned it off', () {
      expect(const AppSettings().saveBeforeRun, isTrue);
      const off = '{"schemaVersion":1,"data":{"saveBeforeRun":false}}';
      expect(decodeSettings(off).saveBeforeRun, isFalse);
      const wrong = '{"schemaVersion":1,"data":{"saveBeforeRun":"no"}}';
      expect(decodeSettings(wrong).saveBeforeRun, isTrue);
    });

    test('null/empty payload yields defaults', () {
      expect(decodeSettings(null), const AppSettings());
      expect(decodeSettings(''), const AppSettings());
    });

    test('corrupt JSON yields defaults instead of crashing', () {
      expect(decodeSettings('{not json'), const AppSettings());
      expect(decodeSettings('[1,2,3]'), const AppSettings());
      expect(decodeSettings('{"schemaVersion":1}'), const AppSettings());
      expect(
        decodeSettings('{"schemaVersion":1,"data":"nope"}'),
        const AppSettings(),
      );
    });

    test('future schema version yields defaults', () {
      const raw = '{"schemaVersion":99,"data":{"themeMode":"light"}}';
      expect(decodeSettings(raw), const AppSettings());
    });

    test('invalid field values fall back per-field', () {
      final raw = encodeSettings(
        const AppSettings(),
      ).replaceAll('"themeMode":"dark"', '"themeMode":"neon"');
      final decoded = decodeSettings(raw);
      expect(decoded.themeMode, ThemeMode.dark);
    });

    test('toolbar keys that are not text, or too long, are dropped', () {
      const number = '{"schemaVersion":1,"data":{"toolbarKeys":5}}';
      expect(decodeSettings(number).toolbarKeys, '');
      final long = '{"schemaVersion":1,"data":{"toolbarKeys":"${'x' * 401}"}}';
      expect(decodeSettings(long).toolbarKeys, '');
      const fine = '{"schemaVersion":1,"data":{"toolbarKeys":"; =>"}}';
      expect(decodeSettings(fine).toolbarKeys, '; =>');
    });

    test('font size is clamped to the supported range', () {
      const raw =
          '{"schemaVersion":1,"data":{"editorFontSize":1000,"reducedMotion":false}}';
      expect(decodeSettings(raw).editorFontSize, 24);
    });
  });

  group('PrefsSettingsStore', () {
    test('persists through SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = PrefsSettingsStore(prefs);
      expect(store.load(), const AppSettings());

      const next = AppSettings(themeMode: ThemeMode.light, welcomeSeen: true);
      await store.save(next);

      // A fresh store instance over the same prefs = app restart.
      final reloaded = PrefsSettingsStore(prefs);
      expect(reloaded.load(), next);
    });
  });
}
