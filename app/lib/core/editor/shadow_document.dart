/// The host's copy of one open document (docs/EDITOR_ARCHITECTURE.md §2).
///
/// The editor page owns the live text while the user types; the shadow
/// follows it by applying every `doc.changed` in order. It is what the host
/// saves and what the page is rebuilt from after a restart, so it must never
/// diverge silently: each change is checked against the version and length
/// it was based on, and a change that does not fit is refused untouched.
library;

import 'change_set.dart';

/// A selection in UTF-16 code units.
final class EditorSelection {
  const EditorSelection({required this.anchor, required this.head});

  final int anchor;
  final int head;

  /// The same selection, kept inside a document of [length].
  EditorSelection clampedTo(int length) => EditorSelection(
    anchor: anchor.clamp(0, length),
    head: head.clamp(0, length),
  );

  Map<String, Object?> toJson() => {'anchor': anchor, 'head': head};
}

final class ShadowDocument {
  ShadowDocument({
    required this.docId,
    required this.language,
    required String text,
    int version = 0,
    this.readOnly = false,
  }) : _text = text,
       _version = version;

  final String docId;

  /// One of `editorLanguageIds`.
  final String language;

  final bool readOnly;

  String _text;
  int _version;

  /// The last selection the page reported (`doc.viewState`).
  EditorSelection? selection;

  /// The last vertical scroll offset the page reported, in CSS pixels.
  double scrollTop = 0;

  String get text => _text;

  /// Bumped by exactly one for every batch of edits the page sends.
  int get version => _version;

  /// Applies one `doc.changed`. Returns null when applied; otherwise the
  /// reason it does not fit, and the shadow is left unchanged.
  String? applyChange({
    required int baseVersion,
    required int version,
    required int lengthBefore,
    required int lengthAfter,
    required List<Object?> changes,
  }) {
    if (baseVersion != _version) {
      return 'based on version $baseVersion, shadow is at $_version';
    }
    if (version != baseVersion + 1) {
      return 'version $version does not follow $baseVersion';
    }
    if (lengthBefore != _text.length) {
      return 'based on length $lengthBefore, shadow has ${_text.length}';
    }
    final String next;
    try {
      next = applyChanges(_text, changes);
    } on ChangeApplyException catch (error) {
      return error.message;
    }
    if (next.length != lengthAfter) {
      return 'result has length ${next.length}, expected $lengthAfter';
    }
    _text = next;
    _version = version;
    return null;
  }

  /// Takes the editor's text as authoritative, after a refused change.
  void resync({required String text, required int version}) {
    _text = text;
    _version = version;
  }
}
