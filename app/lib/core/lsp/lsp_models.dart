/// The language servers' vocabulary (Phase 6 W4; docs/LSP_ARCHITECTURE.md):
/// the servers CodeForge ships, where one works, how it is doing, and what
/// the host and the servers say, as the app holds it. Pure Dart: the Pigeon
/// client (services/lsp/native/) converts the host's messages into these,
/// and the client (application/lsp/) speaks LSP with them.
library;

/// A language server the APK carries (runtime/language-servers/package.json,
/// ADR-0015), by the host's id for it.
enum LspServerId {
  /// Pyright, for Python.
  pyright('pyright', 'Pyright', {'python'}),

  /// typescript-language-server over TypeScript's tsserver, for JavaScript
  /// and TypeScript.
  typescript('typescript', 'TypeScript', {
    'javascript',
    'jsx',
    'typescript',
    'tsx',
  });

  const LspServerId(this.id, this.title, this.languages);

  /// The host's name for it.
  final String id;

  /// What the user reads.
  final String title;

  /// The editor's languages it analyses (core/editor/languages.dart).
  final Set<String> languages;

  /// The server for the editor's [language], or null when none analyses it.
  static LspServerId? forLanguage(String language) {
    for (final server in values) {
      if (server.languages.contains(language)) {
        return server;
      }
    }
    return null;
  }

  /// The server the host calls [id], or null for one this app does not know.
  static LspServerId? fromId(String id) {
    for (final server in values) {
      if (server.id == id) {
        return server;
      }
    }
    return null;
  }
}

/// LSP's language identifier for each of the editor's languages a server
/// analyses (the specification's list of well-known identifiers).
const Map<String, String> lspLanguageIds = {
  'python': 'python',
  'javascript': 'javascript',
  'jsx': 'javascriptreact',
  'typescript': 'typescript',
  'tsx': 'typescriptreact',
};

/// Where a server works: a project's folder by its name, or a folder's copy
/// by its id (ADR-0013), never a path (PHASE_6_PLAN W3, SECURITY T3).
final class LspWorkspace {
  const LspWorkspace.project(String folder) : project = folder, copy = null;

  const LspWorkspace.copy(String id) : project = null, copy = id;

  final String? project;
  final String? copy;

  /// The workspace folder's name, for `workspaceFolders`.
  String get name => project ?? copy ?? '';

  @override
  bool operator ==(Object other) =>
      other is LspWorkspace && other.project == project && other.copy == copy;

  @override
  int get hashCode => Object.hash(project, copy);

  @override
  String toString() =>
      project != null ? 'LspWorkspace(project)' : 'LspWorkspace(copy)';
}

/// What a server is doing, as the status strip's chip names it.
enum LspPhase {
  /// Not running: never started, stopped, or given up on ([LspStatus.reason]).
  off('off'),

  /// Starting: its process, then the handshake.
  starting('starting'),

  /// Running and answering.
  ready('ready'),

  /// Running, and working through something it reports as progress.
  analysing('analysing'),

  /// It ended unasked, and starts again after a pause.
  restarting('restarting');

  const LspPhase(this.label);

  /// The chip's word for it.
  final String label;
}

/// A server's state: its [phase], why when it is off or restarting, and
/// whether the user may start it again (the chip's *Restart*).
final class LspStatus {
  const LspStatus(this.phase, {this.reason, this.canRestart = false});

  static const LspStatus off = LspStatus(LspPhase.off);

  final LspPhase phase;

  /// Why it is off or restarting, for the chip's tooltip.
  final String? reason;

  /// It gave up (three restarts in five minutes, or a start that cannot
  /// succeed by itself): only the user's *Restart* starts it again.
  final bool canRestart;

  /// Running: its language is *analyzable* (core/editor/capabilities.dart).
  bool get running => phase == LspPhase.ready || phase == LspPhase.analysing;

  @override
  bool operator ==(Object other) =>
      other is LspStatus &&
      other.phase == phase &&
      other.reason == reason &&
      other.canRestart == canRestart;

  @override
  int get hashCode => Object.hash(phase, reason, canRestart);

  @override
  String toString() =>
      'LspStatus(${phase.label}${reason == null ? '' : ': $reason'})';
}

/// A server the host started.
final class LspStarted {
  const LspStarted({
    required this.handle,
    required this.root,
    this.bin,
    this.serverDirectory,
  });

  /// The host's handle for it.
  final int handle;

  /// Its workspace's folder as the server sees it: absolute, links resolved.
  /// The documents' URIs are built on it.
  final String root;

  /// The runtime's programs' folder (Pyright's python is there).
  final String? bin;

  /// The folder the server is installed in (tsserver's path is in it).
  final String? serverDirectory;
}

/// One whole message a server wrote, as the host read it.
final class LspIncoming {
  const LspIncoming(this.handle, this.json, {this.readUs});

  final int handle;
  final String json;

  /// When the host had read it whole, on the monotonic clock, in µs.
  final int? readUs;
}

/// A message the host wrote to a server's stdin.
final class LspWritten {
  const LspWritten({this.writtenUs});

  /// When it was written and flushed, on the monotonic clock, in µs.
  final int? writtenUs;
}

/// How a server's process ended (runtime/LspHost.kt's LspEnd).
enum LspEnd {
  /// It exited by itself.
  exited('exited'),

  /// A signal it did not ask for ended it: a crash, or the OOM killer.
  signaled('signaled'),

  /// The host stopped it: asked to, or when the runtime went.
  stopped('stopped'),

  /// The host stopped it to free memory, on Android's warning.
  memory('memory'),

  /// It wrote something that is not LSP's base protocol.
  broken('broken'),

  /// Its launcher wrote no outcome, or could not start node.
  lost('lost');

  const LspEnd(this.code);

  final String code;

  static LspEnd fromCode(String code) {
    for (final end in values) {
      if (end.code == code) {
        return end;
      }
    }
    return lost;
  }
}

/// A server's end, as the host tells it.
final class LspExit {
  const LspExit({
    required this.handle,
    required this.server,
    required this.end,
    this.exitCode,
    this.signal,
    this.detail,
    this.stderr = '',
    this.leftovers = 0,
    this.remaining = 0,
  });

  final int handle;

  /// The host's id for the server.
  final String server;
  final LspEnd end;
  final int? exitCode;
  final int? signal;
  final String? detail;

  /// The last 64 KiB it wrote to stderr.
  final String stderr;

  /// Processes of its tree ended after it, and processes that could not be.
  final int leftovers;
  final int remaining;
}

/// One running server, as the host last saw it.
final class LspServerInfo {
  const LspServerInfo({
    required this.handle,
    required this.server,
    required this.startedAtMs,
    required this.installMs,
    required this.received,
    required this.sent,
    this.project,
    this.copy,
    this.pssKib,
    this.rssKib,
    this.processes,
  });

  final int handle;
  final String server;
  final String? project;
  final String? copy;
  final int startedAtMs;
  final int installMs;
  final int received;
  final int sent;

  /// Its process tree's memory, read every 10 s, in KiB.
  final int? pssKib;
  final int? rssKib;
  final int? processes;
}

/// A position in a document: a line, and a UTF-16 offset in it (the only
/// encoding the client offers, which Dart and CodeMirror count in too).
final class LspPosition {
  const LspPosition(this.line, this.character);

  final int line;
  final int character;

  Map<String, Object?> toJson() => {'line': line, 'character': character};

  /// The position in a server's JSON, or null when it is not one.
  static LspPosition? fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      return null;
    }
    final line = json['line'];
    final character = json['character'];
    if (line is! int || character is! int || line < 0 || character < 0) {
      return null;
    }
    return LspPosition(line, character);
  }

  @override
  bool operator ==(Object other) =>
      other is LspPosition &&
      other.line == line &&
      other.character == character;

  @override
  int get hashCode => Object.hash(line, character);

  @override
  String toString() => '$line:$character';
}

/// A range in a document, [end] exclusive.
final class LspRange {
  const LspRange(this.start, this.end);

  final LspPosition start;
  final LspPosition end;

  Map<String, Object?> toJson() => {
    'start': start.toJson(),
    'end': end.toJson(),
  };

  /// The range in a server's JSON, or null when it is not one.
  static LspRange? fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      return null;
    }
    final start = LspPosition.fromJson(json['start']);
    final end = LspPosition.fromJson(json['end']);
    if (start == null || end == null) {
      return null;
    }
    return LspRange(start, end);
  }

  @override
  bool operator ==(Object other) =>
      other is LspRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => '$start-$end';
}

/// How bad a diagnostic is (LSP's DiagnosticSeverity).
enum LspSeverity {
  error(1),
  warning(2),
  information(3),
  hint(4);

  const LspSeverity(this.value);

  final int value;

  /// The severity a server sent; LSP leaves a missing one to the client,
  /// which takes it as an error.
  static LspSeverity fromValue(Object? value) {
    for (final severity in values) {
      if (severity.value == value) {
        return severity;
      }
    }
    return error;
  }
}

/// One problem a server found.
final class LspDiagnostic {
  const LspDiagnostic({
    required this.range,
    required this.severity,
    required this.message,
    this.source,
    this.code,
  });

  final LspRange range;
  final LspSeverity severity;
  final String message;

  /// Who found it: 'Pyright', 'ts', ...
  final String? source;

  /// The server's code for it, as text.
  final String? code;

  /// The diagnostic in a server's JSON, or null when it is not one.
  static LspDiagnostic? fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      return null;
    }
    final range = LspRange.fromJson(json['range']);
    final message = json['message'];
    if (range == null || message is! String) {
      return null;
    }
    final source = json['source'];
    final code = json['code'];
    return LspDiagnostic(
      range: range,
      severity: LspSeverity.fromValue(json['severity']),
      message: message,
      source: source is String ? source : null,
      code: code is String || code is int ? '$code' : null,
    );
  }
}

/// A document's diagnostics as its server last published them.
final class LspDiagnostics {
  const LspDiagnostics({
    required this.server,
    required this.path,
    required this.items,
    this.version,
  });

  final LspServerId server;

  /// The document's workspace path.
  final String path;

  /// The document's version they were found in, when the server says.
  final int? version;

  final List<LspDiagnostic> items;
}

/// A file that changed in the workspace, for `didChangeWatchedFiles`.
enum LspFileChangeType {
  created(1),
  changed(2),
  deleted(3);

  const LspFileChangeType(this.value);

  /// LSP's FileChangeType.
  final int value;
}

final class LspFileChange {
  const LspFileChange(this.path, this.type);

  /// Its workspace path.
  final String path;
  final LspFileChangeType type;

  @override
  bool operator ==(Object other) =>
      other is LspFileChange && other.path == path && other.type == type;

  @override
  int get hashCode => Object.hash(path, type);

  @override
  String toString() => '${type.name} $path';
}

/// One request's time, split into its stages (PHASE_6_PLAN W4), in µs: the
/// host's queue (from the client's send until the host had written it to the
/// server's stdin), the server (until the host had read its answer whole)
/// and the delivery (until the client had the answer). A stage is null when
/// the host did not say.
final class LspTiming {
  const LspTiming({
    required this.server,
    required this.method,
    required this.outcome,
    required this.totalUs,
    this.queueUs,
    this.serverUs,
    this.deliveryUs,
  });

  final LspServerId server;
  final String method;

  /// 'ok', 'error', or the problem's code that ended it ('timeout',
  /// 'cancelled', 'restarting', ...).
  final String outcome;
  final int totalUs;
  final int? queueUs;
  final int? serverUs;
  final int? deliveryUs;

  @override
  String toString() =>
      'LspTiming($method $outcome total=$totalUs queue=$queueUs '
      'server=$serverUs delivery=$deliveryUs)';
}
