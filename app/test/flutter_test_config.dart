/// Loads the bundled Inter / JetBrains Mono fonts and the two icon fonts for
/// ALL widget tests so layout and golden results reflect real glyph
/// metrics, not Ahem boxes, and bounds every widget test so a hang fails
/// fast and by name.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  if (binding is AutomatedTestWidgetsFlutterBinding) {
    // A widget test waiting on something that never comes fails in two
    // minutes and names itself, instead of holding the run for the
    // binding's default ten (`flutter test --timeout` does not reach
    // testWidgets, which passes its own timeout).
    binding.defaultTestTimeout = const Timeout(Duration(minutes: 2));
  }

  final inter = FontLoader('Inter');
  for (final file in [
    'Inter_400Regular.ttf',
    'Inter_500Medium.ttf',
    'Inter_600SemiBold.ttf',
    'Inter_700Bold.ttf',
  ]) {
    inter.addFont(rootBundle.load('assets/fonts/$file'));
  }
  await inter.load();

  final jbm = FontLoader('JetBrainsMono');
  for (final file in [
    'JetBrainsMono_400Regular.ttf',
    'JetBrainsMono_400Regular_Italic.ttf',
    'JetBrainsMono_500Medium.ttf',
    'JetBrainsMono_700Bold.ttf',
  ]) {
    jbm.addFont(rootBundle.load('assets/fonts/$file'));
  }
  await jbm.load();

  // The icon fonts (Phase 3 W4), so goldens draw the real symbols.
  for (final (family, file) in [
    ('MaterialSymbolsRounded', 'MaterialSymbolsRounded.ttf'),
    ('CfFileGlyphs', 'CfFileGlyphs.ttf'),
  ]) {
    final loader = FontLoader(family)
      ..addFont(rootBundle.load('assets/fonts/$file'));
    await loader.load();
  }

  await testMain();
}
