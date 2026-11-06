/// Shell-state envelope: the last workbench layout, restored before the
/// first frame (gate G5). Versioned exactly like settings.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/files/workspace_path.dart';
import '../../core/logging/logger.dart';

const String shellStateStorageKey = 'codeforge.shell.v1';
const int shellStateSchemaVersion = 1;

/// Terminal panel stop on compact layouts.
enum TerminalStop { closed, peek, half, full }

/// The most tabs a restart reopens.
const int maxRestoredTabs = 50;

/// Which activity's panel is showing in the sidebar.
enum ShellActivity { explorer, search, git, extensions, run }

@immutable
final class ShellState {
  const ShellState({
    this.lastRoute = '/',
    this.activity = ShellActivity.explorer,
    this.terminalStop = TerminalStop.closed,
    this.sidebarWidth = 264,
    this.terminalHeight = 220,
    this.demoWorkspaceOpened = false,
    this.openTabs = const [],
    this.activeTab,
  });

  final String lastRoute;
  final ShellActivity activity;
  final TerminalStop terminalStop;
  final double sidebarWidth;
  final double terminalHeight;
  final bool demoWorkspaceOpened;

  /// Workspace paths of the open tabs, in tab order, reopened after a
  /// restart (Phase 2 W4; W5 moves them into the database with cursor and
  /// scroll).
  final List<String> openTabs;

  /// The active tab among [openTabs].
  final String? activeTab;

  /// Only these routes may be restored on cold start.
  static const Set<String> restorableRoutes = {'/', '/workspace', '/settings'};

  ShellState copyWith({
    String? lastRoute,
    ShellActivity? activity,
    TerminalStop? terminalStop,
    double? sidebarWidth,
    double? terminalHeight,
    bool? demoWorkspaceOpened,
    List<String>? openTabs,
    String? activeTab,
    bool clearActiveTab = false,
  }) {
    return ShellState(
      lastRoute: lastRoute ?? this.lastRoute,
      activity: activity ?? this.activity,
      terminalStop: terminalStop ?? this.terminalStop,
      sidebarWidth: sidebarWidth ?? this.sidebarWidth,
      terminalHeight: terminalHeight ?? this.terminalHeight,
      demoWorkspaceOpened: demoWorkspaceOpened ?? this.demoWorkspaceOpened,
      openTabs: openTabs ?? this.openTabs,
      activeTab: clearActiveTab ? null : activeTab ?? this.activeTab,
    );
  }

  Map<String, Object?> toJson() => {
    'lastRoute': lastRoute,
    'activity': activity.name,
    'terminalStop': terminalStop.name,
    'sidebarWidth': sidebarWidth,
    'terminalHeight': terminalHeight,
    'demoWorkspaceOpened': demoWorkspaceOpened,
    'openTabs': openTabs,
    'activeTab': activeTab,
  };

  static ShellState fromJson(Map<String, Object?> json) {
    const defaults = ShellState();
    final route = json['lastRoute'];
    final activityName = json['activity'];
    final activity = ShellActivity.values
        .where((a) => a.name == activityName)
        .firstOrNull;
    final stopName = json['terminalStop'];
    final stop = TerminalStop.values
        .where((s) => s.name == stopName)
        .firstOrNull;
    final sidebarWidth = json['sidebarWidth'];
    final terminalHeight = json['terminalHeight'];
    final tabs = json['openTabs'];
    // Only valid workspace paths, each once, in their order.
    final openTabs = tabs is List<Object?>
        ? <String>{
            for (final tab in tabs.take(maxRestoredTabs))
              if (tab is String && isWorkspacePath(tab)) tab,
          }.toList()
        : defaults.openTabs;
    final activeTab = json['activeTab'];
    return ShellState(
      lastRoute: route is String && restorableRoutes.contains(route)
          ? route
          : defaults.lastRoute,
      activity: activity ?? defaults.activity,
      terminalStop: stop ?? defaults.terminalStop,
      sidebarWidth: sidebarWidth is num
          ? sidebarWidth.toDouble().clamp(200.0, 420.0).toDouble()
          : defaults.sidebarWidth,
      terminalHeight: terminalHeight is num
          ? terminalHeight.toDouble().clamp(120.0, 480.0).toDouble()
          : defaults.terminalHeight,
      demoWorkspaceOpened: json['demoWorkspaceOpened'] is bool
          ? json['demoWorkspaceOpened']! as bool
          : defaults.demoWorkspaceOpened,
      openTabs: openTabs,
      activeTab: activeTab is String && openTabs.contains(activeTab)
          ? activeTab
          : null,
    );
  }
}

String encodeShellState(ShellState state) {
  return jsonEncode({
    'schemaVersion': shellStateSchemaVersion,
    'data': state.toJson(),
  });
}

ShellState decodeShellState(String? raw) {
  if (raw == null || raw.isEmpty) {
    return const ShellState();
  }
  try {
    final parsed = jsonDecode(raw);
    if (parsed is! Map<String, Object?>) {
      throw const FormatException('shell envelope is not an object');
    }
    final version = parsed['schemaVersion'];
    if (version is! int || version > shellStateSchemaVersion) {
      appLogger.warn(
        'shell',
        'envelope_version_unsupported',
        fields: {'version': version},
      );
      return const ShellState();
    }
    final data = parsed['data'];
    if (data is! Map<String, Object?>) {
      throw const FormatException('shell data is not an object');
    }
    return ShellState.fromJson(data);
  } on FormatException catch (error) {
    appLogger.warn(
      'shell',
      'envelope_corrupt',
      fields: {'error': error.message},
    );
    return const ShellState();
  }
}

abstract interface class ShellStateStore {
  ShellState load();
  Future<void> save(ShellState state);
}

final class PrefsShellStateStore implements ShellStateStore {
  PrefsShellStateStore(this._prefs);

  final SharedPreferences _prefs;

  @override
  ShellState load() => decodeShellState(_prefs.getString(shellStateStorageKey));

  @override
  Future<void> save(ShellState state) async {
    await _prefs.setString(shellStateStorageKey, encodeShellState(state));
  }
}

final class InMemoryShellStateStore implements ShellStateStore {
  InMemoryShellStateStore([ShellState? initial])
    : _state = initial ?? const ShellState();

  ShellState _state;

  @override
  ShellState load() => _state;

  @override
  Future<void> save(ShellState state) async {
    _state = state;
  }
}
