// The typed boundary to the storage broker (Phase 3 W2,
// docs/SECURITY.md §4.1): folders the user picked in Android's folder
// picker, reached through the Storage Access Framework.
//
// Pigeon generates the Dart client and the Kotlin interface from this file.
// Nothing here runs in the authoring sandbox (no Dart SDK): CI's [bootstrap]
// mode runs `dart run pigeon --input pigeons/storage_api.dart` and commits
// the output, and every CI run generates it again and fails if the
// committed copies are stale (.github/workflows/ci.yml, "Generated code
// check").
//
// Every method answers through a callback (`@asyncCallback`): the broker
// runs the work on its own threads, so no call ever blocks Android's main
// thread, and the generated Kotlin needs no coroutines library. A failure
// is a FlutterError whose code the Dart client maps to a FileProblem
// (lib/services/files/native/pigeon_storage_broker.dart). The calls Kotlin
// makes into Dart (StorageEvents, Phase 3 W5) are callback-style too:
// without `@asyncCallback` Pigeon generates Kotlin `suspend` functions,
// which need the coroutines library.
import 'package:pigeon/pigeon.dart';

/// A folder the user picked, as the broker finds it now.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/services/files/native/storage_api.g.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/app/src/main/kotlin/dev/codeforge/app/storage/StorageApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'dev.codeforge.app.storage'),
    dartPackageName: 'codeforge',
  ),
)
class TreeMessage {
  TreeMessage({
    required this.treeUri,
    required this.name,
    required this.status,
    required this.writable,
  });

  /// The grant's tree URI: an opaque token to Dart.
  String treeUri;

  /// The folder's name; empty when it could not be read.
  String name;

  /// 'available', 'missing' (the folder is gone) or 'accessLost' (no
  /// grant, or the provider refused it).
  String status;

  /// Whether the grant and the provider allow changes.
  bool writable;
}

/// One file or folder.
class EntryMessage {
  EntryMessage({
    required this.name,
    required this.isDirectory,
    this.size,
    this.modifiedMs,
    required this.flags,
  });

  String name;
  bool isDirectory;

  /// Bytes, when the provider says.
  int? size;

  /// Milliseconds since the epoch, when the provider says (Android's own
  /// provider says nothing for times before 1971).
  int? modifiedMs;

  /// What the provider allows: 1 write (a file) or create inside (a
  /// folder), 2 delete, 4 rename, 8 move.
  int flags;
}

/// A file's bytes, and the file as it was when they were read.
class ReadMessage {
  ReadMessage({required this.entry, required this.bytes});

  EntryMessage entry;
  Uint8List bytes;
}

/// What a write must find before it replaces a file: its stamp when it was
/// read. A SHA-256 stands in for the time when the provider gave none.
class WriteRequest {
  WriteRequest({
    required this.treeUri,
    required this.path,
    required this.bytes,
    required this.createNew,
    this.expectSize,
    this.expectModifiedMs,
    this.expectSha256,
  });

  String treeUri;
  String path;
  Uint8List bytes;

  /// Refuse when something is already there.
  bool createNew;

  /// The file's size, time and hash when it was read; none for a write
  /// that may replace whatever is there.
  int? expectSize;
  int? expectModifiedMs;
  String? expectSha256;
}

/// A persisted grant.
class GrantMessage {
  GrantMessage({
    required this.treeUri,
    required this.read,
    required this.write,
    required this.persistedAtMs,
  });

  String treeUri;
  bool read;
  bool write;
  int persistedAtMs;
}

/// The storage broker (StorageBroker.kt). Paths are relative to the
/// granted folder ('' is the folder itself) and checked again on the
/// Kotlin side, segment by segment.
@HostApi()
abstract class StorageApi {
  /// Shows Android's folder picker, starting at [initialUri] (a document
  /// or tree URI) when given, and keeps the grant for reading and writing.
  /// Null when the user backs out.
  @asyncCallback
  TreeMessage? pickTree(String? initialUri);

  /// Whether the folder is still there and still granted.
  @asyncCallback
  TreeMessage checkTree(String treeUri);

  /// The folder grants the app keeps.
  @asyncCallback
  List<GrantMessage> listGrants();

  /// Gives a folder's grant back to Android.
  @asyncCallback
  void releaseGrant(String treeUri);

  /// A folder's entries, in one query.
  @asyncCallback
  List<EntryMessage> list(String treeUri, String path);

  @asyncCallback
  EntryMessage stat(String treeUri, String path);

  /// A file's bytes; refused when it holds more than [maxBytes].
  @asyncCallback
  ReadMessage read(String treeUri, String path, int maxBytes);

  /// Writes a file in place (mode "wt"), creating it and any missing
  /// folders above it, and reads its new stamp back.
  @asyncCallback
  EntryMessage write(WriteRequest request);

  /// Creates an empty file or a folder named [name] in [parentPath].
  @asyncCallback
  EntryMessage create(
    String treeUri,
    String parentPath,
    String name,
    bool directory,
  );

  @asyncCallback
  EntryMessage rename(String treeUri, String path, String newName);

  /// Moves into [newParentPath], keeping the name.
  @asyncCallback
  EntryMessage move(String treeUri, String path, String newParentPath);

  /// Copies into [newParentPath] as [newName], folders with everything in
  /// them.
  @asyncCallback
  EntryMessage copy(
    String treeUri,
    String path,
    String newParentPath,
    String newName,
  );

  /// Deletes a file, or a folder with everything in it.
  @asyncCallback
  void delete(String treeUri, String path);

  /// Shows Android's create-document picker (Phase 3 W4: About → Recent
  /// logs → Save), suggesting [suggestedName] as a file of [mimeType] and
  /// starting at [initialUri] (a document URI) when given, and writes
  /// [bytes] to the new file the user picks. The app keeps no grant to it.
  /// Answers the file's name as its storage gave it ('' when the storage
  /// does not say), or null when the user backs out.
  @asyncCallback
  String? saveDocument(
    String suggestedName,
    String mimeType,
    Uint8List bytes,
    String? initialUri,
  );

  /// Starts change notices for the folder at [path] (Phase 3 W5): its
  /// children query stays open, and the provider says when the rows behind
  /// it change, as Android's own provider does while such a query is open.
  /// Notices arrive through [StorageEvents.folderChanged] with [watchId]
  /// until [unwatch]. False when the provider gave no query to keep open.
  @asyncCallback
  bool watch(String treeUri, String path, int watchId);

  /// Stops [watchId]'s notices and closes its query. An id that is not
  /// watched is ignored.
  @asyncCallback
  void unwatch(int watchId);
}

/// What the storage broker tells Dart unasked (Phase 3 W5).
@FlutterApi()
abstract class StorageEvents {
  /// Something in [watchId]'s folder changed: an entry was created,
  /// written, renamed or deleted. Notices for one folder arrive at most
  /// every 100 ms.
  @asyncCallback
  void folderChanged(int watchId);
}
