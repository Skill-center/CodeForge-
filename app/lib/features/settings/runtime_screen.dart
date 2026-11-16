/// Settings → Linux runtime (Phase 4 W3, docs/RUNTIME_INTEGRATION.md §3):
/// where the sealed runtime is, what this build's payload holds, how long it
/// took, what it occupies, its exec audit, and Reinstall.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../application/runtime_controller.dart';
import '../../core/errors/failure.dart';
import '../../design_system/components/buttons.dart';
import '../../design_system/components/dialogs.dart';
import '../../design_system/components/settings_tiles.dart';
import '../../design_system/tokens/colors.dart';
import '../../design_system/tokens/geometry.dart';
import '../../design_system/tokens/icons.dart';
import '../../services/runtime/runtime_service.dart';

/// The runtime's state in a few words (Settings and this page's first row).
String runtimeStatusLine(RuntimeStatus status) {
  return switch (status.state) {
    RuntimeState.unknown => 'Checking…',
    RuntimeState.unavailable =>
      'Not in this build: it carries no runtime for this device',
    RuntimeState.notInstalled =>
      'Not installed yet: it installs when you open a workspace',
    RuntimeState.installed => 'Installed: it starts when you open a workspace',
    RuntimeState.checking => 'Starting…',
    RuntimeState.installing => switch (status.progress) {
      final progress? =>
        'Installing… ${(progress * 100).floor()}% '
            '(${status.done} of ${status.total} files)',
      null => 'Installing…',
    },
    RuntimeState.ready =>
      status.auditing
          ? 'Ready · checking that every program comes from the app…'
          : 'Ready · every program comes from the app',
    RuntimeState.degraded => 'Degraded: ${runtimeProblemLine(status.problem)}',
    RuntimeState.failed =>
      'Not installed: ${runtimeProblemLine(status.problem)}',
  };
}

/// What a problem means for the user.
String runtimeProblemLine(RuntimeProblem? problem) {
  return switch (problem) {
    RuntimeProblem.noPayload => 'this build carries no runtime for this device',
    RuntimeProblem.corrupt =>
      'a file did not match its checksum, so nothing was kept. '
          'Reinstall to try again',
    RuntimeProblem.incomplete =>
      "the app's copy of the runtime is missing files",
    RuntimeProblem.storage =>
      'the device could not store it. Free some space, then reinstall',
    RuntimeProblem.missingExecutables =>
      'the app is missing programs the runtime needs',
    RuntimeProblem.outsideApk =>
      'programs that did not come with the app were found',
    RuntimeProblem.auditIncomplete =>
      'the check of its programs could not finish',
    RuntimeProblem.unexpected || null => 'something went wrong',
  };
}

/// "1 program", "534 programs".
String runtimePrograms(int count) =>
    count == 1 ? '1 program' : '$count programs';

/// Bytes in decimal megabytes, as the app's size budgets are stated.
String runtimeMegabytes(int bytes) =>
    '${(bytes / 1000000).toStringAsFixed(1)} MB';

/// Everything the page shows, as text the user can copy into a report.
String runtimeReport(RuntimeStatus status) {
  final info = status.info;
  final audit = status.audit;
  final lines = <String>[
    'CodeForge runtime',
    'state: ${status.state.name}',
    if (status.abi != null) 'abi: ${status.abi}',
    if (status.payloadId != null) 'payload: ${status.payloadId}',
    if (info != null)
      'bootstrap: ${info.bootstrap} (${info.packages} packages, '
          'resolved ${info.resolvedAt ?? 'unknown'})',
    if (info != null)
      'core: ${info.core.map((p) => '${p.name} ${p.version}').join(', ')}',
    if (status.installMs != null) 'install: ${status.installMs} ms',
    if (status.warmStartMs != null) 'warm start: ${status.warmStartMs} ms',
    if (status.relinked != null) 'relinked: ${status.relinked}',
    if (status.problem != null) 'problem: ${status.problem!.name}',
    if (status.detail != null) 'detail: ${status.detail}',
    if (audit != null) ...['--- exec audit (${audit.millis} ms)', audit.report],
  ];
  return '${lines.join('\n')}\n';
}

class RuntimeScreen extends ConsumerStatefulWidget {
  const RuntimeScreen({super.key});

  @override
  ConsumerState<RuntimeScreen> createState() => _RuntimeScreenState();
}

class _RuntimeScreenState extends ConsumerState<RuntimeScreen> {
  Future<Result<RuntimeSize>>? _size;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(ref.read(runtimeControllerProvider.notifier).refresh());
    });
  }

  void _measure() {
    setState(() {
      _size = ref.read(runtimeControllerProvider.notifier).measure();
    });
  }

  Future<void> _reinstall() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => CfAlertDialog(
        key: const ValueKey('runtime_reinstall_dialog'),
        title: const Text('Reinstall the runtime?'),
        content: const Text(
          "This removes the runtime's files and installs them again from "
          'the app, which takes about a minute. Your projects and folders '
          'are not touched.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('runtime_reinstall_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('runtime_reinstall_ok'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reinstall'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => _size = null);
    await ref.read(runtimeControllerProvider.notifier).reinstall();
  }

  Future<void> _copyReport(RuntimeStatus status) async {
    await Clipboard.setData(ClipboardData(text: runtimeReport(status)));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Runtime report copied')));
  }

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final status = ref.watch(runtimeControllerProvider);
    final controller = ref.read(runtimeControllerProvider.notifier);
    final info = status.info;
    final audit = status.audit;
    final canStart =
        status.state == RuntimeState.notInstalled ||
        status.state == RuntimeState.installed;
    final canReinstall = status.usable || status.state == RuntimeState.failed;
    final stateColor = switch (status.state) {
      RuntimeState.ready => colors.success,
      RuntimeState.degraded => colors.warning,
      RuntimeState.failed => colors.danger,
      RuntimeState.installing || RuntimeState.checking => colors.info,
      _ => colors.textDisabled,
    };
    return Scaffold(
      appBar: AppBar(
        leading: CfIconButton(
          icon: CfIcons.arrowBack,
          tooltip: 'Back',
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/settings'),
        ),
        title: const Text('Linux runtime'),
        actions: [
          CfIconButton(
            key: const ValueKey('runtime_copy_report'),
            icon: CfIcons.contentCopy,
            tooltip: 'Copy the runtime report',
            onPressed: () => _copyReport(status),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          children: [
            CfSettingsTile(
              key: const ValueKey('runtime_status'),
              leading: Icon(CfIcons.memory, color: stateColor),
              title: 'Status',
              subtitle: runtimeStatusLine(status),
            ),
            if (status.state == RuntimeState.installing)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: CfSpacing.lg),
                child: LinearProgressIndicator(
                  key: const ValueKey('runtime_progress'),
                  value: status.progress,
                ),
              ),
            if (canStart || canReinstall)
              Padding(
                padding: const EdgeInsets.all(CfSpacing.lg),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: canStart
                      ? CfButton(
                          key: const ValueKey('runtime_start'),
                          label: 'Install now',
                          icon: CfIcons.playArrow,
                          onPressed: () =>
                              unawaited(controller.ensureStarted()),
                        )
                      : CfButton(
                          key: const ValueKey('runtime_reinstall'),
                          label: 'Reinstall',
                          icon: CfIcons.restartAlt,
                          variant: CfButtonVariant.tonal,
                          onPressed: _reinstall,
                        ),
                ),
              ),
            if (status.detail case final detail?
                when status.problem != null &&
                    status.problem != RuntimeProblem.noPayload)
              CfSettingsTile(
                key: const ValueKey('runtime_detail'),
                leading: const Icon(CfIcons.info),
                title: 'Details',
                subtitle: detail,
              ),
            const CfSectionHeader('Payload'),
            CfSettingsTile(
              key: const ValueKey('runtime_payload'),
              leading: const Icon(CfIcons.inventory),
              title: info == null ? 'No payload' : 'Termux ${info.bootstrap}',
              subtitle: info == null
                  ? 'This build carries no runtime for this device'
                  : '${info.packages} packages for ${status.abi}, pinned '
                        '${info.resolvedAt?.split('T').first ?? ''} · '
                        'payload ${status.payloadId ?? 'unnamed'}',
            ),
            if (info != null && info.core.isNotEmpty)
              CfSettingsTile(
                key: const ValueKey('runtime_versions'),
                leading: const Icon(CfIcons.code),
                title: 'Tools in this payload',
                subtitle: info.core
                    .map((package) => '${package.name} ${package.version}')
                    .join(' · '),
              ),
            if (status.installMs != null || status.warmStartMs != null) ...[
              const CfSectionHeader('Timing'),
              if (status.installMs case final installMs?)
                CfSettingsTile(
                  key: const ValueKey('runtime_install_time'),
                  leading: const Icon(CfIcons.timer),
                  title: 'Install',
                  subtitle:
                      '${(installMs / 1000).toStringAsFixed(1)} s to extract '
                      'and verify every file',
                ),
              if (status.warmStartMs case final warmStartMs?)
                CfSettingsTile(
                  key: const ValueKey('runtime_warm_start'),
                  leading: const Icon(CfIcons.speed),
                  title: 'Start',
                  subtitle:
                      '$warmStartMs ms, nothing extracted'
                      '${(status.relinked ?? 0) > 0 ? ' (${status.relinked} programs relinked)' : ''}',
                ),
            ],
            const CfSectionHeader('Storage'),
            _SizeTile(size: _size, onMeasure: status.usable ? _measure : null),
            const CfSectionHeader('Program check'),
            CfSettingsTile(
              key: const ValueKey('runtime_audit'),
              leading: Icon(
                audit == null
                    ? CfIcons.circle
                    : audit.clean
                    ? CfIcons.check
                    : CfIcons.warning,
                color: audit == null
                    ? colors.textDisabled
                    : audit.clean
                    ? colors.success
                    : colors.warning,
              ),
              title: audit == null
                  ? (status.auditing ? 'Checking…' : 'Not checked yet')
                  : '${runtimePrograms(audit.outsideApk)} outside the app',
              subtitle: audit == null
                  ? 'At every start, every program in the runtime is '
                        'checked to come from the app'
                  : '${runtimePrograms(audit.shipped)} from the app, '
                        '${audit.scanned} paths checked in ${audit.millis} ms'
                        '${audit.truncated ? ', stopped early' : ''}',
              trailing: status.usable && !status.auditing
                  ? CfIconButton(
                      key: const ValueKey('runtime_audit_again'),
                      icon: CfIcons.restartAlt,
                      tooltip: 'Check again',
                      onPressed: () => unawaited(controller.audit()),
                    )
                  : null,
            ),
            const SizedBox(height: CfSpacing.xl),
          ],
        ),
      ),
    );
  }
}

/// What the runtime occupies, measured on request: the walk takes a moment.
class _SizeTile extends StatelessWidget {
  const _SizeTile({required this.size, required this.onMeasure});

  final Future<Result<RuntimeSize>>? size;
  final VoidCallback? onMeasure;

  @override
  Widget build(BuildContext context) {
    final pending = size;
    if (pending == null) {
      return CfSettingsTile(
        key: const ValueKey('runtime_size'),
        leading: const Icon(CfIcons.hardware),
        title: 'Space used',
        subtitle: onMeasure == null
            ? 'Measured once the runtime is installed'
            : 'Not measured yet',
        trailing: onMeasure == null
            ? null
            : CfIconButton(
                key: const ValueKey('runtime_measure'),
                icon: CfIcons.speed,
                tooltip: 'Measure',
                onPressed: onMeasure,
              ),
      );
    }
    return FutureBuilder<Result<RuntimeSize>>(
      future: pending,
      builder: (context, snapshot) {
        final result = snapshot.data;
        return CfSettingsTile(
          key: const ValueKey('runtime_size'),
          leading: const Icon(CfIcons.hardware),
          title: switch (result) {
            null => 'Measuring…',
            Ok<RuntimeSize>(:final value) =>
              '${runtimeMegabytes(value.totalBytes)} in all',
            Err<RuntimeSize>() => 'Could not measure',
          },
          subtitle: switch (result) {
            null => 'Walking the runtime',
            Ok<RuntimeSize>(:final value) =>
              'Runtime files ${runtimeMegabytes(value.prefixBytes)} '
                  '(${value.prefixFiles} files) · programs '
                  '${runtimeMegabytes(value.nativeLibraryBytes)} · app '
                  '${runtimeMegabytes(value.apkBytes)}',
            Err<RuntimeSize>(:final failure) => failure.message,
          },
        );
      },
    );
  }
}
