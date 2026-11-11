/// The projects' folders (Phase 3 W3): one folder per project inside
/// `<filesDir>/workspaces/`, in the app's private storage, where the demo
/// project has lived since Phase 2.
///
/// A project's folder is named after the project. New folders are written
/// beside the others under a hidden name and renamed into place, and a
/// deleted one is renamed away before it is emptied, so an interrupted
/// create or delete never leaves a half project under a project's name.
library;

import 'dart:io';
import 'dart:math';

import '../../core/errors/failure.dart';
import '../../core/files/text_codec.dart';
import '../../core/files/workspace_location.dart';
import '../../core/files/workspace_path.dart';
import '../../core/logging/logger.dart';
import '../contracts.dart';
import 'demo_workspace.dart';
import 'local_file_service.dart';

abstract interface class ProjectStorage {
  /// The project folders on the device, by name, in no order. Hidden and
  /// half-written folders are left out.
  Future<Result<List<String>>> folders();

  Future<Result<bool>> exists(String folder);

  /// Creates [folder] holding [seed]'s files (path → text).
  /// [FileProblem.exists] when a project folder has that name, in any
  /// case.
  Future<Result<void>> create(
    String folder, {
    Map<String, String> seed = const {},
  });

  /// Renames [from] to [to]. A change of case alone goes through a
  /// temporary name.
  Future<Result<void>> rename(String from, String to);

  /// Deletes [folder] and everything in it. Nothing there is no failure.
  Future<Result<void>> delete(String folder);

  /// How many files [folder] holds, counting up to [limit].
  Future<Result<int>> countFiles(String folder, {int limit = 100000});

  /// The file service over [project]'s folder. The demo project is written
  /// with the sample files when its folder is not there; any other
  /// project's missing folder is reported as missing.
  FileService files(ProjectLocation project);
}

/// [ProjectStorage] on the device.
final class LocalProjectStorage implements ProjectStorage {
  LocalProjectStorage({required Future<String> Function() rootPath})
    : _rootPath = rootPath;

  /// The projects' folder, `<filesDir>/workspaces`.
  final Future<String> Function() _rootPath;

  final Random _random = Random();

  /// A hidden name nothing else uses: `.<what>-<12 hex digits>`.
  String _hidden(String what) {
    final buffer = StringBuffer('.$what-');
    for (var i = 0; i < 12; i++) {
      buffer.write(_random.nextInt(16).toRadixString(16));
    }
    return buffer.toString();
  }

  static String _baseName(FileSystemEntity entity) =>
      entity.path.substring(entity.path.lastIndexOf('/') + 1);

  /// A project's folder rather than a hidden or half-written one.
  static bool _isProjectFolder(String name) =>
      nameProblem(name) == null &&
      !name.startsWith('.') &&
      !name.endsWith(projectStagingSuffix);

  /// Runs [body] on the projects' folder; anything thrown becomes a logged
  /// [FileProblem.io].
  Future<Result<T>> _guard<T>(
    String what,
    Future<Result<T>> Function(Directory root) body,
  ) async {
    try {
      return await body(Directory(await _rootPath()));
    } on Object catch (error) {
      appLogger.error(
        'projects',
        'storage_failed',
        fields: {'op': what, 'error': '$error'},
      );
      return Err(
        FileFailure(
          'The project could not be $what.',
          problem: FileProblem.io,
          cause: error,
        ),
      );
    }
  }

  /// Whether anything in [root] is named [name], in any case, apart from
  /// [except].
  Future<bool> _taken(Directory root, String name, {String? except}) async {
    if (!root.existsSync()) {
      return false;
    }
    final lower = name.toLowerCase();
    await for (final entity in root.list(followLinks: false)) {
      final found = _baseName(entity);
      if (found != except && found.toLowerCase() == lower) {
        return true;
      }
    }
    return false;
  }

  static Err<T> _invalid<T>(String problem) =>
      Err(FileFailure(problem, problem: FileProblem.invalidPath));

  @override
  Future<Result<List<String>>> folders() => _guard('listed', (root) async {
    if (!root.existsSync()) {
      return const Ok(<String>[]);
    }
    final names = <String>[];
    await for (final entity in root.list(followLinks: false)) {
      final name = _baseName(entity);
      if (entity is Directory && _isProjectFolder(name)) {
        names.add(name);
      }
    }
    return Ok(names);
  });

  @override
  Future<Result<bool>> exists(String folder) => _guard('found', (root) async {
    if (nameProblem(folder) != null) {
      return const Ok(false);
    }
    return Ok(Directory('${root.path}/$folder').existsSync());
  });

  @override
  Future<Result<void>> create(
    String folder, {
    Map<String, String> seed = const {},
  }) => _guard('created', (root) async {
    final invalid = nameProblem(folder);
    if (invalid != null) {
      return _invalid(invalid);
    }
    await root.create(recursive: true);
    if (await _taken(root, folder)) {
      return Err(
        FileFailure(
          'A project named "$folder" already exists.',
          problem: FileProblem.exists,
        ),
      );
    }
    final staging = Directory('${root.path}/${_hidden('staging')}');
    await staging.create();
    try {
      for (final MapEntry(:key, :value) in seed.entries) {
        final file = File('${staging.path}/$key');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(
          encodeText(value, TextFormat.standard),
          flush: true,
        );
      }
      await staging.rename('${root.path}/$folder');
    } on Object {
      if (staging.existsSync()) {
        await staging.delete(recursive: true);
      }
      rethrow;
    }
    appLogger.info('projects', 'created', fields: {'files': seed.length});
    return const Ok(null);
  });

  @override
  Future<Result<void>> rename(String from, String to) =>
      _guard('renamed', (root) async {
        final invalid = nameProblem(from) ?? nameProblem(to);
        if (invalid != null) {
          return _invalid(invalid);
        }
        final source = Directory('${root.path}/$from');
        if (!source.existsSync()) {
          return Err(
            FileFailure(
              'The project "$from" is missing: its folder is gone.',
              problem: FileProblem.folderMissing,
            ),
          );
        }
        if (from == to) {
          return const Ok(null);
        }
        if (await _taken(root, to, except: from)) {
          return Err(
            FileFailure(
              'A project named "$to" already exists.',
              problem: FileProblem.exists,
            ),
          );
        }
        if (from.toLowerCase() == to.toLowerCase()) {
          final temporary = await source.rename(
            '${root.path}/${_hidden('rename')}',
          );
          await temporary.rename('${root.path}/$to');
        } else {
          await source.rename('${root.path}/$to');
        }
        appLogger.info('projects', 'renamed');
        return const Ok(null);
      });

  @override
  Future<Result<void>> delete(String folder) => _guard('deleted', (root) async {
    final invalid = nameProblem(folder);
    if (invalid != null) {
      return _invalid(invalid);
    }
    final directory = Directory('${root.path}/$folder');
    if (directory.existsSync()) {
      final doomed = await directory.rename(
        '${root.path}/${_hidden('deleting')}',
      );
      await doomed.delete(recursive: true);
    }
    appLogger.info('projects', 'deleted');
    return const Ok(null);
  });

  @override
  Future<Result<int>> countFiles(String folder, {int limit = 100000}) =>
      _guard('counted', (root) async {
        final directory = Directory('${root.path}/$folder');
        if (nameProblem(folder) != null || !directory.existsSync()) {
          return const Ok(0);
        }
        var count = 0;
        await for (final entity in directory.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File) {
            count += 1;
            if (count >= limit) {
              break;
            }
          }
        }
        return Ok(count);
      });

  @override
  FileService files(ProjectLocation project) => LocalFileService(
    rootPath: () async => '${await _rootPath()}/${project.folder}',
    seed: project.isDemo ? DemoWorkspace.files : const {},
    workspace: WorkspaceRef(id: project.id, displayName: project.name),
    createIfMissing: project.isDemo,
  );
}
