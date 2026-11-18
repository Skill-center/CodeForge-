/// Dependency license gate (docs/SECURITY.md §7, ADR-0011).
///
/// Scans the resolved pub cache for every package in pubspec.lock and fails
/// on strong-copyleft licenses (GPL/AGPL/SSPL): pub packages are linked into
/// the app, which is Apache-2.0 with no GPL code in it (ADR-0011, Accepted
/// 2026-11-12). Permissive + weak-copyleft (MIT, BSD, Apache,
/// ISC, MPL, OFL) pass. Unknown licenses are listed for human review and
/// fail the gate until allowlisted here with a justification.
///
/// Since Phase 4 W7 it also keeps THIRD_PARTY_NOTICES.md's section 2
/// current: the app's dependency closure (the regular dependencies and all
/// they need, from `flutter pub deps --json`), each with its version and the
/// licence its own licence file names. The compiler keeps only the code the
/// app reaches, so the binary holds a subset of the list. With
/// `--write-notices` it writes the section (in CI's bootstrap runs);
/// otherwise a stale section fails.
///
/// Run after `flutter pub get`: dart run tool/check_licenses.dart
library;

import 'dart:convert';
import 'dart:io';

/// THIRD_PARTY_NOTICES.md, from app/.
const String _noticesPath = '../THIRD_PARTY_NOTICES.md';
const String _dartBegin = '<!-- dart:begin -->';
const String _dartEnd = '<!-- dart:end -->';

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

void main(List<String> args) {
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
  final licenceTexts = <String, String>{};
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
      licenceTexts[name] = text;
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
          failures.add(
            '$name: unclassified license — review ${licenseFile.path}',
          );
        }
      }
    }
  }

  final notices = _notices(
    licenceTexts,
    write: args.contains('--write-notices'),
  );
  if (notices != null) {
    failures.add(notices);
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

/// Section 2 of THIRD_PARTY_NOTICES.md, written or checked; the problem, or
/// null when it is current (or was written).
String? _notices(Map<String, String> licenceTexts, {required bool write}) {
  // pub refuses --json with --dev or --no-dev: the JSON names the root's
  // regular dependencies itself (directDependencies, Dart 3.6 and later).
  final deps = Process.runSync('flutter', [
    'pub',
    'deps',
    '--json',
  ], runInShell: true);
  final output = deps.stdout as String;
  final start = output.indexOf('{');
  if (deps.exitCode != 0 || start < 0) {
    return 'notices: flutter pub deps --json failed: '
        '${(deps.stderr as String).trim()}';
  }
  final json = jsonDecode(output.substring(start)) as Map<String, Object?>;
  final packages = <String, Map<String, Object?>>{
    for (final entry
        in (json['packages']! as List<Object?>).cast<Map<String, Object?>>())
      entry['name']! as String: entry,
  };
  final roots = packages[json['root']! as String]!['directDependencies'];
  if (roots is! List<Object?>) {
    return 'notices: flutter pub deps --json names no directDependencies';
  }
  final seen = <String>{};
  final pending = [for (final name in roots) name! as String];
  while (pending.isNotEmpty) {
    final name = pending.removeLast();
    final entry = packages[name];
    if (entry == null || !seen.add(name)) {
      continue;
    }
    for (final dependency in entry['dependencies']! as List<Object?>) {
      pending.add(dependency! as String);
    }
  }
  final rows = <(String, String, String)>[];
  for (final name in seen) {
    final entry = packages[name]!;
    // SDK packages ship with Flutter, under its licence (section 4).
    if (entry['source'] == 'sdk' || entry['kind'] == 'root') {
      continue;
    }
    final text = licenceTexts[name];
    rows.add((
      name,
      entry['version']! as String,
      text == null ? 'no licence file' : _spdx(text),
    ));
  }
  rows.sort((a, b) => a.$1.compareTo(b.$1));
  final tally = <String, int>{};
  for (final (_, _, licence) in rows) {
    tally[licence] = (tally[licence] ?? 0) + 1;
  }
  final counts =
      (tally.entries.toList()..sort(
            (a, b) => b.value != a.value
                ? b.value.compareTo(a.value)
                : a.key.compareTo(b.key),
          ))
          .map((e) => '${e.key} ${e.value}')
          .join(', ');
  final section = [
    _dartBegin,
    "<!-- Written by app/tool/check_licenses.dart from the app's resolved "
        'dependencies. Do not edit by hand: CI checks it. -->',
    '',
    "**${rows.length} packages** are in the app's dependency closure: "
        '$counts. The compiler keeps only the code the app reaches, so the '
        'app holds a subset of them.',
    '',
    '| Package | Version | Licence |',
    '|---|---|---|',
    for (final (name, version, licence) in rows)
      '| $name | $version | $licence |',
    '',
    _dartEnd,
  ].join('\n');

  final file = File(_noticesPath);
  final text = file.readAsStringSync();
  final begin = text.indexOf(_dartBegin);
  final end = text.indexOf(_dartEnd);
  if (begin < 0 || end < begin) {
    return 'notices: $_noticesPath needs a $_dartBegin ... $_dartEnd section';
  }
  final updated =
      '${text.substring(0, begin)}$section'
      '${text.substring(end + _dartEnd.length)}';
  stdout.writeln(
    "notices: ${rows.length} packages in the app's dependency closure",
  );
  if (updated == text) {
    return null;
  }
  if (write) {
    file.writeAsStringSync(updated);
    stdout.writeln('notices: wrote section 2 of $_noticesPath');
    return null;
  }
  return 'notices: section 2 of $_noticesPath is stale: a [bootstrap] commit '
      'rewrites it';
}

/// The licence a licence file names, as SPDX, from its wording.
String _spdx(String text) {
  bool has(String phrase) => text.contains(phrase);
  if (has('Apache License') &&
      (has('Version 2.0') || has('version 2.0') || has('VERSION 2.0'))) {
    return 'Apache-2.0';
  }
  if (has('Mozilla Public License')) {
    return 'MPL-2.0';
  }
  if (has('SIL OPEN FONT LICENSE')) {
    return 'OFL-1.1';
  }
  if (has('This is free and unencumbered software')) {
    return 'Unlicense';
  }
  if (has('Redistribution and use in source and binary forms')) {
    return has('Neither the name') || has('neither the name')
        ? 'BSD-3-Clause'
        : 'BSD-2-Clause';
  }
  if (has('Permission is hereby granted, free of charge')) {
    return 'MIT';
  }
  if (has('Permission to use, copy, modify, and/or distribute')) {
    return 'ISC';
  }
  if (has('CC0')) {
    return 'CC0-1.0';
  }
  return 'see its licence file';
}
