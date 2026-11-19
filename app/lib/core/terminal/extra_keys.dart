/// The terminal's extra-keys row (Phase 5 W3; docs/TERMINAL_ARCHITECTURE.md
/// §3): the keys a phone's keyboard lacks. The workbench draws them with
/// the editor's symbol toolbar (CfSymbolToolbar), and the page turns each
/// into the sequence the terminal's modes expect (`session.key`).
library;

/// What a key does.
enum ExtraKeyKind {
  /// Sends [ExtraKey.key]: a name from `terminalKeyNames`, or a character.
  key,

  /// Latches Ctrl for the next key, typed or tapped.
  ctrl,

  /// Latches Alt for the next key.
  alt,
}

/// One key of the row.
final class ExtraKey {
  const ExtraKey({
    required this.id,
    required this.label,
    required this.semanticLabel,
    this.kind = ExtraKeyKind.key,
    this.key,
  });

  /// Unique within the row; widget keys are `toolbar_<id>`.
  final String id;

  /// What the key shows (arrows are drawn as icons).
  final String label;

  /// What a screen reader announces.
  final String semanticLabel;

  final ExtraKeyKind kind;

  /// What a [ExtraKeyKind.key] key sends.
  final String? key;
}

/// The row, in order: the plan's keys (Esc, Ctrl, Alt, Tab, the arrows,
/// `|`, `~`, `/`), then what shells and full-screen programs often want.
const List<ExtraKey> terminalExtraKeys = [
  ExtraKey(id: 'esc', label: 'Esc', semanticLabel: 'Escape', key: 'escape'),
  ExtraKey(
    id: 'ctrl',
    label: 'Ctrl',
    semanticLabel: 'Control, for the next key',
    kind: ExtraKeyKind.ctrl,
  ),
  ExtraKey(
    id: 'alt',
    label: 'Alt',
    semanticLabel: 'Alt, for the next key',
    kind: ExtraKeyKind.alt,
  ),
  ExtraKey(id: 'tab', label: 'Tab', semanticLabel: 'Tab', key: 'tab'),
  ExtraKey(id: 'left', label: '←', semanticLabel: 'Left arrow', key: 'left'),
  ExtraKey(id: 'up', label: '↑', semanticLabel: 'Up arrow', key: 'up'),
  ExtraKey(id: 'down', label: '↓', semanticLabel: 'Down arrow', key: 'down'),
  ExtraKey(id: 'right', label: '→', semanticLabel: 'Right arrow', key: 'right'),
  ExtraKey(id: 'pipe', label: '|', semanticLabel: 'Vertical bar', key: '|'),
  ExtraKey(id: 'tilde', label: '~', semanticLabel: 'Tilde', key: '~'),
  ExtraKey(id: 'slash', label: '/', semanticLabel: 'Slash', key: '/'),
  ExtraKey(id: 'dash', label: '-', semanticLabel: 'Minus', key: '-'),
  ExtraKey(id: 'home', label: 'Home', semanticLabel: 'Home', key: 'home'),
  ExtraKey(id: 'end', label: 'End', semanticLabel: 'End', key: 'end'),
  ExtraKey(id: 'pgup', label: 'PgUp', semanticLabel: 'Page up', key: 'pageUp'),
  ExtraKey(
    id: 'pgdn',
    label: 'PgDn',
    semanticLabel: 'Page down',
    key: 'pageDown',
  ),
];
