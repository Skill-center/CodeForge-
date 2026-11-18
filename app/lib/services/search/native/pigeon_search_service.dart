/// The search host over its Pigeon API (Phase 4 W6): the only Dart code
/// that sees the generated `SearchApi` types (docs/ARCHITECTURE.md §2, rule
/// 3; tool/lint_imports.dart enforces it). search_api.g.dart is generated
/// from pigeons/search_api.dart by CI.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../../../core/files/workspace_location.dart';
import '../../../core/logging/logger.dart';
import '../../../core/search/search_models.dart';
import '../../platform/app_directories.dart';
import '../search_service.dart';
import 'search_api.g.dart';

final class PigeonSearchService implements SearchService {
  PigeonSearchService({SearchApi? api}) : _api = api ?? SearchApi();

  final SearchApi _api;

  /// The runs whose summary has not come yet, by id.
  final Map<int, StreamController<SearchUpdate>> _runs = {};
  int _nextId = 0;
  bool _hearing = false;

  // Kotlin answers `start` and `cancel` at once; this catches a host that
  // never answers at all.
  static const Duration _quick = Duration(seconds: 15);

  @override
  SearchRun start(
    WorkspaceLocation workspace,
    SearchQuery query, {
    int? maxResults,
  }) {
    _hear();
    _nextId += 1;
    final id = _nextId;
    // Kept in [_runs] until its summary comes, and closed then (_finish), or
    // by [dispose].
    final updates = (_runs[id] = StreamController<SearchUpdate>()).stream;
    unawaited(_start(id, workspace, query, maxResults));
    return _PigeonSearchRun(this, id, updates);
  }

  /// Stops hearing the host, and ends every run still open.
  Future<void> dispose() async {
    if (_hearing) {
      SearchEvents.setUp(null);
      _hearing = false;
    }
    final open = [..._runs.values];
    _runs.clear();
    for (final controller in open) {
      await controller.close();
    }
  }

  Future<void> _start(
    int id,
    WorkspaceLocation workspace,
    SearchQuery query,
    int? maxResults,
  ) async {
    try {
      final (projectRoot, treeUri) = switch (workspace) {
        final ProjectLocation project when project.isDemo => (
          await demoWorkspacePath(),
          null,
        ),
        final ProjectLocation project => (
          '${await projectsRootPath()}/${project.folder}',
          null,
        ),
        final FolderLocation folder => (null, folder.treeUri),
      };
      await _api
          .start(
            SearchRequestMessage(
              searchId: id,
              query: query.text,
              caseSensitive: query.caseSensitive,
              regex: query.regex,
              wholeWord: query.wholeWord,
              includes: query.includes,
              excludes: query.excludes,
              projectRoot: projectRoot,
              treeUri: treeUri,
              maxResults: maxResults,
            ),
          )
          .timeout(_quick);
    } on PlatformException catch (error) {
      appLogger.warn('search', 'start_failed', fields: {'code': error.code});
      _finish(
        id,
        SearchSummary.failed(
          SearchProblem.failed,
          error.message ?? 'The search could not start (${error.code}).',
        ),
      );
    } on TimeoutException {
      appLogger.warn('search', 'start_timed_out');
      _finish(
        id,
        const SearchSummary.failed(
          SearchProblem.failed,
          'The search did not start.',
        ),
      );
    } on StateError catch (error) {
      // The app's folders could not be found.
      _finish(id, SearchSummary.failed(SearchProblem.failed, error.message));
    }
  }

  Future<void> _cancel(int id) async {
    if (!_runs.containsKey(id)) {
      return;
    }
    try {
      await _api.cancel(id).timeout(_quick);
    } on PlatformException catch (error) {
      appLogger.warn('search', 'cancel_failed', fields: {'code': error.code});
    } on TimeoutException {
      appLogger.warn('search', 'cancel_timed_out');
    }
  }

  void _found(int id, List<SearchFileMessage> files) {
    if (_runs[id]?.isClosed ?? true) {
      return;
    }
    _runs[id]!.add(SearchFound([for (final file in files) fileFrom(file)]));
  }

  void _finish(int id, SearchSummary summary) {
    final controller = _runs.remove(id);
    if (controller == null || controller.isClosed) {
      return;
    }
    controller.add(SearchFinished(summary));
    unawaited(controller.close());
  }

  /// Takes the host's events from now on, once per client.
  void _hear() {
    if (_hearing) {
      return;
    }
    _hearing = true;
    SearchEvents.setUp(_Events(this));
  }
}

final class _PigeonSearchRun implements SearchRun {
  _PigeonSearchRun(this._service, this._id, this.updates);

  final PigeonSearchService _service;
  final int _id;

  @override
  final Stream<SearchUpdate> updates;

  @override
  Future<void> cancel() => _service._cancel(_id);
}

/// Kotlin's events, to their runs.
final class _Events implements SearchEvents {
  _Events(this._service);

  final PigeonSearchService _service;

  @override
  Future<void> found(int searchId, List<SearchFileMessage> files) async {
    _service._found(searchId, files);
  }

  @override
  Future<void> finished(SearchSummaryMessage summary) async {
    _service._finish(summary.searchId, summaryFrom(summary));
  }
}

/// A host's file as the app's.
SearchFileResult fileFrom(SearchFileMessage message) => SearchFileResult(
  path: message.path,
  lines: [
    for (final line in message.lines)
      SearchLine(
        line: line.line,
        column: line.column,
        preview: line.preview,
        previewStart: line.previewStart,
        cutEnd: line.cutEnd,
        ranges: line.ranges,
        matches: line.matches,
      ),
  ],
);

/// A host's summary as the app's.
SearchSummary summaryFrom(SearchSummaryMessage message) => SearchSummary(
  outcome: SearchOutcome.fromCode(message.outcome),
  engine: SearchEngine.fromCode(message.engine),
  problem: SearchProblem.fromCode(message.failure),
  detail: message.detail,
  filesSearched: message.filesSearched,
  filesMatched: message.filesMatched,
  lines: message.lines,
  matches: message.matches,
  skippedBinary: message.skippedBinary,
  skippedLarge: message.skippedLarge,
  skippedNotText: message.skippedNotText,
  skippedLongLines: message.skippedLongLines,
  unreadable: message.unreadable,
  firstResultMs: message.firstResultMs,
  elapsedMs: message.elapsedMs,
);
