/// Terminal pane, Phase 1: an honest preview with the real 3-stop sheet
/// mechanics. The xterm.js + runtime bridge lands in Phases 4–5.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/providers.dart';
import '../../../design_system/tokens/colors.dart';
import '../../../design_system/tokens/geometry.dart';
import '../../../design_system/tokens/typography.dart';

class TerminalPane extends ConsumerWidget {
  const TerminalPane({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final terminal = ref.watch(terminalServiceProvider);
    return Container(
      color: colors.surfaceSunken,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 36,
            padding: const EdgeInsets.only(left: CfSpacing.md),
            decoration: BoxDecoration(
              color: colors.surfacePanel,
              border: Border(bottom: BorderSide(color: colors.borderSubtle)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.terminal,
                  size: 14,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: CfSpacing.sm),
                Text(
                  'TERMINAL',
                  style: textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (onClose != null)
                  Tooltip(
                    message: 'Hide terminal',
                    child: InkWell(
                      key: const ValueKey('terminal_close'),
                      onTap: onClose,
                      child: SizedBox(
                        width: 36,
                        height: 36,
                        child: Icon(
                          Icons.keyboard_arrow_down,
                          size: 18,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(CfSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r'codeforge:~$ ',
                    style: CfTypography.code(colors, fontSize: 13).copyWith(
                      color: colors.accentEmber,
                    ),
                  ),
                  const SizedBox(height: CfSpacing.sm),
                  Text(
                    terminal.unavailableReason,
                    style: CfTypography.code(colors, fontSize: 12).copyWith(
                      color: colors.syntaxComment,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
