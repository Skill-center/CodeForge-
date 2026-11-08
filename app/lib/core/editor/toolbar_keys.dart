/// The symbol toolbar's keys (Phase 2 W6): what each one does, the preset
/// for each language family, and the user's own keys. The workbench draws
/// them and runs their actions on the editor (docs/EDITOR_ARCHITECTURE.md
/// §9).
library;

/// What a key does when it is tapped or long-pressed.
sealed class ToolbarAction {
  const ToolbarAction();
}

/// Types [text] at every cursor, replacing any selection. The cursor ends
/// [cursorOffset] characters into the text, or after it when null.
final class InsertText extends ToolbarAction {
  const InsertText(this.text, {this.cursorOffset});

  final String text;
  final int? cursorOffset;

  @override
  bool operator ==(Object other) =>
      other is InsertText &&
      other.text == text &&
      other.cursorOffset == cursorOffset;

  @override
  int get hashCode => Object.hash(text, cursorOffset);

  @override
  String toString() => 'InsertText($text, cursorOffset: $cursorOffset)';
}

/// Runs one of the editor's commands (`editorCommands`).
final class RunCommand extends ToolbarAction {
  const RunCommand(this.command);

  final String command;

  @override
  bool operator ==(Object other) =>
      other is RunCommand && other.command == command;

  @override
  int get hashCode => command.hashCode;

  @override
  String toString() => 'RunCommand($command)';
}

/// Puts the soft keyboard away.
final class HideKeyboard extends ToolbarAction {
  const HideKeyboard();

  @override
  bool operator ==(Object other) => other is HideKeyboard;

  @override
  int get hashCode => 'HideKeyboard'.hashCode;

  @override
  String toString() => 'HideKeyboard()';
}

/// How the workbench draws a key and when it enables it.
enum ToolbarKeyKind {
  symbol,
  indent,
  outdent,
  undo,
  redo,
  left,
  up,
  down,
  right,
  hideKeyboard,
}

/// One key of the toolbar.
final class ToolbarKey {
  const ToolbarKey({
    required this.id,
    required this.label,
    required this.semanticLabel,
    required this.action,
    this.longPress,
    this.kind = ToolbarKeyKind.symbol,
  });

  /// Unique within a toolbar; widget keys are `toolbar_<id>`.
  final String id;

  /// What a symbol key shows. The other kinds are drawn as icons.
  final String label;

  /// What a screen reader announces.
  final String semanticLabel;

  final ToolbarAction action;

  /// The key's other variant: a lone opener becomes its pair, a pair its
  /// lone opener.
  final ToolbarAction? longPress;

  final ToolbarKeyKind kind;

  @override
  String toString() => 'ToolbarKey($id)';
}

/// Openers and quotes, with the character that closes each.
const Map<String, String> _closers = {
  '(': ')',
  '[': ']',
  '{': '}',
  '<': '>',
  '"': '"',
  "'": "'",
  '`': '`',
};

/// Names a screen reader can say; other keys are read as typed.
const Map<String, String> _names = {
  '(': 'opening parenthesis',
  ')': 'closing parenthesis',
  '()': 'parentheses',
  '[': 'opening bracket',
  ']': 'closing bracket',
  '[]': 'brackets',
  '{': 'opening brace',
  '}': 'closing brace',
  '{}': 'braces',
  '<': 'less than',
  '>': 'greater than',
  '<>': 'angle brackets',
  '"': 'double quote',
  '""': 'double quotes',
  "'": 'single quote',
  "''": 'single quotes',
  '`': 'backtick',
  '``': 'backticks',
  ';': 'semicolon',
  ':': 'colon',
  ',': 'comma',
  '.': 'full stop',
  '=': 'equals',
  '=>': 'arrow',
  '!': 'exclamation mark',
  '?': 'question mark',
  '&': 'ampersand',
  '|': 'vertical bar',
  r'\': 'backslash',
  '/': 'slash',
  '#': 'hash',
  r'$': 'dollar',
  '%': 'percent',
  '^': 'caret',
  '~': 'tilde',
  '_': 'underscore',
  '-': 'minus',
  '+': 'plus',
  '*': 'asterisk',
  '@': 'at sign',
  '</': 'closing tag',
  '=""': 'attribute value',
  r'${}': 'template placeholder',
};

/// What typing [token] from the toolbar does. A token whose last character
/// closes the one before it (`()`, `""`, `${}`) leaves the cursor between
/// the two.
InsertText insertFor(String token) {
  final length = token.length;
  final paired =
      length >= 2 && _closers[token[length - 2]] == token[length - 1];
  return InsertText(token, cursorOffset: paired ? length - 1 : null);
}

/// The long-press variant of [token], if it has one.
InsertText? variantFor(String token) {
  if (token.length == 1) {
    final closer = _closers[token];
    return closer == null
        ? null
        : InsertText('$token$closer', cursorOffset: 1);
  }
  if (token.length == 2 && _closers[token[0]] == token[1]) {
    return InsertText(token[0]);
  }
  return null;
}

/// A key that types [token].
ToolbarKey symbolKey(String token) => ToolbarKey(
  id: 'symbol:$token',
  label: token,
  semanticLabel: 'Insert ${_names[token] ?? token}',
  action: insertFor(token),
  longPress: variantFor(token),
);

const ToolbarKey indentKey = ToolbarKey(
  id: 'indent',
  label: 'Tab',
  semanticLabel: 'Indent',
  action: RunCommand('insertIndent'),
  kind: ToolbarKeyKind.indent,
);

const ToolbarKey outdentKey = ToolbarKey(
  id: 'outdent',
  label: 'Shift+Tab',
  semanticLabel: 'Outdent',
  action: RunCommand('indentLess'),
  kind: ToolbarKeyKind.outdent,
);

const ToolbarKey undoKey = ToolbarKey(
  id: 'undo',
  label: 'Undo',
  semanticLabel: 'Undo',
  action: RunCommand('undo'),
  kind: ToolbarKeyKind.undo,
);

const ToolbarKey redoKey = ToolbarKey(
  id: 'redo',
  label: 'Redo',
  semanticLabel: 'Redo',
  action: RunCommand('redo'),
  kind: ToolbarKeyKind.redo,
);

const List<ToolbarKey> arrowKeys = [
  ToolbarKey(
    id: 'left',
    label: 'Left',
    semanticLabel: 'Cursor left',
    action: RunCommand('cursorCharLeft'),
    kind: ToolbarKeyKind.left,
  ),
  ToolbarKey(
    id: 'up',
    label: 'Up',
    semanticLabel: 'Cursor up',
    action: RunCommand('cursorLineUp'),
    kind: ToolbarKeyKind.up,
  ),
  ToolbarKey(
    id: 'down',
    label: 'Down',
    semanticLabel: 'Cursor down',
    action: RunCommand('cursorLineDown'),
    kind: ToolbarKeyKind.down,
  ),
  ToolbarKey(
    id: 'right',
    label: 'Right',
    semanticLabel: 'Cursor right',
    action: RunCommand('cursorCharRight'),
    kind: ToolbarKeyKind.right,
  ),
];

/// Pinned at the end of the row, outside the scrolling keys.
const ToolbarKey hideKeyboardKey = ToolbarKey(
  id: 'hide_keyboard',
  label: 'Hide keyboard',
  semanticLabel: 'Hide keyboard',
  action: HideKeyboard(),
  kind: ToolbarKeyKind.hideKeyboard,
);

/// Symbols for a file with no family of its own: the row of the original
/// toolbar design (docs/EDITOR_ARCHITECTURE.md §3).
const List<String> generalSymbols = [
  '{}',
  '[]',
  '()',
  ';',
  ':',
  '=',
  '>',
  '<',
  '"',
  "'",
  '|',
  '&',
  r'$',
  '#',
  '~',
  '`',
  '_',
  '/',
];

/// Each language family's symbols, most used first.
const Map<String, List<String>> familySymbols = {
  'javascript': [
    '{}',
    '()',
    '[]',
    ';',
    '=',
    '=>',
    '.',
    ',',
    ':',
    "'",
    '"',
    '`',
    r'${}',
    '<',
    '>',
    '!',
    '&',
    '|',
    '?',
    '+',
    '-',
    '*',
    '/',
    '_',
  ],
  'python': [
    ':',
    '()',
    '[]',
    '{}',
    '=',
    '.',
    ',',
    "'",
    '"',
    '#',
    '_',
    '-',
    '+',
    '*',
    '/',
    '<',
    '>',
    '!',
    '@',
    '%',
    r'\',
  ],
  'html': [
    '<',
    '>',
    '/',
    '</',
    '=""',
    '"',
    "'",
    '!',
    '-',
    '&',
    ';',
    '#',
    '{}',
    '()',
  ],
  'css': [
    '{}',
    ':',
    ';',
    '.',
    '#',
    '()',
    '-',
    '%',
    '"',
    "'",
    ',',
    '>',
    '*',
    '!',
    '@',
    '[]',
  ],
  'json': ['{}', '[]', '""', ':', ',', '-', '.', 'true', 'false', 'null'],
  'markdown': [
    '#',
    '*',
    '_',
    '`',
    '-',
    '[]',
    '()',
    '>',
    '!',
    '|',
    '~',
    '=',
  ],
};

/// The family whose symbols [language] (an editor language id) uses.
String toolbarFamilyOf(String? language) {
  const scripts = {'javascript', 'jsx', 'typescript', 'tsx'};
  if (scripts.contains(language)) {
    return 'javascript';
  }
  if (language != null && familySymbols.containsKey(language)) {
    return language;
  }
  return 'general';
}

/// The symbols [language] gets: its family's, or the general row.
List<String> symbolsFor(String? language) =>
    familySymbols[toolbarFamilyOf(language)] ?? generalSymbols;

/// How many symbols the compact preset keeps.
const int compactSymbolCount = 6;

/// At most this many keys of the user's own.
const int maxCustomKeys = 40;

/// The longest key of the user's own, in UTF-16 code units.
const int maxCustomKeyLength = 8;

/// The user's own keys from [text]: separated by spaces, duplicates
/// dropped, too-long keys skipped, and no more than [maxCustomKeys].
List<String> parseToolbarKeys(String text) {
  final seen = <String>{};
  final keys = <String>[];
  for (final token in text.split(RegExp(r'\s+'))) {
    if (keys.length == maxCustomKeys) {
      break;
    }
    if (token.isNotEmpty &&
        token.length <= maxCustomKeyLength &&
        seen.add(token)) {
      keys.add(token);
    }
  }
  return keys;
}

/// The scrolling keys of the toolbar for a document in [language] (null:
/// none open). The user's own keys, when they have any, replace the
/// language's symbols. A compact toolbar keeps Tab and the first
/// [compactSymbolCount] symbols of a preset (all of the user's own keys).
/// The hide-keyboard key is pinned apart: [hideKeyboardKey].
List<ToolbarKey> toolbarKeysFor({
  String? language,
  bool compact = false,
  String customKeys = '',
}) {
  final custom = parseToolbarKeys(customKeys);
  final symbols = custom.isNotEmpty ? custom : symbolsFor(language);
  final shown = compact && custom.isEmpty
      ? symbols.take(compactSymbolCount)
      : symbols;
  return [
    indentKey,
    if (!compact) outdentKey,
    for (final token in shown) symbolKey(token),
    if (!compact) ...[undoKey, redoKey, ...arrowKeys],
  ];
}
