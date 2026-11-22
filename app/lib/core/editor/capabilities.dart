/// What CodeForge can do with each language (spec §6.5,
/// docs/RUNTIME_INTEGRATION.md §3): every language is *editable*; one is
/// *analyzable* while its language server is installed, verified and running
/// (Phase 6 W4: Python with Pyright, JavaScript and TypeScript with the
/// TypeScript server), *compilable* with the build-tools pack, and
/// *executable* when the sealed runtime can run it. Since Phase 4 W4, JavaScript, Python and shell
/// scripts are executable once the runtime is ready; Ruby and Perl joined
/// them with Run (Phase 5 W4, core/run/run_commands.dart).
library;

import 'languages.dart';

/// Shell scripts. The editor has no highlighting for them yet, so it shows
/// them as plain text; here they are a language of their own.
const String shellLanguage = 'shell';

/// Ruby and Perl, which the runtime carries (Phase 4 W4's tools). Like shell
/// scripts, the editor shows them as plain text.
const String rubyLanguage = 'ruby';
const String perlLanguage = 'perl';

/// The languages the runtime runs that the editor shows as plain text: the
/// status strip names them itself.
const Set<String> runtimeOnlyLanguages = {
  shellLanguage,
  rubyLanguage,
  perlLanguage,
};

/// The runtime's program for each language it can execute.
const Map<String, String> runtimeInterpreters = {
  'javascript': 'node',
  'python': 'python',
  shellLanguage: 'bash',
  rubyLanguage: 'ruby',
  perlLanguage: 'perl',
};

/// File extensions (lower case) of Ruby and Perl scripts.
const Map<String, String> scriptLanguageByExtension = {
  'rb': rubyLanguage,
  'pl': perlLanguage,
};

/// `#!` interpreters of Ruby and Perl scripts.
const Map<String, String> scriptLanguageByInterpreter = {
  'ruby': rubyLanguage,
  'perl': perlLanguage,
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
/// ([languageForPath]), or one of [runtimeOnlyLanguages] for a shell, Ruby
/// or Perl script, by extension or by `#!` line. Like [languageForPath], an
/// extension the editor knows as plain text (`.txt`) stays plain whatever
/// its first line says.
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
    final script = scriptLanguageByExtension[extension];
    if (script != null) {
      return script;
    }
    if (editorLanguageByExtension.containsKey(extension)) {
      return natural;
    }
  }
  if (firstLine != null) {
    final interpreter = shebangInterpreter(firstLine);
    if (shellInterpreters.contains(interpreter)) {
      return shellLanguage;
    }
    final script = scriptLanguageByInterpreter[interpreter];
    if (script != null) {
      return script;
    }
  }
  return natural;
}

/// The capabilities of [language], with the runtime ready or not, and its
/// language server running or not ([analyzable], Phase 6 W4). The
/// runtime's readiness flips executable, for the languages in
/// [runtimeInterpreters].
LanguageCapabilities capabilitiesOf(
  String language, {
  required bool runtimeReady,
  bool analyzable = false,
}) {
  final interpreter = runtimeInterpreters[language];
  return LanguageCapabilities(
    language: language,
    analyzable: analyzable,
    executable: runtimeReady && interpreter != null,
    interpreter: interpreter,
  );
}

/// The languages the runtime can execute, as the user reads them.
const Map<String, String> runtimeLanguageNames = {
  'javascript': 'JavaScript',
  'python': 'Python',
  shellLanguage: 'shell scripts',
  rubyLanguage: 'Ruby',
  perlLanguage: 'Perl',
};
