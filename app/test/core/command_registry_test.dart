import 'package:codeforge/core/commands/command_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fuzzyScore', () {
    test('empty query matches everything with score 0', () {
      expect(fuzzyScore('', 'Anything'), 0);
    });

    test('subsequence matches, out-of-order does not', () {
      expect(fuzzyScore('gth', 'Go to Home'), isNotNull);
      expect(fuzzyScore('htg', 'Go to Home'), isNull);
    });

    test('contiguous runs score higher than scattered hits', () {
      // 'term' is a contiguous run in 'Terminal' but scattered mid-word in
      // 'The Error Room Map' (no word-boundary bonuses), so it must score
      // strictly higher in the former.
      final contiguous = fuzzyScore('term', 'Terminal')!;
      final scattered = fuzzyScore('term', 'The Error Room Map')!;
      expect(contiguous, greaterThan(scattered));
    });

    test('case insensitive', () {
      expect(fuzzyScore('DARK', 'use dark theme'), isNotNull);
    });
  });

  group('CommandRegistry', () {
    late CommandRegistry registry;
    final executed = <String>[];

    setUp(() {
      executed.clear();
      registry = CommandRegistry();
      registry.register(
        CfCommand(
          id: 'nav.home',
          title: 'Go to Home',
          category: 'Navigate',
          onExecute: () => executed.add('nav.home'),
        ),
      );
      registry.register(
        CfCommand(
          id: 'theme.dark',
          title: 'Use Dark Theme',
          category: 'Appearance',
          onExecute: () => executed.add('theme.dark'),
        ),
      );
      registry.register(
        CfCommand(
          id: 'theme.light',
          title: 'Use Light Theme',
          category: 'Appearance',
          onExecute: () => executed.add('theme.light'),
        ),
      );
    });

    test('empty query lists all commands', () {
      expect(registry.search(''), hasLength(3));
    });

    test('query filters and ranks', () {
      final results = registry.search('dark');
      expect(results, hasLength(1));
      expect(results.single.id, 'theme.dark');
    });

    test('category is searchable', () {
      final results = registry.search('appearance');
      expect(results, hasLength(2));
    });

    test('execution dispatches to the handler', () {
      registry.search('dark').single.onExecute();
      expect(executed, ['theme.dark']);
    });

    test('unregister removes the command', () {
      registry.unregister('nav.home');
      expect(registry.search(''), hasLength(2));
      expect(registry.search('home'), isEmpty);
    });
  });
}
