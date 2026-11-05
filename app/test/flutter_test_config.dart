/// Loads the bundled Inter / JetBrains Mono fonts for ALL widget tests so
/// layout and golden results reflect real glyph metrics, not Ahem boxes.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  await testMain();
}
