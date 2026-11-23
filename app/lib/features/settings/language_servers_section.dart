/// Settings → Linux runtime, its language servers (Phase 6 W5,
/// PHASE_6_PLAN W5): each server's version, its state, its memory while it
/// runs, and *Restart*.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../application/lsp/lsp_controller.dart';
import '../../application/providers.dart';
import '../../core/errors/failure.dart';
import '../../core/lsp/lsp_models.dart';
import '../../design_system/components/buttons.dart';
import '../../design_system/components/settings_tiles.dart';
import '../../design_system/tokens/colors.dart';
import '../../design_system/tokens/icons.dart';

/// How often the memory shown is read again: the host measures it every
/// 10 s (LanguageServerHost.kt).
const Duration serverMemoryRefresh = Duration(seconds: 10);

/// A server's line in Settings: its state, and its memory while it runs.
String languageServerLine(LspStatus status, {int? pssKib}) {
  final reason = status.reason;
  final state = switch (status.phase) {
    LspPhase.off =>
      reason == null ? 'Off: starts with a file it analyses' : 'Off: $reason',
    LspPhase.starting => 'Starting',
    LspPhase.ready => 'Ready',
    LspPhase.analysing => 'Analysing the project',
    LspPhase.restarting =>
      reason == null ? 'Restarting' : 'Restarting: $reason',
  };
  final memory = pssKib == null
      ? null
      : '${(pssKib / 1024).toStringAsFixed(1)} MB in memory';
  return memory == null || !status.running ? state : '$state · $memory';
}

class LanguageServersSection extends ConsumerStatefulWidget {
  const LanguageServersSection({super.key});

  @override
  ConsumerState<LanguageServersSection> createState() =>
      _LanguageServersSectionState();
}

class _LanguageServersSectionState
    extends ConsumerState<LanguageServersSection> {
  Map<String, int> _memory = const {};
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_readMemory());
    _timer = Timer.periodic(
      serverMemoryRefresh,
      (_) => unawaited(_readMemory()),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _readMemory() async {
    final service = ref.read(lspServiceProvider);
    if (!service.available) {
      return;
    }
    final servers = await service.servers();
    if (!mounted) {
      return;
    }
    if (servers case Ok<List<LspServerInfo>>(:final value)) {
      setState(() {
        _memory = {
          for (final info in value)
            if (info.pssKib != null) info.server: info.pssKib!,
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final state = ref.watch(lspControllerProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const CfSectionHeader('Language servers'),
        for (final server in LspServerId.values)
          () {
            final status = state.statusOf(server);
            final running =
                state.statuses.containsKey(server) && state.isOn(server);
            return CfSettingsTile(
              key: ValueKey('runtime_server_${server.id}'),
              leading: Icon(
                CfIcons.code,
                color: status.running
                    ? colors.success
                    : status.phase == LspPhase.restarting || status.canRestart
                    ? colors.warning
                    : colors.textDisabled,
              ),
              title: '${server.title} · ${server.versions}',
              subtitle: state.available || !state.isOn(server)
                  ? languageServerLine(status, pssKib: _memory[server.id])
                  : 'Not on this device',
              trailing: running
                  ? CfIconButton(
                      key: ValueKey('runtime_server_restart_${server.id}'),
                      icon: CfIcons.restartAlt,
                      tooltip: 'Restart ${server.title}',
                      onPressed: () => unawaited(
                        ref
                            .read(lspControllerProvider.notifier)
                            .restart(server),
                      ),
                    )
                  : null,
            );
          }(),
      ],
    );
  }
}
