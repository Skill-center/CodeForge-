/// An in-memory storage broker for tests (Phase 3 W2): folders keyed by
/// tree URI, each a tree of files and folders, with the grants, the folder
/// statuses and the picker's answers under the test's control. It follows
/// the Kotlin broker's rules where the file service depends on them: a
/// write checks the stamp it was given (time and size, or a SHA-256 when
/// the folder gives no time), new names are compared without case, and a
/// missing folder or a lost grant fails every call.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/services/files/storage_broker.dart';
import 'package:crypto/crypto.dart';

final class FakeFolder {
  FakeFolder(this.name);

  String name;

  /// Deleted, as another app might: every call fails as missing.
  bool missing = false;

  /// The provider reports no modification times (Android's own, for files
  /// dated before 1971).
  bool timeless = false;

  final Map<String, Uint8List> files = {};
  final Set<String> folders = {};
  final Map<String, DateTime> modified = {};

  int _clock = 0;

  DateTime tick() {
    _clock += 1;
    return DateTime.fromMillisecondsSinceEpoch(1700000000000 + _clock * 1000);
  }

  void putText(String path, String text) => putBytes(path, utf8.encode(text));

  void putBytes(String path, List<int> bytes) {
    for (var parent = _parentOf(path); parent.isNotEmpty;) {
      folders.add(parent);
      parent = _parentOf(parent);
    }
    files[path] = Uint8List.fromList(bytes);
    modified[path] = tick();
  }

  String? text(String path) {
    final bytes = files[path];
    return bytes == null ? null : utf8.decode(bytes);
  }

  bool exists(String path) =>
      path.isEmpty || files.containsKey(path) || folders.contains(path);

  BrokerEntry entry(String path) {
    final isDirectory = path.isEmpty || folders.contains(path);
    return BrokerEntry(
      name: path.isEmpty ? name : _nameOf(path),
      isDirectory: isDirectory,
      size: isDirectory ? null : files[path]!.length,
      modified: isDirectory || timeless ? null : modified[path],
      flags: 15,
    );
  }

  List<String> childrenOf(String path) {
    final prefix = path.isEmpty ? '' : '$path/';
    return [
      for (final p in {...folders, ...files.keys})
        if (p.startsWith(prefix) && !p.substring(prefix.length).contains('/'))
          p,
    ];
  }
}

final class FakeStorageBroker implements StorageBroker {
  final Map<String, FakeFolder> trees = {};
  final Set<String> granted = {};

  /// What the picker answers next: a tree URI, or null when the user backs
  /// out. Picking grants the tree.
  String? pickAnswer;

  /// Where each picker call asked to start.
  final List<String?> pickStarts = [];

  /// Every call, by name, in order.
  final List<String> calls = [];

  /// Fails the next write with this, as a provider error would.
  FileFailure? failNextWrite;

  FakeFolder addTree(
    String treeUri,
    String name, {
    Map<String, String> files = const {},
    bool grant = true,
  }) {
    final folder = FakeFolder(name);
    for (final MapEntry(:key, :value) in files.entries) {
      folder.putText(key, value);
    }
    trees[treeUri] = folder;
    if (grant) {
      granted.add(treeUri);
    }
    return folder;
  }

  @override
  Future<Result<FolderInfo?>> pickFolder({String? initialUri}) async {
    calls.add('pickFolder');
    pickStarts.add(initialUri);
    final uri = pickAnswer;
    if (uri == null) {
      return const Ok(null);
    }
    granted.add(uri);
    return Ok(_info(uri));
  }

  @override
  Future<Result<FolderInfo>> checkFolder(String treeUri) async {
    calls.add('checkFolder');
    return Ok(_info(treeUri));
  }

  @override
  Future<Result<List<FolderGrant>>> grants() async {
    calls.add('grants');
    return Ok([
      for (final uri in granted)
        FolderGrant(
          treeUri: uri,
          read: true,
          write: true,
          persistedAt: DateTime(2026),
        ),
    ]);
  }

  @override
  Future<Result<void>> releaseGrant(String treeUri) async {
    calls.add('releaseGrant');
    granted.remove(treeUri);
    return const Ok(null);
  }

  @override
  Future<Result<List<BrokerEntry>>> list(String treeUri, String path) async {
    calls.add('list');
    final folder = _folder(treeUri);
    if (folder is Err<FakeFolder>) {
      return Err(folder.failure);
    }
    final tree = folder.valueOrNull!;
    if (!tree.exists(path)) {
      return _fail(FileProblem.notFound);
    }
    if (tree.files.containsKey(path)) {
      return _fail(FileProblem.wrongType);
    }
    return Ok([for (final child in tree.childrenOf(path)) tree.entry(child)]);
  }

  @override
  Future<Result<BrokerEntry>> stat(String treeUri, String path) async {
    calls.add('stat');
    final folder = _folder(treeUri);
    if (folder is Err<FakeFolder>) {
      return Err(folder.failure);
    }
    final tree = folder.valueOrNull!;
    return tree.exists(path)
        ? Ok(tree.entry(path))
        : _fail(FileProblem.notFound);
  }

  @override
  Future<Result<BrokerRead>> read(
    String treeUri,
    String path, {
    required int maxBytes,
  }) async {
    calls.add('read');
    final folder = _folder(treeUri);
    if (folder is Err<FakeFolder>) {
      return Err(folder.failure);
    }
    final tree = folder.valueOrNull!;
    final bytes = tree.files[path];
    if (bytes == null) {
      return _fail(
        tree.exists(path) ? FileProblem.wrongType : FileProblem.notFound,
      );
    }
    if (bytes.length > maxBytes) {
      return _fail(FileProblem.tooLarge);
    }
    return Ok(BrokerRead(entry: tree.entry(path), bytes: bytes));
  }

  @override
  Future<Result<BrokerEntry>> write(
    String treeUri,
    String path,
    Uint8List bytes, {
    bool createNew = false,
    BrokerExpectation? expect,
  }) async {
    calls.add('write');
    final folder = _folder(treeUri);
    if (folder is Err<FakeFolder>) {
      return Err(folder.failure);
    }
    final tree = folder.valueOrNull!;
    final injected = failNextWrite;
    if (injected != null) {
      failNextWrite = null;
      return Err(injected);
    }
    if (tree.folders.contains(path)) {
      return _fail(FileProblem.wrongType);
    }
    final current = tree.files[path];
    if (current != null && createNew) {
      return _fail(FileProblem.exists);
    }
    if (current == null && _clash(tree, path)) {
      return _fail(FileProblem.exists);
    }
    if (current != null && expect != null) {
      final sha = expect.sha256;
      final same = sha != null
          ? sha256.convert(current).toString() == sha
          : current.length == expect.size &&
                tree.modified[path] == expect.modified;
      if (!same) {
        return _fail(FileProblem.changedOnDisk);
      }
    }
    tree.putBytes(path, bytes);
    return Ok(tree.entry(path));
  }

  @override
  Future<Result<BrokerEntry>> create(
    String treeUri,
    String parentPath,
    String name, {
    required bool directory,
  }) async {
    calls.add('create');
    final folder = _folder(treeUri);
    if (folder is Err<FakeFolder>) {
      return Err(folder.failure);
    }
    final tree = folder.valueOrNull!;
    final path = parentPath.isEmpty ? name : '$parentPath/$name';
    if (_clash(tree, path)) {
      return _fail(FileProblem.exists);
    }
    if (directory) {
      tree.folders.add(path);
    } else {
      tree.putBytes(path, const []);
    }
    return Ok(tree.entry(path));
  }

  @override
  Future<Result<BrokerEntry>> rename(
    String treeUri,
    String path,
    String newName,
  ) async {
    calls.add('rename');
    final parent = _parentOf(path);
    return _relocate(
      treeUri,
      path,
      parent.isEmpty ? newName : '$parent/$newName',
    );
  }

  @override
  Future<Result<BrokerEntry>> move(
    String treeUri,
    String path,
    String newParentPath,
  ) async {
    calls.add('move');
    final name = _nameOf(path);
    return _relocate(
      treeUri,
      path,
      newParentPath.isEmpty ? name : '$newParentPath/$name',
    );
  }

  @override
  Future<Result<BrokerEntry>> copy(
    String treeUri,
    String path,
    String newParentPath,
    String newName,
  ) async {
    calls.add('copy');
    final folder = _folder(treeUri);
    if (folder is Err<FakeFolder>) {
      return Err(folder.failure);
    }
    final tree = folder.valueOrNull!;
    final target = newParentPath.isEmpty ? newName : '$newParentPath/$newName';
    if (!tree.exists(path)) {
      return _fail(FileProblem.notFound);
    }
    if (_clash(tree, target)) {
      return _fail(FileProblem.exists);
    }
    for (final file in [...tree.files.keys]) {
      if (file == path || file.startsWith('$path/')) {
        tree.putBytes(target + file.substring(path.length), tree.files[file]!);
      }
    }
    for (final dir in [...tree.folders]) {
      if (dir == path || dir.startsWith('$path/')) {
        tree.folders.add(target + dir.substring(path.length));
      }
    }
    return Ok(tree.entry(target));
  }

  @override
  Future<Result<void>> delete(String treeUri, String path) async {
    calls.add('delete');
    final folder = _folder(treeUri);
    if (folder is Err<FakeFolder>) {
      return Err(folder.failure);
    }
    final tree = folder.valueOrNull!;
    if (path.isEmpty || !tree.exists(path)) {
      return _fail(
        path.isEmpty ? FileProblem.invalidPath : FileProblem.notFound,
      );
    }
    tree.files.removeWhere((p, _) => p == path || p.startsWith('$path/'));
    tree.folders.removeWhere((p) => p == path || p.startsWith('$path/'));
    return const Ok(null);
  }

  Future<Result<BrokerEntry>> _relocate(
    String treeUri,
    String from,
    String to,
  ) async {
    final folder = _folder(treeUri);
    if (folder is Err<FakeFolder>) {
      return Err(folder.failure);
    }
    final tree = folder.valueOrNull!;
    if (!tree.exists(from)) {
      return _fail(FileProblem.notFound);
    }
    if (from.toLowerCase() != to.toLowerCase() && _clash(tree, to)) {
      return _fail(FileProblem.exists);
    }
    for (final file in [...tree.files.keys]) {
      if (file == from || file.startsWith('$from/')) {
        final bytes = tree.files.remove(file)!;
        tree.putBytes(to + file.substring(from.length), bytes);
      }
    }
    for (final dir in [...tree.folders]) {
      if (dir == from || dir.startsWith('$from/')) {
        tree.folders
          ..remove(dir)
          ..add(to + dir.substring(from.length));
      }
    }
    return Ok(tree.entry(to));
  }

  FolderInfo _info(String uri) {
    final tree = trees[uri];
    if (!granted.contains(uri)) {
      return FolderInfo(
        treeUri: uri,
        name: '',
        status: FolderStatus.accessLost,
      );
    }
    if (tree == null || tree.missing) {
      return FolderInfo(treeUri: uri, name: '', status: FolderStatus.missing);
    }
    return FolderInfo(
      treeUri: uri,
      name: tree.name,
      status: FolderStatus.available,
      writable: true,
    );
  }

  Result<FakeFolder> _folder(String uri) {
    if (!granted.contains(uri)) {
      return _fail(FileProblem.accessLost);
    }
    final tree = trees[uri];
    if (tree == null || tree.missing) {
      return _fail(FileProblem.folderMissing);
    }
    return Ok(tree);
  }

  static bool _clash(FakeFolder tree, String path) {
    final folded = path.toLowerCase();
    return {
      ...tree.files.keys,
      ...tree.folders,
    }.any((p) => p.toLowerCase() == folded);
  }

  static Err<T> _fail<T>(FileProblem problem) =>
      Err(FileFailure(brokerMessage(problem), problem: problem));
}

String _parentOf(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? '' : path.substring(0, slash);
}

String _nameOf(String path) => path.substring(path.lastIndexOf('/') + 1);
