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
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/editor/editor_host.dart';
import '../../../application/editor/editor_providers.dart';
import '../../../application/settings_controller.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/tokens/colors.dart';
import 'editor_appearance.dart';

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
            child: host.buildView(context),
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
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: colors.textSecondary),
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
