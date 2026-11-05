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
          ..having((s) => s.lastRoute, 'lastRoute', '/workspace')
          ..having((s) => s.activity, 'activity', ShellActivity.git)
          ..having((s) => s.terminalStop, 'terminalStop', TerminalStop.half)
          ..having((s) => s.sidebarWidth, 'sidebarWidth', 300)
          ..having((s) => s.terminalHeight, 'terminalHeight', 260)
          ..having((s) => s.demoWorkspaceOpened, 'demoWorkspaceOpened', true),
      );
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
