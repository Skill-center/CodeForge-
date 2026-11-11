/// SafFileService (Phase 3 W2, gate G1; docs/SECURITY.md §4.1) over a fake
/// storage broker: the folder's statuses, the strict codec, stamps with
/// and without modification times, in-place saves and what their failures
/// say, and paths refused before the broker is asked. The Pigeon client's
/// error mapping runs against a mocked channel.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/file_stamp.dart';
import 'package:codeforge/core/files/text_codec.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:codeforge/services/files/native/pigeon_storage_broker.dart';
import 'package:codeforge/services/files/native/storage_api.g.dart';
import 'package:codeforge/services/files/saf_file_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_storage_broker.dart';

const _uri =
    'content://com.android.externalstorage.documents/tree/primary%3ADocuments%2Fcf-gate';

Matcher _fails(FileProblem problem) =>
    isA<FileFailure>().having((f) => f.problem, 'problem', problem);

void main() {
  late FakeStorageBroker broker;
  late FakeFolder folder;
  late SafFileService files;

  setUp(() {
    broker = FakeStorageBroker();
    folder = broker.addTree(
      _uri,
      'cf-gate',
      files: {
        'hello.txt': 'Hello from the gate\n',
        'src/main.js': 'console.log(1);\n',
        '.hidden/x': 'x\n',
      },
    );
    files = SafFileService(
      broker: broker,
      folder: const FolderLocation(treeUri: _uri, name: 'cf-gate'),
    );
  });

  group('the folder', () {
    test('opens under an id that holds no URI', () async {
      final opened = (await files.openWorkspace()).orThrow;
      expect(opened.displayName, 'cf-gate');
      expect(opened.id, folderWorkspaceId(_uri));
      expect(opened.id, startsWith('folder-'));
      expect(opened.id, isNot(contains('content')));
      expect(opened.id, isNot(contains('cf-gate')));
    });

    test('a missing folder and a lost grant say so', () async {
      folder.missing = true;
      final missing = (await files.openWorkspace()).failureOrNull;
      expect(missing, _fails(FileProblem.folderMissing));
      expect(missing!.message, contains('"cf-gate" is missing'));
      expect(
        (await files.listDirectory('')).failureOrNull,
        _fails(FileProblem.folderMissing),
      );

      folder.missing = false;
      broker.granted.clear();
      final lost = (await files.openWorkspace()).failureOrNull;
      expect(lost, _fails(FileProblem.accessLost));
      expect(lost!.message, contains('no longer has access to "cf-gate"'));
      expect(
        (await files.readText('hello.txt')).failureOrNull,
        _fails(FileProblem.accessLost),
      );
    });
  });

  group('listing and reading', () {
    test('lists folders first, dotfiles marked hidden, with sizes', () async {
      final entries = (await files.listDirectory('')).orThrow;
      expect(entries.map((e) => e.path), ['.hidden', 'src', 'hello.txt']);
      expect(entries.first.hidden, isTrue);
      expect(entries.last.sizeBytes, 20);
      final src = (await files.listDirectory('src')).orThrow;
      expect(src.single.path, 'src/main.js');
    });

    test('reads text with its byte-order mark and line endings', () async {
      folder.putBytes('crlf.txt', [0xEF, 0xBB, 0xBF, ...utf8.encode('a\r\nb\r\n')]);
      final read = (await files.readText('crlf.txt')).orThrow;
      expect(read.text, 'a\nb\n');
      expect(read.format.bom, isTrue);
      expect(read.format.lineEnding, LineEnding.crlf);
    });

    test('refuses binary, missing and oversized files', () async {
      folder
        ..putBytes('logo.png', [0x89, 0x50, 0x4E, 0x47, 0x00, 0x1A])
        ..putBytes('big.txt', Uint8List(maxTextFileBytes + 1));
      expect(
        (await files.readText('logo.png')).failureOrNull,
        _fails(FileProblem.notText),
      );
      expect(
        (await files.readText('ghost.txt')).failureOrNull,
        _fails(FileProblem.notFound),
      );
      final big = (await files.readText('big.txt')).failureOrNull;
      expect(big, _fails(FileProblem.tooLarge));
      expect(big!.message, contains('10 MB'));
    });

    test('paths that could escape are refused before the broker', () async {
      broker.calls.clear();
      for (final path in ['../x', '/abs', 'a/../b', 'a//b', 'x\u0000']) {
        expect(
          (await files.readText(path)).failureOrNull,
          _fails(FileProblem.invalidPath),
        );
        expect(
          (await files.writeText(path, 'x')).failureOrNull,
          _fails(FileProblem.invalidPath),
        );
      }
      expect(
        (await files.listDirectory('../..')).failureOrNull,
        _fails(FileProblem.invalidPath),
      );
      expect(broker.calls, isEmpty);
    });
  });

  group('saving', () {
    test('writes in the file\'s own format and returns the new stamp', () async {
      final read = (await files.readText('hello.txt')).orThrow;
      final stamp = (await files.writeText(
        'hello.txt',
        'Hi\n',
        format: const TextFormat(lineEnding: LineEnding.crlf),
        expected: read.stamp,
      )).orThrow;
      expect(folder.text('hello.txt'), 'Hi\r\n');
      expect(stamp, (await files.readText('hello.txt')).orThrow.stamp);
      expect(stamp.digest, isNull);
    });

    test('a file changed by another app is not overwritten', () async {
      final read = (await files.readText('hello.txt')).orThrow;
      folder.putText('hello.txt', 'theirs\n');
      final saved = await files.writeText(
        'hello.txt',
        'mine\n',
        expected: read.stamp,
      );
      expect(saved.failureOrNull, _fails(FileProblem.changedOnDisk));
      expect(folder.text('hello.txt'), 'theirs\n');
      expect(
        (await files.writeText('hello.txt', 'mine\n')).isOk,
        isTrue,
        reason: 'overwriting is the user\'s choice',
      );
    });

    test('without modification times the stamp is a SHA-256', () async {
      folder.timeless = true;
      final read = (await files.readText('hello.txt')).orThrow;
      expect(read.stamp.modified, FileStamp.unknownTime);
      expect(read.stamp.digest, hasLength(64));
      // Changed behind our back, same size, still no time: noticed.
      folder.putText('hello.txt', 'HELLO FROM THE GATE\n');
      expect(
        (await files.writeText(
          'hello.txt',
          'x\n',
          expected: read.stamp,
        )).failureOrNull,
        _fails(FileProblem.changedOnDisk),
      );
      final again = (await files.readText('hello.txt')).orThrow;
      final stamp = (await files.writeText(
        'hello.txt',
        'x\n',
        expected: again.stamp,
      )).orThrow;
      expect(stamp.digest, isNotNull);
      expect(folder.text('hello.txt'), 'x\n');
    });

    test('new files refuse taken names, case ignored', () async {
      expect(
        (await files.writeText(
          'hello.txt',
          '',
          mode: WriteMode.createNew,
        )).failureOrNull,
        _fails(FileProblem.exists),
      );
      expect(
        (await files.writeText(
          'HELLO.TXT',
          '',
          mode: WriteMode.createNew,
        )).failureOrNull,
        _fails(FileProblem.exists),
      );
      expect(
        (await files.writeText(
          'notes/new.md',
          '# new\n',
          mode: WriteMode.createNew,
        )).isOk,
        isTrue,
      );
      expect(folder.text('notes/new.md'), '# new\n');
    });

    test('a failed save says the file may be incomplete', () async {
      broker.failNextWrite = const FileFailure(
        'The provider failed.',
        problem: FileProblem.io,
      );
      final failed = (await files.writeText('hello.txt', 'x\n')).failureOrNull;
      expect(failed, _fails(FileProblem.io));
      expect(failed!.message, contains('may be incomplete'));
      expect(failed.message, contains('still here, unsaved'));
    });
  });

  group('the Pigeon client', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const prefix = 'dev.flutter.pigeon.codeforge.StorageApi';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const codec = StorageApi.pigeonChannelCodec;

    void answer(String method, Object? Function(List<Object?> args) reply) {
      messenger.setMockMessageHandler('$prefix.$method', (message) async {
        final args = codec.decodeMessage(message)! as List<Object?>;
        return codec.encodeMessage(reply(args));
      });
    }

    tearDown(() {
      for (final method in ['list', 'read', 'checkTree']) {
        messenger.setMockMessageHandler('$prefix.$method', null);
      }
    });

    test('maps entries, times and flags', () async {
      answer('list', (args) {
        expect(args, [_uri, 'src']);
        return [
          [
            EntryMessage(
              name: 'main.js',
              isDirectory: false,
              size: 16,
              modifiedMs: 1700000000000,
              flags: 15,
            ),
            EntryMessage(name: 'old.txt', isDirectory: false, flags: 0),
          ],
        ];
      });
      final listed = (await PigeonStorageBroker().list(_uri, 'src')).orThrow;
      expect(listed.first.modified, DateTime.fromMillisecondsSinceEpoch(1700000000000));
      expect(listed.first.canWrite && listed.first.canMove, isTrue);
      expect(listed.last.modified, isNull);
      expect(listed.last.canDelete, isFalse);
    });

    test('maps the broker\'s error codes to problems', () async {
      final codes = {
        'invalid_path': FileProblem.invalidPath,
        'access_lost': FileProblem.accessLost,
        'missing': FileProblem.folderMissing,
        'outside': FileProblem.outsideWorkspace,
        'changed': FileProblem.changedOnDisk,
        'name_changed': FileProblem.nameChanged,
        'timeout': FileProblem.timeout,
        'busy': FileProblem.io,
        'something_new': FileProblem.io,
      };
      for (final MapEntry(key: code, value: problem) in codes.entries) {
        answer('read', (args) => [code, 'from Kotlin', null]);
        final failed = await PigeonStorageBroker().read(
          _uri,
          '../x',
          maxBytes: 10,
        );
        expect(failed.failureOrNull, _fails(problem), reason: code);
        expect(failed.failureOrNull!.message, isNot(contains('Kotlin')));
      }
    });

    test('without a host, folders are unsupported', () async {
      final failed = await PigeonStorageBroker().checkFolder(_uri);
      expect(failed.failureOrNull, _fails(FileProblem.unsupported));
    });
  });
}
