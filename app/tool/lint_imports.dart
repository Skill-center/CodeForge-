/// Architecture import-boundary lint (docs/ARCHITECTURE.md §2.1).
///
/// Rules (relative-import aware):
///  * design_system/ must not import features/, services/, application/.
///  * services/ must not import features/, application/, design_system/.
///  * core/ must not import flutter (pure Dart) — except core/version.dart
///    is also pure; platform helpers live in core/platform and may use
///    foundation only. features may import anything above them.
///  * features/X must not import features/Y except via workbench (the
///    workbench is the composition root for panels) and the shared palette.
///  * features/ never read `fileServiceProvider`: files are reached through
///    the application controllers (WorkspaceController, DocumentController).
///  * No package: imports of our own package (prefer_relative_imports).
///
/// Run: dart run tool/lint_imports.dart   (exit 1 on violation)
library;

import 'dart:io';

const String _selfPackage = 'package:codeforge/';

void main() {
  final lib = Directory('lib');
  if (!lib.existsSync()) {
    stderr.writeln('lib/ not found — run from app/');
    exitCode = 1;
    return;
  }
  final violations = <String>[];
  final importPattern = RegExp(r'''import\s+['"]([^'"]+)['"]''');

  for (final entity in lib.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) {
      continue;
    }
    final path = entity.path.replaceAll('\\', '/');
    final rel = path.substring('lib/'.length);
    final source = entity.readAsStringSync();
    if (rel.startsWith('features/') && source.contains('fileServiceProvider')) {
      violations.add(
        '$rel: reach files through WorkspaceController or '
        'DocumentController, not fileServiceProvider',
      );
    }

    for (final match in importPattern.allMatches(source)) {
      final target = match.group(1)!;
      if (target.startsWith(_selfPackage)) {
        violations.add('$rel: use relative imports, not $target');
        continue;
      }
      final resolved = _resolve(rel, target);
      if (resolved == null) {
        continue; // dart: or external package
      }

      if (rel.startsWith('design_system/') &&
          (_startsWithAny(resolved, [
            'features/',
            'services/',
            'application/',
          ]))) {
        violations.add(
          '$rel: design_system must stay dependency-free → $target',
        );
      }
      if (rel.startsWith('services/') &&
          _startsWithAny(resolved, [
            'features/',
            'application/',
            'design_system/',
          ])) {
        violations.add('$rel: services must not depend upward → $target');
      }
      if (rel.startsWith('core/')) {
        if (target.startsWith('package:flutter/') &&
            !target.startsWith('package:flutter/foundation') &&
            !target.startsWith('package:flutter/animation') &&
            !rel.startsWith('core/platform/')) {
          violations.add(
            '$rel: core stays pure Dart (foundation/animation ok) → $target',
          );
        }
        if (_startsWithAny(resolved, [
          'features/',
          'services/',
          'application/',
          'design_system/',
        ])) {
          violations.add('$rel: core must not depend on app layers → $target');
        }
      }
      if (rel.startsWith('features/')) {
        final feature = rel.split('/')[1];
        if (resolved.startsWith('features/')) {
          final other = resolved.split('/')[1];
          final allowed =
              other == feature ||
              feature == 'workbench' ||
              other == 'palette' ||
              (feature == 'settings' && other == 'settings');
          if (!allowed) {
            violations.add('$rel: cross-feature import $feature → $other');
          }
        }
      }
    }
  }

  // Version constant must match pubspec (no package_info dependency yet).
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final versionMatch = RegExp(
    r'^version:\s*([0-9.]+)',
    multiLine: true,
  ).firstMatch(pubspec);
  final versionFile = File('lib/core/version.dart').readAsStringSync();
  final constMatch = RegExp("appVersion = '([^']+)'").firstMatch(versionFile);
  if (versionMatch == null ||
      constMatch == null ||
      versionMatch.group(1) != constMatch.group(1)) {
    violations.add(
      'core/version.dart appVersion (${constMatch?.group(1)}) != '
      'pubspec version (${versionMatch?.group(1)})',
    );
  }

  if (violations.isEmpty) {
    stdout.writeln('import lint: OK');
    return;
  }
  for (final v in violations) {
    stderr.writeln(v);
  }
  stderr.writeln('${violations.length} violation(s)');
  exitCode = 1;
}

bool _startsWithAny(String value, List<String> prefixes) =>
    prefixes.any(value.startsWith);

/// Resolves a relative import against the importing file, returning a
/// lib/-relative path, or null for dart:/package: targets.
String? _resolve(String fromRel, String target) {
  if (target.startsWith('dart:') || target.startsWith('package:')) {
    return null;
  }
  final fromDir = fromRel.contains('/')
      ? fromRel.substring(0, fromRel.lastIndexOf('/'))
      : '';
  final parts = <String>[...fromDir.split('/')..removeWhere((p) => p.isEmpty)];
  for (final segment in target.split('/')) {
    if (segment == '..') {
      if (parts.isNotEmpty) {
        parts.removeLast();
      }
    } else if (segment != '.' && segment.isNotEmpty) {
      parts.add(segment);
    }
  }
  return parts.join('/');
}
