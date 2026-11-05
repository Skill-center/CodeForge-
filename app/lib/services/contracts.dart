/// Service interfaces (docs/ARCHITECTURE.md §2).
///
/// Phase 1 ships interfaces + honest fakes only. Native implementations
/// (Pigeon bridges, SAF, sealed runtime) arrive in later phases behind the
/// exact same contracts. No implementation may leak platform types.
library;

import '../core/errors/failure.dart';

/// A workspace handle. In Phase 1 only the bundled demo workspace exists.
final class WorkspaceRef {
  const WorkspaceRef({required this.id, required this.displayName});

  final String id;
  final String displayName;
}

/// File metadata, independent of any storage backend.
final class FileEntry {
  const FileEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.hidden = false,
    this.sizeBytes,
  });

  final String path;
  final String name;
  final bool isDirectory;
  final bool hidden;
  final int? sizeBytes;
}

abstract interface class FileService {
  Future<Result<WorkspaceRef>> openDemoWorkspace();
  Future<Result<List<FileEntry>>> listDirectory(String path);
  Future<Result<String>> readTextFile(String path);
  Future<Result<void>> writeTextFile(String path, String content);
}

/// Editor document state. Phase 2 replaces the fake with the CM6 engine.
final class EditorDocument {
  const EditorDocument({
    required this.path,
    required this.language,
    required this.content,
    this.dirty = false,
  });

  final String path;
  final String language;
  final String content;
  final bool dirty;

  EditorDocument copyWith({String? content, bool? dirty}) => EditorDocument(
    path: path,
    language: language,
    content: content ?? this.content,
    dirty: dirty ?? this.dirty,
  );
}

abstract interface class EditorService {
  Future<Result<EditorDocument>> openDocument(String path);
  Future<Result<void>> saveDocument(String path);
}

/// Terminal session state. Phases 4–5 provide the real runtime-backed impl.
enum TerminalAvailability { unavailable, available }

abstract interface class TerminalService {
  TerminalAvailability get availability;
  String get unavailableReason;
}

/// Sealed-runtime install state (docs/RUNTIME_ARCHITECTURE.md).
enum RuntimeState { notInstalled, installing, ready, unhealthy }

abstract interface class RuntimeService {
  Future<Result<RuntimeState>> state();
}

/// Git status for the status strip. Phase 6 provides the real impl.
final class GitSummary {
  const GitSummary({required this.branch, this.dirtyCount = 0});

  final String branch;
  final int dirtyCount;
}

abstract interface class GitService {
  Future<Result<GitSummary>> summary();
}

/// Workspace search. Phase 3 provides the real impl.
abstract interface class SearchService {
  Future<Result<List<String>>> searchFiles(String query);
}
