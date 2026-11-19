/// Hosts the terminal page (Phase 5 W3) and keeps its appearance in step
/// with the theme, the terminal font size and the user's text scale, as
/// EditorSurfaceView does for the editor page.
///
/// It is mounted while the panel shows a session; the page itself lives as
/// long as the app (terminalViewProvider), so the sessions' views survive
/// the panel closing and opening again.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../application/settings_controller.dart';
import '../../../application/terminal/terminal_controller.dart';
import '../../../application/terminal/terminal_providers.dart';
import '../../../design_system/tokens/colors.dart';
import 'editor_surface_view.dart' show editorPageKeys;
import 'terminal_appearance.dart';

class TerminalSurfaceView extends ConsumerStatefulWidget {
  const TerminalSurfaceView({super.key});

  @override
  ConsumerState<TerminalSurfaceView> createState() =>
      _TerminalSurfaceViewState();
}

class _TerminalSurfaceViewState extends ConsumerState<TerminalSurfaceView> {
  String? _sentConfiguration;

  /// Holds the page's focus nodes, and the focus itself if the view has
  /// none (see EditorSurfaceView).
  final FocusNode _pageFocus = FocusNode(
    debugLabel: 'terminal page',
    skipTraversal: true,
  );

  @override
  void dispose() {
    _pageFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(terminalViewProvider);
    final settings = ref.watch(settingsControllerProvider);
    final colors = CfColors.of(context);
    // The page reports when its terminal takes the keyboard; Flutter's
    // focus follows it to the platform view, within reach of the keys the
    // page handles itself (Tab, the arrows, Enter, Escape).
    ref.listen(terminalControllerProvider.select((panel) => panel.focused), (
      _,
      focused,
    ) {
      if (!focused || _pageFocus.hasFocus) {
        return;
      }
      final views = _pageFocus.descendants.where(
        (node) => node.canRequestFocus,
      );
      (views.isEmpty ? _pageFocus : views.first).requestFocus();
    });
    _configure(
      terminalConfiguration(
        colors,
        dark: Theme.of(context).brightness == Brightness.dark,
        fontSize: MediaQuery.textScalerOf(
          context,
        ).scale(settings.editorFontSize),
      ),
    );
    return ColoredBox(
      color: colors.surfaceSunken,
      child: Shortcuts(
        shortcuts: editorPageKeys,
        child: Focus(
          focusNode: _pageFocus,
          includeSemantics: false,
          child: KeyedSubtree(
            key: const ValueKey('terminal_surface'),
            child: view.buildView(context),
          ),
        ),
      ),
    );
  }

  /// Sends the appearance when it changed, after the frame: talking to the
  /// page is a side effect a build must not perform.
  void _configure(Map<String, Object?> configuration) {
    final encoded = jsonEncode(configuration);
    if (encoded == _sentConfiguration) {
      return;
    }
    _sentConfiguration = encoded;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(
          ref.read(terminalControllerProvider.notifier).configure(configuration),
        );
      }
    });
  }
}
