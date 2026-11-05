/// Editor pane, Phase 1: read-only syntax specimens of demo files with real
/// tab state. The interactive CM6 editor lands in Phase 2 behind this pane.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/editor_tabs_controller.dart';
import '../../../application/settings_controller.dart';
import '../../../design_system/components/buttons.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/workbench_chrome.dart';
import '../../../design_system/tokens/colors.dart';
import '../../../design_system/tokens/geometry.dart';
import '../../../design_system/tokens/typography.dart';
import '../../../services/settings/settings_model.dart';

class EditorPane extends ConsumerWidget {
  const EditorPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = CfColors.of(context);
    final tabs = ref.watch(editorTabsProvider);
    final settings = ref.watch(settingsControllerProvider);
    final activeDoc = tabs.activePath == null
        ? null
        : tabs.documents[tabs.activePath];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (tabs.openPaths.isNotEmpty)
          CfTabStrip(
            tabs: [
              for (final path in tabs.openPaths)
                CfTab(
                  id: path,
                  label: path.split('/').last,
                  dirty: tabs.documents[path]?.dirty ?? false,
                ),
            ],
            activeId: tabs.activePath,
            onActivate: (id) =>
                ref.read(editorTabsProvider.notifier).activate(id),
            onClose: (id) => ref.read(editorTabsProvider.notifier).close(id),
          ),
        Expanded(
          child: activeDoc == null
              ? CfEmptyState(
                  icon: Icons.code,
                  title: 'No file open',
                  message:
                      'Pick a file from the explorer to preview it here. '
                      'The interactive editor arrives in Phase 2.',
                  actionLabel: 'Open main.js',
                  onAction: () =>
                      ref.read(editorTabsProvider.notifier).open('main.js'),
                )
              : _CodeSpecimen(
                  content: activeDoc.content,
                  fontSize: settings.editorFontSize,
                ),
        ),
        if (activeDoc != null)
          Padding(
            padding: const EdgeInsets.all(CfSpacing.sm),
            child: Row(
              children: [
                const Expanded(
                  child: CfBanner(
                    message: 'Read-only preview — editing arrives in Phase 2.',
                  ),
                ),
                const SizedBox(width: CfSpacing.sm),
                CfIconButton(
                  key: const ValueKey('demo_edit'),
                  icon: Icons.edit_outlined,
                  tooltip: 'Demo: mark file dirty',
                  onPressed: () =>
                      ref.read(editorTabsProvider.notifier).simulateEdit(),
                ),
                CfIconButton(
                  key: const ValueKey('demo_save'),
                  icon: Icons.save_outlined,
                  tooltip: 'Demo: save file',
                  onPressed: activeDoc.dirty
                      ? () => ref.read(editorTabsProvider.notifier).saveActive()
                      : null,
                ),
              ],
            ),
          ),
        if (settings.toolbarPreset != ToolbarPreset.none)
          CfSymbolToolbar(
            enabled: false,
            phaseNote: 'Editor arrives in Phase 2',
          ),
      ],
    );
  }
}

/// Lightweight regex-based syntax coloring for specimens. Deliberately
/// simple: the real tokenizer ships with the CM6 editor in Phase 2.
class _CodeSpecimen extends StatelessWidget {
  const _CodeSpecimen({required this.content, required this.fontSize});

  final String content;
  final double fontSize;

  static final RegExp _pattern = RegExp(
    r'(#.*$|//.*$)|'
    r'("(?:[^"\\]|\\.)*"|'
    r"'(?:[^'\\]|\\.)*'|"
    r'`(?:[^`\\]|\\.)*`)|'
    r'\b(\d+(?:\.\d+)?)\b|'
    r'\b(function|const|let|var|return|import|export|from|for|of|if|else|'
    r'class|def|print|void|String|new|true|false|null|None|True|False)\b|'
    r'\b([A-Z][A-Za-z0-9_]*)\b',
    multiLine: true,
  );

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final base = CfTypography.code(colors, fontSize: fontSize);
    final lines = content.split('\n');
    return Container(
      color: colors.surfaceSunken,
      child: SingleChildScrollView(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(CfSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < lines.length; i++)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 36,
                      child: Text(
                        '${i + 1}',
                        textAlign: TextAlign.right,
                        style: base.copyWith(color: colors.textDisabled),
                      ),
                    ),
                    const SizedBox(width: CfSpacing.md),
                    Text.rich(_highlight(lines[i], base, colors)),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  TextSpan _highlight(String line, TextStyle base, CfColors colors) {
    final spans = <TextSpan>[];
    var last = 0;
    for (final match in _pattern.allMatches(line)) {
      if (match.start > last) {
        spans.add(TextSpan(text: line.substring(last, match.start)));
      }
      final color = match.group(1) != null
          ? colors.syntaxComment
          : match.group(2) != null
          ? colors.syntaxString
          : match.group(3) != null
          ? colors.syntaxNumber
          : match.group(4) != null
          ? colors.syntaxKeyword
          : colors.syntaxType;
      spans.add(TextSpan(text: match.group(0), style: TextStyle(color: color)));
      last = match.end;
    }
    if (last < line.length) {
      spans.add(TextSpan(text: line.substring(last)));
    }
    return TextSpan(style: base, children: spans);
  }
}
