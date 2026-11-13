/// Root widget: theme wiring, router, lifecycle flush.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'application/documents/document_controller.dart';
import 'application/explorer_view_controller.dart';
import 'application/router.dart';
import 'application/settings_controller.dart';
import 'application/shell_controller.dart';
import 'design_system/theme/theme.dart';

class CodeForgeApp extends ConsumerStatefulWidget {
  const CodeForgeApp({super.key});

  @override
  ConsumerState<CodeForgeApp> createState() => _CodeForgeAppState();
}

class _CodeForgeAppState extends ConsumerState<CodeForgeApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      ref.read(shellControllerProvider.notifier).flush();
      // Android may kill a backgrounded process without warning: store the
      // unsaved edits' snapshots and the tabs now (ADR-0008). Only when
      // documents exist — reading the controller would create the editor.
      if (ref.exists(documentControllerProvider)) {
        unawaited(ref.read(documentControllerProvider.notifier).checkpoint());
      }
      // The explorer's expanded folders and scroll (Phase 3 W3).
      if (ref.exists(explorerViewProvider)) {
        unawaited(ref.read(explorerViewProvider.notifier).flush());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsControllerProvider);
    final router = ref.watch(routerProvider);
    final reducedMotion = settings.reducedMotion;
    return MaterialApp.router(
      title: 'CodeForge',
      debugShowCheckedModeBanner: false,
      theme: CfTheme.light(),
      darkTheme: CfTheme.dark(),
      themeMode: settings.themeMode,
      routerConfig: router,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            disableAnimations: media.disableAnimations || reducedMotion,
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
