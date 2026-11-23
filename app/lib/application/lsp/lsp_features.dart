/// The editor's language features (Phase 6 W5, PHASE_6_PLAN W5): the page's
/// requests answered through the servers, and the servers' diagnostics
/// shown.
///
/// - **Requests** (EditorHost.pageRequestHandler): completion and its
///   documentation, hover, definition and rename. Each goes to the server
///   of the document's language once every edit before it has gone out, and
///   its answer is converted for the page (core/lsp/lsp_answers.dart). No
///   server to ask (off, starting, restarting, given up) is answered as
///   unavailable, and completion falls back to the document's words.
/// - **Definition** opens the file at the place, in the same workspace; a
///   place in the server's own files (Python's stubs, TypeScript's
///   `lib.d.ts`) opens read-only ([LibraryView]).
/// - **Rename:** the place is checked with the server (`prepareRename`),
///   the user names the new name ([PendingRename], the workbench's dialog),
///   and the edit is applied all or nothing (rename.dart).
/// - **Diagnostics:** each open document's, as its server publishes them,
///   go to the page (`diag.set`), the status strip and the Problems sheet
///   ([ProblemsState]); again after the page restarts, and gone with the
///   server that found them.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/failure.dart';
import '../../core/logging/logger.dart';
import '../../core/lsp/lsp_answers.dart';
import '../../core/lsp/lsp_models.dart';
import '../../core/lsp/lsp_uri.dart';
import '../../core/lsp/text_sync.dart';
import '../documents/document_controller.dart';
import '../documents/document_state.dart';
import '../editor/editor_host.dart';
import '../editor/editor_providers.dart';
import '../providers.dart';
import 'language_client.dart';
import 'lsp_connection.dart';
import 'lsp_controller.dart';
import 'rename.dart';

const String _tag = 'lsp.features';

/// How long the server may take for each request the page makes; the page
/// waits a second more (editor/src/editor/requests.ts). Completion keeps
/// the client's own limit (LspClientSettings.completionTimeout, 2 s).
const Duration resolveTimeout = Duration(seconds: 3);
const Duration hoverTimeout = Duration(seconds: 3);
const Duration definitionTimeout = Duration(seconds: 10);
const Duration prepareRenameTimeout = Duration(seconds: 10);

/// How many completion answers `lsp.resolve` can still ask about.
const int _keptCompletions = 4;

/// The number of problems of each kind.
final class ProblemCounts {
  const ProblemCounts({this.errors = 0, this.warnings = 0, this.others = 0});

  final int errors;
  final int warnings;

  /// Information and hints.
  final int others;

  int get total => errors + warnings + others;

  static ProblemCounts of(Iterable<LspDiagnostic> diagnostics) {
    var errors = 0;
    var warnings = 0;
    var others = 0;
    for (final d in diagnostics) {
      switch (d.severity) {
        case LspSeverity.error:
          errors += 1;
        case LspSeverity.warning:
          warnings += 1;
        case LspSeverity.information || LspSeverity.hint:
          others += 1;
      }
    }
    return ProblemCounts(errors: errors, warnings: warnings, others: others);
  }

  @override
  bool operator ==(Object other) =>
      other is ProblemCounts &&
      other.errors == errors &&
      other.warnings == warnings &&
      other.others == others;

  @override
  int get hashCode => Object.hash(errors, warnings, others);
}

/// The open documents' diagnostics, for the status strip and the Problems
/// sheet.
final class ProblemsState {
  const ProblemsState({this.files = const {}});

  /// Each open document's diagnostics, by workspace path, in the order the
  /// documents were opened; documents without any are left out.
  final Map<String, List<LspDiagnostic>> files;

  ProblemCounts countsOf(String path) =>
      ProblemCounts.of(files[path] ?? const []);

  ProblemCounts get total =>
      ProblemCounts.of([for (final list in files.values) ...list]);
}

/// A place in a language server's own files, shown read-only.
final class LibraryView {
  const LibraryView({
    required this.name,
    required this.where,
    required this.text,
    required this.line,
    required this.column,
  });

  /// The file's name.
  final String name;

  /// Whose file it is and where: "Pyright: stdlib/builtins.pyi".
  final String where;
  final String text;

  /// The place, 0-based.
  final int line;
  final int column;
}

/// The definition in a server's own files to show, until the workbench
/// shows it.
final libraryViewProvider = NotifierProvider<LibraryViews, LibraryView?>(
  LibraryViews.new,
);

final class LibraryViews extends Notifier<LibraryView?> {
  @override
  LibraryView? build() => null;

  void show(LibraryView view) => state = view;

  /// The view to show, taken: null once shown.
  LibraryView? take() {
    final view = state;
    state = null;
    return view;
  }
}

/// The rename to ask the new name for, until the workbench asks.
final pendingRenameProvider = NotifierProvider<PendingRename, RenameRequest?>(
  PendingRename.new,
);

final class PendingRename extends Notifier<RenameRequest?> {
  @override
  RenameRequest? build() => null;

  void ask(RenameRequest request) => state = request;

  /// The rename to ask about, taken: null once asked.
  RenameRequest? take() {
    final request = state;
    state = null;
    return request;
  }
}

final class _Completion {
  _Completion(this.id, this.docId, this.text, this.raw, this.client);

  final String id;
  final String docId;

  /// The document the completion was asked in: resolved edits are offsets
  /// into it.
  final String text;
  final List<Map<String, Object?>> raw;
  final LanguageClient client;
}

final lspFeaturesProvider = NotifierProvider<LspFeatures, ProblemsState>(
  LspFeatures.new,
);

final class LspFeatures extends Notifier<ProblemsState> {
  Map<LspServerId, ({LanguageClient client, StreamSubscription<void> sub})>
  _watched = {};

  /// The diagnostics as published, by server, then by path.
  Map<LspServerId, Map<String, LspDiagnostics>> _published = {};
  final List<_Completion> _completions = [];
  int _nextCompletion = 0;
  int _build = 0;

  @override
  ProblemsState build() {
    final host = ref.watch(editorHostProvider);
    _build += 1;
    final build = _build;
    _published = {};
    final watched =
        <LspServerId, ({LanguageClient client, StreamSubscription<void> sub})>{};
    _watched = watched;
    _completions.clear();
    host.pageRequestHandler = _answer;
    final events = host.events.listen((event) {
      if (event is PageSynced) {
        _sendAll();
      }
    });
    ref.onDispose(() {
      _build += 1;
      if (host.pageRequestHandler == _answer) {
        host.pageRequestHandler = null;
      }
      unawaited(events.cancel());
      for (final entry in watched.values) {
        unawaited(entry.sub.cancel());
      }
    });
    ref.listen<LspState>(lspControllerProvider, (_, _) => _watchClients());
    ref.listen<DocumentsState>(documentControllerProvider, _onDocuments);
    scheduleMicrotask(() {
      if (build == _build) {
        _watchClients();
      }
    });
    return const ProblemsState();
  }

  // ------------------------------------------------------------ requests

  Future<Result<Object?>> _answer(PageRequest request) async {
    final payload = request.payload;
    final docId = payload['docId'];
    final doc = docId is String ? _documentOf(docId) : null;
    if (docId is! String || doc == null) {
      return const Err(
        LspFailure('That document is not open.', problem: LspProblem.stopped),
      );
    }
    final server = doc.largeFile ? null : LspServerId.forLanguage(doc.language);
    final client = server == null
        ? null
        : ref.read(lspControllerProvider.notifier).clientFor(server);
    if (server == null || client == null) {
      return const Err(
        LspFailure(
          'No language server analyses this file now.',
          problem: LspProblem.stopped,
        ),
      );
    }
    if (request.type == 'lsp.resolve') {
      return _resolve(request, client);
    }
    final host = ref.read(editorHostProvider);
    final text = host.textOf(docId);
    final version = payload['version'];
    if (text == null || version is! int || host.versionOf(docId) != version) {
      // The page sends its edits before asking; anything else is a resync.
      return const Err(
        LspFailure('The document changed.', problem: LspProblem.cancelled),
      );
    }
    final uri = client.uriOf(doc.path);
    if (uri == null) {
      return Err(
        LspFailure(
          '${server.title} is ${client.status.phase.label}.',
          problem: LspProblem.restarting,
        ),
      );
    }
    final pos = payload['pos'];
    final at = pos is int ? pos.clamp(0, text.length) : 0;
    final params = <String, Object?>{
      'textDocument': {'uri': uri},
      'position': LineIndex(text).positionAt(at).toJson(),
    };
    final cancel = LspCancel();
    request.onCancel(cancel.cancel);
    Future<Result<Object?>> ask(String method, Map<String, Object?> extra,
        {Duration? timeout}) =>
        client.request(
          method,
          {...params, ...extra},
          path: doc.path,
          atVersion: version,
          cancel: cancel,
          timeout: timeout,
        );
    switch (request.type) {
      case 'lsp.complete':
        final trigger = payload['trigger'];
        final character = payload['character'];
        final answer = await ask('textDocument/completion', {
          'context': {
            'triggerKind': switch (trigger) {
              'character' => 2,
              'incomplete' => 3,
              _ => 1,
            },
            if (trigger == 'character' && character is String)
              'triggerCharacter': character,
          },
        });
        return switch (answer) {
          Err<Object?>(:final failure) => Err(failure),
          Ok<Object?>(:final value) => Ok(
            _completed(value, docId: docId, text: text, pos: at, client: client),
          ),
        };
      case 'lsp.hover':
        final answer = await ask('textDocument/hover', const {},
            timeout: hoverTimeout);
        return switch (answer) {
          Err<Object?>(:final failure) => Err(failure),
          Ok<Object?>(:final value) => Ok(hoverAnswer(value, text: text)),
        };
      case 'lsp.definition':
        final answer = await ask('textDocument/definition', const {},
            timeout: definitionTimeout);
        if (answer case Err<Object?>(:final failure)) {
          return Err(failure);
        }
        return _goTo(
          locationsOf((answer as Ok<Object?>).value),
          server,
          client,
        );
      case 'lsp.prepareRename':
        return _prepareRename(
          ask,
          server: server,
          client: client,
          doc: doc,
          text: text,
          version: version,
          pos: at,
        );
    }
    return Err(
      LspFailure('No answer for ${request.type}.', problem: LspProblem.badRequest),
    );
  }

  Map<String, Object?> _completed(
    Object? result, {
    required String docId,
    required String text,
    required int pos,
    required LanguageClient client,
  }) {
    final provider = client.capabilities['completionProvider'];
    final answer = completionAnswer(
      result,
      text: text,
      pos: pos,
      resolvable: provider is Map<String, Object?> &&
          provider['resolveProvider'] == true,
    );
    _nextCompletion += 1;
    final id = 'c$_nextCompletion';
    _completions.add(_Completion(id, docId, text, answer.raw, client));
    if (_completions.length > _keptCompletions) {
      _completions.removeAt(0);
    }
    final triggers = provider is Map<String, Object?>
        ? provider['triggerCharacters']
        : null;
    return {
      'resultId': id,
      'items': answer.items,
      'incomplete': answer.incomplete,
      if (triggers is List<Object?>)
        'triggerCharacters': [
          for (final t in triggers)
            if (t is String && t.length == 1) t,
        ].take(32).toList(),
    };
  }

  Future<Result<Object?>> _resolve(
    PageRequest request,
    LanguageClient client,
  ) async {
    final resultId = request.payload['resultId'];
    final index = request.payload['index'];
    _Completion? completion;
    for (final kept in _completions) {
      if (kept.id == resultId) {
        completion = kept;
      }
    }
    // Asked about an answer long gone, or a server since restarted:
    // nothing more to show.
    if (completion == null ||
        index is! int ||
        index >= completion.raw.length ||
        !identical(completion.client, client) ||
        completion.docId != request.payload['docId']) {
      return const Ok(<String, Object?>{});
    }
    final cancel = LspCancel();
    request.onCancel(cancel.cancel);
    final answer = await client.request(
      'completionItem/resolve',
      completion.raw[index],
      cancel: cancel,
      timeout: resolveTimeout,
    );
    return switch (answer) {
      Err<Object?>(:final failure) => Err(failure),
      Ok<Object?>(:final value) => Ok(
        resolveAnswer(value, text: completion.text),
      ),
    };
  }

  /// Opens the first of [locations]: in the workspace, its document at the
  /// place; in the server's own files, read-only.
  Future<Result<Object?>> _goTo(
    List<LspLocation> locations,
    LspServerId server,
    LanguageClient client,
  ) async {
    if (locations.isEmpty) {
      return const Ok({'found': 0});
    }
    final target = locations.first;
    final path = client.pathOf(target.uri);
    if (path != null && path.isNotEmpty) {
      final opened = await ref
          .read(documentControllerProvider.notifier)
          .open(path);
      if (opened case Err<void>(:final failure)) {
        return Err(
          LspFailure(
            'The definition could not be opened: ${failure.message}',
            problem: LspProblem.serverError,
          ),
        );
      }
      final start = target.range.start;
      await ref
          .read(editorHostProvider)
          .gotoLine(start.line + 1, column: start.character + 1);
      appLogger.debug(_tag, 'definition_opened', fields: {'server': server.id});
      return Ok({'found': locations.length});
    }
    return _openLibrary(target, server, client, locations.length);
  }

  Future<Result<Object?>> _openLibrary(
    LspLocation target,
    LspServerId server,
    LanguageClient client,
    int found,
  ) async {
    final path = pathOfFileUri(target.uri);
    final roots = client.libraryRoots;
    if (path == null) {
      return const Err(
        LspFailure(
          'The definition is in a place CodeForge cannot open.',
          problem: LspProblem.serverError,
        ),
      );
    }
    final read = await ref.read(libraryFilesProvider).read(path, roots);
    switch (read) {
      case Err<String>(:final failure):
        return Err(
          LspFailure(
            'The definition could not be opened: ${failure.message}',
            problem: LspProblem.serverError,
          ),
        );
      case Ok<String>(:final value):
        ref
            .read(libraryViewProvider.notifier)
            .show(
              LibraryView(
                name: path.substring(path.lastIndexOf('/') + 1),
                where: libraryLabel(path, server: server, roots: roots),
                text: value,
                line: target.range.start.line,
                column: target.range.start.character,
              ),
            );
        appLogger.debug(_tag, 'library_opened', fields: {'server': server.id});
        return Ok({'found': found});
    }
  }

  Future<Result<Object?>> _prepareRename(
    Future<Result<Object?>> Function(String, Map<String, Object?>,
            {Duration? timeout})
        ask, {
    required LspServerId server,
    required LanguageClient client,
    required OpenDocument doc,
    required String text,
    required int version,
    required int pos,
  }) async {
    final provider = client.capabilities['renameProvider'];
    if (provider == null || provider == false) {
      return Err(
        LspFailure(
          '${server.title} cannot rename.',
          problem: LspProblem.serverError,
        ),
      );
    }
    LspRange? range;
    String? placeholder;
    if (provider is Map<String, Object?> && provider['prepareProvider'] == true) {
      final answer = await ask('textDocument/prepareRename', const {},
          timeout: prepareRenameTimeout);
      if (answer case Err<Object?>(:final failure)) {
        return Err(failure);
      }
      final prepared = prepareRenameOf((answer as Ok<Object?>).value);
      if (!prepared.renameable) {
        return const Err(
          LspFailure(
            'There is nothing to rename here.',
            problem: LspProblem.serverError,
          ),
        );
      }
      range = prepared.range;
      placeholder = prepared.placeholder;
    }
    final index = LineIndex(text);
    final word = range == null
        ? wordAt(text, pos)
        : (from: index.offsetAt(range.start), to: index.offsetAt(range.end));
    if (word == null || word.to <= word.from) {
      return const Err(
        LspFailure(
          'There is nothing to rename here.',
          problem: LspProblem.serverError,
        ),
      );
    }
    final oldName = text.substring(word.from, word.to);
    final suggested = _clip(placeholder ?? oldName, 500);
    ref
        .read(pendingRenameProvider.notifier)
        .ask(
          RenameRequest(
            server: server,
            docId: doc.docId,
            path: doc.path,
            version: version,
            pos: pos,
            oldName: oldName,
            placeholder: suggested,
          ),
        );
    return Ok({'from': word.from, 'to': word.to, 'placeholder': suggested});
  }

  /// Renames as [request] asked, to [newName], all or nothing (rename.dart).
  Future<Result<RenameSummary>> rename(
    RenameRequest request,
    String newName,
  ) async {
    final client = ref
        .read(lspControllerProvider.notifier)
        .clientFor(request.server);
    if (client == null) {
      return Err(
        LspFailure(
          'Nothing was renamed: ${request.server.title} is not running.',
          problem: LspProblem.stopped,
        ),
      );
    }
    return runRename(
      request: request,
      newName: newName,
      client: client,
      host: ref.read(editorHostProvider),
      files: ref.read(fileServiceProvider),
      documents: () => ref.read(documentControllerProvider),
      written: ref.read(lspControllerProvider.notifier).filesWritten,
    );
  }

  // --------------------------------------------------------- diagnostics

  void _watchClients() {
    final clients = ref.read(lspControllerProvider.notifier).clients;
    final changed = <String>{};
    for (final server in [..._watched.keys]) {
      final watched = _watched[server]!;
      if (!identical(clients[server], watched.client)) {
        unawaited(watched.sub.cancel());
        _watched.remove(server);
        changed.addAll(_published.remove(server)?.keys ?? const <String>[]);
      }
    }
    for (final MapEntry(key: server, value: client) in clients.entries) {
      if (_watched.containsKey(server)) {
        continue;
      }
      _watched[server] = (
        client: client,
        sub: client.diagnosticsChanges.listen(_onDiagnostics),
      );
      for (final published in client.diagnostics.values) {
        if (_take(published)) {
          changed.add(published.path);
        }
      }
    }
    if (changed.isEmpty) {
      return;
    }
    changed.forEach(_send);
    _refresh();
  }

  void _onDiagnostics(LspDiagnostics published) {
    if (_take(published)) {
      _send(published.path);
      _refresh();
    }
  }

  /// Keeps [published] unless it is stale: found in a version the server
  /// has since been sent changes after (a newer set follows).
  bool _take(LspDiagnostics published) {
    final client = _watched[published.server]?.client;
    final found = published.version;
    final now = client?.versionOf(published.path);
    if (found != null && now != null && found < now) {
      return false;
    }
    final byPath = _published.putIfAbsent(published.server, () => {});
    if (published.items.isEmpty) {
      byPath.remove(published.path);
    } else {
      byPath[published.path] = published;
    }
    return true;
  }

  List<LspDiagnostic> _diagnosticsOf(String path) => [
    for (final byPath in _published.values) ...?byPath[path]?.items,
  ];

  /// Sends [path]'s diagnostics to the page, if its document is open.
  void _send(String path) {
    final doc = ref.read(documentControllerProvider).documents[path];
    if (doc == null) {
      return;
    }
    final host = ref.read(editorHostProvider);
    final text = host.textOf(doc.docId);
    final version = host.versionOf(doc.docId);
    if (text == null || version == null) {
      return;
    }
    final items = diagnosticItems(_diagnosticsOf(path), text);
    unawaited(
      host.setDiagnostics(doc.docId, version, items).then((sent) {
        if (sent case Err<void>(:final failure)) {
          // Stale for the page (it moved on): the next set follows.
          appLogger.debug(
            _tag,
            'diagnostics_not_shown',
            fields: {'error': failure.message},
          );
        }
      }),
    );
  }

  void _sendAll() {
    for (final path in ref.read(documentControllerProvider).documents.keys) {
      if (_diagnosticsOf(path).isNotEmpty) {
        _send(path);
      }
    }
  }

  void _onDocuments(DocumentsState? previous, DocumentsState next) {
    var changed = false;
    for (final MapEntry(key: path, value: doc) in next.documents.entries) {
      final before = previous?.documents[path];
      if (before == null || before.docId != doc.docId) {
        changed = true;
        if (_diagnosticsOf(path).isNotEmpty) {
          _send(path);
        }
      }
    }
    if (changed ||
        (previous?.documents.length ?? 0) != next.documents.length) {
      _refresh();
    }
  }

  void _refresh() {
    final documents = ref.read(documentControllerProvider).documents;
    final files = <String, List<LspDiagnostic>>{};
    for (final path in documents.keys) {
      final diagnostics = _diagnosticsOf(path);
      if (diagnostics.isNotEmpty) {
        files[path] = diagnostics;
      }
    }
    state = ProblemsState(files: files);
  }

  OpenDocument? _documentOf(String docId) {
    for (final doc in ref.read(documentControllerProvider).documents.values) {
      if (doc.docId == docId) {
        return doc;
      }
    }
    return null;
  }
}

/// Where a library file is, as the read-only view names it: whose it is,
/// and its path from there.
String libraryLabel(
  String path, {
  required LspServerId server,
  required List<String> roots,
}) {
  for (final (index, root) in roots.indexed) {
    if (!path.startsWith('$root/')) {
      continue;
    }
    var rest = path.substring(root.length + 1);
    if (index > 0) {
      return 'The Linux runtime: $rest';
    }
    for (final (prefix, label) in const [
      ('node_modules/pyright/dist/typeshed-fallback/', 'Python stubs'),
      ('node_modules/typescript/lib/', 'TypeScript'),
    ]) {
      if (rest.startsWith(prefix)) {
        rest = rest.substring(prefix.length);
        return '$label: $rest';
      }
    }
    return '${server.title}: $rest';
  }
  return path;
}

String _clip(String text, int max) =>
    text.length <= max ? text : text.substring(0, max);
