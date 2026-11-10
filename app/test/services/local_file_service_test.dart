/// LocalFileService on a real folder (Phase 2 W4, gate G2): atomic saves,
/// byte-for-byte BOM and CRLF, refusals, and paths that try to leave the
/// workspace by name or through a symbolic link. Plain tests: real file
/// I/O in real time (it never completes inside testWidgets).
library;

import 'dart:convert';
import 'dart:io';

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/text_codec.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:codeforge/services/files/demo_workspace.dart';
import 'package:codeforge/services/files/file_mode.dart';
import 'package:codeforge/services/files/local_file_service.dart';
import 'package:flutter_test/flutter_test.dart';

late Directory _temp;

String get _root => '${_temp.path}/workspace';

/// A service over `<temp>/workspace`, seeded with [seed] on first use.
LocalFileService _service({
  BeforeCommit? beforeCommit,
  Map<String, String> seed = const {
    'main.js': 'console.log(1);\n',
    'src/app.py': 'print(1)\n',
  },
}) => LocalFileService(
  rootPath: () async => _root,
  seed: seed,
  beforeCommit: beforeCommit,
);

/// An opened service.
Future<LocalFileService> _opened({BeforeCommit? beforeCommit}) async {
  final files = _service(beforeCommit: beforeCommit);
  expect((await files.openWorkspace()).isOk, isTrue);
  return files;
}

File _file(String path) => File('$_root/$path');

Matcher _fails(FileProblem problem) =>
    isA<FileFailure>().having((f) => f.problem, 'problem', problem);

void main() {
  setUp(() async {
    _temp = await Directory.systemTemp.createTemp('codeforge_files_');
  });

  tearDown(() async {
    await _temp.delete(recursive: true);
  });

  group('workspace', () {
    test('the first open writes the demo project as real files', () async {
      final files = LocalFileService(rootPath: () async => _root);
      expect((await files.openWorkspace()).isOk, isTrue);
      for (final MapEntry(:key, :value) in DemoWorkspace.files.entries) {
        expect(_file(key).readAsStringSync(), value, reason: key);
      }
      expect(Directory('$_root.seeding').existsSync(), isFalse);
    });

    test('an existing workspace is never seeded again', () async {
      Directory(_root).createSync(recursive: true);
      _file('mine.txt').writeAsStringSync('mine');
      await _opened();
      expect(_file('main.js').existsSync(), isFalse);
      expect(_file('mine.txt').readAsStringSync(), 'mine');
    });

    test('a workspace that cannot be created fails typed', () async {
      final blocker = File('${_temp.path}/blocker')..writeAsStringSync('');
      final files = LocalFileService(rootPath: () async => '${blocker.path}/w');
      expect(
        (await files.openWorkspace()).failureOrNull,
        _fails(FileProblem.io),
      );
      final noChannel = LocalFileService(
        rootPath: () async => throw StateError('no platform channel'),
      );
      expect(
        (await noChannel.openWorkspace()).failureOrNull,
        _fails(FileProblem.io),
      );
    });

    test('lists folders first, by name, and hides save temp files', () async {
      final files = _service(
        seed: const {'b.js': '', 'A.md': '', 'src/x.py': '', '.env': ''},
      );
      await files.openWorkspace();
      File('$_root/.b.js.cf-tmp').writeAsStringSync('left by a crash');
      final entries = (await files.listDirectory('')).orThrow;
      expect(entries.map((e) => e.name), ['src', '.env', 'A.md', 'b.js']);
      expect(entries.first.isDirectory, isTrue);
      expect(entries[1].hidden, isTrue);
      final nested = (await files.listDirectory('src')).orThrow;
      expect(nested.map((e) => e.path), ['src/x.py']);
    });

    test('wrong kinds of path fail typed', () async {
      final files = await _opened();
      expect(
        (await files.readText('src')).failureOrNull,
        _fails(FileProblem.wrongType),
      );
      expect(
        (await files.writeText('src', 'x')).failureOrNull,
        _fails(FileProblem.wrongType),
      );
      expect(
        (await files.listDirectory('main.js')).failureOrNull,
        _fails(FileProblem.wrongType),
      );
      expect(
        (await files.listDirectory('nope')).failureOrNull,
        _fails(FileProblem.notFound),
      );
      expect(
        (await files.readText('nope.js')).failureOrNull,
        _fails(FileProblem.notFound),
      );
    });
  });

  group('reading', () {
    test('text comes with its format and stamp', () async {
      final files = await _opened();
      _file(
        'win.txt',
      ).writeAsBytesSync([...utf8Bom, ...utf8.encode('a\r\nb\r\n')]);
      final read = (await files.readText('win.txt')).orThrow;
      expect(read.text, 'a\nb\n');
      expect(
        read.format,
        const TextFormat(lineEnding: LineEnding.crlf, bom: true),
      );
      expect(read.stamp.size, 9);
      expect(read.mixedLineEndings, isFalse);
    });

    test('binary and malformed files are refused and left alone', () async {
      final files = await _opened();
      _file('img.png').writeAsBytesSync([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00]);
      _file('latin1.txt').writeAsBytesSync([0x63, 0x61, 0x66, 0xE9]);
      expect(
        (await files.readText('img.png')).failureOrNull,
        _fails(FileProblem.notText),
      );
      expect(
        (await files.readText('latin1.txt')).failureOrNull,
        _fails(FileProblem.notText),
      );
      expect(_file('latin1.txt').readAsBytesSync(), [0x63, 0x61, 0x66, 0xE9]);
    });

    test('a file over the size cap is refused', () async {
      final files = await _opened();
      // Sparse: no 10 MiB actually written.
      final handle = _file('big.txt').openSync(mode: FileMode.write)
        ..truncateSync(maxTextFileBytes + 1);
      handle.closeSync();
      final refused = (await files.readText('big.txt')).failureOrNull;
      expect(refused, _fails(FileProblem.tooLarge));
      // Both sizes, so the user knows how far over it is (W7).
      expect(
        refused?.message,
        'big.txt is 10.1 MB: the editor opens files up to 10 MB.',
      );
    });
  });

  group('writing', () {
    test('BOM and CRLF are written back byte for byte (G2)', () async {
      final files = await _opened();
      final original = [...utf8Bom, ...utf8.encode('one\r\ntwo\r\n')];
      _file('win.txt').writeAsBytesSync(original);
      final read = (await files.readText('win.txt')).orThrow;

      final same = await files.writeText(
        'win.txt',
        read.text,
        format: read.format,
        expected: read.stamp,
      );
      expect(same.isOk, isTrue);
      expect(_file('win.txt').readAsBytesSync(), original);

      await files.writeText(
        'win.txt',
        '${read.text}three\n',
        format: read.format,
      );
      expect(_file('win.txt').readAsBytesSync(), [
        ...utf8Bom,
        ...utf8.encode('one\r\ntwo\r\nthree\r\n'),
      ]);
    });

    test('an interrupted save leaves the old file intact (G2)', () async {
      final files = await _opened(
        beforeCommit: (path) async =>
            throw const FileSystemException('power cut'),
      );
      final before = _file('main.js').readAsBytesSync();
      final result = await files.writeText('main.js', 'half written?\n');
      expect(result.failureOrNull, _fails(FileProblem.io));
      expect(_file('main.js').readAsBytesSync(), before);
      expect(File('$_root/.main.js.cf-tmp').existsSync(), isFalse);
    });

    test('a temp file left by a crash is replaced by the next save', () async {
      final files = await _opened();
      File(
        '$_root/.main.js.cf-tmp',
      ).writeAsStringSync('garbage from a crash, longer than the new text');
      expect((await files.writeText('main.js', 'new\n')).isOk, isTrue);
      expect(_file('main.js').readAsStringSync(), 'new\n');
      expect(File('$_root/.main.js.cf-tmp').existsSync(), isFalse);
    });

    test(
      'a save keeps the permission bits: 755 stays 755, 600 stays 600',
      () async {
        final files = await _opened();
        for (final mode in ['755', '600']) {
          // The system's chmod sets them, to check ours independently.
          final set = Process.runSync('chmod', [mode, _file('main.js').path]);
          expect(set.exitCode, 0, reason: '${set.stderr}');
          expect(
            (await files.writeText('main.js', 'saved as $mode\n')).isOk,
            isTrue,
          );
          expect(_file('main.js').readAsStringSync(), 'saved as $mode\n');
          expect(
            _file('main.js').statSync().mode & fileModeBits,
            int.parse(mode, radix: 8),
            reason: 'after a save of a $mode file',
          );
        }
      },
      skip: Platform.isWindows ? 'no permission bits on Windows' : false,
    );

    test(
      'setFileMode sets exactly the bits asked for',
      () {
        final path = _file('main.js').path;
        Directory(_root).createSync(recursive: true);
        File(path).writeAsStringSync('x');
        for (final mode in [0x1A0, 0x1ED, 0x124, 0x180]) {
          expect(setFileMode(path, mode), isTrue, reason: mode.toRadixString(8));
          expect(File(path).statSync().mode & fileModeBits, mode);
        }
        // The kind of file above the permission bits is never passed on.
        expect(setFileMode(path, 0x81A4), isTrue);
        expect(File(path).statSync().mode & fileModeBits, 0x1A4);
        expect(setFileMode('$_root/missing/file', 0x1A4), isFalse);
      },
      skip: Platform.isWindows ? 'no permission bits on Windows' : false,
    );

    test('new files are exclusive, even in new folders', () async {
      final files = await _opened();
      final created = await files.writeText(
        'src/new.ts',
        '',
        mode: WriteMode.createNew,
      );
      expect(created.isOk, isTrue);
      expect(_file('src/new.ts').readAsStringSync(), '');
      final again = await files.writeText(
        'src/new.ts',
        'x',
        mode: WriteMode.createNew,
      );
      expect(again.failureOrNull, _fails(FileProblem.exists));
      expect(_file('src/new.ts').readAsStringSync(), '');
      final deep = await files.writeText(
        'lib/deep/a.js',
        'a',
        mode: WriteMode.createNew,
      );
      expect(deep.isOk, isTrue);
      expect(_file('lib/deep/a.js').readAsStringSync(), 'a');
    });

    test('a file changed since it was read is not overwritten', () async {
      final files = await _opened();
      final read = (await files.readText('main.js')).orThrow;
      _file('main.js').writeAsStringSync('changed elsewhere, and longer\n');
      final refused = await files.writeText(
        'main.js',
        'mine\n',
        expected: read.stamp,
      );
      expect(refused.failureOrNull, _fails(FileProblem.changedOnDisk));
      expect(
        _file('main.js').readAsStringSync(),
        'changed elsewhere, and longer\n',
      );
      final fresh = (await files.readText('main.js')).orThrow;
      final saved = await files.writeText(
        'main.js',
        'mine\n',
        expected: fresh.stamp,
      );
      expect(saved.isOk, isTrue);
      expect(saved.valueOrNull!.size, 5);
      expect(_file('main.js').readAsStringSync(), 'mine\n');
    });
  });

  group('staying inside the workspace', () {
    test('paths that name a way out are refused', () async {
      final files = await _opened();
      File('${_temp.path}/secret.txt').writeAsStringSync('secret');
      for (final path in [
        '../secret.txt',
        'src/../../secret.txt',
        '/etc/hostname',
        'src/./app.py',
      ]) {
        expect(
          (await files.readText(path)).failureOrNull,
          _fails(FileProblem.invalidPath),
          reason: path,
        );
        expect(
          (await files.writeText(path, 'x')).failureOrNull,
          _fails(FileProblem.invalidPath),
          reason: path,
        );
      }
    });

    test('symbolic links out of the workspace are refused', () async {
      final files = await _opened();
      final secret = File('${_temp.path}/secret.txt')
        ..writeAsStringSync('secret');
      Link('$_root/escape.txt').createSync(secret.path);
      Link('$_root/out').createSync(_temp.path);
      expect(
        (await files.readText('escape.txt')).failureOrNull,
        _fails(FileProblem.outsideWorkspace),
      );
      expect(
        (await files.writeText('escape.txt', 'pwned')).failureOrNull,
        _fails(FileProblem.outsideWorkspace),
      );
      expect(
        (await files.writeText('out/new.txt', 'pwned')).failureOrNull,
        _fails(FileProblem.outsideWorkspace),
      );
      expect(
        (await files.listDirectory('out')).failureOrNull,
        _fails(FileProblem.outsideWorkspace),
      );
      expect(secret.readAsStringSync(), 'secret');
      expect(File('${_temp.path}/new.txt').existsSync(), isFalse);
      final names = (await files.listDirectory('')).orThrow.map((e) => e.name);
      expect(names, isNot(contains('escape.txt')));
    });

    test('a link that stays inside works and stays a link', () async {
      final files = await _opened();
      Link('$_root/alias.js').createSync('$_root/main.js');
      final read = (await files.readText('alias.js')).orThrow;
      expect(read.text, 'console.log(1);\n');
      expect((await files.writeText('alias.js', 'via alias\n')).isOk, isTrue);
      expect(_file('main.js').readAsStringSync(), 'via alias\n');
      expect(FileSystemEntity.isLinkSync('$_root/alias.js'), isTrue);
    });
  });
}
