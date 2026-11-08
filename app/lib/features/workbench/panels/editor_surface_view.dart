/// Hosts the editor page (Phase 2 W2) and keeps its appearance in step with
/// the theme, the editor font size and the user's text scale.
///
/// The surface is always mounted while the pane is visible, so the page
/// starts loading as soon as the workbench opens. Loading and failure are
/// shown as static overlays — no endless animation, which would also keep
/// `pumpAndSettle` from ever settling.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/editor/editor_host.dart';
import '../../../application/editor/editor_providers.dart';
import '../../../application/settings_controller.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/tokens/colors.dart';
import 'editor_appearance.dart';

/// Keys the editor page handles itself while it has the focus.
///
/// Android hands a key to Flutter before the focused WebView, and Flutter's
/// app-wide defaults would take these for moving the focus (Tab, the
/// arrows), scrolling (Ctrl+arrows, Page Up and Page Down), activating and
/// dismissing. Mapped to [DoNothingAndStopPropagationIntent], they stop
/// there without being consumed, so the embedding passes them on to the
/// page. Chords such as Ctrl+Tab match none of these and still reach the
/// workbench's shortcuts.
const Map<ShortcutActivator, Intent> editorPageKeys = {
  SingleActivator(LogicalKeyboardKey.tab): _toThePage,
  SingleActivator(LogicalKeyboardKey.tab, shift: true): _toThePage,
  SingleActivator(LogicalKeyboardKey.arrowLeft): _toThePage,
  SingleActivator(LogicalKeyboardKey.arrowRight): _toThePage,
  SingleActivator(LogicalKeyboardKey.arrowUp): _toThePage,
  SingleActivator(LogicalKeyboardKey.arrowDown): _toThePage,
  SingleActivator(LogicalKeyboardKey.arrowLeft, control: true): _toThePage,
  SingleActivator(LogicalKeyboardKey.arrowRight, control: true): _toThePage,
  SingleActivator(LogicalKeyboardKey.arrowUp, control: true): _toThePage,
  SingleActivator(LogicalKeyboardKey.arrowDown, control: true): _toThePage,
  SingleActivator(LogicalKeyboardKey.pageUp): _toThePage,
  SingleActivator(LogicalKeyboardKey.pageDown): _toThePage,
  SingleActivator(LogicalKeyboardKey.enter): _toThePage,
  SingleActivator(LogicalKeyboardKey.numpadEnter): _toThePage,
  SingleActivator(LogicalKeyboardKey.space): _toThePage,
  SingleActivator(LogicalKeyboardKey.escape): _toThePage,
};

const _toThePage = DoNothingAndStopPropagationIntent();

class EditorSurfaceView extends ConsumerStatefulWidget {
  const EditorSurfaceView({super.key});

  @override
  ConsumerState<EditorSurfaceView> createState() => _EditorSurfaceViewState();
}

class _EditorSurfaceViewState extends ConsumerState<EditorSurfaceView> {
  String? _sentConfiguration;

  @override
  void initState() {
    super.initState();
    unawaited(ref.read(editorHostProvider).start());
  }

  @override
  Widget build(BuildContext context) {
    final host = ref.watch(editorHostProvider);
    final status = ref.watch(editorHostStatusProvider);
    final settings = ref.watch(settingsControllerProvider);
    final colors = CfColors.of(context);
    _configure(
      host,
      editorConfiguration(
        colors,
        dark: Theme.of(context).brightness == Brightness.dark,
        fontSize: MediaQuery.textScalerOf(
          context,
        ).scale(settings.editorFontSize),
      ),
    );
    return ColoredBox(
      color: colors.surfaceSunken,
      child: Stack(
        fit: StackFit.expand,
        children: [
          KeyedSubtree(
            key: const ValueKey('editor_surface'),
            child: Shortcuts(
              shortcuts: editorPageKeys,
              child: host.buildView(context),
            ),
          ),
          if (status.phase != EditorHostPhase.ready)
            ColoredBox(
              color: colors.surfaceSunken,
              child: status.phase == EditorHostPhase.failed
                  ? CfEmptyState(
                      icon: Icons.error_outline,
                      title: 'The editor could not start',
                      message: status.message ?? 'Unknown error.',
                      actionLabel: 'Try again',
                      onAction: () => unawaited(host.reloadPage()),
                    )
                  : Center(
                      child: Text(
                        'Starting the editor…',
                        key: const ValueKey('editor_starting'),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
            ),
        ],
      ),
    );
  }

  /// Sends the configuration when it changed. It goes out after the frame:
  /// talking to the page is a side effect a build must not perform.
  void _configure(EditorHost host, Map<String, Object?> configuration) {
    final encoded = jsonEncode(configuration);
    if (encoded == _sentConfiguration) {
      return;
    }
    _sentConfiguration = encoded;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(host.configure(configuration));
      }
    });
  }
}
