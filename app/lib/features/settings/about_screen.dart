/// About page: version, license notices for bundled fonts, log viewer.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../application/logs.dart';
import '../../core/logging/logger.dart';
import '../../core/version.dart';
import '../../design_system/components/buttons.dart';
import '../../design_system/components/settings_tiles.dart';
import '../../design_system/tokens/colors.dart';
import '../../design_system/tokens/geometry.dart';
import '../../design_system/tokens/icons.dart';
import '../../design_system/tokens/typography.dart';

class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = CfColors.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: CfIconButton(
          icon: CfIcons.arrowBack,
          tooltip: 'Back',
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/settings'),
        ),
        title: const Text('About CodeForge'),
      ),
      body: SafeArea(
        child: ListView(
          children: [
            const SizedBox(height: CfSpacing.xl),
            Center(
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: colors.surfacePanel,
                  borderRadius: BorderRadius.circular(CfRadius.lg),
                  border: Border.all(color: colors.borderSubtle),
                ),
                child: Icon(
                  CfIcons.hardware,
                  size: 32,
                  color: colors.accentEmber,
                ),
              ),
            ),
            const SizedBox(height: CfSpacing.lg),
            Center(
              child: Text(
                'CodeForge',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Center(
              child: Text(
                'v$appVersion · preview',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const CfSectionHeader('Legal'),
            CfSettingsTile(
              leading: const Icon(CfIcons.fontDownload),
              title: 'Bundled font licenses',
              subtitle:
                  'Inter & JetBrains Mono (SIL OFL 1.1), '
                  'Material Symbols (Apache 2.0)',
              trailing: const Icon(CfIcons.chevronRight, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => const _FontLicensesScreen(),
                ),
              ),
            ),
            CfSettingsTile(
              leading: const Icon(CfIcons.description),
              title: 'Open-source licenses',
              subtitle: 'Flutter and Dart packages',
              trailing: const Icon(CfIcons.chevronRight, size: 18),
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'CodeForge',
                applicationVersion: appVersion,
              ),
            ),
            const CfSectionHeader('Diagnostics'),
            CfSettingsTile(
              leading: const Icon(CfIcons.receiptLong),
              title: 'Recent logs',
              subtitle:
                  'Kept on this device, never backed up; secrets redacted',
              trailing: const Icon(CfIcons.chevronRight, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => const _LogsScreen(),
                ),
              ),
            ),
            const SizedBox(height: CfSpacing.xl),
          ],
        ),
      ),
    );
  }
}

class _FontLicensesScreen extends StatelessWidget {
  const _FontLicensesScreen();

  Future<String> _load() async {
    final inter = await rootBundle.loadString('assets/fonts/Inter-OFL.txt');
    final jbm = await rootBundle.loadString(
      'assets/fonts/JetBrainsMono-OFL.txt',
    );
    final symbols = await rootBundle.loadString(
      'assets/fonts/MaterialSymbols-LICENSE.txt',
    );
    return 'INTER\n\n$inter\n\nJETBRAINS MONO\n\n$jbm\n\n'
        'MATERIAL SYMBOLS ROUNDED\n\n'
        'The app’s icons are a subset of Material Symbols Rounded '
        '(google/material-design-icons, version 2.978), modified by '
        'CodeForge: a static instance holding only the icons the app uses.'
        '\n\n$symbols';
  }

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Font licenses')),
      body: FutureBuilder<String>(
        future: _load(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(CfSpacing.lg),
            child: SelectableText(
              snapshot.data!,
              style: CfTypography.code(colors, fontSize: 11),
            ),
          );
        },
      ),
    );
  }
}

class _LogsScreen extends StatelessWidget {
  const _LogsScreen();

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final records = appLogger.records.reversed.toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recent logs'),
        actions: [
          CfIconButton(
            icon: CfIcons.contentCopy,
            tooltip: 'Copy logs',
            onPressed: () async {
              // The log files' newest 256 KiB, earlier sessions too; this
              // session's records if the file is not running.
              final text = await recentLogText();
              await Clipboard.setData(ClipboardData(text: text));
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Logs copied')));
              }
            },
          ),
        ],
      ),
      body: records.isEmpty
          ? Center(
              child: Text(
                'No log entries yet',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(CfSpacing.md),
              itemCount: records.length,
              itemBuilder: (context, index) {
                final record = records[index];
                final color = switch (record.level) {
                  LogLevel.error => colors.danger,
                  LogLevel.warn => colors.warning,
                  LogLevel.info => colors.textPrimary,
                  LogLevel.debug => colors.textSecondary,
                };
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    record.render(),
                    style: CfTypography.code(
                      colors,
                      fontSize: 10,
                    ).copyWith(color: color),
                  ),
                );
              },
            ),
    );
  }
}
