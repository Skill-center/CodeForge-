/// The large-file policy (Phase 2 W7; docs/EDITOR_ARCHITECTURE.md, "Large
/// files"), set from the emulator measurements of phase gate 42616081317
/// (app/ci-results/gate/large_files.txt):
///
/// * a document longer than [plainTextAboveChars] opens as plain text and
///   says so; the user can switch highlighting back on for it;
/// * a file larger than `maxTextFileBytes` (core/files/text_codec.dart) is
///   refused before it is read, with a message giving both sizes.
///
/// The decision is taken when a document gets its language (opening,
/// restoring, Save As), not while it grows or shrinks under editing.
library;

import 'languages.dart';

/// Documents longer than this, in UTF-16 code units (as the editor and its
/// protocol count text), open as plain text. Without a parser the page
/// does no highlighting, folding, syntax-aware indentation or comment
/// toggling: on the gate emulator a highlighted 1 MiB document typed 70 %
/// slower (mean) than the same text as plain text, and on a phone it was
/// four times over the typing budget (ADR-0004). The boundary is the one
/// the journal already draws for large documents
/// (DocumentJournal.smallDocumentLength).
const int plainTextAboveChars = 512 * 1024;

/// Whether a document of [chars] characters that would be highlighted as
/// [language] opens as plain text instead. Plain text has nothing to
/// switch off.
bool opensAsPlainText(int chars, String language) =>
    language != plainTextLanguage && chars > plainTextAboveChars;

/// [bytes] in megabytes of 1024 × 1024 bytes, for messages: rounded up to
/// one decimal, so a size over a limit never shows as the limit itself
/// ("10 MB", "10.1 MB").
String formatMegabytes(int bytes) {
  final tenths = (bytes * 10 / (1024 * 1024)).ceil();
  final whole = tenths ~/ 10;
  final tenth = tenths % 10;
  return tenth == 0 ? '$whole MB' : '$whole.$tenth MB';
}
