/// Dependency license gate (docs/SECURITY.md §7, ADR-0011).
///
/// Scans the resolved pub cache for every package in pubspec.lock and fails
/// on strong-copyleft licenses (GPL/AGPL/SSPL) that would conflict with a
/// future proprietary release. Permissive + weak-copyleft (MIT, BSD, Apache,
/// ISC, MPL, OFL) pass. Unknown licenses are listed for human review and
/// fail the gate until allowlisted here with a justification.
///
/// Run after `flutter pub get`: dart run tool/check_licenses.dart
library;

import 'dart:io';

/// Packages whose license text our scanner cannot classify but a human has
/// reviewed. Keep justifications current.
const Map<String, String> _allowlist = {
  // name: justification
};

const List<String> _blockedMarkers = [
  'GNU GENERAL PUBLIC LICENSE',
  'GNU AFFERO GENERAL PUBLIC LICENSE',
  'Server Side Public License',
];

const List<String> _knownMarkers = [
  'MIT License',
  'Permission is hereby granted, free of charge', // MIT text
  'Redistribution and use in source and binary forms', // BSD text
  'Apache License',
  'ISC License',
  'Permission to use, copy, modify, and/or distribute', // ISC text
  'Mozilla Public License',
  'SIL OPEN FONT LICENSE',
  'The Unlicense',
  'CC0',
];

void main() {
  final lock = File('pubspec.lock');
  if (!lock.existsSync()) {
    stderr.writeln('pubspec.lock missing — run flutter pub get first');
    exitCode = 1;
    return;
  }
  final packageConfig = File('.dart_tool/package_config.json');
  if (!packageConfig.existsSync()) {
    stderr.writeln('.dart_tool/package_config.json missing — run pub get');
    exitCode = 1;
    return;
  }

  final configText = packageConfig.readAsStringSync();
  final namePattern = RegExp(
    r'"name"\s*:\s*"([^"]+)"\s*,\s*"rootUri"\s*:\s*"([^"]+)"',
  );
  final failures = <String>[];
  final reviewed = <String>[];
  var checked = 0;

  for (final match in namePattern.allMatches(configText)) {
    final name = match.group(1)!;
    final rootUri = match.group(2)!;
    if (rootUri.startsWith('file:///')) {
      final rootPath = Uri.parse(rootUri).toFilePath();
      // SDK packages (flutter, sky_engine, integration_test…) ship with
      // Flutter under its own BSD license — covered by the Flutter audit.
      if (rootPath.contains('/flutter/packages/') ||
          rootPath.contains('/flutter/bin/cache/')) {
        continue;
      }
      final dir = Directory(rootPath);
      if (!dir.existsSync()) {
        continue;
      }
      checked++;
      final licenseFile = _findLicense(dir);
      if (licenseFile == null) {
        if (_allowlist.containsKey(name)) {
          reviewed.add('$name (allowlisted: ${_allowlist[name]})');
        } else {
          failures.add('$name: no LICENSE file found');
        }
        continue;
      }
      final text = licenseFile.readAsStringSync();
      final blocked = _blockedMarkers.where(text.contains).toList();
      if (blocked.isNotEmpty) {
        failures.add('$name: blocked license marker(s): ${blocked.join(', ')}');
        continue;
      }
      final known = _knownMarkers.any(text.contains);
      if (!known) {
        if (_allowlist.containsKey(name)) {
          reviewed.add('$name (allowlisted: ${_allowlist[name]})');
        } else {
          failures.add('$name: unclassified license — review ${licenseFile.path}');
        }
      }
    }
  }

  stdout.writeln('license gate: $checked hosted packages checked');
  for (final r in reviewed) {
    stdout.writeln('  reviewed: $r');
  }
  if (failures.isEmpty) {
    stdout.writeln('license gate: OK');
    return;
  }
  for (final f in failures) {
    stderr.writeln('  FAIL $f');
  }
  exitCode = 1;
}

File? _findLicense(Directory dir) {
  for (final name in ['LICENSE', 'LICENSE.md', 'LICENSE.txt', 'COPYING']) {
    final file = File('${dir.path}/$name');
    if (file.existsSync()) {
      return file;
    }
  }
  return null;
}
