/// Go to File's matching (Phase 3 W4, core/files/fuzzy_match.dart): the
/// query's characters in order, case and spaces ignored; the file name, word
/// starts and runs ranked first.
library;

import 'package:codeforge/core/files/fuzzy_match.dart';
import 'package:flutter_test/flutter_test.dart';

const List<String> _paths = [
  'lib/main.dart',
  'test/main_test.dart',
  'lib/features/workbench/workbench_screen.dart',
  'lib/web/webview_surface.dart',
  'docs/README.md',
  'README.md',
  'lib/app.dart',
  'android/app/src/main/kotlin/MainActivity.kt',
  'lib/design_system/tokens/icons.dart',
  'test/design_system/icons_test.dart',
];

final List<FuzzyTarget> _targets = [for (final p in _paths) FuzzyTarget(p)];

List<String> _rank(String query) => [
  for (final match in rankTargets(normalizeQuery(query), _targets)) match.path,
];

void main() {
  group('matching', () {
    test('takes the characters in order, in any case', () {
      final target = FuzzyTarget('lib/features/workbench/workbench_screen.dart');
      expect(fuzzyContains('wbscr', target), isTrue);
      expect(fuzzyContains(normalizeQuery('WbScr'), target), isTrue);
      expect(fuzzyContains('rcsbw', target), isFalse);
      expect(matchPath('zz', target), isNull);
    });

    test('ignores spaces in the query', () {
      expect(normalizeQuery(' Lib  Main '), 'libmain');
      expect(_rank('lib main'), ['lib/main.dart']);
    });

    test('an empty query keeps the first files in order', () {
      expect(_rank(''), _paths);
      expect(
        rankTargets('', _targets, limit: 2).map((m) => m.path),
        _paths.take(2),
      );
    });

    test('answers which characters matched', () {
      final match = matchPath(
        'wbscr',
        FuzzyTarget('lib/features/workbench/workbench_screen.dart'),
      )!;
      // In the file name, not in the folder of the same name.
      expect(match.positions, [23, 27, 33, 34, 35]);
      expect(
        matchPath('main', FuzzyTarget('lib/main.dart'))!.positions,
        [4, 5, 6, 7],
      );
      expect(
        matchPath('libmain', FuzzyTarget('lib/main.dart'))!.positions,
        [0, 1, 2, 4, 5, 6, 7],
      );
    });

    test('keeps indices when lower case would change the length', () {
      // A dotted capital I lowers to two code units; indices must still
      // point into the path.
      final target = FuzzyTarget('İstanbul/Notes.md');
      expect(target.lower.length, target.path.length);
      final match = matchPath('notes', target)!;
      expect(
        match.positions.map((i) => target.path[i]).join(),
        'Notes',
      );
    });

    test('knows hidden paths', () {
      expect(FuzzyTarget('.github/ci.yml').hidden, isTrue);
      expect(FuzzyTarget('app/.env').hidden, isTrue);
      expect(FuzzyTarget('app/env.dart').hidden, isFalse);
    });
  });

  group('ranking', () {
    test('a file name beats the same letters across folders', () {
      expect(_rank('wbscr'), [
        'lib/features/workbench/workbench_screen.dart',
        'lib/web/webview_surface.dart',
      ]);
    });

    test('on a tie, the shorter file name first', () {
      expect(_rank('main'), [
        'lib/main.dart',
        'test/main_test.dart',
        'android/app/src/main/kotlin/MainActivity.kt',
      ]);
      expect(_rank('icons').take(2), [
        'lib/design_system/tokens/icons.dart',
        'test/design_system/icons_test.dart',
      ]);
      expect(_rank('readme'), ['README.md', 'docs/README.md']);
    });

    test('word starts and runs beat scattered letters', () {
      expect(_rank('app'), [
        'lib/app.dart',
        'android/app/src/main/kotlin/MainActivity.kt',
      ]);
    });

    test('nothing matches nothing', () {
      expect(_rank('zz'), isEmpty);
    });

    test('stops at the limit', () {
      final many = [for (var i = 0; i < 500; i++) FuzzyTarget('src/f$i.dart')];
      expect(rankTargets('f', many, limit: 100), hasLength(100));
    });
  });
}
