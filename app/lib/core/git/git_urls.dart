/// The remote URLs a clone may take (Phase 7 W3, PHASE_7_PLAN W3): the same
/// rules as the Git host's (android/…/git/GitUrls.kt), checked here first so
/// the clone dialog says why before anything runs; both sides read
/// test/fixtures/git/urls.tsv in their tests.
///
/// HTTPS, SSH (`ssh://` or `user@host:path`), and plain HTTP to this device
/// only. A URL that carries a password or a token is refused: CodeForge asks
/// for the credential instead, and keeps it in the Keystore. A user name
/// alone, as SSH's `git@host` has, is kept.
library;

/// A URL a clone may take.
final class GitRemoteUrl {
  const GitRemoteUrl({
    required this.scheme,
    required this.host,
    required this.path,
    this.user,
  });

  /// `https`, `ssh` or `http`.
  final String scheme;

  /// The host as git names it, lower case, with its port when it has one.
  final String host;
  final String? user;

  /// The repository's path on its host.
  final String path;
}

/// Why a URL cannot be cloned.
final class GitUrlProblem {
  const GitUrlProblem(this.message);

  final String message;

  @override
  String toString() => message;
}

const int _maxUrl = 2048;

final RegExp _scheme = RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*)://');
final RegExp _hostname = RegExp(
  r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?'
  r'(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?)*$',
);
final RegExp _ipv6 = RegExp(r'^\[[0-9A-Fa-f:.]+]$');

/// GitHub's, GitLab's, Bitbucket's and Hugging Face's token prefixes.
const List<String> _tokenPrefixes = [
  'ghp_',
  'gho_',
  'ghu_',
  'ghs_',
  'ghr_',
  'github_pat_',
  'glpat-',
  'gldt-',
  'glptt-',
  'glrt-',
  'ATBB',
  'ATCTT',
  'hf_',
];

const String _password =
    'This URL holds a password. Leave it out: CodeForge asks for it, and can '
    'remember it safely.';
const String _token =
    'This URL holds a token. Leave it out: CodeForge asks for it, and can '
    'remember it safely.';

/// [url] read, or why it cannot be cloned.
({GitRemoteUrl? url, GitUrlProblem? problem}) checkRemoteUrl(String url) {
  try {
    return (url: _check(url), problem: null);
  } on GitUrlProblem catch (problem) {
    return (url: null, problem: problem);
  }
}

GitRemoteUrl _check(String url) {
  if (url.isEmpty || url.length > _maxUrl) {
    throw const GitUrlProblem('Enter the repository\'s URL.');
  }
  if (url.runes.any((r) => r <= 0x20 || r == 0x7f || r == 0x5c)) {
    throw const GitUrlProblem(
      'A URL has no spaces, control characters or backslashes.',
    );
  }
  if (url.startsWith('-')) {
    throw const GitUrlProblem('A URL never starts with -.');
  }
  final scheme = _scheme.firstMatch(url)?.group(1);
  if (scheme != null) {
    return _withScheme(scheme.toLowerCase(), url.substring(scheme.length + 3));
  }
  if (url.contains('::')) {
    throw const GitUrlProblem('Only HTTPS and SSH remotes can be cloned.');
  }
  return _scpLike(url);
}

GitRemoteUrl _withScheme(String scheme, String rest) {
  if (!const {'https', 'http', 'ssh'}.contains(scheme)) {
    throw GitUrlProblem(
      'Only HTTPS and SSH remotes can be cloned, not $scheme://.',
    );
  }
  if (rest.contains('?') || rest.contains('#')) {
    throw const GitUrlProblem(
      'Leave out the part after ? or #: it may carry a token.',
    );
  }
  final slash = rest.indexOf('/');
  if (slash <= 0 || slash == rest.length - 1) {
    throw const GitUrlProblem('The URL names a host and a repository on it.');
  }
  final authority = rest.substring(0, slash);
  final path = rest.substring(slash);
  final at = authority.lastIndexOf('@');
  final user = at >= 0 ? authority.substring(0, at) : null;
  final hostPort = at >= 0 ? authority.substring(at + 1) : authority;
  if (user != null) {
    _checkUser(user);
  }
  final host = _checkHostPort(hostPort, allowPort: true);
  if (scheme == 'http' && !isLoopbackHost(host)) {
    throw const GitUrlProblem(
      'Plain HTTP only reaches this device. Use HTTPS, which keeps a token '
      'private.',
    );
  }
  return GitRemoteUrl(scheme: scheme, host: host, path: path, user: user);
}

/// `[user@]host:path`, as ssh and scp write it.
GitRemoteUrl _scpLike(String url) {
  final colon = url.indexOf(':');
  final slash = url.indexOf('/');
  if (colon <= 0 || (slash >= 0 && slash < colon)) {
    throw const GitUrlProblem(
      'Only HTTPS and SSH remotes can be cloned, not a folder.',
    );
  }
  final authority = url.substring(0, colon);
  final path = url.substring(colon + 1);
  if (path.isEmpty || path.startsWith('-')) {
    throw const GitUrlProblem('The URL names a repository on its host.');
  }
  // user:password@host:path reads as host "user" and path
  // "password@host:path".
  if (path.contains('@')) {
    throw const GitUrlProblem(_password);
  }
  final at = authority.lastIndexOf('@');
  final user = at >= 0 ? authority.substring(0, at) : null;
  final host = at >= 0 ? authority.substring(at + 1) : authority;
  if (user != null) {
    _checkUser(user);
  }
  _checkHostPort(host, allowPort: false);
  return GitRemoteUrl(
    scheme: 'ssh',
    host: host.toLowerCase(),
    path: path,
    user: user,
  );
}

void _checkUser(String user) {
  if (user.isEmpty) {
    throw const GitUrlProblem('There is no user name before @.');
  }
  if (user.contains(':')) {
    throw const GitUrlProblem(_password);
  }
  final decoded = _percentDecoded(user);
  if (decoded.contains(':')) {
    throw const GitUrlProblem(_password);
  }
  if (looksLikeToken(decoded)) {
    throw const GitUrlProblem(_token);
  }
  if (decoded.length > 256 ||
      decoded.runes.any((r) => r <= 0x20 || r == 0x7f || r == 0x40 || r == 0x2f)) {
    throw const GitUrlProblem('That is not a user name.');
  }
}

String _checkHostPort(String hostPort, {required bool allowPort}) {
  String host;
  String? port;
  if (hostPort.startsWith('[')) {
    final close = hostPort.indexOf(']');
    if (close < 0) {
      throw const GitUrlProblem('That is not a host.');
    }
    host = hostPort.substring(0, close + 1);
    final after = hostPort.substring(close + 1);
    if (after.isEmpty) {
      port = null;
    } else if (after.startsWith(':')) {
      port = after.substring(1);
    } else {
      throw const GitUrlProblem('That is not a host.');
    }
    if (!_ipv6.hasMatch(host)) {
      throw const GitUrlProblem('That is not a host.');
    }
  } else {
    final colon = hostPort.indexOf(':');
    host = colon >= 0 ? hostPort.substring(0, colon) : hostPort;
    port = colon >= 0 ? hostPort.substring(colon + 1) : null;
    if (!_hostname.hasMatch(host)) {
      throw const GitUrlProblem('That is not a host.');
    }
  }
  if (port != null) {
    if (!allowPort) {
      throw const GitUrlProblem('That is not a host.');
    }
    final number = int.tryParse(port);
    if (number == null ||
        number < 1 ||
        number > 65535 ||
        port.length > 5 ||
        !RegExp(r'^[0-9]+$').hasMatch(port)) {
      throw const GitUrlProblem('That is not a port.');
    }
  }
  final name = host.toLowerCase();
  return port != null ? '$name:$port' : name;
}

/// A user name that is really a secret: a known token's prefix, or a long
/// random-looking string.
bool looksLikeToken(String user) {
  if (_tokenPrefixes.any(user.startsWith)) {
    return true;
  }
  return user.length >= 32 &&
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(user) &&
      RegExp('[0-9]').hasMatch(user) &&
      RegExp('[A-Za-z]').hasMatch(user);
}

/// 127.0.0.0/8, `localhost` and `[::1]`, with or without a port.
bool isLoopbackHost(String host) {
  String name;
  if (host.startsWith('[')) {
    name = host.substring(1, host.contains(']') ? host.indexOf(']') : host.length);
  } else if (':'.allMatches(host).length == 1) {
    name = host.substring(0, host.indexOf(':'));
  } else {
    name = host;
  }
  name = name.toLowerCase();
  if (name == 'localhost' || name == '::1') {
    return true;
  }
  final parts = name.split('.');
  return parts.length == 4 &&
      parts[0] == '127' &&
      parts.every((part) {
        final value = int.tryParse(part);
        return value != null &&
            value >= 0 &&
            value <= 255 &&
            RegExp(r'^[0-9]+$').hasMatch(part);
      });
}

String _percentDecoded(String text) {
  try {
    return Uri.decodeComponent(text);
  } on ArgumentError {
    return text;
  } on FormatException {
    return text;
  }
}

/// The name a clone's project gets by default: the repository's last path
/// part without `.git` (`Hello-World` for `…/octocat/Hello-World.git`), or
/// null when nothing usable is left.
String? projectNameFromUrl(String url) {
  final checked = checkRemoteUrl(url.trim()).url;
  if (checked == null) {
    return null;
  }
  var path = checked.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  var name = path.substring(path.lastIndexOf('/') + 1);
  if (name.endsWith('.git')) {
    name = name.substring(0, name.length - 4);
  }
  name = name.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '-');
  while (name.startsWith('.') || name.startsWith('-')) {
    name = name.substring(1);
  }
  return name.isEmpty ? null : name;
}
