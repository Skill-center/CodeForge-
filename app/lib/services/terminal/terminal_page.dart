/// The built terminal page (Phase 5 W3): app/assets/terminal/, produced by
/// editor/tool/build_terminal.mjs and never committed
/// (docs/REPOSITORY_STRUCTURE.md).
///
/// Verified against its manifest before anything runs it, as the editor page
/// is (docs/SECURITY.md §3): a page that does not hash to the manifest's
/// SHA-256 is refused, whatever put it there.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/errors/failure.dart';
import '../editor/editor_page.dart' show parseEditorNotices;

const String terminalPageAsset = 'assets/terminal/terminal.html';
const String terminalManifestAsset = 'assets/terminal/manifest.json';
const String terminalNoticesAsset = 'assets/terminal/NOTICES.txt';

/// A terminal page that matched its manifest.
final class TerminalPage {
  const TerminalPage({
    required this.html,
    required this.sha256,
    required this.engineVersion,
    required this.protocol,
  });

  final String html;
  final String sha256;

  /// xterm.js's version.
  final String engineVersion;
  final int protocol;
}

/// Loads the page and its manifest from [bundle] and verifies the page.
Future<Result<TerminalPage>> loadTerminalPage(AssetBundle bundle) async {
  final List<int> bytes;
  final String manifestText;
  try {
    final data = await bundle.load(terminalPageAsset);
    bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    manifestText = await bundle.loadString(
      terminalManifestAsset,
      cache: false,
    );
  } on Object catch (error) {
    return Err(
      StorageFailure(
        'The terminal page is missing from the app bundle.',
        cause: error,
      ),
    );
  }
  return verifyTerminalPage(bytes, manifestText);
}

/// Checks [bytes] against the SHA-256 recorded in [manifestText].
Result<TerminalPage> verifyTerminalPage(List<int> bytes, String manifestText) {
  final Object? manifest;
  try {
    manifest = jsonDecode(manifestText);
  } on FormatException catch (error) {
    return Err(
      BridgeFailure('The terminal manifest is not valid JSON.', cause: error),
    );
  }
  if (manifest is! Map<String, Object?>) {
    return const Err(BridgeFailure('The terminal manifest is malformed.'));
  }
  final html = manifest['html'];
  final expected = html is Map<String, Object?> ? html['sha256'] : null;
  final engineVersion = manifest['engineVersion'];
  final protocol = manifest['protocol'];
  if (expected is! String || engineVersion is! String || protocol is! int) {
    return const Err(BridgeFailure('The terminal manifest is malformed.'));
  }
  final actual = sha256.convert(bytes).toString();
  if (actual != expected) {
    return const Err(
      BridgeFailure('The terminal page does not match its manifest.'),
    );
  }
  final String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException catch (error) {
    return Err(
      BridgeFailure('The terminal page is not valid UTF-8.', cause: error),
    );
  }
  return Ok(
    TerminalPage(
      html: text,
      sha256: actual,
      engineVersion: engineVersion,
      protocol: protocol,
    ),
  );
}

/// [terminalLicenses] from the app's own bundle, for
/// `LicenseRegistry.addLicense` at startup.
Stream<LicenseEntry> bundledTerminalLicenses() =>
    terminalLicenses(rootBundle);

/// The terminal page's third-party notices (NOTICES.txt from
/// editor/tool/build_terminal.mjs), one entry per npm package: the page
/// ships without licence comments, so these entries carry xterm.js's MIT
/// notice.
Stream<LicenseEntry> terminalLicenses(AssetBundle bundle) async* {
  final String notices;
  try {
    notices = await bundle.loadString(terminalNoticesAsset, cache: false);
  } on Object {
    // No page in this build (it is built, not committed): nothing to list.
    return;
  }
  yield* Stream.fromIterable(parseEditorNotices(notices));
}
