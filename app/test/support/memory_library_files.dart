/// The language servers' own files, in memory (Phase 6 W5): what a
/// definition in Python's stubs or TypeScript's `lib.d.ts` reads, under the
/// same rule as the device's ([isUnderRoots]).
library;

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/services/lsp/library_files.dart';

final class MemoryLibraryFiles implements LibraryFiles {
  /// Each file's text, by its absolute path.
  final Map<String, String> files = {};

  /// Every path asked for, in order.
  final List<String> reads = [];

  @override
  Future<Result<String>> read(String path, List<String> roots) async {
    reads.add(path);
    if (!isUnderRoots(path, roots)) {
      return const Err(
        FileFailure(
          'Only the language servers\u2019 own files open here.',
          problem: FileProblem.invalidPath,
        ),
      );
    }
    final text = files[path];
    return text == null
        ? const Err(
            FileFailure('That file is not there.', problem: FileProblem.notFound),
          )
        : Ok(text);
  }
}
