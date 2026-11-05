/// Settings persistence over shared_preferences, behind a versioned envelope.
///
/// Corrupt or future-version payloads degrade to defaults with a warning —
/// they never crash the app (gate G5).
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/logging/logger.dart';
import 'settings_model.dart';

const String settingsStorageKey = 'codeforge.settings.v1';
const int settingsSchemaVersion = 1;

abstract interface class SettingsStore {
  AppSettings load();
  Future<void> save(AppSettings settings);
}

/// Encodes settings into the versioned envelope.
String encodeSettings(AppSettings settings) {
  return jsonEncode({
    'schemaVersion': settingsSchemaVersion,
    'data': settings.toJson(),
  });
}

/// Decodes an envelope; returns defaults on any malformed input.
AppSettings decodeSettings(String? raw) {
  if (raw == null || raw.isEmpty) {
    return const AppSettings();
  }
  try {
    final parsed = jsonDecode(raw);
    if (parsed is! Map<String, Object?>) {
      throw const FormatException('settings envelope is not an object');
    }
    final version = parsed['schemaVersion'];
    if (version is! int || version > settingsSchemaVersion) {
      appLogger.warn('settings', 'envelope_version_unsupported', fields: {
        'version': version,
      });
      return const AppSettings();
    }
    final data = parsed['data'];
    if (data is! Map<String, Object?>) {
      throw const FormatException('settings data is not an object');
    }
    return AppSettings.fromJson(data);
  } on FormatException catch (error) {
    appLogger.warn('settings', 'envelope_corrupt', fields: {
      'error': error.message,
    });
    return const AppSettings();
  }
}

final class PrefsSettingsStore implements SettingsStore {
  PrefsSettingsStore(this._prefs);

  final SharedPreferences _prefs;

  @override
  AppSettings load() => decodeSettings(_prefs.getString(settingsStorageKey));

  @override
  Future<void> save(AppSettings settings) async {
    await _prefs.setString(settingsStorageKey, encodeSettings(settings));
  }
}

/// In-memory store for tests and previews.
final class InMemorySettingsStore implements SettingsStore {
  InMemorySettingsStore([AppSettings? initial])
    : _settings = initial ?? const AppSettings();

  AppSettings _settings;

  @override
  AppSettings load() => _settings;

  @override
  Future<void> save(AppSettings settings) async {
    _settings = settings;
  }
}
