/// Workbench actions that need the screen (docs/EDITOR_ARCHITECTURE.md,
/// "Shortcuts"). Palette commands, the editor page's forwarded shortcuts
/// and Flutter's own key bindings all fire intents; the workbench screen,
/// which can show dialogs, carries them out.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'editor/editor_host.dart';
import 'editor/editor_providers.dart';

enum WorkbenchIntent {
  newFile,
  save,
  saveAs,
  closeEditor,
  closeOtherEditors,
  nextEditor,
  previousEditor,
  commandPalette,
  find,
  replace,
  gotoLine,
  goToFile,
  undo,
  redo,
}

/// Shortcut names the page forwards (protocol `appShortcuts`) → intents.
const Map<String, WorkbenchIntent> intentForShortcut = {
  'save': WorkbenchIntent.save,
  'saveAs': WorkbenchIntent.saveAs,
  'palette': WorkbenchIntent.commandPalette,
  'closeTab': WorkbenchIntent.closeEditor,
  'nextTab': WorkbenchIntent.nextEditor,
  'previousTab': WorkbenchIntent.previousEditor,
  'newFile': WorkbenchIntent.newFile,
  'find': WorkbenchIntent.find,
  'replace': WorkbenchIntent.replace,
  'gotoLine': WorkbenchIntent.gotoLine,
  'goToFile': WorkbenchIntent.goToFile,
};

/// A broadcast of intents. Nobody listening (the workbench is not on
/// screen) means an intent is dropped, which is what should happen.
final class WorkbenchIntents {
  final StreamController<WorkbenchIntent> _controller =
      StreamController<WorkbenchIntent>.broadcast();

  Stream<WorkbenchIntent> get stream => _controller.stream;

  void fire(WorkbenchIntent intent) {
    if (!_controller.isClosed) {
      _controller.add(intent);
    }
  }

  Future<void> dispose() => _controller.close();
}

final workbenchIntentsProvider = Provider<WorkbenchIntents>((ref) {
  final intents = WorkbenchIntents();
  final subscription = ref.watch(editorHostProvider).events.listen((event) {
    if (event is ShortcutPressed) {
      final intent = intentForShortcut[event.shortcut];
      if (intent != null) {
        intents.fire(intent);
      }
    }
  });
  ref.onDispose(() {
    unawaited(subscription.cancel());
    unawaited(intents.dispose());
  });
  return intents;
});
