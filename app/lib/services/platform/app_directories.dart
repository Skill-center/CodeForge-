/// Where the app keeps its files on the device.
///
/// One method on a platform channel (MainActivity.kt) instead of the
/// path_provider plugin, whose Android implementation now brings a JNI and
/// NDK build into every APK (docs/TECH_STACK.md).
library;

import 'package:flutter/services.dart';

const MethodChannel _pathsChannel = MethodChannel('dev.codeforge/paths');

/// The app's private files folder (Android `Context.getFilesDir()`).
/// Throws when the platform does not answer, as under `flutter test`.
Future<String> applicationFilesPath() async {
  final path = await _pathsChannel.invokeMethod<String>('filesDir');
  if (path == null || path.isEmpty) {
    throw StateError('The platform reported no files folder.');
  }
  return path;
}

/// The folder Android never backs up (`Context.getNoBackupFilesDir()`),
/// whatever the backup switch and the rules files say: the logs live here
/// (Phase 3 W1, ADR-0012). Throws when the platform does not answer.
Future<String> noBackupFilesPath() async {
  final path = await _pathsChannel.invokeMethod<String>('noBackupFilesDir');
  if (path == null || path.isEmpty) {
    throw StateError('The platform reported no no-backup folder.');
  }
  return path;
}

/// The Phase 2 workspace folder: `<files>/workspaces/demo`.
Future<String> demoWorkspacePath() async =>
    '${await applicationFilesPath()}/workspaces/demo';
