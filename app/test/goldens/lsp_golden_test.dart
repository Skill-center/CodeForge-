/// Goldens of Phase 6 W5's language features (PHASE_6_PLAN W5: widget tests
/// for the chip, the Problems sheet and the rename dialog, with goldens at
/// the three breakpoints): the Problems sheet over the workbench, whose
/// status strip shows the problems chip, and the rename dialog, at
/// 412x915, 800x1280 and 1280x800. Baselines are generated on the CI Linux
/// runner via the [bootstrap] flow, like the screen goldens.
@Tags(['golden'])
library;

import 'package:codeforge/application/workbench_intents.dart';
import 'package:codeforge/features/workbench/workbench_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../widget/lsp_workbench.dart';

const String _source = 'import os\nprint(greet)\n\n\ndef greet():\n    pass\n';

const List<(double, double)> _sizes = [(412, 915), (800, 1280), (1280, 800)];

Future<void> _expectGolden(WidgetTester tester, String file) async {
  expect(tester.takeException(), isNull);
  await expectLater(find.byType(MaterialApp), matchesGoldenFile(file));
  // Let the shell's debounced persistence timer fire before teardown.
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  for (final (width, height) in _sizes) {
    final size = '${width.toInt()}x${height.toInt()}';

    testWidgets('problems sheet $size dark', (tester) async {
      final (_, lsp) = await pumpWithServers(
        tester,
        width: width,
        height: height,
        files: {'greet.py': _source},
      );
      await openFile(tester, 'greet.py');
      await publish(tester, lsp, 'greet.py', [
        lspProblem(1, 6, 11, 1),
        lspProblem(0, 7, 9, 2),
      ]);
      ProviderScope.containerOf(
        tester.element(find.byType(WorkbenchScreen)),
        listen: false,
      ).read(workbenchIntentsProvider).fire(WorkbenchIntent.problems);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('problems_sheet')), findsOneWidget);
      await _expectGolden(tester, 'lsp/problems_sheet_${size}_dark.png');
    });

    testWidgets('rename dialog $size dark', (tester) async {
      final (harness, lsp) = await pumpWithServers(
        tester,
        width: width,
        height: height,
        files: {'greet.py': _source},
      );
      lsp.answerWith({
        'textDocument/prepareRename': (_) => {
          'range': lspRange(4, 4, 4, 9),
          'placeholder': 'greet',
        },
      });
      await openFile(tester, 'greet.py');
      await pageAsks(tester, harness, 'lsp.prepareRename', 30);
      expect(find.byKey(const ValueKey('rename_dialog')), findsOneWidget);
      await _expectGolden(tester, 'lsp/rename_dialog_${size}_dark.png');
    });
  }
}
