/// What a file looked like when the app last read or wrote it.
library;

/// Modification time and size of a file at one moment. Saving compares
/// the stamp taken when the file was read with the file's stamp now, so a
/// change made by something else is noticed instead of overwritten.
///
/// Some storage reports no modification time: a folder's provider may say
/// nothing (Android's own says nothing for files dated before 1971, as a
/// restore from backup leaves them). Such a stamp carries the content's
/// SHA-256 in [digest] instead, and [modified] is the epoch.
final class FileStamp {
  const FileStamp({required this.modified, required this.size, this.digest});

  /// The epoch: no modification time is known ([digest] stands in).
  static final DateTime unknownTime = DateTime.fromMillisecondsSinceEpoch(
    0,
    isUtc: true,
  );

  final DateTime modified;

  /// Size in bytes.
  final int size;

  /// Hex SHA-256 of the content, when the storage gave no time.
  final String? digest;

  @override
  bool operator ==(Object other) =>
      other is FileStamp &&
      other.modified == modified &&
      other.size == size &&
      other.digest == digest;

  @override
  int get hashCode => Object.hash(modified, size, digest);

  @override
  String toString() => digest == null
      ? 'FileStamp($size bytes, ${modified.toIso8601String()})'
      : 'FileStamp($size bytes, sha256 $digest)';
}
