/// Short notices about files that changed outside the app (Phase 3 W5,
/// docs/EDITOR_ARCHITECTURE.md §6): a document reloaded, a tab closed
/// because its file was deleted, unsaved changes kept over a file that
/// changed. The workbench shows each as a snack bar.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One notice. [serial] tells two notices with the same words apart.
final class DiskNotice {
  const DiskNotice(this.serial, this.message);

  final int serial;
  final String message;
}

final class DiskNotices extends Notifier<DiskNotice?> {
  int _serial = 0;

  @override
  DiskNotice? build() => null;

  /// Shows [message].
  void post(String message) {
    _serial += 1;
    state = DiskNotice(_serial, message);
  }
}

final diskNoticesProvider = NotifierProvider<DiskNotices, DiskNotice?>(
  DiskNotices.new,
);
