/// A runtime host in memory (Phase 4 W3): it answers at once and moves
/// through the host's states synchronously, as RuntimeHub.kt does when its
/// worker is free. Installed and not started unless a test says otherwise,
/// so opening a workspace makes it ready by a warm start. Since W4 it runs
/// commands through [onExec] and answers the tool probes with [toolAnswers]
/// (every tool its pinned version unless a test says otherwise), refusing
/// both until it is ready, as the host does.
library;

import 'dart:async';

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/services/runtime/runtime_service.dart';

final class FakeRuntimeService implements RuntimeService {
  FakeRuntimeService({
    RuntimeState state = RuntimeState.installed,
    this.installFails,
    this.auditFindsOutside = false,
    this.answers = true,
  }) {
    _status = _make(state);
  }

  /// The problem every install ends in; null: installs succeed.
  RuntimeProblem? installFails;

  /// Whether the audit finds a program outside the app.
  bool auditFindsOutside;

  /// False: every call fails as if no host answered.
  bool answers;

  final StreamController<RuntimeStatus> _changes =
      StreamController<RuntimeStatus>.broadcast();
  late RuntimeStatus _status;
  int _revision = 0;

  int starts = 0;
  int reinstalls = 0;
  int audits = 0;
  int sizes = 0;
  int toolProbes = 0;

  /// Every command asked for, in order.
  final List<(String, List<String>)> commands = [];

  /// The answer to a command once the runtime is ready; exit 0 when null.
  ExecResult Function(String program, List<String> arguments)? onExec;

  /// The tool probes' answer once the runtime is ready.
  List<RuntimeTool> toolAnswers = pinnedTools;

  /// The seven probed tools, each its package's pinned version.
  static const List<RuntimeTool> pinnedTools = [
    RuntimeTool(
      tool: 'node',
      packageName: 'nodejs',
      version: '26.13.1',
      pinned: '26.13.1',
      health: ToolHealth.ok,
      millis: 140,
    ),
    RuntimeTool(
      tool: 'python',
      packageName: 'python',
      version: '3.14.10',
      pinned: '3.14.10',
      health: ToolHealth.ok,
      millis: 95,
    ),
    RuntimeTool(
      tool: 'git',
      packageName: 'git',
      version: '2.56.1',
      pinned: '2.56.1',
      health: ToolHealth.ok,
      millis: 12,
    ),
    RuntimeTool(
      tool: 'bash',
      packageName: 'bash',
      version: '5.3.9',
      pinned: '5.3.9',
      health: ToolHealth.ok,
      millis: 9,
    ),
    RuntimeTool(
      tool: 'perl',
      packageName: 'perl',
      version: '5.44.0',
      pinned: '5.44.0-1',
      health: ToolHealth.ok,
      millis: 31,
    ),
    RuntimeTool(
      tool: 'ruby',
      packageName: 'ruby',
      version: '4.0.9',
      pinned: '4.0.9',
      health: ToolHealth.ok,
      millis: 160,
    ),
    RuntimeTool(
      tool: 'rg',
      packageName: 'ripgrep',
      version: '15.2.0',
      pinned: '15.2.0',
      health: ToolHealth.ok,
      millis: 8,
    ),
  ];

  RuntimeStatus get current => _status;

  static const RuntimePayloadInfo info = RuntimePayloadInfo(
    bootstrap: '2026.02.12-r1+apt.android-7',
    packages: 112,
    core: [
      RuntimePackage('git', '2.56.1'),
      RuntimePackage('python', '3.14.10'),
      RuntimePackage('nodejs', '26.13.1'),
    ],
    resolvedAt: '2026-11-13T09:43:19Z',
  );

  static const RuntimeSize size14 = RuntimeSize(
    prefixBytes: 312000000,
    prefixFiles: 13892,
    nativeLibraryBytes: 101000000,
    apkBytes: 170000000,
  );

  RuntimeAudit get _audit => RuntimeAudit(
    outsideApk: auditFindsOutside ? 1 : 0,
    outsideScripts: 3,
    shipped: 534,
    scanned: 16210,
    truncated: false,
    millis: 412,
    report: auditFindsOutside
        ? 'exec audit: 1 binary executable outside it\n  outside: bin/rogue [ELF]\n'
        : 'exec audit: 534 shipped in the APK, 0 binary executables outside it\n',
  );

  RuntimeStatus _make(
    RuntimeState state, {
    int done = 0,
    int total = 0,
    RuntimeProblem? problem,
    String? detail,
    int? installMs,
    int? warmStartMs,
    RuntimeAudit? audit,
    bool auditing = false,
  }) {
    final unavailable = state == RuntimeState.unavailable;
    return RuntimeStatus(
      revision: ++_revision,
      state: state,
      abi: unavailable ? null : 'x86_64',
      payloadId: unavailable ? null : '0123456789abcdef',
      info: unavailable ? null : info,
      done: done,
      total: total,
      problem: unavailable ? RuntimeProblem.noPayload : problem,
      detail: detail,
      installMs: installMs ?? (state == RuntimeState.installed ? 23456 : null),
      warmStartMs: warmStartMs,
      audit: audit,
      auditing: auditing,
    );
  }

  void _emit(RuntimeStatus status) {
    _status = status;
    _changes.add(status);
  }

  Result<T> _answer<T>(T value) => answers
      ? Ok(value)
      : const Err(RuntimeFailure('The runtime needs Android.'));

  @override
  Stream<RuntimeStatus> get changes => _changes.stream;

  @override
  Future<Result<RuntimeStatus>> status() async => _answer(_status);

  @override
  Future<Result<RuntimeStatus>> start() async {
    starts++;
    if (!answers) {
      return _answer(_status);
    }
    final idle =
        _status.state == RuntimeState.notInstalled ||
        _status.state == RuntimeState.installed;
    if (!idle) {
      return Ok(_status);
    }
    final warm = _status.state == RuntimeState.installed;
    _emit(_make(RuntimeState.checking));
    if (warm) {
      _emit(
        _make(
          RuntimeState.ready,
          warmStartMs: 12,
          installMs: 23456,
          auditing: true,
        ),
      );
      _finishAudit(installMs: 23456, warmStartMs: 12);
    } else {
      _install();
    }
    return Ok(_status);
  }

  @override
  Future<Result<RuntimeStatus>> reinstall() async {
    reinstalls++;
    if (!answers) {
      return _answer(_status);
    }
    if (_status.state != RuntimeState.unavailable) {
      _install();
    }
    return Ok(_status);
  }

  @override
  Future<Result<RuntimeStatus>> audit() async {
    audits++;
    if (_status.usable) {
      _finishAudit(
        installMs: _status.installMs,
        warmStartMs: _status.warmStartMs,
      );
    }
    return _answer(_status);
  }

  @override
  Future<Result<RuntimeSize>> size() async {
    sizes++;
    return _answer(size14);
  }

  @override
  Future<Result<ExecResult>> exec(
    String program,
    List<String> arguments, {
    String? directory,
    Duration? timeout,
    int? outputLimit,
  }) async {
    commands.add((program, arguments));
    if (!_status.usable) {
      return _answer(
        ExecResult(
          failure: ExecFailure.notReady,
          detail: 'the runtime is ${_status.state.name}',
        ),
      );
    }
    final handler = onExec;
    return _answer(
      handler == null ? const ExecResult(exitCode: 0) : handler(program, arguments),
    );
  }

  @override
  Future<Result<RuntimeTools>> tools() async {
    toolProbes++;
    if (!_status.usable) {
      return _answer(
        RuntimeTools(
          tools: [
            for (final tool in pinnedTools)
              RuntimeTool(
                tool: tool.tool,
                packageName: tool.packageName,
                health: ToolHealth.unavailable,
              ),
          ],
          failure: 'the runtime is ${_status.state.name}',
        ),
      );
    }
    return _answer(RuntimeTools(tools: toolAnswers, millis: 455));
  }

  /// Sets the host to [state], with its usual fields, and tells the app.
  void moveTo(
    RuntimeState state, {
    int done = 0,
    int total = 0,
    RuntimeProblem? problem,
    String? detail,
    RuntimeAudit? audit,
    bool auditing = false,
  }) {
    _emit(
      _make(
        state,
        done: done,
        total: total,
        problem: problem,
        detail: detail,
        audit: audit,
        auditing: auditing,
      ),
    );
  }

  void _install() {
    _emit(_make(RuntimeState.installing, total: 13892));
    _emit(_make(RuntimeState.installing, done: 6946, total: 13892));
    final problem = installFails;
    if (problem != null) {
      _emit(
        _make(
          RuntimeState.failed,
          done: 6946,
          total: 13892,
          problem: problem,
          detail: 'digest differs: lib/python3.14/os.py',
        ),
      );
      return;
    }
    _emit(
      _make(
        RuntimeState.ready,
        done: 13892,
        total: 13892,
        installMs: 23456,
        auditing: true,
      ),
    );
    _finishAudit(installMs: 23456);
  }

  void _finishAudit({int? installMs, int? warmStartMs}) {
    final audit = _audit;
    _emit(
      _make(
        audit.clean ? RuntimeState.ready : RuntimeState.degraded,
        done: _status.done,
        total: _status.total,
        problem: audit.clean ? null : RuntimeProblem.outsideApk,
        detail: audit.clean ? null : '1 executables outside the APK',
        installMs: installMs,
        warmStartMs: warmStartMs,
        audit: audit,
      ),
    );
  }

  Future<void> dispose() => _changes.close();
}
