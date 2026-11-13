/// G2 navigation (docs/phases/PHASE_1_PLAN.md §2.4, §4): deep links resolve,
/// unknown locations land on home, and system back never strands the user
/// or silently leaves the app from a top-level destination.
///
/// Both are driven through the same platform messages the engine sends:
/// `pushRouteInformation` for an Android deep link and `popRoute` for the
/// back button — which is also what a predictive back gesture commits
/// through when no route claims the gesture (top-level pages here).
library;

import 'package:codeforge/features/home/home_screen.dart';
import 'package:codeforge/features/settings/appearance_screen.dart';
import 'package:codeforge/features/settings/settings_screen.dart';
import 'package:codeforge/features/workbench/workbench_screen.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'test_harness.dart';

Future<void> _navigationMessage(WidgetTester tester, MethodCall call) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    const JSONMethodCodec().encodeMethodCall(call),
    (_) {},
  );
  await tester.pumpAndSettle();
}

Future<void> _deepLink(WidgetTester tester, String location) =>
    _navigationMessage(
      tester,
      MethodCall('pushRouteInformation', <String, Object?>{
        'location': location,
        'state': null,
      }),
    );

Future<void> _systemBack(WidgetTester tester) =>
    _navigationMessage(tester, const MethodCall('popRoute'));

/// Records SystemNavigator.pop — the app leaving — instead of acting on it.
List<String> _recordAppExits(WidgetTester tester) {
  final exits = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'SystemNavigator.pop') exits.add(call.method);
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return exits;
}

Future<void> _start(WidgetTester tester, String route) async {
  setSurface(tester, 412, 915);
  await tester.pumpWidget(
    TestHarness(shell: ShellState(lastRoute: route)).app(),
  );
  await tester.pumpAndSettle();
}

/// Let the shell's debounced persistence timer fire before teardown.
Future<void> _flush(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 500));

void main() {
  group('G2 deep links', () {
    testWidgets('/workspace, /settings and a nested page resolve', (
      tester,
    ) async {
      await _start(tester, '/');
      expect(find.byType(HomeScreen), findsOneWidget);

      await _deepLink(tester, '/workspace');
      expect(find.byType(WorkbenchScreen), findsOneWidget);

      await _deepLink(tester, '/settings');
      expect(find.byType(SettingsScreen), findsOneWidget);

      await _deepLink(tester, '/settings/appearance');
      expect(find.byType(AppearanceScreen), findsOneWidget);
      await _flush(tester);
    });

    testWidgets('an unknown location lands on home, not an error page', (
      tester,
    ) async {
      await _start(tester, '/settings');
      await _deepLink(tester, '/no/such/place');
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(SettingsScreen), findsNothing);
      await _flush(tester);
    });
  });

  group('G2 system back', () {
    for (final route in ['/workspace', '/settings']) {
      testWidgets('from $route returns home instead of leaving the app', (
        tester,
      ) async {
        final exits = _recordAppExits(tester);
        await _start(tester, route);
        await _systemBack(tester);
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(exits, isEmpty);
        await _flush(tester);
      });
    }

    testWidgets('from a nested settings page pops to its parent', (
      tester,
    ) async {
      final exits = _recordAppExits(tester);
      await _start(tester, '/settings');
      await tester.tap(find.text('Appearance'));
      await tester.pumpAndSettle();
      expect(find.byType(AppearanceScreen), findsOneWidget);

      await _systemBack(tester);
      expect(find.byType(AppearanceScreen), findsNothing);
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(exits, isEmpty);
      await _flush(tester);
    });

    testWidgets('a dialog closes before the page handles back', (tester) async {
      final exits = _recordAppExits(tester);
      await _start(tester, '/workspace');
      await tester.tap(find.byKey(const ValueKey('palette_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('palette_input')), findsOneWidget);

      await _systemBack(tester);
      expect(find.byKey(const ValueKey('palette_input')), findsNothing);
      expect(find.byType(WorkbenchScreen), findsOneWidget);
      expect(exits, isEmpty);
      await _flush(tester);
    });

    testWidgets('on home leaves the app (start destination)', (tester) async {
      final exits = _recordAppExits(tester);
      await _start(tester, '/');
      await _systemBack(tester);
      expect(exits, ['SystemNavigator.pop']);
      await _flush(tester);
    });
  });
}
