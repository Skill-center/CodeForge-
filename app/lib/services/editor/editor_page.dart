/// The built editor page: app/assets/editor/, produced by
/// editor/tool/build.mjs and never committed (docs/REPOSITORY_STRUCTURE.md).
///
/// The page is verified against its manifest before anything runs it
/// (docs/SECURITY.md §3): a page that does not hash to the manifest's
/// SHA-256 is refused, whatever put it there.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/errors/failure.dart';

const String editorPageAsset = 'assets/editor/editor.html';
const String editorManifestAsset = 'assets/editor/manifest.json';
const String editorNoticesAsset = 'assets/editor/NOTICES.txt';

/// A page that matched its manifest.
final class EditorPage {
  const EditorPage({
    required this.html,
    required this.sha256,
    required this.engineVersion,
    required this.protocol,
  });

  final String html;
  final String sha256;
  final String engineVersion;
  final int protocol;
}

/// Loads the page and its manifest from [bundle] and verifies the page.
Future<Result<EditorPage>> loadEditorPage(AssetBundle bundle) async {
  final List<int> bytes;
  final String manifestText;
  try {
    final data = await bundle.load(editorPageAsset);
    bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    manifestText = await bundle.loadString(editorManifestAsset, cache: false);
  } on Object catch (error) {
    return Err(
      StorageFailure(
        'The editor page is missing from the app bundle.',
        cause: error,
      ),
    );
  }
  return verifyEditorPage(bytes, manifestText);
}

/// Checks [bytes] against the SHA-256 recorded in [manifestText].
Result<EditorPage> verifyEditorPage(List<int> bytes, String manifestText) {
  final Object? manifest;
  try {
    manifest = jsonDecode(manifestText);
  } on FormatException catch (error) {
    return Err(
      BridgeFailure('The editor manifest is not valid JSON.', cause: error),
    );
  }
  if (manifest is! Map<String, Object?>) {
    return const Err(BridgeFailure('The editor manifest is malformed.'));
  }
  final html = manifest['html'];
  final expected = html is Map<String, Object?> ? html['sha256'] : null;
  final engineVersion = manifest['engineVersion'];
  final protocol = manifest['protocol'];
  if (expected is! String || engineVersion is! String || protocol is! int) {
    return const Err(BridgeFailure('The editor manifest is malformed.'));
  }
  final actual = sha256.convert(bytes).toString();
  if (actual != expected) {
    return const Err(
      BridgeFailure('The editor page does not match its manifest.'),
    );
  }
  final String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException catch (error) {
    return Err(
      BridgeFailure('The editor page is not valid UTF-8.', cause: error),
    );
  }
  return Ok(
    EditorPage(
      html: text,
      sha256: actual,
      engineVersion: engineVersion,
      protocol: protocol,
    ),
  );
}

/// [editorLicenses] from the app's own bundle, for
/// `LicenseRegistry.addLicense` at startup.
Stream<LicenseEntry> bundledEditorLicenses() => editorLicenses(rootBundle);

/// The page's third-party notices (NOTICES.txt from editor/tool/build.mjs),
/// one entry per npm package, for the app's licenses page. The page itself
/// ships without licence comments, so these entries are what satisfies the
/// MIT notice requirement for the code inside it.
Stream<LicenseEntry> editorLicenses(AssetBundle bundle) async* {
  final String notices;
  try {
    notices = await bundle.loadString(editorNoticesAsset, cache: false);
  } on Object {
    // No page in this build (it is built, not committed): nothing to list.
    return;
  }
  yield* Stream.fromIterable(parseEditorNotices(notices));
}

/// Splits NOTICES.txt: sections divided by a line of 72 dashes, each headed
/// `name version (licence)` and followed by the licence text.
List<LicenseEntry> parseEditorNotices(String notices) {
  final entries = <LicenseEntry>[];
  for (final section in notices.split(RegExp(r'\n-{72}\n'))) {
    final trimmed = section.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    final newline = trimmed.indexOf('\n');
    final header = newline < 0 ? trimmed : trimmed.substring(0, newline);
    final text = newline < 0 ? '' : trimmed.substring(newline + 1).trim();
    entries.add(
      LicenseEntryWithLineBreaks([
        header.split(' ').first,
      ], text.isEmpty ? header : text),
    );
  }
  return entries;
}
