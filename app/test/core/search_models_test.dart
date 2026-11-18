import 'package:codeforge/core/search/search_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a glob field splits at commas and drops blanks', () {
    expect(SearchQuery.globsOf(''), isEmpty);
    expect(SearchQuery.globsOf(' src , *.js,, docs/** '), [
      'src',
      '*.js',
      'docs/**',
    ]);
  });

  test("the host's codes map to the app's, unknown ones failing safe", () {
    expect(SearchOutcome.fromCode('done'), SearchOutcome.done);
    expect(SearchOutcome.fromCode('limit'), SearchOutcome.limit);
    expect(SearchOutcome.fromCode('cancelled'), SearchOutcome.cancelled);
    expect(SearchOutcome.fromCode('???'), SearchOutcome.failed);
    expect(SearchEngine.fromCode('ripgrep'), SearchEngine.ripgrep);
    expect(SearchEngine.fromCode('scan'), SearchEngine.scan);
    expect(SearchProblem.fromCode(null), isNull);
    expect(SearchProblem.fromCode('bad_query'), SearchProblem.badQuery);
    expect(SearchProblem.fromCode('access_lost'), SearchProblem.accessLost);
    expect(SearchProblem.fromCode('new_code'), SearchProblem.failed);
  });

  test('a file counts the matches of its lines, not its lines', () {
    const file = SearchFileResult(
      path: 'src/a.js',
      lines: [
        SearchLine(line: 1, column: 1, preview: 'a a a', matches: 3),
        SearchLine(line: 4, column: 2, preview: ' a'),
      ],
    );
    expect(file.matches, 4);
    expect(file.lines, hasLength(2));
  });

  test('queries compare by every field, globs included', () {
    const a = SearchQuery(text: 'x', includes: ['src']);
    expect(a, const SearchQuery(text: 'x', includes: ['src']));
    expect(a == const SearchQuery(text: 'x'), isFalse);
    expect(a == a.copyWith(caseSensitive: true), isFalse);
    expect(a.copyWith(text: 'y').includes, ['src']);
    const failed = SearchSummary.failed(SearchProblem.badQuery, 'why');
    expect(failed.outcome, SearchOutcome.failed);
    expect(failed.skipped, 0);
  });
}
