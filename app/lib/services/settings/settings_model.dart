/// Persisted user settings (schema v1).
library;

import 'package:flutter/material.dart';

/// Which symbol-toolbar preset the workbench shows.
enum ToolbarPreset { standard, compact, none }

@immutable
final class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.dark,
    this.editorFontSize = 14,
    this.reducedMotion = false,
    this.toolbarPreset = ToolbarPreset.standard,
    this.welcomeSeen = false,
    this.showHiddenFiles = false,
  });

  final ThemeMode themeMode;
  final double editorFontSize;
  final bool reducedMotion;
  final ToolbarPreset toolbarPreset;
  final bool welcomeSeen;
  final bool showHiddenFiles;

  AppSettings copyWith({
    ThemeMode? themeMode,
    double? editorFontSize,
    bool? reducedMotion,
    ToolbarPreset? toolbarPreset,
    bool? welcomeSeen,
    bool? showHiddenFiles,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      editorFontSize: editorFontSize ?? this.editorFontSize,
      reducedMotion: reducedMotion ?? this.reducedMotion,
      toolbarPreset: toolbarPreset ?? this.toolbarPreset,
      welcomeSeen: welcomeSeen ?? this.welcomeSeen,
      showHiddenFiles: showHiddenFiles ?? this.showHiddenFiles,
    );
  }

  Map<String, Object?> toJson() => {
    'themeMode': themeMode.name,
    'editorFontSize': editorFontSize,
    'reducedMotion': reducedMotion,
    'toolbarPreset': toolbarPreset.name,
    'welcomeSeen': welcomeSeen,
    'showHiddenFiles': showHiddenFiles,
  };

  /// Tolerant decode: unknown/invalid values fall back to defaults instead
  /// of crashing (corrupt-prefs resilience, gate G5).
  static AppSettings fromJson(Map<String, Object?> json) {
    const defaults = AppSettings();
    final themeName = json['themeMode'];
    final themeMode = ThemeMode.values
        .where((m) => m.name == themeName)
        .firstOrNull;
    final fontSize = json['editorFontSize'];
    final presetName = json['toolbarPreset'];
    final preset = ToolbarPreset.values
        .where((p) => p.name == presetName)
        .firstOrNull;
    return AppSettings(
      themeMode: themeMode ?? defaults.themeMode,
      editorFontSize: fontSize is num
          ? fontSize.toDouble().clamp(10.0, 24.0).toDouble()
          : defaults.editorFontSize,
      reducedMotion: json['reducedMotion'] is bool
          ? json['reducedMotion']! as bool
          : defaults.reducedMotion,
      toolbarPreset: preset ?? defaults.toolbarPreset,
      welcomeSeen: json['welcomeSeen'] is bool
          ? json['welcomeSeen']! as bool
          : defaults.welcomeSeen,
      showHiddenFiles: json['showHiddenFiles'] is bool
          ? json['showHiddenFiles']! as bool
          : defaults.showHiddenFiles,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.themeMode == themeMode &&
      other.editorFontSize == editorFontSize &&
      other.reducedMotion == reducedMotion &&
      other.toolbarPreset == toolbarPreset &&
      other.welcomeSeen == welcomeSeen &&
      other.showHiddenFiles == showHiddenFiles;

  @override
  int get hashCode => Object.hash(
    themeMode,
    editorFontSize,
    reducedMotion,
    toolbarPreset,
    welcomeSeen,
    showHiddenFiles,
  );
}
