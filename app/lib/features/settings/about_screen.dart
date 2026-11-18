/// About page: version; the source offer, CodeForge's license and the
/// open-source and font licenses (Phase 5 W1); the logs.
library;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../application/logs.dart';
import '../../application/providers.dart';
import '../../core/errors/failure.dart';
import '../../core/legal/source_offer.dart';
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
              key: const ValueKey('about_source_code'),
              leading: const Icon(CfIcons.code),
              title: 'Source code',
              subtitle:
                  'Where it is, and the written offer for the Linux '
                  "userland's copyleft packages",
              trailing: const Icon(CfIcons.chevronRight, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => const _SourceOfferScreen(),
                ),
              ),
            ),
            CfSettingsTile(
              key: const ValueKey('about_codeforge_license'),
              leading: const Icon(CfIcons.info),
              title: "CodeForge's license",
              subtitle: 'Apache License 2.0',
              trailing: const Icon(CfIcons.chevronRight, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => const _CodeForgeLicenseScreen(),
                ),
              ),
            ),
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
              key: const ValueKey('about_open_source_licenses'),
              leading: const Icon(CfIcons.description),
              title: 'Open-source licenses',
              subtitle:
                  'Flutter and Dart packages, the editor page and the Linux '
                  'userland',
              trailing: const Icon(CfIcons.chevronRight, size: 18),
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'CodeForge',
                applicationVersion: appVersion,
                applicationLegalese:
                    'CodeForge is licensed under the Apache License 2.0. '
                    'The packages below keep their own licenses.',
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

/// About → Source code (Phase 5 W1): where CodeForge's source is, and the
/// written offer for the userland's copyleft packages, worded as
/// SOURCE_OFFER.md words it.
class _SourceOfferScreen extends StatelessWidget {
  const _SourceOfferScreen();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return Scaffold(
      appBar: AppBar(title: const Text('Source code')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(CfSpacing.lg),
          children: [
            for (final paragraph in sourceOfferParagraphs(appVersion))
              Padding(
                padding: const EdgeInsets.only(bottom: CfSpacing.md),
                child: SelectableText(paragraph, style: style),
              ),
          ],
        ),
      ),
    );
  }
}

/// About → CodeForge's license (Phase 5 W1): the repository's LICENSE.
class _CodeForgeLicenseScreen extends StatelessWidget {
  const _CodeForgeLicenseScreen();

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text("CodeForge's license")),
      body: FutureBuilder<String>(
        future: rootBundle.loadString(codeForgeLicenseAsset),
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

class _LogsScreen extends ConsumerWidget {
  const _LogsScreen();

  /// Save (Phase 3 W4): the log files to a file the user makes in
  /// Android's create-document picker. Backing out says nothing.
  Future<void> _save(BuildContext context, WidgetRef ref) async {
    final saved = await saveLogs(ref.read(storageBrokerProvider));
    if (!context.mounted) {
      return;
    }
    final message = switch (saved) {
      Ok(value: null) => null,
      Ok(value: '') => 'Logs saved',
      Ok(value: final String name) => 'Logs saved to $name',
      Err(:final failure) => saveLogsFailureMessage(failure),
    };
    if (message != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = CfColors.of(context);
    final records = appLogger.records.reversed.toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recent logs'),
        actions: [
          CfIconButton(
            key: const ValueKey('logs_save'),
            icon: CfIcons.save,
            tooltip: 'Save logs to a file',
            onPressed: () => _save(context, ref),
          ),
          CfIconButton(
            key: const ValueKey('logs_copy'),
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
