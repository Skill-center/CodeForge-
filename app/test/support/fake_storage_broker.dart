/// An in-memory storage broker for tests (Phase 3 W2): folders keyed by
/// tree URI, each a tree of files and folders, with the grants, the folder
/// statuses and the picker's answers under the test's control. It follows
/// the Kotlin broker's rules where the file service depends on them: a
/// write checks the stamp it was given (time and size, or a SHA-256 when
/// the folder gives no time), new names are compared without case, and a
/// missing folder or a lost grant fails every call.
library;

import 'dart:async';
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

  /// Granted for reading only: the folder says it is not writable, and
  /// every change fails as unsupported (Phase 3 W4).
  bool readOnly = false;

  /// What the provider declares for an item, where a test says otherwise
  /// than everything (15: write, delete, rename, move).
  final Map<String, int> flags = {};

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
      flags: flags[path] ?? 15,
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

  /// The tree URIs whose grants were given back, in order.
  final List<String> released = [];

  /// Fails the next write with this, as a provider error would.
  FileFailure? failNextWrite;

  /// Fails the next folder check with this, as a storage that does not
  /// answer would.
  FileFailure? failNextCheck;

  /// What the create-document picker answers next: the new file's name,
  /// or null when the user backs out.
  String? saveAnswer;

  /// Fails the next save with this, after the user picked a file.
  FileFailure? failNextSave;

  /// Every file saved through the create-document picker, in order.
  final List<({String suggestedName, String mimeType, Uint8List bytes})> saved =
      [];

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
    final failure = failNextCheck;
    if (failure != null) {
      failNextCheck = null;
      return Err(failure);
    }
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
    released.add(treeUri);
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
    if (tree.readOnly) {
      return _fail(FileProblem.unsupported);
    }
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
    if (tree.readOnly) {
      return _fail(FileProblem.unsupported);
    }
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
    if (tree.readOnly) {
      return _fail(FileProblem.unsupported);
    }
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
    if (tree.readOnly) {
      return _fail(FileProblem.unsupported);
    }
    if (path.isEmpty || !tree.exists(path)) {
      return _fail(
        path.isEmpty ? FileProblem.invalidPath : FileProblem.notFound,
      );
    }
    tree.files.removeWhere((p, _) => p == path || p.startsWith('$path/'));
    tree.folders.removeWhere((p) => p == path || p.startsWith('$path/'));
    return const Ok(null);
  }

  @override
  Future<Result<String?>> saveDocument({
    required String suggestedName,
    required String mimeType,
    required Uint8List bytes,
    String? initialUri,
  }) async {
    calls.add('saveDocument');
    final name = saveAnswer;
    if (name == null) {
      return const Ok(null);
    }
    final failure = failNextSave;
    if (failure != null) {
      failNextSave = null;
      return Err(failure);
    }
    saved.add((suggestedName: suggestedName, mimeType: mimeType, bytes: bytes));
    return Ok(name);
  }

  /// The folders watched now (Phase 3 W5), as `<tree URI>|<path>`.
  final Map<String, StreamController<void>> _watches = {};

  /// Watching fails with this from now on, as a provider that refuses
  /// would.
  FileFailure? failWatch;

  /// Whether [path] in [treeUri] is being watched.
  bool isWatched(String treeUri, String path) =>
      _watches.containsKey('$treeUri|$path');

  /// How many folders are being watched.
  int get watchCount => _watches.length;

  /// Tells whoever watches [path] in [treeUri] that it changed, as the
  /// provider would.
  void notifyChanged(String treeUri, String path) {
    _watches['$treeUri|$path']?.add(null);
  }

  @override
  Stream<void> watch(String treeUri, String path) {
    final key = '$treeUri|$path';
    late final StreamController<void> controller;
    controller = StreamController<void>(
      onListen: () {
        final failure = failWatch;
        if (failure != null) {
          controller.addError(failure);
          return;
        }
        _watches[key] = controller;
      },
      onCancel: () {
        if (identical(_watches[key], controller)) {
          _watches.remove(key);
        }
        unawaited(controller.close());
      },
    );
    return controller.stream;
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
    if (tree.readOnly) {
      return _fail(FileProblem.unsupported);
    }
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

  // ------------------------------------------------- run copies (Phase 5 W4)

  /// Each folder's run copy, by copy id: what a run sees, path → bytes.
  /// A test writes a run's output here.
  final Map<String, Map<String, Uint8List>> copies = {};

  /// What each copy took from its folder, as it took it: path → bytes.
  final Map<String, Map<String, Uint8List>> _copied = {};

  /// Every sync's copy id, in order.
  final List<String> synced = [];

  /// The copy ids deleted, in order.
  final List<String> deletedCopies = [];

  /// When set, a sync waits for it (to show its progress, or cancel it).
  Completer<void>? syncGate;

  /// What the next sync answers, when a test says, after copying.
  CopySummary? nextSummary;

  /// Imports, by project name: what the folder held. The harness hands
  /// them to its project storage.
  void Function(String folderName, Map<String, String> files)? onImport;

  final StreamController<CopyProgress> _progress =
      StreamController<CopyProgress>.broadcast();

  /// Reports progress, as Kotlin does while a copy runs.
  void emitProgress(String copyId, {required int files, int bytes = 0}) =>
      _progress.add(CopyProgress(copyId: copyId, files: files, bytes: bytes));

  @override
  Stream<CopyProgress> get copyProgress => _progress.stream;

  @override
  Future<Result<CopySummary>> syncCopy(String treeUri, String copyId) async {
    calls.add('syncCopy');
    final folder = _folder(treeUri);
    if (folder case Err(:final failure)) {
      return Err(failure);
    }
    final tree = (folder as Ok<FakeFolder>).value;
    synced.add(copyId);
    final gate = syncGate;
    if (gate != null) {
      await gate.future;
    }
    final copy = copies.putIfAbsent(copyId, () => {});
    final copied = _copied.putIfAbsent(copyId, () => {});
    var count = 0;
    var bytes = 0;
    var unchanged = 0;
    var skipped = 0;
    for (final MapEntry(key: path, value: data) in tree.files.entries) {
      if (path.split('/').contains('.git')) {
        skipped += 1;
        continue;
      }
      final before = copied[path];
      final now = copy[path];
      if (before != null &&
          now != null &&
          _same(before, data) &&
          identical(now, before)) {
        unchanged += 1;
        continue;
      }
      final taken = Uint8List.fromList(data);
      copy[path] = taken;
      copied[path] = taken;
      count += 1;
      bytes += data.length;
    }
    var removed = 0;
    for (final path in [...copied.keys]) {
      if (!tree.files.containsKey(path)) {
        copied.remove(path);
        copy.remove(path);
        removed += 1;
      }
    }
    return Ok(
      nextSummary ??
          CopySummary(
            files: copied.length,
            bytes: copied.values.fold(0, (sum, b) => sum + b.length),
            copied: count,
            bytesCopied: bytes,
            unchanged: unchanged,
            removed: removed,
            skipped: skipped,
          ),
    );
  }

  @override
  Future<void> cancelCopy(String copyId) async {
    calls.add('cancelCopy');
  }

  @override
  Future<Result<CopyChanges>> copyChanges(String copyId) async {
    calls.add('copyChanges');
    final copy = copies[copyId] ?? const {};
    final copied = _copied[copyId] ?? const {};
    final paths = copy.keys.toList()..sort();
    return Ok(
      CopyChanges(
        changes: [
          for (final path in paths)
            if (!identical(copy[path], copied[path]))
              CopyChange(
                path: path,
                created: !copied.containsKey(path),
                size: copy[path]!.length,
              ),
        ],
      ),
    );
  }

  @override
  Future<Result<ExportResult>> exportCopy(
    String treeUri,
    String copyId,
    List<String> paths,
  ) async {
    calls.add('exportCopy');
    final folder = _folder(treeUri);
    if (folder case Err(:final failure)) {
      return Err(failure);
    }
    final tree = (folder as Ok<FakeFolder>).value;
    final copy = copies[copyId] ?? {};
    final copied = _copied.putIfAbsent(copyId, () => {});
    var exported = 0;
    final failures = <({String path, FileFailure failure})>[];
    for (final path in paths) {
      final data = copy[path];
      if (data == null) {
        failures.add((
          path: path,
          failure: FileFailure(
            brokerMessage(FileProblem.notFound),
            problem: FileProblem.notFound,
          ),
        ));
        continue;
      }
      tree.putBytes(path, data);
      copied[path] = data;
      exported += 1;
    }
    return Ok(ExportResult(exported: exported, failures: failures));
  }

  @override
  Future<Result<void>> deleteCopy(String copyId) async {
    calls.add('deleteCopy');
    deletedCopies.add(copyId);
    copies.remove(copyId);
    _copied.remove(copyId);
    return const Ok(null);
  }

  @override
  Future<Result<CopySummary>> importFolder(
    String treeUri,
    String folderName,
  ) async {
    calls.add('importFolder');
    final folder = _folder(treeUri);
    if (folder case Err(:final failure)) {
      return Err(failure);
    }
    final tree = (folder as Ok<FakeFolder>).value;
    final gate = syncGate;
    if (gate != null) {
      await gate.future;
    }
    final files = {
      for (final MapEntry(:key, :value) in tree.files.entries)
        key: utf8.decode(value, allowMalformed: true),
    };
    onImport?.call(folderName, files);
    return Ok(
      CopySummary(
        files: files.length,
        bytes: tree.files.values.fold(0, (sum, b) => sum + b.length),
        copied: files.length,
      ),
    );
  }

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
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
      writable: !tree.readOnly,
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
