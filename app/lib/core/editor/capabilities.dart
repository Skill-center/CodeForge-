/// What CodeForge can do with each language (spec §6.5,
/// docs/RUNTIME_INTEGRATION.md §3): every language is *editable*; one becomes
/// *analyzable* when its language server passes its smoke suite (Phase 6),
/// *compilable* with the build-tools pack, and *executable* when the sealed
/// runtime can run it. Since Phase 4 W4, JavaScript, Python and shell
/// scripts are executable once the runtime is ready. Only the flag changes
/// here: Run arrives in Phase 5.
library;

import 'languages.dart';

/// Shell scripts. The editor has no highlighting for them yet, so it shows
/// them as plain text; here they are a language of their own.
const String shellLanguage = 'shell';

/// The runtime's program for each language it can execute.
const Map<String, String> runtimeInterpreters = {
  'javascript': 'node',
  'python': 'python',
  shellLanguage: 'bash',
};

/// File extensions (lower case) of shell scripts.
const Set<String> shellExtensions = {'sh', 'bash'};

/// `#!` interpreters of shell scripts. zsh and others are not in the
/// runtime.
const Set<String> shellInterpreters = {'sh', 'bash', 'dash'};

/// What can be done with one language.
final class LanguageCapabilities {
  const LanguageCapabilities({
    required this.language,
    this.editable = true,
    this.analyzable = false,
    this.compilable = false,
    this.executable = false,
    this.interpreter,
  });

  final String language;
  final bool editable;
  final bool analyzable;
  final bool compilable;

  /// The runtime can run it now.
  final bool executable;

  /// The runtime's program that runs it, ready or not; null when the
  /// runtime cannot run the language at all.
  final String? interpreter;

  /// The runtime could run it once it is ready.
  bool get runnable => interpreter != null;
}

/// The language a file is for its capabilities: what the editor detects
/// ([languageForPath]), or [shellLanguage] for a shell script, by extension
/// or by `#!` line. Like [languageForPath], an extension the editor knows
/// as plain text (`.txt`) stays plain whatever its first line says.
String capabilityLanguageFor(String path, {String? firstLine}) {
  final natural = languageForPath(path, firstLine: firstLine);
  if (natural != plainTextLanguage) {
    return natural;
  }
  final name = path.split('/').last.toLowerCase();
  final dot = name.lastIndexOf('.');
  if (dot > 0) {
    final extension = name.substring(dot + 1);
    if (shellExtensions.contains(extension)) {
      return shellLanguage;
    }
    if (editorLanguageByExtension.containsKey(extension)) {
      return natural;
    }
  }
  if (firstLine != null &&
      shellInterpreters.contains(shebangInterpreter(firstLine))) {
    return shellLanguage;
  }
  return natural;
}

/// The capabilities of [language], with the runtime ready or not. Only the
/// runtime's readiness flips anything in Phase 4: executable, for the
/// languages in [runtimeInterpreters].
LanguageCapabilities capabilitiesOf(
  String language, {
  required bool runtimeReady,
}) {
  final interpreter = runtimeInterpreters[language];
  return LanguageCapabilities(
    language: language,
    executable: runtimeReady && interpreter != null,
    interpreter: interpreter,
  );
}

/// The languages the runtime can execute, as the user reads them.
const Map<String, String> runtimeLanguageNames = {
  'javascript': 'JavaScript',
  'python': 'Python',
  shellLanguage: 'shell scripts',
};
