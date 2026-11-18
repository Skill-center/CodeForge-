/// The editor page's WebView floor (core/editor/webview_floor.dart).
library;

import 'dart:io';

import 'package:codeforge/core/editor/webview_floor.dart';
import 'package:flutter_test/flutter_test.dart';

/// A user agent in the form Android's WebView sends, at the version the
/// gate's API 26 image runs (69.0.3497.100, gate 44239443885).
const String _api26 =
    'Mozilla/5.0 (Linux; Android 8.0.0; wv) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Version/4.0 Chrome/69.0.3497.100 Mobile '
    'Safari/537.36';

void main() {
  test('reads the Chromium major version from a WebView user agent', () {
    expect(chromeMajorVersion(_api26), 69);
    expect(chromeMajorVersion('... Chrome/138.0.7204.179 Mobile ...'), 138);
    expect(chromeMajorVersion('Mozilla/5.0 (Linux; Android 14)'), isNull);
    expect(chromeMajorVersion(null), isNull);
  });

  test('the floor is the editor page build target', () {
    final build = File('../editor/tool/build.mjs').readAsStringSync();
    final target = RegExp(r"'chrome(\d+)'").firstMatch(build);
    expect(target, isNotNull, reason: 'build.mjs names no Chrome target');
    expect(int.parse(target!.group(1)!), minimumWebViewMajor);
  });

  test('the message names both versions and what to update', () {
    final message = webViewTooOldMessage(61);
    expect(message, contains('version 61'));
    expect(message, contains('version $minimumWebViewMajor or later'));
    expect(message, contains('Android System WebView'));
  });
}
