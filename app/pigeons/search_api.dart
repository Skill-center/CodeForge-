// The typed boundary to the search host (Phase 4 W6, PHASE_4_PLAN W6):
// searching across the open workspace's files. A project is searched by the
// runtime's ripgrep while the runtime is ready (and by CodeForge's own scan
// otherwise); a folder from shared storage by the scan, through the storage
// broker's grant (android/…/search/SearchHost.kt).
//
// Pigeon generates the Dart client and the Kotlin interface from this file,
// as for pigeons/storage_api.dart: CI's [bootstrap] mode runs
// `dart run pigeon --input pigeons/search_api.dart` and commits the output,
// and every CI run generates it again and fails if the committed copies are
// stale (.github/workflows/ci.yml, "Generated code check").
//
// `start` answers at once. The results arrive through SearchEvents: batches
// of files as they are found, then one summary, whatever happened: done,
// stopped at a cap, cancelled or failed. One search runs at a time; a new
// one cancels the one before, which still ends with its summary. Every
// method answers through a callback (`@asyncCallback`), so the generated
// Kotlin needs no coroutines library.
import 'package:pigeon/pigeon.dart';

/// One search: what to look for, and where.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/services/search/native/search_api.g.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/app/src/main/kotlin/dev/codeforge/app/search/SearchApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'dev.codeforge.app.search'),
    dartPackageName: 'codeforge',
  ),
)
class SearchRequestMessage {
  SearchRequestMessage({
    required this.searchId,
    required this.query,
    required this.caseSensitive,
    required this.regex,
    required this.wholeWord,
    required this.includes,
    required this.excludes,
    this.projectRoot,
    this.treeUri,
    this.maxResults,
  });

  /// Chosen by Dart; every event of this search carries it.
  int searchId;

  String query;
  bool caseSensitive;
  bool regex;
  bool wholeWord;

  /// Globs, as the user typed them (ripgrep's `-g` rules).
  List<String> includes;
  List<String> excludes;

  /// A project's folder, `<filesDir>/workspaces/<name>`; or null.
  String? projectRoot;

  /// A folder the user picked; or null. Exactly one of the two is set.
  String? treeUri;

  /// Matching lines to keep (10,000 when null).
  int? maxResults;
}

/// One matching line. Offsets count UTF-16 code units.
class SearchLineMessage {
  SearchLineMessage({
    required this.line,
    required this.column,
    required this.preview,
    required this.previewStart,
    required this.cutEnd,
    required this.ranges,
    required this.matches,
  });

  /// 1-based.
  int line;

  /// 1-based, in the whole line: where its first match starts.
  int column;

  /// The line, or the part of it around its first match.
  String preview;

  /// Where [preview] starts in the line; 0 unless it was cut before it.
  int previewStart;

  /// Whether the line goes on after [preview].
  bool cutEnd;

  /// The matches inside [preview]: start and end offsets, in pairs.
  List<int> ranges;

  /// Matches in the whole line.
  int matches;
}

/// One file's matching lines.
class SearchFileMessage {
  SearchFileMessage({required this.path, required this.lines});

  /// The workspace path: relative to its top, '/'-separated.
  String path;

  List<SearchLineMessage> lines;
}

/// How a search ended, with its counts.
class SearchSummaryMessage {
  SearchSummaryMessage({
    required this.searchId,
    required this.outcome,
    required this.engine,
    required this.filesMatched,
    required this.lines,
    required this.matches,
    required this.skippedBinary,
    required this.skippedLarge,
    required this.skippedNotText,
    required this.skippedLongLines,
    required this.unreadable,
    required this.elapsedMs,
    this.failure,
    this.detail,
    this.filesSearched,
    this.firstResultMs,
  });

  int searchId;

  /// 'done', 'limit' (stopped at a cap), 'cancelled' or 'failed'.
  String outcome;

  /// 'ripgrep' or 'scan'.
  String engine;

  /// When it failed: 'bad_query', 'not_found', 'access_lost', 'timed_out'
  /// or 'failed' (SearchModels.kt).
  String? failure;

  /// Why it failed, or a warning.
  String? detail;

  /// Files read; null for ripgrep, which does not report it.
  int? filesSearched;
  int filesMatched;
  int lines;
  int matches;
  int skippedBinary;
  int skippedLarge;
  int skippedNotText;
  int skippedLongLines;
  int unreadable;

  /// From the start to the first file with a match, on the host.
  int? firstResultMs;
  int elapsedMs;
}

@HostApi()
abstract class SearchApi {
  /// Starts [request], cancelling any search still running. Answers at once.
  @asyncCallback
  void start(SearchRequestMessage request);

  /// Cancels the search [searchId], if it still runs.
  @asyncCallback
  void cancel(int searchId);
}

/// What the search host tells Dart unasked.
@FlutterApi()
abstract class SearchEvents {
  /// More files with matches, in the order they were found.
  @asyncCallback
  void found(int searchId, List<SearchFileMessage> files);

  /// The search ended; nothing of it follows.
  @asyncCallback
  void finished(SearchSummaryMessage summary);
}
