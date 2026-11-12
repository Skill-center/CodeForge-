/// The `folders` group's half of the gate protocol (Phase 3 W2, gate G1).
///
/// The test asks the host for something in the device log, one request at
/// a time (`FOLDERGATE <run>.<n> <kind> [<path>]`), and
/// app/tool/ci/emulator_gate.sh acts on it: it drives Android's folder
/// picker (`pick`), looks at the gate folder on disk (`disk <path>`: the
/// file's SHA-256, `dir` or `absent`; `list <path>`: the names, sorted),
/// or changes it behind the app's back (`rmtree`, `mkdir`; since Phase 3
/// W5 `put` and `rm` there, and `pput` and `prm` in the app's own projects
/// through `run-as`), and sends the app to the background and back (`home`,
/// `front`). It writes its answer into the app's files folder through
/// `run-as`
/// (`files/foldergate/<run>.<n>`), where the test reads it. As in the keys
/// group, requests are printed in the root zone: a print inside a test
/// goes to the test runner, not to the device log.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/services/platform/app_directories.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

final class FolderGate {
  FolderGate._(this._answers, this._run);

  /// A new run: answers left by an earlier attempt are dropped.
  static Future<FolderGate> start() async {
    final answers = Directory('${await applicationFilesPath()}/foldergate');
    if (answers.existsSync()) {
      answers.deleteSync(recursive: true);
    }
    return FolderGate._(answers, DateTime.now().millisecondsSinceEpoch);
  }

  final Directory _answers;
  final int _run;
  int _step = 0;

  /// Asks the host for [request] and returns its answer. Waits with plain
  /// timers, not frames: while Android's picker covers the app, Flutter
  /// draws nothing, and a pump would wait for the picker to close.
  Future<String> ask(
    String request, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    _step += 1;
    final id = '$_run.$_step';
    final line = 'FOLDERGATE $id $request';
    Zone.root.print(line);
    debugPrint(line);
    final file = File('${_answers.path}/$id');
    final watch = Stopwatch()..start();
    while (true) {
      // The host writes the answer with one echo: complete once it ends
      // its line.
      if (file.existsSync()) {
        final answer = file.readAsStringSync();
        if (answer.endsWith('\n')) {
          debugPrint('folder gate: request $id answered ${answer.trim()}');
          return answer.trim();
        }
      }
      if (watch.elapsed > timeout) {
        fail(
          'The host did not answer "$request" (request $id) within '
          '${timeout.inSeconds} s.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  /// What the host finds at [path] in the gate folder: the file's SHA-256,
  /// `dir`, or `absent`.
  Future<String> disk(String path) => ask('disk $path');

  /// The names in the gate folder's folder [path] ('' for the folder
  /// itself), as the host lists them: dotfiles included, sorted by byte,
  /// comma-separated.
  Future<String> names(String path) => ask('list ${path.isEmpty ? '.' : path}');

  /// The host writes [word] and a line break to [path] in the gate folder
  /// as the shell user: another app, as far as the app can tell (Phase 3
  /// W5). Answers the device's clock just before the write, or null when
  /// the host's shell could not say. [word] holds letters, digits and
  /// `._,:-` only.
  Future<DateTime?> put(String path, String word) async =>
      _deviceTime(await ask('put $path $word'));

  /// The host deletes the file [path] in the gate folder as the shell user.
  Future<DateTime?> remove(String path) async =>
      _deviceTime(await ask('rm $path'));

  /// [put] in the app's own storage: [path] is under `files/workspaces`
  /// (`demo/main.js`), written through `run-as`, as the app's user in
  /// another process.
  Future<DateTime?> putInProject(String path, String word) async =>
      _deviceTime(await ask('pput $path $word'));

  /// [remove] in the app's own storage, through `run-as`.
  Future<DateTime?> removeInProject(String path) async =>
      _deviceTime(await ask('prm $path'));

  /// The host presses Home: the app goes to the background.
  Future<void> home() async => expect(await ask('home'), 'done');

  /// The host brings the app back to the front (`am start`).
  Future<void> front() async => expect(await ask('front'), 'done');

  /// The device time a change answered: seconds since the epoch, to the
  /// microsecond (the shell's EPOCHREALTIME).
  static DateTime? _deviceTime(String answer) {
    final seconds = double.tryParse(answer);
    return seconds == null
        ? null
        : DateTime.fromMicrosecondsSinceEpoch((seconds * 1e6).round());
  }

  /// The host may stop looking for requests.
  void done() {
    Zone.root.print('FOLDERGATE $_run.${_step + 1} done');
  }
}

/// The hex SHA-256 of [text] in UTF-8, as `sha256sum` prints it.
String sha256Of(String text) => sha256.convert(utf8.encode(text)).toString();

/// A failure with [problem].
Matcher failsWith(FileProblem problem) =>
    isA<FileFailure>().having((f) => f.problem, 'problem', problem);
