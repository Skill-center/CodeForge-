/// Shell-state controller: layout memory with debounced write-through and
/// an explicit flush for app pause (gate G5).
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/files/workspace_location.dart';
import '../core/logging/logger.dart';
import '../services/shell/shell_state.dart';
import 'providers.dart';

final class ShellController extends Notifier<ShellState> {
  Timer? _debounce;

  @override
  ShellState build() {
    ref.keepAlive();
    ref.onDispose(() => _debounce?.cancel());
    return ref.watch(shellStateStoreProvider).load();
  }

  void _schedulePersist() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), flush);
  }

  /// Immediately persists the current state (called on pause/dispose).
  Future<void> flush() async {
    _debounce?.cancel();
    try {
      await ref.read(shellStateStoreProvider).save(state);
    } on Object catch (error) {
      appLogger.error('shell', 'persist_failed', fields: {'error': '$error'});
    }
  }

  void setLastRoute(String route) {
    if (!ShellState.restorableRoutes.contains(route) ||
        route == state.lastRoute) {
      return;
    }
    state = state.copyWith(lastRoute: route);
    _schedulePersist();
  }

  void setActivity(ShellActivity activity) {
    if (activity == state.activity) {
      return;
    }
    state = state.copyWith(activity: activity);
    _schedulePersist();
  }

  void setTerminalStop(TerminalStop stop) {
    if (stop == state.terminalStop) {
      return;
    }
    state = state.copyWith(terminalStop: stop);
    _schedulePersist();
  }

  void setSidebarWidth(double width) {
    final clamped = width.clamp(200.0, 420.0).toDouble();
    if (clamped == state.sidebarWidth) {
      return;
    }
    state = state.copyWith(sidebarWidth: clamped);
    _schedulePersist();
  }

  void setTerminalHeight(double height) {
    final clamped = height.clamp(120.0, 480.0).toDouble();
    if (clamped == state.terminalHeight) {
      return;
    }
    state = state.copyWith(terminalHeight: clamped);
    _schedulePersist();
  }

  /// Remembers the open tabs and the active one, to reopen after a restart.
  void setOpenTabs(List<String> tabs, String? active) {
    if (active == state.activeTab && listEquals(tabs, state.openTabs)) {
      return;
    }
    state = state.copyWith(
      openTabs: List.unmodifiable(tabs),
      activeTab: active,
      clearActiveTab: active == null,
    );
    _schedulePersist();
  }

  /// Remembers the open workspace: [folder], or the built-in project when
  /// null. Stored at once, not after the usual delay: a process death right
  /// after a switch must reopen the new workspace.
  Future<void> setFolder(FolderLocation? folder) async {
    if (folder == state.folder) {
      return;
    }
    state = state.copyWith(folder: folder, clearFolder: folder == null);
    await flush();
  }

  void markDemoWorkspaceOpened() {
    if (state.demoWorkspaceOpened) {
      return;
    }
    state = state.copyWith(demoWorkspaceOpened: true);
    _schedulePersist();
  }
}

final shellControllerProvider = NotifierProvider<ShellController, ShellState>(
  ShellController.new,
);
