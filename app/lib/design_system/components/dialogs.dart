/// Dialog components: an alert dialog that fits beside the soft keyboard.
library;

import 'package:material_ui/material_ui.dart';

import '../tokens/geometry.dart';

/// A Material [AlertDialog] that keeps fitting while the soft keyboard
/// leaves a short screen little room, as on a phone in landscape (Phase 2
/// gate G8: no overflow with the keyboard up). Its title and content
/// scroll above the actions instead of overflowing them, and when the room
/// is short the margins above and below, and the space under the actions,
/// shrink to keep a text field in view. With room to spare it is a plain
/// AlertDialog.
class CfAlertDialog extends StatelessWidget {
  const CfAlertDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
  });

  final Widget title;
  final Widget content;
  final List<Widget> actions;

  /// Below this height beside the keyboard the dialog goes compact: phones
  /// and tablets in landscape with the keyboard up have less, phones in
  /// portrait more.
  static const double compactBelow = 480;

  @override
  Widget build(BuildContext context) {
    final room =
        MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom;
    final compact = room < compactBelow;
    return AlertDialog(
      scrollable: true,
      insetPadding: compact
          ? const EdgeInsets.symmetric(horizontal: 40, vertical: CfSpacing.sm)
          : null,
      actionsPadding: compact
          ? const EdgeInsets.fromLTRB(
              CfSpacing.xl,
              0,
              CfSpacing.xl,
              CfSpacing.sm,
            )
          : null,
      title: title,
      content: content,
      actions: actions,
    );
  }
}
