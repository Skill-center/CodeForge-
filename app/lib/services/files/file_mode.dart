/// Permission bits for the files the app saves (Phase 3 W1).
///
/// A save writes a new file and renames it over the old one
/// (local_file_service.dart), so the new file starts with the default mode
/// (0600 for an Android app's own files, the umask's elsewhere): a script
/// would lose its executable bit, and a private file could become readable.
/// dart:io reads modes (`FileStat.mode`) but cannot set them, so this asks
/// the C library's `chmod` through dart:ffi, finding it the way package:ffi
/// finds `malloc` (`DynamicLibrary.process()`).
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

typedef _ChmodC = Int32 Function(Pointer<Uint8> path, Uint32 mode);
typedef _ChmodDart = int Function(Pointer<Uint8> path, int mode);
typedef _MallocC = Pointer<Void> Function(IntPtr size);
typedef _MallocDart = Pointer<Void> Function(int size);
typedef _FreeC = Void Function(Pointer<Void> pointer);
typedef _FreeDart = void Function(Pointer<Void> pointer);

/// The three C library functions this needs.
final class _LibC {
  _LibC(DynamicLibrary library)
    : chmod = library.lookupFunction<_ChmodC, _ChmodDart>('chmod'),
      malloc = library.lookupFunction<_MallocC, _MallocDart>('malloc'),
      free = library.lookupFunction<_FreeC, _FreeDart>('free');

  final _ChmodDart chmod;
  final _MallocDart malloc;
  final _FreeDart free;
}

_LibC? _libC;
var _lookedUp = false;

_LibC? _library() {
  if (!_lookedUp) {
    _lookedUp = true;
    if (!Platform.isWindows) {
      try {
        _libC = _LibC(DynamicLibrary.process());
      } on Object {
        _libC = null;
      }
    }
  }
  return _libC;
}

/// The bits [setFileMode] sets: permissions, set-user-ID, set-group-ID and
/// sticky. `FileStat.mode` also carries the kind of file above them.
const int fileModeBits = 0xFFF;

/// Sets [path]'s permission bits to [mode] & [fileModeBits]. False when
/// they could not be set, and always on Windows, which has no such bits.
bool setFileMode(String path, int mode) {
  final libC = _library();
  if (libC == null) {
    return false;
  }
  final bytes = utf8.encode(path);
  final buffer = libC.malloc(bytes.length + 1).cast<Uint8>();
  if (buffer == nullptr) {
    return false;
  }
  try {
    buffer.asTypedList(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = 0;
    return libC.chmod(buffer, mode & fileModeBits) == 0;
  } finally {
    libC.free(buffer.cast());
  }
}
