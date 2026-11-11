/// Writes the emulator gate's folder fixture (Phase 3 W2) into a local
/// directory, for `adb push` to /sdcard/Documents: the gate folder and the
/// folder beside it (integration_test/folder_fixture.dart).
///
/// Run from app/: `dart run tool/ci/write_folder_fixture.dart <directory>`
library;

import 'dart:convert';
import 'dart:io';

import '../../integration_test/folder_fixture.dart';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/ci/write_folder_fixture.dart <dir>');
    exitCode = 2;
    return;
  }
  final root = Directory(args.single);
  for (final (folder, files) in [
    (gateFolderName, gateFixture),
    (gateOutsideName, gateOutsideFixture),
  ]) {
    for (final MapEntry(key: path, value: text) in files.entries) {
      final file = File('${root.path}/$folder/$path');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(utf8.encode(text));
      stdout.writeln('$folder/$path ${text.length} chars');
    }
  }
}
