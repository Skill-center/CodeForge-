/// The Phase 2 W3 engine benchmark pages (editor/tool/build_bench.mjs):
/// CodeMirror 6 and Monaco at the same scope, one self-contained page each.
///
/// Only builds whose CI step built them bundle the pages: the phase gate's
/// debug APK and the phone profile APK. Everywhere else assets/editor_bench/
/// holds just its README, and the benchmark screen says so.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../core/errors/failure.dart';
import '../editor_page.dart';

const String benchAssetDir = 'assets/editor_bench/';
const String benchManifestAsset = '${benchAssetDir}manifest.json';
const String benchNoticesAsset = '${benchAssetDir}NOTICES.txt';

/// One page as the manifest lists it.
@immutable
final class BenchPageInfo {
  const BenchPageInfo({
    required this.engine,
    required this.engineVersion,
    required this.file,
    required this.bytes,
    required this.gzipBytes,
    required this.sha256,
  });

  final String engine;
  final String engineVersion;
  final String file;
  final int bytes;
  final int gzipBytes;
  final String sha256;

  Map<String, Object?> toJson() => {
    'engine': engine,
    'engineVersion': engineVersion,
    'bytes': bytes,
    'gzipBytes': gzipBytes,
    'sha256': sha256,
  };
}

/// A page whose bytes matched the manifest.
@immutable
final class BenchPage {
  const BenchPage({required this.info, required this.html});

  final BenchPageInfo info;
  final String html;
}

/// The pages listed in manifest.json, in manifest order.
Result<List<BenchPageInfo>> parseBenchManifest(String text) {
  const malformed = BridgeFailure('The benchmark manifest is malformed.');
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (error) {
    return Err(
      BridgeFailure('The benchmark manifest is not valid JSON.', cause: error),
    );
  }
  if (decoded is! Map<String, Object?>) {
    return const Err(malformed);
  }
  final pages = decoded['pages'];
  if (pages is! Map<String, Object?>) {
    return const Err(malformed);
  }
  final infos = <BenchPageInfo>[];
  for (final MapEntry(key: engine, value: page) in pages.entries) {
    if (page is! Map<String, Object?>) {
      return const Err(malformed);
    }
    final file = page['file'];
    final version = page['engineVersion'];
    final bytes = page['bytes'];
    final gzipBytes = page['gzipBytes'];
    final hash = page['sha256'];
    if (file is! String ||
        version is! String ||
        bytes is! int ||
        gzipBytes is! int ||
        hash is! String ||
        file.contains('/')) {
      return const Err(malformed);
    }
    infos.add(
      BenchPageInfo(
        engine: engine,
        engineVersion: version,
        file: file,
        bytes: bytes,
        gzipBytes: gzipBytes,
        sha256: hash,
      ),
    );
  }
  return Ok(infos);
}

/// The pages this build bundles: an empty list when it bundles none.
Future<Result<List<BenchPageInfo>>> loadBenchManifest(
  AssetBundle bundle,
) async {
  final String text;
  try {
    text = await bundle.loadString(benchManifestAsset, cache: false);
  } on Object {
    return const Ok(<BenchPageInfo>[]);
  }
  return parseBenchManifest(text);
}

/// Loads a page and checks it against its manifest entry.
Future<Result<BenchPage>> loadBenchPage(
  AssetBundle bundle,
  BenchPageInfo info,
) async {
  final List<int> bytes;
  try {
    final data = await bundle.load('$benchAssetDir${info.file}');
    bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } on Object catch (error) {
    return Err(
      StorageFailure(
        'The ${info.engine} benchmark page is missing from the app bundle.',
        cause: error,
      ),
    );
  }
  return verifyBenchPage(info, bytes);
}

Result<BenchPage> verifyBenchPage(BenchPageInfo info, List<int> bytes) {
  if (sha256.convert(bytes).toString() != info.sha256) {
    return Err(
      BridgeFailure(
        'The ${info.engine} benchmark page does not match its manifest.',
      ),
    );
  }
  try {
    return Ok(BenchPage(info: info, html: utf8.decode(bytes)));
  } on FormatException catch (error) {
    return Err(
      BridgeFailure(
        'The ${info.engine} benchmark page is not valid UTF-8.',
        cause: error,
      ),
    );
  }
}

/// The benchmark pages' third-party notices, for
/// `LicenseRegistry.addLicense` (nothing when the build has no pages).
Stream<LicenseEntry> bundledBenchLicenses() => benchLicenses(rootBundle);

Stream<LicenseEntry> benchLicenses(AssetBundle bundle) async* {
  final String notices;
  try {
    notices = await bundle.loadString(benchNoticesAsset, cache: false);
  } on Object {
    return;
  }
  yield* Stream.fromIterable(parseEditorNotices(notices));
}
