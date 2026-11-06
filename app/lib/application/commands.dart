/// Command palette wiring: registers real commands once per app shell.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/commands/command_registry.dart';
import 'router.dart';
import 'settings_controller.dart';
import 'workbench_intents.dart';

final commandRegistryProvider = Provider<CommandRegistry>((ref) {
  ref.keepAlive();
  final registry = CommandRegistry();
  final router = ref.read(routerProvider);

  void go(String route) => router.go(route);

  registry.register(
    CfCommand(
      id: 'nav.home',
      title: 'Go to Home',
      category: 'Navigate',
      onExecute: () => go('/'),
    ),
  );
  registry.register(
    CfCommand(
      id: 'nav.workspace',
      title: 'Open Demo Workspace',
      category: 'Navigate',
      onExecute: () => go('/workspace'),
    ),
  );
  registry.register(
    CfCommand(
      id: 'nav.settings',
      title: 'Open Settings',
      category: 'Navigate',
      onExecute: () => go('/settings'),
    ),
  );
  registry.register(
    CfCommand(
      id: 'nav.appearance',
      title: 'Open Appearance Settings',
      category: 'Navigate',
      onExecute: () => go('/settings/appearance'),
    ),
  );
  registry.register(
    CfCommand(
      id: 'theme.dark',
      title: 'Use Dark Theme',
      category: 'Appearance',
      onExecute: () => ref
          .read(settingsControllerProvider.notifier)
          .setThemeMode(ThemeMode.dark),
    ),
  );
  registry.register(
    CfCommand(
      id: 'theme.light',
      title: 'Use Light Theme',
      category: 'Appearance',
      onExecute: () => ref
          .read(settingsControllerProvider.notifier)
          .setThemeMode(ThemeMode.light),
    ),
  );
  registry.register(
    CfCommand(
      id: 'theme.system',
      title: 'Follow System Theme',
      category: 'Appearance',
      onExecute: () => ref
          .read(settingsControllerProvider.notifier)
          .setThemeMode(ThemeMode.system),
    ),
  );
  // File and tab commands need the workbench screen (dialogs, prompts):
  // they fire intents it carries out.
  for (final (id, title, category, intent) in const [
    ('file.new', 'New File…', 'File', WorkbenchIntent.newFile),
    ('editor.save', 'Save File', 'File', WorkbenchIntent.save),
    ('file.saveAs', 'Save As…', 'File', WorkbenchIntent.saveAs),
    ('editor.close', 'Close Editor', 'View', WorkbenchIntent.closeEditor),
    (
      'editor.closeOthers',
      'Close Other Editors',
      'View',
      WorkbenchIntent.closeOtherEditors,
    ),
    ('editor.next', 'Next Editor', 'View', WorkbenchIntent.nextEditor),
    (
      'editor.previous',
      'Previous Editor',
      'View',
      WorkbenchIntent.previousEditor,
    ),
  ]) {
    registry.register(
      CfCommand(
        id: id,
        title: title,
        category: category,
        onExecute: () => ref.read(workbenchIntentsProvider).fire(intent),
      ),
    );
  }
  return registry;
});
