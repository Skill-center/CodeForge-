/// The sealed runtime for the app (Phase 4 W3, docs/RUNTIME_INTEGRATION.md
/// §3): what the host last said, the newest snapshot winning, and the
/// requests the workbench and Settings → Runtime make. The install is lazy:
/// the workbench starts the runtime when a workspace opens, and the editor
/// works on its files meanwhile.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/failure.dart';
import '../core/logging/logger.dart';
import '../services/runtime/runtime_service.dart';
import 'providers.dart';

final class RuntimeController extends Notifier<RuntimeStatus> {
  @override
  RuntimeStatus build() {
    final service = ref.watch(runtimeServiceProvider);
    final subscription = service.changes.listen(_take);
    ref.onDispose(() => unawaited(subscription.cancel()));
    unawaited(refresh());
    return RuntimeStatus.initial;
  }

  /// Asks the host where the runtime is (never installs).
  Future<void> refresh() async {
    _answer('status', await ref.read(runtimeServiceProvider).status());
  }

  /// Starts the runtime, once per run: what opening a workspace does. A
  /// runtime that is starting, started, absent or failed is left as it is;
  /// a failed install waits for [reinstall].
  Future<void> ensureStarted() async {
    final now = state.state;
    if (now != RuntimeState.unknown &&
        now != RuntimeState.notInstalled &&
        now != RuntimeState.installed) {
      return;
    }
    _answer('start', await ref.read(runtimeServiceProvider).start());
  }

  /// Removes the runtime and installs it again (Settings → Runtime).
  Future<void> reinstall() async {
    if (state.state == RuntimeState.installing ||
        state.state == RuntimeState.unavailable) {
      return;
    }
    appLogger.info('runtime', 'reinstall_requested');
    _answer('reinstall', await ref.read(runtimeServiceProvider).reinstall());
  }

  /// Runs the exec audit again (Settings → Runtime).
  Future<void> audit() async {
    _answer('audit', await ref.read(runtimeServiceProvider).audit());
  }

  /// Measures what the runtime occupies (Settings → Runtime): a walk of
  /// its files, so only on request.
  Future<Result<RuntimeSize>> measure() =>
      ref.read(runtimeServiceProvider).size();

  void _answer(String op, Result<RuntimeStatus> result) {
    if (!ref.mounted) {
      return;
    }
    switch (result) {
      case Ok<RuntimeStatus>(:final value):
        _take(value);
      case Err<RuntimeStatus>(:final failure):
        appLogger.warn(
          'runtime',
          'request_failed',
          fields: {'op': op, 'error': failure.message},
        );
        // No host to ask (or one that never answers): no runtime here.
        if (state.state == RuntimeState.unknown) {
          state = RuntimeStatus.unavailable;
        }
    }
  }

  /// Takes a snapshot unless a newer one is already in.
  void _take(RuntimeStatus status) {
    if (!ref.mounted || status.revision < state.revision) {
      return;
    }
    final before = state;
    state = status;
    _log(before, status);
  }

  /// Each state, problem and audit once in the app's log.
  void _log(RuntimeStatus before, RuntimeStatus after) {
    final auditDone = before.auditing && !after.auditing;
    if (before.state == after.state &&
        before.problem == after.problem &&
        !auditDone) {
      return;
    }
    final audit = after.audit;
    appLogger.info(
      'runtime',
      'state',
      fields: {
        'state': after.state.name,
        'abi': ?after.abi,
        'payload': ?after.payloadId,
        'problem': ?after.problem?.name,
        'installMs': ?after.installMs,
        'warmStartMs': ?after.warmStartMs,
        'outsideApk': ?audit?.outsideApk,
        'auditMs': ?audit?.millis,
      },
    );
  }
}

final runtimeControllerProvider =
    NotifierProvider<RuntimeController, RuntimeStatus>(RuntimeController.new);
