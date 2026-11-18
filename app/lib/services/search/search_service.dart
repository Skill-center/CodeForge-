/// Search across the open workspace's files (Phase 4 W6), as the app sees
/// it. Only Kotlin can search (android/…/search/SearchHost.kt): the Pigeon
/// client implements this contract (native/pigeon_search_service.dart), and
/// tests use a fake.
library;

import '../../core/files/workspace_location.dart';
import '../../core/search/search_models.dart';

/// What a running search reports.
sealed class SearchUpdate {
  const SearchUpdate();
}

/// More files with matches, in the order they were found.
final class SearchFound extends SearchUpdate {
  const SearchFound(this.files);

  final List<SearchFileResult> files;
}

/// The end: nothing of this search follows.
final class SearchFinished extends SearchUpdate {
  const SearchFinished(this.summary);

  final SearchSummary summary;
}

/// One search on its way.
abstract interface class SearchRun {
  /// Batches of files as they are found, then one [SearchFinished],
  /// whatever happened; then the stream closes. Listening to it once is
  /// enough; no listener at all still lets the search run.
  Stream<SearchUpdate> get updates;

  /// Asks the host to stop. [updates] still ends with a [SearchFinished],
  /// whose outcome is [SearchOutcome.cancelled] unless the search ended
  /// first.
  Future<void> cancel();
}

abstract interface class SearchService {
  /// Starts searching [workspace] for [query], keeping at most [maxResults]
  /// matching lines (10,000 when null). A search still running is
  /// cancelled: one runs at a time.
  SearchRun start(
    WorkspaceLocation workspace,
    SearchQuery query, {
    int? maxResults,
  });
}
