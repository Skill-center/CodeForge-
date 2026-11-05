/// Honest fakes for Phase 1 (docs/ARCHITECTURE.md §2.4).
///
/// The demo workspace is real in-memory data: tabs open/close, dirty state
/// and fake saves genuinely mutate it. Anything that would need a native
/// backend reports its real availability instead of pretending.
library;

import '../core/errors/failure.dart';
import 'contracts.dart';

/// The bundled demo project shown on first run.
abstract final class DemoWorkspace {
  static const String id = 'demo';
  static const String displayName = 'Demo Workspace';

  static const Map<String, String> files = {
    'main.js': '''
// CodeForge demo — JavaScript
import { greet } from './utils.js';

const languages = ['JavaScript', 'Python', 'Dart'];

function main() {
  for (const lang of languages) {
    console.log(greet(lang));
  }
}

main();
''',
    'utils.js': '''
// Helpers for the demo entry point.
export function greet(language) {
  return `Hello from \${language}!`;
}
''',
    'app.py': '''
# CodeForge demo — Python
from dataclasses import dataclass


@dataclass
class Forge:
    temperature: int = 1200

    def heat(self, delta: int) -> None:
        self.temperature += delta


if __name__ == "__main__":
    forge = Forge()
    forge.heat(50)
    print(f"Forge at {forge.temperature}°C")
''',
    'README.md': '''
# Demo Workspace

A bundled sample project. Editing, terminals, and runtimes arrive in
later phases — this workspace demonstrates the CodeForge workbench.

- `main.js` — JavaScript entry point
- `app.py` — Python sample
- `src/` — nested folder example
''',
    'src/greeting.dart': '''
// CodeForge demo — Dart
String greet(String name) => 'Hello, \$name!';

void main() {
  print(greet('CodeForge'));
}
''',
    'src/notes.txt': 'Scratch notes live here.\n',
    '.gitignore': 'node_modules/\n__pycache__/\nbuild/\n',
    'package.json': '''
{
  "name": "codeforge-demo",
  "version": "0.1.0",
  "type": "module",
  "private": true
}
''',
  };

  static String languageFor(String path) {
    if (path.endsWith('.js')) return 'javascript';
    if (path.endsWith('.py')) return 'python';
    if (path.endsWith('.dart')) return 'dart';
    if (path.endsWith('.md')) return 'markdown';
    if (path.endsWith('.json')) return 'json';
    return 'plaintext';
  }
}

final class FakeFileService implements FileService {
  final Map<String, String> _files = Map.of(DemoWorkspace.files);
  bool _opened = false;

  @override
  Future<Result<WorkspaceRef>> openDemoWorkspace() async {
    _opened = true;
    return const Ok(WorkspaceRef(id: DemoWorkspace.id, displayName: DemoWorkspace.displayName));
  }

  void _requireOpen() {
    if (!_opened) {
      throw StateError('Demo workspace not opened');
    }
  }

  @override
  Future<Result<List<FileEntry>>> listDirectory(String path) async {
    _requireOpen();
    final prefix = path.isEmpty ? '' : '$path/';
    final seen = <String, FileEntry>{};
    for (final filePath in _files.keys) {
      if (!filePath.startsWith(prefix)) {
        continue;
      }
      final rest = filePath.substring(prefix.length);
      final slash = rest.indexOf('/');
      if (slash < 0) {
        seen[rest] = FileEntry(
          path: filePath,
          name: rest,
          isDirectory: false,
          hidden: rest.startsWith('.'),
          sizeBytes: _files[filePath]!.length,
        );
      } else {
        final dirName = rest.substring(0, slash);
        seen[dirName] = FileEntry(
          path: '$prefix$dirName',
          name: dirName,
          isDirectory: true,
          hidden: dirName.startsWith('.'),
        );
      }
    }
    final entries = seen.values.toList()
      ..sort((a, b) {
        if (a.isDirectory != b.isDirectory) {
          return a.isDirectory ? -1 : 1;
        }
        return a.name.compareTo(b.name);
      });
    return Ok(entries);
  }

  @override
  Future<Result<String>> readTextFile(String path) async {
    _requireOpen();
    final content = _files[path];
    if (content == null) {
      return Err(StorageFailure('File not found: $path'));
    }
    return Ok(content);
  }

  @override
  Future<Result<void>> writeTextFile(String path, String content) async {
    _requireOpen();
    _files[path] = content;
    return const Ok(null);
  }
}

final class FakeEditorService implements EditorService {
  FakeEditorService(this._files);

  final FakeFileService _files;
  final Map<String, EditorDocument> _documents = {};

  @override
  Future<Result<EditorDocument>> openDocument(String path) async {
    final existing = _documents[path];
    if (existing != null) {
      return Ok(existing);
    }
    final content = await _files.readTextFile(path);
    return switch (content) {
      Ok<String>(:final value) => () {
        final doc = EditorDocument(
          path: path,
          language: DemoWorkspace.languageFor(path),
          content: value,
        );
        _documents[path] = doc;
        return Ok(doc);
      }(),
      Err<String>(:final failure) => Err(failure),
    };
  }

  /// Marks a document dirty (used by the demo "simulate edit" action).
  void markDirty(String path) {
    final doc = _documents[path];
    if (doc != null) {
      _documents[path] = doc.copyWith(dirty: true);
    }
  }

  EditorDocument? document(String path) => _documents[path];

  @override
  Future<Result<void>> saveDocument(String path) async {
    final doc = _documents[path];
    if (doc == null) {
      return const Err(StorageFailure('Document not open'));
    }
    final result = await _files.writeTextFile(path, doc.content);
    return switch (result) {
      Ok<void>() => () {
        _documents[path] = doc.copyWith(dirty: false);
        return const Ok(null);
      }(),
      Err<void>(:final failure) => Err(failure),
    };
  }
}

final class FakeTerminalService implements TerminalService {
  @override
  TerminalAvailability get availability => TerminalAvailability.unavailable;

  @override
  String get unavailableReason =>
      'The Linux runtime and terminal arrive in Phases 4–5. '
      'This pane is a preview of the real thing.';
}

final class FakeRuntimeService implements RuntimeService {
  @override
  Future<Result<RuntimeState>> state() async => const Ok(RuntimeState.notInstalled);
}

final class FakeGitService implements GitService {
  @override
  Future<Result<GitSummary>> summary() async =>
      const Ok(GitSummary(branch: 'main'));
}

final class FakeSearchService implements SearchService {
  FakeSearchService(this._files);

  final FakeFileService _files;

  @override
  Future<Result<List<String>>> searchFiles(String query) async {
    if (query.isEmpty) {
      return const Ok([]);
    }
    final listing = await _files.listDirectory('');
    return switch (listing) {
      Ok<List<FileEntry>>(:final value) => Ok(
        value
            .where((e) => !e.isDirectory && e.name.contains(query.toLowerCase()))
            .map((e) => e.path)
            .toList(),
      ),
      Err<List<FileEntry>>(:final failure) => Err(failure),
    };
  }
}
