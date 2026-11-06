import 'package:codeforge/application/editor_tabs_controller.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/core/editor/protocol.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/design_system/components/workbench_chrome.dart';
import 'package:codeforge/design_system/tokens/colors.dart';
import 'package:codeforge/features/workbench/panels/editor_appearance.dart';
import 'package:codeforge/features/workbench/panels/editor_pane.dart';
import 'package:codeforge/features/workbench/panels/editor_surface_view.dart';
import 'package:codeforge/services/settings/settings_model.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_editor_surface.dart';
import 'test_harness.dart';

void main() {
  group('editor appearance', () {
    test('the configuration is a valid editor.configure, both themes', () {
      for (final (colors, dark) in [
        (CfColors.dark, true),
        (CfColors.light, false),
      ]) {
        final message = BridgeMessage(
          id: 'h1',
          type: 'editor.configure',
          payload: editorConfiguration(colors, dark: dark, fontSize: 14),
        );
        final result = parseMessage(
          message.encode(),
          MessageDirection.hostToEditor,
        );
        expect(
          result,
          isA<ParsedMessage>(),
          reason: result is RejectedMessage ? result.reason : null,
        );
      }
    });

    test('colours are CSS hex, alpha last and only when translucent', () {
      expect(cssHex(const Color(0xFF0F1115)), '#0F1115');
      expect(cssHex(const Color(0x47FF7A45)), '#FF7A4547');
      expect(cssHex(const Color(0x00000000)), '#00000000');
    });

    test('font sizes clamp to what the page accepts', () {
      double size(double requested) =>
          editorConfiguration(
                CfColors.dark,
                dark: true,
                fontSize: requested,
              )['fontSize']!
              as double;
      expect(size(100), maxEditorFontSize);
      expect(size(2), minEditorFontSize);
      expect(size(17.5), 17.5);
    });
  });

  testWidgets('the page follows the theme, font size and text scale', (
    tester,
  ) async {
    setSurface(tester, 1280, 800);
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final harness = TestHarness(
      shell: const ShellState(lastRoute: '/workspace'),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    final configuration = harness.editorSurface.configuration!;
    // 14 (the default editor font size) × 1.5 — the page's own text zoom
    // is pinned at 100 %, so the host's scaled size is the only scaling.
    expect(configuration['fontSize'], 21);
    final palette = configuration['palette']! as Map<String, Object?>;
    expect(palette['dark'], isTrue);
    expect(palette['background'], cssHex(CfColors.dark.surfaceSunken));
    expect(palette['foreground'], cssHex(CfColors.dark.textPrimary));
  });

  testWidgets('switching to the light theme reconfigures the page', (
    tester,
  ) async {
    setSurface(tester, 1280, 800);
    final harness = TestHarness(
      settings: const AppSettings(
        welcomeSeen: true,
        themeMode: ThemeMode.light,
      ),
      shell: const ShellState(lastRoute: '/workspace'),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    final palette =
        harness.editorSurface.configuration!['palette']!
            as Map<String, Object?>;
    expect(palette['dark'], isFalse);
    expect(palette['background'], cssHex(CfColors.light.surfaceSunken));
  });

  testWidgets('an editor that cannot start says why and can try again', (
    tester,
  ) async {
    setSurface(tester, 1280, 800);
    var attempts = 0;
    final harness = TestHarness(
      shell: const ShellState(lastRoute: '/workspace'),
      editorPageLoader: () async {
        attempts += 1;
        return attempts == 1
            ? const Err(
                BridgeFailure('The editor page does not match its manifest.'),
              )
            : const Ok(fakeEditorPage);
      },
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    expect(find.text('The editor could not start'), findsOneWidget);
    expect(
      find.text('The editor page does not match its manifest.'),
      findsOneWidget,
    );
    expect(harness.editorSurface.loads, 0);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.text('The editor could not start'), findsNothing);
    expect(attempts, 2);
    // main.js was waiting in its shadow and opened with the sync.
    expect(harness.editorSurface.documents, hasLength(1));
  });
  testWidgets('the page outlives the tab strip and toolbar leaving together', (
    tester,
  ) async {
    final harness = TestHarness();
    final height = ValueNotifier<double>(400);
    addTearDown(height.dispose);
    await tester.pumpWidget(
      harness.wrap(
        ValueListenableBuilder<double>(
          valueListenable: height,
          builder: (context, value, _) => Align(
            alignment: Alignment.topCenter,
            child: SizedBox(height: value, child: const EditorPane()),
          ),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(EditorPane)),
      listen: false,
    );
    await container.read(fileServiceProvider).openDemoWorkspace();
    await container.read(editorTabsProvider.notifier).open('main.js');
    await tester.pumpAndSettle();
    expect(find.byType(CfTabStrip), findsOneWidget);
    expect(find.byType(CfSymbolToolbar), findsOneWidget);
    final view = tester.state(find.byType(EditorSurfaceView));

    // Both strips leave in one layout: the keyboard on a short landscape
    // phone. The editor body must be the same element afterwards.
    height.value = 40;
    await tester.pumpAndSettle();
    expect(find.byType(CfTabStrip), findsNothing);
    expect(find.byType(CfSymbolToolbar), findsNothing);
    expect(tester.state(find.byType(EditorSurfaceView)), same(view));

    height.value = 400;
    await tester.pumpAndSettle();
    expect(find.byType(CfTabStrip), findsOneWidget);
    expect(tester.state(find.byType(EditorSurfaceView)), same(view));
    expect(harness.editorSurfaces, hasLength(1));
    expect(harness.editorSurface.loads, 1);
  });
}
