/// The language servers' own files, read for the editor (Phase 6 W5): a
/// definition in Python's stubs or TypeScript's `lib.d.ts` opens read-only
/// (PHASE_6_PLAN W5). Only files under the server's roots are read (its
/// install folder, the runtime's programs: LanguageClient.libraryRoots),
/// with links resolved before the check, and at most [maxLibraryFileBytes].
library;

import 'dart:convert';
import 'dart:io';

import '../../core/errors/failure.dart';
import '../../core/lsp/lsp_uri.dart';

/// The largest library file the editor shows: TypeScript's `lib.dom.d.ts`
/// is the largest the servers name, under 3 MB.
const int maxLibraryFileBytes = 8 * 1024 * 1024;

abstract interface class LibraryFiles {
  /// The text of [path], an absolute path under one of [roots]. Refused as
  /// [FileProblem.invalidPath] outside them.
  Future<Result<String>> read(String path, List<String> roots);
}

/// Whether [path] lies under one of [roots]: both normalized, no `..`
/// left; a root itself is not a file under it.
bool isUnderRoots(String path, List<String> roots) {
  final normalized = normalizedAbsolutePath(path);
  if (normalized == null) {
    return false;
  }
  for (final root in roots) {
    final base = normalizedAbsolutePath(root);
    if (base != null && base != '/' && normalized.startsWith('$base/')) {
      return true;
    }
  }
  return false;
}

/// Reads them from the device's storage: they are the app's own files.
final class IoLibraryFiles implements LibraryFiles {
  const IoLibraryFiles();

  @override
  Future<Result<String>> read(String path, List<String> roots) async {
    if (!isUnderRoots(path, roots)) {
      return const Err(
        FileFailure(
          'Only the language servers\u2019 own files open here.',
          problem: FileProblem.invalidPath,
        ),
      );
    }
    try {
      // Links resolved, so none leads out of the roots.
      final real = await File(path).resolveSymbolicLinks();
      final realRoots = <String>[
        for (final root in roots)
          if (Directory(root).existsSync())
            await Directory(root).resolveSymbolicLinks(),
      ];
      if (!isUnderRoots(real, realRoots)) {
        return const Err(
          FileFailure(
            'Only the language servers\u2019 own files open here.',
            problem: FileProblem.invalidPath,
          ),
        );
      }
      final file = File(real);
      final size = await file.length();
      if (size > maxLibraryFileBytes) {
        return const Err(
          FileFailure(
            'That file is too large to show.',
            problem: FileProblem.tooLarge,
          ),
        );
      }
      final text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
      return Ok(text.replaceAll('\r\n', '\n').replaceAll('\r', '\n'));
    } on FileSystemException catch (error) {
      return Err(
        FileFailure(
          'That file could not be read (${error.osError?.message ?? error.message}).',
          problem: FileProblem.notFound,
        ),
      );
    }
  }
}
