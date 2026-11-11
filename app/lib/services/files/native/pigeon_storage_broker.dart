/// The storage broker over its Pigeon API (Phase 3 W2): the only Dart code
/// that sees the generated `StorageApi` types (docs/ARCHITECTURE.md §2,
/// rule 3; tool/lint_imports.dart enforces it). storage_api.g.dart is
/// generated from pigeons/storage_api.dart by CI.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../../../core/errors/failure.dart';
import '../../../core/logging/logger.dart';
import '../storage_broker.dart';
import 'storage_api.g.dart';

final class PigeonStorageBroker implements StorageBroker {
  PigeonStorageBroker({StorageApi? api}) : _api = api ?? StorageApi();

  final StorageApi _api;

  // Kotlin's time limits (StorageBroker.kt) plus 5 s: Kotlin answers
  // `timeout` itself; these catch a host that never answers at all.
  static const Duration _quick = Duration(seconds: 15);
  static const Duration _list = Duration(seconds: 25);
  static const Duration _transfer = Duration(seconds: 35);
  static const Duration _change = Duration(seconds: 25);
  static const Duration _copy = Duration(seconds: 125);

  @override
  Future<Result<FolderInfo?>> pickFolder({String? initialUri}) {
    // No limit: the user takes the time they need in the picker.
    return _call('pickTree', null, () async {
      final tree = await _api.pickTree(initialUri);
      return tree == null ? null : _folder(tree);
    });
  }

  @override
  Future<Result<FolderInfo>> checkFolder(String treeUri) => _call(
    'checkTree',
    _quick,
    () async => _folder(await _api.checkTree(treeUri)),
  );

  @override
  Future<Result<List<FolderGrant>>> grants() => _call(
    'listGrants',
    _quick,
    () async => [
      for (final grant in await _api.listGrants())
        FolderGrant(
          treeUri: grant.treeUri,
          read: grant.read,
          write: grant.write,
          persistedAt: DateTime.fromMillisecondsSinceEpoch(grant.persistedAtMs),
        ),
    ],
  );

  @override
  Future<Result<void>> releaseGrant(String treeUri) =>
      _call('releaseGrant', _quick, () => _api.releaseGrant(treeUri));

  @override
  Future<Result<List<BrokerEntry>>> list(String treeUri, String path) => _call(
    'list',
    _list,
    () async => [for (final entry in await _api.list(treeUri, path)) _entry(entry)],
  );

  @override
  Future<Result<BrokerEntry>> stat(String treeUri, String path) => _call(
    'stat',
    _quick,
    () async => _entry(await _api.stat(treeUri, path)),
  );

  @override
  Future<Result<BrokerRead>> read(
    String treeUri,
    String path, {
    required int maxBytes,
  }) => _call('read', _transfer, () async {
    final read = await _api.read(treeUri, path, maxBytes);
    return BrokerRead(entry: _entry(read.entry), bytes: read.bytes);
  });

  @override
  Future<Result<BrokerEntry>> write(
    String treeUri,
    String path,
    Uint8List bytes, {
    bool createNew = false,
    BrokerExpectation? expect,
  }) => _call(
    'write',
    _transfer,
    () async => _entry(
      await _api.write(
        WriteRequest(
          treeUri: treeUri,
          path: path,
          bytes: bytes,
          createNew: createNew,
          expectSize: expect?.size,
          expectModifiedMs: expect?.modified?.millisecondsSinceEpoch,
          expectSha256: expect?.sha256,
        ),
      ),
    ),
  );

  @override
  Future<Result<BrokerEntry>> create(
    String treeUri,
    String parentPath,
    String name, {
    required bool directory,
  }) => _call(
    'create',
    _change,
    () async =>
        _entry(await _api.create(treeUri, parentPath, name, directory)),
  );

  @override
  Future<Result<BrokerEntry>> rename(
    String treeUri,
    String path,
    String newName,
  ) => _call(
    'rename',
    _change,
    () async => _entry(await _api.rename(treeUri, path, newName)),
  );

  @override
  Future<Result<BrokerEntry>> move(
    String treeUri,
    String path,
    String newParentPath,
  ) => _call(
    'move',
    _copy,
    () async => _entry(await _api.move(treeUri, path, newParentPath)),
  );

  @override
  Future<Result<BrokerEntry>> copy(
    String treeUri,
    String path,
    String newParentPath,
    String newName,
  ) => _call(
    'copy',
    _copy,
    () async =>
        _entry(await _api.copy(treeUri, path, newParentPath, newName)),
  );

  @override
  Future<Result<void>> delete(String treeUri, String path) =>
      _call('delete', _change, () => _api.delete(treeUri, path));

  static FolderInfo _folder(TreeMessage tree) => FolderInfo(
    treeUri: tree.treeUri,
    name: tree.name,
    status: switch (tree.status) {
      'available' => FolderStatus.available,
      'missing' => FolderStatus.missing,
      _ => FolderStatus.accessLost,
    },
    writable: tree.writable,
  );

  static BrokerEntry _entry(EntryMessage entry) {
    final modified = entry.modifiedMs;
    return BrokerEntry(
      name: entry.name,
      isDirectory: entry.isDirectory,
      size: entry.size,
      modified: modified == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(modified),
      flags: entry.flags,
    );
  }

  /// Runs one call: its value, or a [FileFailure] for the broker's error
  /// code. Logs name the call and the code, never a path or a URI.
  static Future<Result<T>> _call<T>(
    String op,
    Duration? limit,
    Future<T> Function() call,
  ) async {
    try {
      final pending = call();
      return Ok(limit == null ? await pending : await pending.timeout(limit));
    } on PlatformException catch (error) {
      appLogger.warn(
        'storage',
        'call_failed',
        fields: {'op': op, 'code': error.code},
      );
      return Err(storageFailureFor(error.code, cause: error));
    } on TimeoutException catch (error) {
      appLogger.warn('storage', 'call_timed_out', fields: {'op': op});
      return Err(
        FileFailure(
          brokerMessage(FileProblem.timeout),
          problem: FileProblem.timeout,
          cause: error,
        ),
      );
    }
  }
}

/// The failure for a broker error code (StorageErrors.kt), or for Pigeon's
/// own codes when no host answered.
FileFailure storageFailureFor(String code, {Object? cause}) {
  if (code == 'channel-error') {
    return FileFailure(
      'Folders from shared storage need Android.',
      problem: FileProblem.unsupported,
      cause: cause,
    );
  }
  final problem = switch (code) {
    'invalid_path' => FileProblem.invalidPath,
    'not_found' => FileProblem.notFound,
    'exists' => FileProblem.exists,
    'wrong_type' => FileProblem.wrongType,
    'changed' => FileProblem.changedOnDisk,
    'too_large' => FileProblem.tooLarge,
    'access_lost' => FileProblem.accessLost,
    'missing' => FileProblem.folderMissing,
    'outside' => FileProblem.outsideWorkspace,
    'timeout' => FileProblem.timeout,
    'unsupported' => FileProblem.unsupported,
    'name_changed' => FileProblem.nameChanged,
    _ => FileProblem.io,
  };
  final message = switch (code) {
    'busy' => "The folder's storage is busy. Try again.",
    'ambiguous' => 'Several items in that folder share the name.',
    _ => brokerMessage(problem),
  };
  return FileFailure(message, problem: problem, cause: cause);
}
