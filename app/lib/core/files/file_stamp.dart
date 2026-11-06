/// What a file looked like when the app last read or wrote it.
library;

/// Modification time and size of a file at one moment. Saving compares
/// the stamp taken when the file was read with the file's stamp now, so a
/// change made by something else is noticed instead of overwritten.
final class FileStamp {
  const FileStamp({required this.modified, required this.size});

  final DateTime modified;

  /// Size in bytes.
  final int size;

  @override
  bool operator ==(Object other) =>
      other is FileStamp && other.modified == modified && other.size == size;

  @override
  int get hashCode => Object.hash(modified, size);

  @override
  String toString() => 'FileStamp($size bytes, ${modified.toIso8601String()})';
}
