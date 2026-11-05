/// Command palette wiring: registers real commands once per app shell.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/commands/command_registry.dart';
import 'editor_tabs_controller.dart';
import 'router.dart';
import 'settings_controller.dart';

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
  registry.register(
    CfCommand(
      id: 'editor.simulateEdit',
      title: 'Demo: Mark Active File Dirty',
      category: 'Demo',
      onExecute: () => ref.read(editorTabsProvider.notifier).simulateEdit(),
    ),
  );
  registry.register(
    CfCommand(
      id: 'editor.save',
      title: 'Demo: Save Active File',
      category: 'Demo',
      onExecute: () => ref.read(editorTabsProvider.notifier).saveActive(),
    ),
  );
  return registry;
});
