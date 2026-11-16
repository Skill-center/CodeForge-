/// The sealed runtime as the app sees it (Phase 4 W3,
/// docs/RUNTIME_INTEGRATION.md §3): the Linux userland the APK carries,
/// installed into the app's storage when the first workspace opens, started
/// warm after that, and audited at every start. Only Kotlin can reach it
/// (android/…/runtime/RuntimeHost.kt): the Pigeon client implements this
/// contract (native/pigeon_runtime_service.dart), and tests use a fake.
library;

import 'dart:convert';

import '../../core/errors/failure.dart';

/// Where the runtime is.
enum RuntimeState {
  /// The host has not answered yet.
  unknown,

  /// This build carries no runtime for the device.
  unavailable,

  /// The build carries one, and it is not installed yet.
  notInstalled,

  /// Installed earlier, and not started in this run.
  installed,

  /// Starting: an earlier install is checked (a warm start).
  checking,

  /// Extracting and verifying the payload; [RuntimeStatus.done] of
  /// [RuntimeStatus.total] files so far.
  installing,

  /// Installed, verified and linked. The exec audit runs after every start
  /// ([RuntimeStatus.auditing], [RuntimeStatus.audit]).
  ready,

  /// Installed, but the audit found executables outside the APK, or could
  /// not finish.
  degraded,

  /// The install failed, and nothing was marked installed
  /// ([RuntimeStatus.problem]).
  failed;

  static RuntimeState fromCode(String code) => switch (code) {
    'unavailable' => unavailable,
    'notInstalled' => notInstalled,
    'installed' => installed,
    'checking' => checking,
    'installing' => installing,
    'ready' => ready,
    'degraded' => degraded,
    'failed' => failed,
    _ => unknown,
  };
}

/// Why the runtime is not usable, or not healthy (SealedRuntime.kt's
/// RuntimeProblem).
enum RuntimeProblem {
  /// This build carries no runtime for the device.
  noPayload,

  /// A file differs from its manifest, or the payload is damaged.
  corrupt,

  /// The payload lacks files its manifest lists.
  incomplete,

  /// The device could not store the runtime: no space, or a write failed.
  storage,

  /// The app lacks an executable the payload names.
  missingExecutables,

  /// The audit found executables outside the APK.
  outsideApk,

  /// The audit could not walk the whole runtime.
  auditIncomplete,

  unexpected;

  static RuntimeProblem? fromCode(String? code) => switch (code) {
    null => null,
    'no_payload' => noPayload,
    'corrupt' => corrupt,
    'incomplete' => incomplete,
    'storage' => storage,
    'missing_executables' => missingExecutables,
    'outside_apk' => outsideApk,
    'audit_incomplete' => auditIncomplete,
    _ => unexpected,
  };
}

/// One pass of t1's exec audit over the runtime.
final class RuntimeAudit {
  const RuntimeAudit({
    required this.outsideApk,
    required this.outsideScripts,
    required this.shipped,
    required this.scanned,
    required this.truncated,
    required this.millis,
    required this.report,
    this.failure,
  });

  /// Executables outside the APK: 0 is the only healthy count.
  final int outsideApk;

  /// Scripts outside the APK, which run through their interpreter.
  final int outsideScripts;

  /// Executables that come from the APK.
  final int shipped;
  final int scanned;
  final bool truncated;
  final int millis;

  /// The audit's own report, as the user can copy it.
  final String report;

  /// Why the walk could not run at all.
  final String? failure;

  bool get clean => outsideApk == 0 && !truncated && failure == null;
}

/// One package in the payload, at its pinned version.
final class RuntimePackage {
  const RuntimePackage(this.name, this.version);

  final String name;
  final String version;
}

/// What the build's payload holds (runtime/pins.py `info`).
final class RuntimePayloadInfo {
  const RuntimePayloadInfo({
    required this.bootstrap,
    required this.packages,
    required this.core,
    this.resolvedAt,
  });

  /// The Termux bootstrap's release.
  final String bootstrap;

  /// How many packages the payload carries.
  final int packages;

  /// The core set the payload was asked for, at its pinned versions.
  final List<RuntimePackage> core;

  /// When the set was resolved, as an ISO 8601 UTC time.
  final String? resolvedAt;

  /// The host's JSON; null when there is none or it cannot be read.
  static RuntimePayloadInfo? parse(String? text) {
    if (text == null || text.isEmpty) {
      return null;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) {
      return null;
    }
    final bootstrap = decoded['bootstrap'];
    if (bootstrap is! String) {
      return null;
    }
    final packages = decoded['packages'];
    final resolvedAt = decoded['resolvedAt'];
    final core = <RuntimePackage>[];
    final entries = decoded['core'];
    if (entries is List<Object?>) {
      for (final entry in entries) {
        if (entry is Map<String, Object?>) {
          final name = entry['package'];
          final version = entry['version'];
          if (name is String && version is String) {
            core.add(RuntimePackage(name, version));
          }
        }
      }
    }
    return RuntimePayloadInfo(
      bootstrap: bootstrap,
      packages: packages is int ? packages : 0,
      core: core,
      resolvedAt: resolvedAt is String ? resolvedAt : null,
    );
  }
}

/// One snapshot of the runtime.
final class RuntimeStatus {
  const RuntimeStatus({
    this.revision = 0,
    this.state = RuntimeState.unknown,
    this.abi,
    this.payloadId,
    this.info,
    this.done = 0,
    this.total = 0,
    this.problem,
    this.detail,
    this.installMs,
    this.warmStartMs,
    this.relinked,
    this.audit,
    this.auditing = false,
  });

  /// Before the host answered.
  static const RuntimeStatus initial = RuntimeStatus();

  /// The snapshot without a host to ask (tests, or a build without one).
  static const RuntimeStatus unavailable = RuntimeStatus(
    state: RuntimeState.unavailable,
    problem: RuntimeProblem.noPayload,
  );

  /// Grows with every change on the host: the newest snapshot wins.
  final int revision;
  final RuntimeState state;

  /// The payload's ABI ('arm64-v8a' or 'x86_64').
  final String? abi;

  /// The payload's identity (16 hex digits).
  final String? payloadId;

  /// What the payload holds.
  final RuntimePayloadInfo? info;

  /// While installing: files written so far, and in all.
  final int done;
  final int total;

  final RuntimeProblem? problem;

  /// What went wrong, for the report.
  final String? detail;

  /// How long this payload's install took.
  final int? installMs;

  /// How long this run's warm start took.
  final int? warmStartMs;

  /// Executable links the warm start pointed at the app's libraries again.
  final int? relinked;

  /// The last exec audit in this run.
  final RuntimeAudit? audit;

  /// The exec audit is running.
  final bool auditing;

  /// The share of the files written, while installing.
  double? get progress => total > 0 ? done / total : null;

  /// Installed and linked: ready, or degraded.
  bool get usable =>
      state == RuntimeState.ready || state == RuntimeState.degraded;

  /// Something is happening that a second request would only queue behind.
  bool get busy =>
      state == RuntimeState.checking || state == RuntimeState.installing;
}

/// What the runtime occupies on the device.
final class RuntimeSize {
  const RuntimeSize({
    required this.prefixBytes,
    required this.prefixFiles,
    required this.nativeLibraryBytes,
    required this.apkBytes,
  });

  /// The runtime's files in the app's storage.
  final int prefixBytes;
  final int prefixFiles;

  /// The executables Android extracted from the APK, and the app's own
  /// native libraries.
  final int nativeLibraryBytes;

  /// The installed APK.
  final int apkBytes;

  int get totalBytes => prefixBytes + nativeLibraryBytes + apkBytes;
}

/// The sealed runtime, behind a contract so that tests can fake it.
abstract interface class RuntimeService {
  /// Every change from now on: the state, the progress, the audit.
  Stream<RuntimeStatus> get changes;

  /// The status; the first call in a run looks whether the build carries a
  /// runtime and whether it is installed, and never installs.
  Future<Result<RuntimeStatus>> status();

  /// Starts the runtime once per run: a warm start when the build's payload
  /// is installed, an install otherwise, then the exec audit. Answers at
  /// once; the rest arrives through [changes].
  Future<Result<RuntimeStatus>> start();

  /// Removes the runtime and installs it again. Answers at once.
  Future<Result<RuntimeStatus>> reinstall();

  /// Audits the installed runtime again; answers when the audit is done.
  Future<Result<RuntimeStatus>> audit();

  /// Measures what the runtime occupies.
  Future<Result<RuntimeSize>> size();
}
