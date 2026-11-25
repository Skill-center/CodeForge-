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
import 'application/terminal/terminal_controller.dart';
import 'design_system/theme/theme.dart';
import 'features/git/credential_prompts.dart';

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
      // Terminal sessions run on under the foreground service; their views
      // let go, so none waits for a page Android may stop (Phase 5 W5).
      if (ref.exists(terminalControllerProvider)) {
        ref.read(terminalControllerProvider.notifier).releaseAllViews();
      }
    } else if (state == AppLifecycleState.resumed) {
      // ...and the shown one is drawn again from the host's buffer.
      if (ref.exists(terminalControllerProvider)) {
        ref.read(terminalControllerProvider.notifier).showAgain();
      }
    }
  }

  /// Android's onTrimMemory, through Flutter (Phase 5 W5): every level from
  /// RUNNING_LOW up, and the UI's hiding when the user leaves the app, for
  /// which Android asks that large UI allocations go. The terminal's hidden
  /// sessions let go of their views; their output waits in the host, which
  /// trims its buffers itself at real pressure (RuntimeHubs), and a view is
  /// drawn again when its tab is shown. Only when terminals exist: reading
  /// the controller would make the page.
  @override
  void didHaveMemoryPressure() {
    if (ref.exists(terminalControllerProvider)) {
      ref.read(terminalControllerProvider.notifier).releaseHiddenViews();
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
          // A remote git operation's questions (Phase 7 W3), wherever the
          // user is when one asks.
          child: GitCredentialPrompts(
            navigatorKey: router.routerDelegate.navigatorKey,
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
    );
  }
}
