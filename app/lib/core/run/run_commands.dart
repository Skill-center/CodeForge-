/// What Run runs (Phase 5 W4; docs/TERMINAL_ARCHITECTURE.md §3): the
/// runtime's program for a file, by its language in the capability model
/// (`core/editor/capabilities.dart`), and what a project offers: each script
/// of its `package.json`, run with npm, then its entry file. Paths are the
/// workspace's own, relative; the host resolves the project's folder.
library;

import 'dart:convert';

import '../editor/capabilities.dart';

/// One run: a program in the runtime's bin, its arguments, and its title.
final class RunCommand {
  const RunCommand({
    required this.program,
    this.arguments = const [],
    required this.title,
  });

  /// A name in the runtime's bin: `node`, `python`, `bash`, `npm`.
  final String program;

  /// The file, relative to the project's folder, or npm's `run <script>`.
  final List<String> arguments;

  /// What the run's tab and the Run panel call it: `main.js`,
  /// `npm run test`.
  final String title;

  /// The command as a shell would show it.
  String get commandLine => [program, ...arguments.map(_quoted)].join(' ');

  static String _quoted(String argument) =>
      RegExp(r'^[A-Za-z0-9_./:=@%+-]+$').hasMatch(argument)
      ? argument
      : "'${argument.replaceAll("'", r"'\''")}'";

  @override
  bool operator ==(Object other) =>
      other is RunCommand &&
      other.program == program &&
      other.title == title &&
      _sameList(other.arguments, arguments);

  @override
  int get hashCode => Object.hash(program, title, Object.hashAll(arguments));

  @override
  String toString() => 'RunCommand($commandLine)';
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

/// How Run runs [path] (a workspace path) by itself, or null when its
/// language is not one the runtime executes: `node main.js`,
/// `python app.py`, `bash build.sh`, `ruby tool.rb`, `perl report.pl`. A
/// script without an extension counts by its `#!` line ([firstLine]).
RunCommand? runCommandForFile(String path, {String? firstLine}) {
  final language = capabilityLanguageFor(path, firstLine: firstLine);
  final program = runtimeInterpreters[language];
  if (program == null) {
    return null;
  }
  return RunCommand(
    program: program,
    arguments: [path],
    title: path.split('/').last,
  );
}

/// Files a project's entry is looked for in, in its root, in this order,
/// when its `package.json` names no `main` that Run can run.
const List<String> projectEntryFiles = [
  'main.js',
  'index.js',
  'app.js',
  'server.js',
  'main.mjs',
  'index.mjs',
  'main.py',
  'app.py',
  '__main__.py',
  'main.sh',
  'run.sh',
  'main.rb',
  'main.pl',
];

/// The most `package.json` scripts offered.
const int maxProjectScripts = 50;

/// What a project offers to Run Project: each script of its `package.json`
/// ([packageJson], its text, if it has one) as `npm run <script>`, in the
/// file's order, then its entry file: `package.json`'s `main` if Run can
/// run it, else the first of [projectEntryFiles] among [rootFiles] (the
/// names in the project's root). A `package.json` that is not a JSON object
/// offers no script.
List<RunCommand> projectRunsFrom({
  String? packageJson,
  required Iterable<String> rootFiles,
}) {
  final runs = <RunCommand>[];
  String? main;
  if (packageJson != null) {
    final manifest = _decodeObject(packageJson);
    final scripts = manifest?['scripts'];
    if (scripts is Map<Object?, Object?>) {
      for (final entry in scripts.entries) {
        final name = entry.key;
        if (name is! String || entry.value is! String || name.isEmpty) {
          continue;
        }
        if (runs.length >= maxProjectScripts) {
          break;
        }
        runs.add(
          RunCommand(
            program: 'npm',
            arguments: ['run', name],
            title: 'npm run $name',
          ),
        );
      }
    }
    final declared = manifest?['main'];
    if (declared is String) {
      main = _normalized(declared);
    }
  }
  final declaredRun = main == null ? null : runCommandForFile(main);
  if (declaredRun != null) {
    runs.add(declaredRun);
    return runs;
  }
  final present = {for (final name in rootFiles) name};
  for (final name in projectEntryFiles) {
    if (present.contains(name)) {
      final entry = runCommandForFile(name);
      if (entry != null) {
        runs.add(entry);
      }
      break;
    }
  }
  return runs;
}

Map<Object?, Object?>? _decodeObject(String text) {
  try {
    final Object? decoded = jsonDecode(text);
    return decoded is Map<Object?, Object?> ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// `./src/app.js` as `src/app.js`; null for a path leaving the project.
String? _normalized(String path) {
  var trimmed = path.trim();
  while (trimmed.startsWith('./')) {
    trimmed = trimmed.substring(2);
  }
  if (trimmed.isEmpty ||
      trimmed.startsWith('/') ||
      trimmed.split('/').any((segment) => segment == '..' || segment.isEmpty)) {
    return null;
  }
  return trimmed;
}
