/// The runtime host over its Pigeon API (Phase 4 W3): the only Dart code
/// that sees the generated `RuntimeApi` types (docs/ARCHITECTURE.md §2,
/// rule 3; tool/lint_imports.dart enforces it). runtime_api.g.dart is
/// generated from pigeons/runtime_api.dart by CI.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../../../core/errors/failure.dart';
import '../../../core/logging/logger.dart';
import '../runtime_service.dart';
import 'runtime_api.g.dart';

final class PigeonRuntimeService implements RuntimeService {
  PigeonRuntimeService({RuntimeApi? api}) : _api = api ?? RuntimeApi();

  final RuntimeApi _api;

  /// The host's snapshots, as they arrive (RuntimeEvents).
  final StreamController<RuntimeStatus> _changes =
      StreamController<RuntimeStatus>.broadcast();
  bool _hearing = false;

  // Kotlin answers a status, a start and a reinstall at once; these catch a
  // host that never answers at all. An audit walks the whole runtime
  // (ExecAudit stops itself after 120 s), and so does a size.
  static const Duration _quick = Duration(seconds: 15);
  static const Duration _walk = Duration(seconds: 150);

  // A command answers when it ends: at its own time limit at the latest,
  // plus the host's grace and kill phase. The tool probes run seven
  // commands of at most 30 s each, one after another.
  static const Duration _commandDefault = Duration(seconds: 60);
  static const Duration _commandMargin = Duration(seconds: 15);
  static const Duration _probes = Duration(seconds: 240);

  @override
  Stream<RuntimeStatus> get changes {
    _hear();
    return _changes.stream;
  }

  @override
  Future<Result<RuntimeStatus>> status() => _call(
    'status',
    _quick,
    () async => runtimeStatusFrom(await _api.status()),
  );

  @override
  Future<Result<RuntimeStatus>> start() =>
      _call('start', _quick, () async => runtimeStatusFrom(await _api.start()));

  @override
  Future<Result<RuntimeStatus>> reinstall() => _call(
    'reinstall',
    _quick,
    () async => runtimeStatusFrom(await _api.reinstall()),
  );

  @override
  Future<Result<RuntimeStatus>> audit() =>
      _call('audit', _walk, () async => runtimeStatusFrom(await _api.audit()));

  @override
  Future<Result<RuntimeSize>> size() => _call('size', _walk, () async {
    final size = await _api.size();
    return RuntimeSize(
      prefixBytes: size.prefixBytes,
      prefixFiles: size.prefixFiles,
      nativeLibraryBytes: size.nativeLibraryBytes,
      apkBytes: size.apkBytes,
    );
  });

  @override
  Future<Result<ExecResult>> exec(
    String program,
    List<String> arguments, {
    String? directory,
    Duration? timeout,
    int? outputLimit,
  }) {
    final limit = timeout ?? _commandDefault;
    return _call('exec', limit + _commandMargin, () async {
      final result = await _api.exec(
        ExecRequestMessage(
          program: program,
          arguments: arguments,
          directory: directory,
          timeoutMs: limit.inMilliseconds,
          outputLimit: outputLimit,
        ),
      );
      return execResultFrom(result);
    });
  }

  @override
  Future<Result<RuntimeTools>> tools() =>
      _call('tools', _probes, () async => runtimeToolsFrom(await _api.tools()));

  /// Stops hearing the host and closes [changes].
  Future<void> dispose() async {
    if (_hearing) {
      RuntimeEvents.setUp(null);
    }
    await _changes.close();
  }

  /// Takes the host's notices from now on, once per client.
  void _hear() {
    if (_hearing) {
      return;
    }
    _hearing = true;
    RuntimeEvents.setUp(_Notices(_changes));
  }

  /// Runs one call: its value, or a [RuntimeFailure].
  static Future<Result<T>> _call<T>(
    String op,
    Duration limit,
    Future<T> Function() call,
  ) async {
    try {
      return Ok(await call().timeout(limit));
    } on PlatformException catch (error) {
      appLogger.warn(
        'runtime',
        'call_failed',
        fields: {'op': op, 'code': error.code},
      );
      return Err(runtimeFailureFor(error));
    } on TimeoutException catch (error) {
      appLogger.warn('runtime', 'call_timed_out', fields: {'op': op});
      return Err(RuntimeFailure('The runtime did not answer.', cause: error));
    }
  }
}

/// Kotlin's snapshots, into the stream of changes.
final class _Notices implements RuntimeEvents {
  _Notices(this._changes);

  final StreamController<RuntimeStatus> _changes;

  @override
  Future<void> changed(RuntimeStatusMessage status) async {
    if (!_changes.isClosed) {
      _changes.add(runtimeStatusFrom(status));
    }
  }
}

/// A host snapshot as the app's.
RuntimeStatus runtimeStatusFrom(RuntimeStatusMessage message) {
  final audit = message.audit;
  return RuntimeStatus(
    revision: message.revision,
    state: RuntimeState.fromCode(message.state),
    abi: message.abi,
    payloadId: message.payloadId,
    info: RuntimePayloadInfo.parse(message.info),
    done: message.done,
    total: message.total,
    problem: RuntimeProblem.fromCode(message.problem),
    detail: message.detail,
    installMs: message.installMs,
    warmStartMs: message.warmStartMs,
    relinked: message.relinked,
    audit: audit == null
        ? null
        : RuntimeAudit(
            outsideApk: audit.outsideApk,
            outsideScripts: audit.outsideScripts,
            shipped: audit.shipped,
            scanned: audit.scanned,
            truncated: audit.truncated,
            millis: audit.millis,
            report: audit.report,
            failure: audit.failure,
          ),
    auditing: message.auditing,
  );
}

/// A host's command result as the app's.
ExecResult execResultFrom(ExecResultMessage message) => ExecResult(
  exitCode: message.exitCode,
  signal: message.signal,
  stdout: message.stdout,
  stderr: message.stderr,
  stdoutBytes: message.stdoutBytes,
  stderrBytes: message.stderrBytes,
  stdoutTruncated: message.stdoutTruncated,
  stderrTruncated: message.stderrTruncated,
  durationMs: message.durationMs,
  failure: ExecFailure.fromCode(message.failure),
  detail: message.detail,
  leftovers: message.leftovers,
  remaining: message.remaining,
);

/// The host's tool probes as the app's.
RuntimeTools runtimeToolsFrom(ToolsMessage message) => RuntimeTools(
  tools: [
    for (final tool in message.tools)
      RuntimeTool(
        tool: tool.tool,
        packageName: tool.packageName,
        version: tool.version,
        pinned: tool.pinned,
        health: ToolHealth.fromCode(tool.health),
        detail: tool.detail,
        millis: tool.millis,
      ),
  ],
  millis: message.millis,
  failure: message.failure,
);

/// The failure for a host's error, or for Pigeon's own when no host
/// answered.
RuntimeFailure runtimeFailureFor(PlatformException error) =>
    error.code == 'channel-error'
    ? RuntimeFailure('The runtime needs Android.', cause: error)
    : RuntimeFailure(error.message ?? 'The runtime failed.', cause: error);
