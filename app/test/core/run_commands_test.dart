/// What Run runs (Phase 5 W4): a file's program by its language, and what a
/// project offers, its package.json's scripts and then its entry file.
library;

import 'package:codeforge/core/run/run_commands.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('each language Run runs has its program', () {
    final cases = {
      'main.js': 'node',
      'tool.mjs': 'node',
      'legacy.cjs': 'node',
      'src/app.py': 'python',
      'build.sh': 'bash',
      'scripts/setup.bash': 'bash',
      'tool.rb': 'ruby',
      'report.pl': 'perl',
    };
    for (final MapEntry(key: path, value: program) in cases.entries) {
      final run = runCommandForFile(path);
      expect(run?.program, program, reason: path);
      expect(run!.arguments, [path], reason: path);
      expect(run.title, path.split('/').last);
    }
  });

  test('a script without an extension counts by its #! line', () {
    expect(
      runCommandForFile('bin/serve', firstLine: '#!/usr/bin/env node'),
      const RunCommand(
        program: 'node',
        arguments: ['bin/serve'],
        title: 'serve',
      ),
    );
    expect(
      runCommandForFile('bin/tool', firstLine: '#!/usr/bin/env perl -w'),
      const RunCommand(program: 'perl', arguments: ['bin/tool'], title: 'tool'),
    );
    expect(runCommandForFile('bin/tool'), isNull);
  });

  test('what Run cannot run gives nothing', () {
    for (final path in [
      'README.md',
      'notes.txt',
      'index.html',
      'main.ts',
      'src/greeting.dart',
      'package.json',
    ]) {
      expect(runCommandForFile(path), isNull, reason: path);
    }
  });

  test('a command line quotes what a shell would need quoted', () {
    expect(
      const RunCommand(
        program: 'node',
        arguments: ['src/main.js'],
        title: 'main.js',
      ).commandLine,
      'node src/main.js',
    );
    expect(
      const RunCommand(
        program: 'python',
        arguments: ["my app's/run me.py"],
        title: 'run me.py',
      ).commandLine,
      r"python 'my app'\''s/run me.py'",
    );
  });

  group('a project', () {
    test("offers its package.json's scripts in order, then its main", () {
      const manifest = '''
{
  "name": "demo",
  "main": "./src/server.js",
  "scripts": {"test": "node test.js", "start": "node src/server.js",
              "build:all": "sh build.sh"}
}
''';
      final runs = projectRunsFrom(
        packageJson: manifest,
        rootFiles: ['package.json', 'main.js'],
      );
      expect([for (final run in runs) run.title], [
        'npm run test',
        'npm run start',
        'npm run build:all',
        'server.js',
      ]);
      expect(runs.first.program, 'npm');
      expect(runs.first.arguments, ['run', 'test']);
      expect(runs.last.arguments, ['src/server.js']);
    });

    test('without a main it runs, offers its entry file', () {
      final runs = projectRunsFrom(
        packageJson: '{"main": "lib/index.ts", "scripts": {}}',
        rootFiles: ['README.md', 'app.py', 'index.js'],
      );
      expect(runs, [
        const RunCommand(
          program: 'node',
          arguments: ['index.js'],
          title: 'index.js',
        ),
      ]);
      // In projectEntryFiles' order: JavaScript before Python.
      expect(
        projectRunsFrom(rootFiles: ['app.py', 'main.sh']).single.program,
        'python',
      );
      expect(
        projectRunsFrom(rootFiles: ['run.sh', 'notes.txt']).single.title,
        'run.sh',
      );
    });

    test('offers nothing it cannot run, and survives a broken manifest', () {
      expect(projectRunsFrom(rootFiles: ['README.md']), isEmpty);
      expect(
        projectRunsFrom(packageJson: '{not json', rootFiles: ['main.js']),
        [
          const RunCommand(
            program: 'node',
            arguments: ['main.js'],
            title: 'main.js',
          ),
        ],
      );
      expect(projectRunsFrom(packageJson: '[1, 2]', rootFiles: []), isEmpty);
      // Scripts that are not commands, and a main outside the project.
      final runs = projectRunsFrom(
        packageJson:
            '{"scripts": {"a": 1, "": "x", "b": "echo b"}, '
            '"main": "../escape.js"}',
        rootFiles: [],
      );
      expect([for (final run in runs) run.title], ['npm run b']);
      expect(
        projectRunsFrom(
          packageJson: '{"main": "/etc/passwd.js"}',
          rootFiles: [],
        ),
        isEmpty,
      );
    });

    test('offers at most maxProjectScripts scripts', () {
      final scripts = [
        for (var i = 0; i < maxProjectScripts + 10; i++) '"s$i": "echo $i"',
      ].join(', ');
      final runs = projectRunsFrom(
        packageJson: '{"scripts": {$scripts}}',
        rootFiles: [],
      );
      expect(runs, hasLength(maxProjectScripts));
      expect(runs.last.title, 'npm run s${maxProjectScripts - 1}');
    });
  });
}
