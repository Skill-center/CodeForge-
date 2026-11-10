/// Settings → Developer → Create large test files (Phase 3 W1): the
/// large-file gate's seven files, byte for byte (core/editor/
/// large_samples.dart), written into the open workspace so that the
/// large-file policy can be tried on a phone, where the gate's files never
/// are. Debug and profile builds only, like the rest of the Developer
/// section.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/editor/large_samples.dart';
import '../../core/errors/failure.dart';
import '../../core/logging/logger.dart';
import '../../services/contracts.dart';
import '../providers.dart';
import '../workspace_controller.dart';

/// Where the files go in the workspace, to keep its root tidy.
const String largeTestFolder = 'large-files';

final class LargeTestFilesState {
  const LargeTestFilesState({
    this.running = false,
    this.current,
    this.written = 0,
    this.bytes = 0,
    this.failure,
  });

  /// Whether files are being written.
  final bool running;

  /// The file being written, while [running].
  final String? current;

  /// How many files the last run wrote, and their size.
  final int written;
  final int bytes;

  /// Why the last run stopped, if it did.
  final Failure? failure;
}

final class LargeTestFilesController extends Notifier<LargeTestFilesState> {
  @override
  LargeTestFilesState build() => const LargeTestFilesState();

  /// Writes [samples] (the gate's seven unless a test says otherwise) into
  /// [largeTestFolder], each replacing an earlier copy, then lists the
  /// workspace again. Returns how many files were written.
  Future<Result<int>> create({List<LargeSample>? samples}) async {
    if (state.running) {
      return const Err(UnexpectedFailure('Already writing the files.'));
    }
    state = const LargeTestFilesState(running: true);
    final workspace = ref.read(workspaceControllerProvider.notifier);
    final opened = await workspace.open();
    if (opened case Err(:final failure)) {
      return _stop(failure, 0, 0);
    }
    final files = ref.read(fileServiceProvider);
    final clock = Stopwatch()..start();
    var written = 0;
    var bytes = 0;
    var text = '';
    var textChars = -1;
    for (final sample in samples ?? largeSamples) {
      if (!ref.mounted) {
        return Ok(written);
      }
      state = LargeTestFilesState(
        running: true,
        current: sample.name,
        written: written,
        bytes: bytes,
      );
      // The .js and .txt files of a size share one text.
      if (textChars != sample.chars) {
        text = largeJavaScript(sample.chars);
        textChars = sample.chars;
      }
      final result = await files.writeText(
        '$largeTestFolder/${sample.name}',
        text,
        mode: WriteMode.replace,
      );
      if (result case Err(:final failure)) {
        return _stop(failure, written, bytes);
      }
      written += 1;
      bytes += text.length;
    }
    await workspace.refresh();
    appLogger.info(
      'dev',
      'large_files_written',
      fields: {
        'files': written,
        'bytes': bytes,
        'folder': largeTestFolder,
        'ms': clock.elapsedMilliseconds,
      },
    );
    if (ref.mounted) {
      state = LargeTestFilesState(written: written, bytes: bytes);
    }
    return Ok(written);
  }

  Result<int> _stop(Failure failure, int written, int bytes) {
    appLogger.warn(
      'dev',
      'large_files_failed',
      fields: {'written': written, 'error': failure.message},
    );
    if (ref.mounted) {
      state = LargeTestFilesState(
        written: written,
        bytes: bytes,
        failure: failure,
      );
    }
    return Err(failure);
  }
}

final largeTestFilesProvider =
    NotifierProvider<LargeTestFilesController, LargeTestFilesState>(
      LargeTestFilesController.new,
    );
