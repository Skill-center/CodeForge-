/// The native-addon limitation (Phase 5 W4, PHASE_5_PLAN): the runtime
/// ships no compiler, and Android won't run a program written to the app's
/// storage. A package that builds a native addon (npm's node-gyp and
/// prebuild) or a C extension (pip) fails; this spots that in a session's
/// output so the terminal can say why, once per session. Pure Dart.
library;

/// What kind of build failed.
enum NativeAddonKind {
  /// npm: node-gyp, prebuild-install, node-pre-gyp.
  npm,

  /// pip: building a wheel with a C (or Rust) extension.
  pip,

  /// A compiler or make was called and is not there.
  compiler,
}

/// What the terminal says for [kind] (PHASE_5_PLAN W4: no compiler ships,
/// a build-tools pack comes later, Android won't execute a program written
/// to app storage; pure packages and prebuilt wheels work).
String nativeAddonMessage(NativeAddonKind kind) => switch (kind) {
  NativeAddonKind.npm =>
    'A package tried to build a native addon. The runtime has no C '
        'compiler (a build-tools pack comes later), and Android won’t run '
        'programs written to app storage. Try a pure-JavaScript package.',
  NativeAddonKind.pip =>
    'A package tried to build a C extension. The runtime has no C compiler '
        '(a build-tools pack comes later), and Android won’t run programs '
        'written to app storage. Try a pure-Python package or a prebuilt '
        'wheel.',
  NativeAddonKind.compiler =>
    'The runtime has no C compiler (a build-tools pack comes later), and '
        'Android won’t run programs written to app storage.',
};

/// Escape sequences (CSI and OSC) that colour and move output: npm colours
/// `gyp ERR!` word by word.
final RegExp _escapes = RegExp(
  r'\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]',
);

/// Words one of the patterns needs: a chunk without any skips the patterns.
final RegExp _hint = RegExp(
  r'gyp|prebuil|wheel|compiler|Python\.h|command|execute|not found',
);

const List<(NativeAddonKind, String)> _patterns = [
  (NativeAddonKind.npm, r'gyp ERR!'),
  (NativeAddonKind.npm, r'node-pre-gyp (?:ERR|WARN)'),
  (NativeAddonKind.npm, r'prebuild-install (?:warn|WARN) install'),
  (NativeAddonKind.pip, r'Failed building wheel for'),
  (NativeAddonKind.pip, r'Failed to build installable wheels'),
  (
    NativeAddonKind.pip,
    r"error: command '[^']*(?:cc|clang|g\+\+|c\+\+)' failed",
  ),
  (NativeAddonKind.pip, r"unable to execute '[^']*(?:cc|clang|g\+\+)'"),
  (NativeAddonKind.pip, r'fatal error: Python\.h'),
  (NativeAddonKind.pip, r"can't find Rust compiler"),
  (NativeAddonKind.compiler, r'C compiler cannot create executables'),
  (
    NativeAddonKind.compiler,
    r'\b(?:gcc|g\+\+|cc|c\+\+|clang|clang\+\+|make|cmake): (?:command )?not '
        r'found',
  ),
];

final List<(NativeAddonKind, RegExp)> _compiled = [
  for (final (kind, pattern) in _patterns) (kind, RegExp(pattern)),
];

/// Watches one session's output for a native build failing. Feed it the
/// output as it comes; it answers the kind once, the first time it sees
/// one, and nothing after.
final class NativeAddonDetector {
  /// The output kept from the last chunk, so a line split across chunks
  /// still matches.
  static const int carry = 256;

  String _tail = '';
  NativeAddonKind? _found;

  /// What it found, if anything.
  NativeAddonKind? get found => _found;

  /// Looks at [text], the session's next output; the kind when this is the
  /// first time one shows.
  NativeAddonKind? feed(String text) {
    if (_found != null || text.isEmpty) {
      return null;
    }
    final plain = text.contains('\x1b') ? text.replaceAll(_escapes, '') : text;
    final window = _tail + plain;
    _tail = window.length <= carry
        ? window
        : window.substring(window.length - carry);
    if (!_hint.hasMatch(window)) {
      return null;
    }
    for (final (kind, pattern) in _compiled) {
      if (pattern.hasMatch(window)) {
        return _found = kind;
      }
    }
    return null;
  }
}
