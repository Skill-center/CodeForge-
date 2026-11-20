/// Import as project (Phase 5 W4, ADR-0013's option (b)), from Home's
/// recents and from a folder's explorer: the project's name, the copy as it
/// goes with Cancel, then the new project opens. The folder stays as it is
/// and in the recents.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../application/providers.dart';
import '../../application/recents_controller.dart';
import '../../application/workspace_switcher.dart';
import '../../core/errors/failure.dart';
import '../../core/files/workspace_location.dart';
import '../../services/files/storage_broker.dart';
import 'home_dialogs.dart';

/// What the import left out, in a sentence, or null when it took all.
String? importLeftOutNote(CopySummary summary) {
  final left = summary.leftOut + summary.unreadable;
  if (left == 0) {
    return null;
  }
  return left == 1
      ? 'The import left out 1 file (too large, unreadable, or past the '
            'limits).'
      : 'The import left out $left files (too large, unreadable, or past '
            'the limits).';
}

/// Imports [folder] as a project and opens it. [tell] says what went wrong
/// or what was left out; [opened] runs once the new project is open.
/// False when nothing was imported.
Future<bool> importFolderAsProject(
  BuildContext context,
  WidgetRef ref,
  FolderLocation folder, {
  required void Function(String message) tell,
  required VoidCallback opened,
}) async {
  final taken =
      (await ref.read(projectStorageProvider).folders()).valueOrNull ??
      const <String>[];
  if (!context.mounted) {
    return false;
  }
  final name = await askImportName(
    context,
    folderName: folder.name,
    taken: taken,
  );
  if (!context.mounted || name == null) {
    return false;
  }
  final broker = ref.read(storageBrokerProvider);
  final switcher = ref.read(workspaceSwitcherProvider);
  var cancelled = false;
  final imported = await showImportProgress(
    context,
    folderName: folder.name,
    work: switcher.importFolder(folder, name),
    progress: broker.copyProgress.where((p) => p.copyId == importCopyId),
    onCancel: () {
      cancelled = true;
      unawaited(broker.cancelCopy(importCopyId));
    },
  );
  if (!context.mounted) {
    return false;
  }
  switch (imported) {
    case Err(:final failure):
      tell(
        cancelled
            ? 'The import was cancelled; nothing was kept.'
            : failure.message,
      );
      unawaited(ref.read(recentsProvider.notifier).refresh());
      return false;
    case Ok(:final value):
      final result = await switcher.open(value.project);
      unawaited(ref.read(recentsProvider.notifier).refresh());
      if (!context.mounted) {
        return true;
      }
      switch (result) {
        case Err(:final failure):
          tell(failure.message);
        case Ok():
          final note = importLeftOutNote(value.summary);
          if (note != null) {
            tell(note);
          }
          opened();
      }
      return true;
  }
}
