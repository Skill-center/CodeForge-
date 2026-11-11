import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('shell envelope', () {
    test('roundtrips every field', () {
      const state = ShellState(
        lastRoute: '/workspace',
        activity: ShellActivity.git,
        terminalStop: TerminalStop.half,
        sidebarWidth: 300,
        terminalHeight: 260,
        demoWorkspaceOpened: true,
      );
      expect(
        decodeShellState(encodeShellState(state)),
        isA<ShellState>()
            .having((s) => s.lastRoute, 'lastRoute', '/workspace')
            .having((s) => s.activity, 'activity', ShellActivity.git)
            .having((s) => s.terminalStop, 'terminalStop', TerminalStop.half)
            .having((s) => s.sidebarWidth, 'sidebarWidth', 300)
            .having((s) => s.terminalHeight, 'terminalHeight', 260)
            .having((s) => s.demoWorkspaceOpened, 'demoWorkspaceOpened', true),
      );
    });

    test('open tabs round trip, and only valid paths come back', () {
      const state = ShellState(
        openTabs: ['main.js', 'src/app.py'],
        activeTab: 'src/app.py',
      );
      final restored = decodeShellState(encodeShellState(state));
      expect(restored.openTabs, ['main.js', 'src/app.py']);
      expect(restored.activeTab, 'src/app.py');

      final tampered = decodeShellState(
        '{"schemaVersion":1,"data":{"openTabs":'
        '["a.js","../x.js","a.js",7,"/etc/passwd","b.js"],'
        '"activeTab":"../x.js"}}',
      );
      expect(tampered.openTabs, ['a.js', 'b.js']);
      expect(tampered.activeTab, isNull);

      // Envelopes written before W4 have no tabs at all.
      final older = decodeShellState(
        '{"schemaVersion":1,"data":{"lastRoute":"/workspace"}}',
      );
      expect(older.openTabs, isEmpty);
      expect(older.activeTab, isNull);
      expect(older.lastRoute, '/workspace');
    });

    test('corrupt payloads yield defaults', () {
      final defaults = decodeShellState(null);
      expect(decodeShellState('garbage').lastRoute, defaults.lastRoute);
      expect(decodeShellState('[]').lastRoute, defaults.lastRoute);
      expect(
        decodeShellState('{"schemaVersion":1,"data":42}').lastRoute,
        defaults.lastRoute,
      );
    });

    test('future version yields defaults', () {
      const raw = '{"schemaVersion":42,"data":{"lastRoute":"/workspace"}}';
      expect(decodeShellState(raw).lastRoute, '/');
    });

    test('only whitelisted routes are restorable', () {
      const raw =
          '{"schemaVersion":1,"data":{"lastRoute":"/settings/gallery"}}';
      expect(decodeShellState(raw).lastRoute, '/');
      const ok = '{"schemaVersion":1,"data":{"lastRoute":"/settings"}}';
      expect(decodeShellState(ok).lastRoute, '/settings');
    });

    test('the open folder round trips; a bad one is dropped', () {
      const folder = FolderLocation(
        treeUri:
            'content://com.android.externalstorage.documents/tree/primary%3Acf',
        name: 'cf',
      );
      const state = ShellState(folder: folder);
      expect(decodeShellState(encodeShellState(state)).folder, folder);
      expect(
        decodeShellState(encodeShellState(const ShellState())).folder,
        isNull,
      );
      // Phase 3 W1 envelopes have no folder: the built-in project opens.
      const w1 = '{"schemaVersion":1,"data":{"lastRoute":"/workspace"}}';
      expect(decodeShellState(w1).folder, isNull);
      for (final bad in [
        '"content://x"',
        '{"uri":"file:///sdcard/x","name":"x"}',
        '{"uri":42,"name":"x"}',
      ]) {
        final raw = '{"schemaVersion":1,"data":{"folder":$bad}}';
        expect(decodeShellState(raw).folder, isNull, reason: bad);
      }
      const unnamed =
          '{"schemaVersion":1,"data":{"folder":{"uri":"content://a/tree/b"}}}';
      expect(decodeShellState(unnamed).folder?.name, 'Folder');
      expect(state.copyWith(clearFolder: true).folder, isNull);
    });

    test('layout dimensions are clamped', () {
      const raw =
          '{"schemaVersion":1,"data":{"sidebarWidth":9000,"terminalHeight":-5}}';
      final decoded = decodeShellState(raw);
      expect(decoded.sidebarWidth, 420);
      expect(decoded.terminalHeight, 120);
    });
  });

  group('PrefsShellStateStore', () {
    test('survives a store restart', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = PrefsShellStateStore(prefs);
      const state = ShellState(
        lastRoute: '/workspace',
        terminalStop: TerminalStop.peek,
      );
      await store.save(state);
      final reloaded = PrefsShellStateStore(prefs);
      expect(reloaded.load().lastRoute, '/workspace');
      expect(reloaded.load().terminalStop, TerminalStop.peek);
    });
  });
}
