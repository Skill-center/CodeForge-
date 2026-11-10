/// Settings → Developer → Create large test files (Phase 3 W1): the
/// generator's text, byte for byte, in `large-files/`; a refusal stops the
/// run and says where. The full seven files are written by
/// test/widget/developer_tools_test.dart.
library;

import 'dart:convert';

import 'package:codeforge/application/bench/large_test_files.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/workspace_controller.dart';
import 'package:codeforge/core/editor/large_samples.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/features/settings/settings_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/memory_file_service.dart';

const List<LargeSample> _small = [
  LargeSample('small.js', 2000),
  LargeSample('small.txt', 2000),
  LargeSample('medium.js', 9000),
];

ProviderContainer _container(MemoryFileService files) => ProviderContainer.test(
  overrides: [fileServiceProvider.overrideWithValue(files)],
);

void main() {
  test('writes each file into large-files/ and lists it', () async {
    final files = MemoryFileService();
    final container = _container(files);
    final result = await container
        .read(largeTestFilesProvider.notifier)
        .create(samples: _small);

    expect(result.valueOrNull, 3);
    expect(files.writes, [
      'large-files/small.js',
      'large-files/small.txt',
      'large-files/medium.js',
    ]);
    for (final sample in _small) {
      expect(
        files.bytesOf('large-files/${sample.name}'),
        utf8.encode(largeJavaScript(sample.chars)),
        reason: sample.name,
      );
    }
    final state = container.read(largeTestFilesProvider);
    expect(state.running, isFalse);
    expect(state.failure, isNull);
    expect(state.written, 3);
    expect(
      state.bytes,
      2 * largeJavaScript(2000).length + largeJavaScript(9000).length,
    );
    // The explorer sees the folder without a manual refresh.
    final root = container.read(workspaceControllerProvider).listings['']!;
    expect(
      root.valueOrNull!.map((entry) => entry.name),
      contains(largeTestFolder),
    );
    expect(largeTestFilesLine(state), startsWith('Wrote 3 files ('));
  });

  test('a second run replaces the files', () async {
    final files = MemoryFileService();
    final container = _container(files);
    final controller = container.read(largeTestFilesProvider.notifier);
    await controller.create(samples: _small);
    final again = await controller.create(samples: _small);
    expect(again.valueOrNull, 3);
    expect(files.writes, hasLength(6));
  });

  test('a refused write stops the run and says where', () async {
    // A folder where the second file should go.
    final files = MemoryFileService(
      seed: const {'large-files/small.txt/keep.md': 'x'},
    );
    final container = _container(files);
    final result = await container
        .read(largeTestFilesProvider.notifier)
        .create(samples: _small);

    expect(result.isOk, isFalse);
    expect(files.writes, ['large-files/small.js']);
    final state = container.read(largeTestFilesProvider);
    expect(state.running, isFalse);
    expect(state.written, 1);
    expect(state.failure, isA<FileFailure>());
    expect(
      largeTestFilesLine(state),
      'Stopped after 1 file: large-files/small.txt is a folder.',
    );
  });

  test('one run at a time', () async {
    final container = _container(MemoryFileService());
    final controller = container.read(largeTestFilesProvider.notifier);
    final first = controller.create(samples: _small);
    expect(container.read(largeTestFilesProvider).running, isTrue);
    expect(
      largeTestFilesLine(container.read(largeTestFilesProvider)),
      startsWith('Writing'),
    );
    final second = await controller.create(samples: _small);
    expect(second.isOk, isFalse);
    expect((await first).valueOrNull, 3);
  });

  test("the row names the gate's files before a run", () {
    expect(largeSamples, hasLength(7));
    expect(
      largeTestFilesLine(const LargeTestFilesState()),
      "The large-file gate's 7 files, 512 KiB to 10 MiB, written to "
      'large-files/ in the workspace',
    );
  });
}
