/// The command palette: fuzzy search over the command registry.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/commands.dart';
import '../../core/commands/command_registry.dart';
import '../../design_system/tokens/colors.dart';
import '../../design_system/tokens/geometry.dart';

/// Opens the palette as a dialog. Returns after a command runs or dismiss.
Future<void> showCommandPalette(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => const _CommandPaletteDialog(),
  );
}

class _CommandPaletteDialog extends ConsumerStatefulWidget {
  const _CommandPaletteDialog();

  @override
  ConsumerState<_CommandPaletteDialog> createState() =>
      _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends ConsumerState<_CommandPaletteDialog> {
  final TextEditingController _query = TextEditingController();
  List<CfCommand> _results = const [];
  int _highlighted = 0;

  @override
  void initState() {
    super.initState();
    _results = ref.read(commandRegistryProvider).search('');
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _onQueryChanged(String query) {
    setState(() {
      _results = ref.read(commandRegistryProvider).search(query);
      _highlighted = 0;
    });
  }

  void _execute(CfCommand command) {
    Navigator.of(context).pop();
    command.onExecute();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _results.isEmpty) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _highlighted = (_highlighted + 1).clamp(0, _results.length - 1).toInt();
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _highlighted = (_highlighted - 1).clamp(0, _results.length - 1).toInt();
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      _execute(_results[_highlighted]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colors = CfColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.fromLTRB(
        CfSpacing.lg,
        CfSpacing.xxl * 2,
        CfSpacing.lg,
        CfSpacing.lg,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(CfSpacing.md),
              child: Focus(
                onKeyEvent: _onKey,
                child: TextField(
                  key: const ValueKey('palette_input'),
                  controller: _query,
                  autofocus: true,
                  onChanged: _onQueryChanged,
                  decoration: const InputDecoration(
                    hintText: 'Type a command…',
                    prefixIcon: Icon(Icons.chevron_right, size: 18),
                  ),
                ),
              ),
            ),
            Flexible(
              child: _results.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(CfSpacing.xl),
                      child: Text(
                        'No matching commands',
                        style: textTheme.bodySmall,
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _results.length,
                      itemBuilder: (context, index) {
                        final command = _results[index];
                        final selected = index == _highlighted;
                        return Material(
                          color: selected
                              ? colors.accentEmberSoft
                              : Colors.transparent,
                          child: InkWell(
                            key: ValueKey('palette_${command.id}'),
                            onTap: () => _execute(command),
                            child: Container(
                              constraints: const BoxConstraints(
                                minHeight: CfSpacing.minTouchTarget,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: CfSpacing.lg,
                                vertical: CfSpacing.md,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      command.title,
                                      style: textTheme.bodyMedium,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Text(
                                    command.category,
                                    style: textTheme.labelSmall,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
