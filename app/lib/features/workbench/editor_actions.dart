/// Editing flows the workbench runs for palette commands and shortcuts
/// (Phase 2 W6): the ones that need the screen for a dialog.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/documents/document_controller.dart';
import '../../application/editor/editor_providers.dart';
import '../../core/editor/line_target.dart';
import '../../core/errors/failure.dart';
import 'editor_dialogs.dart';

/// Asks for a line (and column) and moves the active document's cursor
/// there, giving the editor the keyboard back.
Future<void> goToLine(BuildContext context, WidgetRef ref) async {
  final docId = ref.read(documentControllerProvider).active?.docId;
  if (docId == null) {
    return;
  }
  final host = ref.read(editorHostProvider);
  // The line count and the cursor's line include edits still on their way.
  await host.flush(docId);
  if (!context.mounted) {
    return;
  }
  final text = host.textOf(docId) ?? '';
  final head = host.viewStateOf(docId)?.selection?.head ?? 0;
  final target = await askLineTarget(
    context,
    lineCount: lineCountOf(text),
    currentLine: lineAtOffset(text, head),
  );
  if (target == null || !context.mounted) {
    return;
  }
  final moved = await host.gotoLine(target.line, column: target.column);
  if (moved.isOk) {
    await host.exec('focus');
  }
}
