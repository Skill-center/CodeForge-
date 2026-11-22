/// LSP's glob patterns (Phase 6 W4), for the files a server asks to hear
/// about (`workspace/didChangeWatchedFiles` registrations): `*` matches
/// within one path segment, `**` across any number of them, `?` one
/// character, `{a,b}` either, `[a-z]` a character in the range and `[!a]`
/// one that is not.
library;

/// [glob] as a regular expression over a whole path, `/`-separated.
RegExp globToRegExp(String glob) {
  final out = StringBuffer('^');
  var depth = 0;
  var i = 0;
  while (i < glob.length) {
    final char = glob[i];
    switch (char) {
      case '*':
        final twice = i + 1 < glob.length && glob[i + 1] == '*';
        if (twice) {
          final atStart = i == 0 || glob[i - 1] == '/';
          final slashAfter = i + 2 < glob.length && glob[i + 2] == '/';
          if (atStart && slashAfter) {
            // `**/`: any number of whole segments, none included.
            out.write('(?:.*/)?');
            i += 3;
          } else {
            out.write('.*');
            i += 2;
          }
        } else {
          out.write('[^/]*');
          i += 1;
        }
      case '?':
        out.write('[^/]');
        i += 1;
      case '{':
        depth += 1;
        out.write('(?:');
        i += 1;
      case '}' when depth > 0:
        depth -= 1;
        out.write(')');
        i += 1;
      case ',' when depth > 0:
        out.write('|');
        i += 1;
      case '[':
        final close = glob.indexOf(']', i + 2);
        if (close < 0) {
          out.write(RegExp.escape(char));
          i += 1;
        } else {
          var body = glob.substring(i + 1, close);
          final negated = body.startsWith('!');
          if (negated) {
            body = body.substring(1);
          }
          out
            ..write(negated ? '[^' : '[')
            ..write(body.replaceAll(r'\', r'\\').replaceAll('^', r'\^'))
            ..write(']');
          i = close + 1;
        }
      default:
        out.write(RegExp.escape(char));
        i += 1;
    }
  }
  while (depth > 0) {
    out.write(')');
    depth -= 1;
  }
  out.write(r'$');
  return RegExp(out.toString());
}
