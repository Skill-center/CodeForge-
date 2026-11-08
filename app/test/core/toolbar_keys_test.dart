/// The symbol toolbar's keys (Phase 2 W6, gate G6): what each one types,
/// the presets per language family, and the user's own keys.
library;

import 'package:codeforge/core/editor/protocol.dart';
import 'package:codeforge/core/editor/toolbar_keys.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> _ids(List<ToolbarKey> keys) => [for (final key in keys) key.id];

void main() {
  group('a key', () {
    test('of a pair leaves the cursor between the two', () {
      expect(insertFor('()'), const InsertText('()', cursorOffset: 1));
      expect(insertFor('""'), const InsertText('""', cursorOffset: 1));
      expect(insertFor(r'${}'), const InsertText(r'${}', cursorOffset: 2));
      expect(insertFor('=""'), const InsertText('=""', cursorOffset: 2));
    });

    test('of anything else leaves the cursor after it', () {
      expect(insertFor(';'), const InsertText(';'));
      expect(insertFor('=>'), const InsertText('=>'));
      expect(insertFor('</'), const InsertText('</'));
      expect(insertFor(')('), const InsertText(')('));
    });

    test('long-pressed gives its other variant', () {
      expect(variantFor('('), const InsertText('()', cursorOffset: 1));
      expect(variantFor('"'), const InsertText('""', cursorOffset: 1));
      expect(variantFor('{}'), const InsertText('{'));
      expect(variantFor(';'), isNull);
      expect(variantFor('=>'), isNull);
      expect(variantFor(r'${}'), isNull);
    });

    test('says what it types', () {
      expect(symbolKey('{}').semanticLabel, 'Insert braces');
      expect(symbolKey('=>').semanticLabel, 'Insert arrow');
      expect(symbolKey('foo').semanticLabel, 'Insert foo');
      expect(symbolKey('{}').label, '{}');
      expect(symbolKey('{}').id, 'symbol:{}');
    });

    test('runs commands the page knows', () {
      final keys = [
        indentKey,
        outdentKey,
        undoKey,
        redoKey,
        ...arrowKeys,
      ];
      for (final key in keys) {
        final action = key.action;
        expect(action, isA<RunCommand>());
        expect(editorCommands, contains((action as RunCommand).command));
      }
      expect(indentKey.action, const RunCommand('insertIndent'));
      expect(outdentKey.action, const RunCommand('indentLess'));
      expect(hideKeyboardKey.action, const HideKeyboard());
    });
  });

  group('presets', () {
    test('follow the language family', () {
      expect(toolbarFamilyOf('typescript'), 'javascript');
      expect(toolbarFamilyOf('tsx'), 'javascript');
      expect(toolbarFamilyOf('python'), 'python');
      expect(toolbarFamilyOf('markdown'), 'markdown');
      expect(toolbarFamilyOf('plaintext'), 'general');
      expect(toolbarFamilyOf(null), 'general');
      expect(symbolsFor('python').first, ':');
      expect(symbolsFor('json'), contains('""'));
      expect(symbolsFor('html'), contains('</'));
      expect(symbolsFor(null), generalSymbols);
    });

    test('have no duplicate keys', () {
      for (final symbols in [generalSymbols, ...familySymbols.values]) {
        expect(symbols.toSet(), hasLength(symbols.length), reason: '$symbols');
      }
    });

    test('standard: Tab, Shift+Tab, symbols, undo, redo, arrows', () {
      final keys = toolbarKeysFor(language: 'css');
      expect(_ids(keys).take(3), ['indent', 'outdent', 'symbol:{}']);
      expect(_ids(keys).skip(keys.length - 6), [
        'undo',
        'redo',
        'left',
        'up',
        'down',
        'right',
      ]);
      expect(keys, hasLength(familySymbols['css']!.length + 8));
      expect(_ids(keys).toSet(), hasLength(keys.length));
    });

    test('compact: Tab and the first symbols only', () {
      final keys = toolbarKeysFor(language: 'python', compact: true);
      expect(_ids(keys), [
        'indent',
        for (final token in familySymbols['python']!.take(compactSymbolCount))
          'symbol:$token',
      ]);
    });
  });

  group("the user's own keys", () {
    test('split on spaces, drop duplicates and skip long ones', () {
      expect(parseToolbarKeys('  {} ()\n;  {}  =>\tabcdefghi  '), [
        '{}',
        '()',
        ';',
        '=>',
      ]);
      expect(parseToolbarKeys(''), isEmpty);
      expect(parseToolbarKeys('   '), isEmpty);
    });

    test('stop at the limit', () {
      final many = [for (var i = 0; i < 60; i++) 'k$i'].join(' ');
      expect(parseToolbarKeys(many), hasLength(maxCustomKeys));
    });

    test('replace the preset, in standard and compact alike', () {
      final standard = toolbarKeysFor(language: 'python', customKeys: '; ->');
      expect(_ids(standard).take(4), [
        'indent',
        'outdent',
        'symbol:;',
        'symbol:->',
      ]);
      final compact = toolbarKeysFor(
        language: 'python',
        compact: true,
        customKeys: 'a b c d e f g h',
      );
      expect(compact, hasLength(9));
    });
  });
}
