/// The editor's symbol toolbar (Phase 2 W6): Tab and Shift+Tab, the active
/// document's language preset or the user's own keys, undo and redo, the
/// cursor arrows, and a pinned key that puts the keyboard away. Keys act on
/// the editor, so they are live only while it has the keyboard; they never
/// take focus, so it keeps the keyboard (docs/EDITOR_ARCHITECTURE.md §9).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../application/documents/document_controller.dart';
import '../../../application/editor/editor_providers.dart';
import '../../../application/editor/editor_status.dart';
import '../../../application/keyboard_state.dart';
import '../../../application/settings_controller.dart';
import '../../../core/editor/toolbar_keys.dart';
import '../../../design_system/components/workbench_chrome.dart';
import '../../../design_system/tokens/icons.dart';
import '../../../services/settings/settings_model.dart';

class EditorSymbolToolbar extends ConsumerWidget {
  const EditorSymbolToolbar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final active = ref.watch(documentControllerProvider).active;
    final status = ref.watch(editorStatusProvider);
    final keyboardUp = ref.watch(softKeyboardVisibleProvider);
    final docId = active?.docId;
    final live = docId != null && status.focused;

    bool enabled(ToolbarKey key) => switch (key.kind) {
      ToolbarKeyKind.undo => live && status.canUndo(docId),
      ToolbarKeyKind.redo => live && status.canRedo(docId),
      ToolbarKeyKind.hideKeyboard => keyboardUp || status.focused,
      _ => live,
    };

    void run(ToolbarAction action) {
      final host = ref.read(editorHostProvider);
      switch (action) {
        case InsertText(:final text, :final cursorOffset):
          unawaited(host.insert(text, cursorOffset: cursorOffset));
        case RunCommand(:final command):
          unawaited(host.exec(command));
        case HideKeyboard():
          // The page drops its focus, which closes the keyboard it opened;
          // a field of the app's own (the find bar) is simply unfocused.
          if (ref.read(editorStatusProvider).focused) {
            unawaited(host.exec('blur'));
          } else {
            FocusManager.instance.primaryFocus?.unfocus();
          }
      }
    }

    CfToolbarKey toolbarKey(ToolbarKey key) {
      final longPress = key.longPress;
      final on = enabled(key);
      final icon = _iconFor(key.kind);
      return CfToolbarKey(
        id: key.id,
        semanticLabel: key.semanticLabel,
        label: icon == null ? key.label : null,
        icon: icon,
        onPressed: on ? () => run(key.action) : null,
        onLongPress: on && longPress != null ? () => run(longPress) : null,
      );
    }

    final keys = toolbarKeysFor(
      language: active?.language,
      compact: settings.toolbarPreset == ToolbarPreset.compact,
      customKeys: settings.toolbarKeys,
    );
    return CfSymbolToolbar(
      key: const ValueKey('symbol_toolbar'),
      keys: [for (final key in keys) toolbarKey(key)],
      trailing: [toolbarKey(hideKeyboardKey)],
    );
  }
}

IconData? _iconFor(ToolbarKeyKind kind) => switch (kind) {
  ToolbarKeyKind.symbol || ToolbarKeyKind.indent => null,
  ToolbarKeyKind.outdent => CfIcons.formatIndentDecrease,
  ToolbarKeyKind.undo => CfIcons.undo,
  ToolbarKeyKind.redo => CfIcons.redo,
  ToolbarKeyKind.left => CfIcons.keyboardArrowLeft,
  ToolbarKeyKind.up => CfIcons.keyboardArrowUp,
  ToolbarKeyKind.down => CfIcons.keyboardArrowDown,
  ToolbarKeyKind.right => CfIcons.keyboardArrowRight,
  ToolbarKeyKind.hideKeyboard => CfIcons.keyboardHide,
};
