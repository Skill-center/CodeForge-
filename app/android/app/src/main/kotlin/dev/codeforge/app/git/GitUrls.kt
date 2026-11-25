package dev.codeforge.app.git

/**
 * The remote URLs the Git host clones from (Phase 7 W3, PHASE_7_PLAN W3):
 * HTTPS, SSH (`ssh://` or `user@host:path`), and plain HTTP to this device
 * only. A URL that carries a password or a token is refused, with why: the
 * credential helper asks for it instead, and the store keeps it. A user name
 * alone, as SSH's `git@host` has, is kept. Dart checks the same rules first
 * (lib/core/git/git_urls.dart, with the same fixture,
 * test/fixtures/git/urls.json), to say why before anything runs.
 */
object GitUrls {
    /** A URL that may be cloned. */
    data class Remote(val scheme: String, val user: String?, val host: String, val path: String)

    const val MAX_URL = 2_048

    /** [url] read, or why not ([GitRefused] with BAD_REQUEST). */
    fun check(url: String): Remote {
        if (url.isEmpty() || url.length > MAX_URL) refuse("a URL of at most $MAX_URL characters")
        if (url.any { it <= ' ' || it == '\u007f' || it == '\\' }) refuse("a URL holds no space, control character or backslash")
        if (url.startsWith("-")) refuse("a URL never starts with -")
        val scheme = SCHEME.find(url)?.groupValues?.get(1)?.lowercase()
        return when {
            scheme != null -> withScheme(scheme, url.substring(scheme.length + 3))
            url.contains("::") -> refuse("only HTTPS and SSH remotes: not a remote helper (transport::address)")
            else -> scpLike(url)
        }
    }

    private fun withScheme(scheme: String, rest: String): Remote {
        if (scheme !in setOf("https", "http", "ssh")) refuse("only HTTPS and SSH remotes, not $scheme://")
        if (rest.contains('?') || rest.contains('#')) refuse("a URL with a query or a fragment may carry a token: leave it out")
        val slash = rest.indexOf('/')
        if (slash <= 0 || slash == rest.length - 1) refuse("a URL names a host and a repository on it")
        val authority = rest.substring(0, slash)
        val path = rest.substring(slash)
        val at = authority.lastIndexOf('@')
        val user = if (at >= 0) authority.substring(0, at) else null
        val hostPort = if (at >= 0) authority.substring(at + 1) else authority
        if (user != null) checkUser(user)
        val host = checkHostPort(hostPort, allowPort = true)
        if (scheme == "http" && !CredentialBroker.isLoopback(host)) {
            refuse("plain HTTP only to this device: use HTTPS, which keeps a token private")
        }
        return Remote(scheme, user, host, path)
    }

    /** `[user@]host:path`, as ssh and scp write it. */
    private fun scpLike(url: String): Remote {
        val colon = url.indexOf(':')
        val slash = url.indexOf('/')
        if (colon <= 0 || (slash in 0 until colon)) refuse("only HTTPS and SSH remotes: not a folder on the device")
        val authority = url.substring(0, colon)
        val path = url.substring(colon + 1)
        if (path.isEmpty() || path.startsWith("-")) refuse("a URL names a repository on its host")
        // user:password@host:path reads as host "user" with "password@host:path": refuse what looks like it.
        if (path.contains('@')) refuse("a URL that carries a password: leave it out, CodeForge asks for it")
        val at = authority.lastIndexOf('@')
        val user = if (at >= 0) authority.substring(0, at) else null
        val host = if (at >= 0) authority.substring(at + 1) else authority
        if (user != null) checkUser(user)
        checkHostPort(host, allowPort = false)
        return Remote("ssh", user, host.lowercase(), path)
    }

    private fun checkUser(user: String) {
        if (user.isEmpty()) refuse("an empty user name before @")
        if (user.contains(':')) refuse("a URL that carries a password: leave it out, CodeForge asks for it")
        val decoded = percentDecoded(user)
        if (decoded.contains(':')) refuse("a URL that carries a password: leave it out, CodeForge asks for it")
        if (looksLikeToken(decoded)) refuse("a URL that carries a token: leave it out, CodeForge asks for it")
        if (decoded.length > 256 || decoded.any { it <= ' ' || it == '\u007f' || it == '@' || it == '/' }) refuse("not a user name")
    }

    /** `host`, `host:port` or `[v6]:port`: the host lower case, with its port. */
    private fun checkHostPort(hostPort: String, allowPort: Boolean): String {
        val host: String
        val port: String?
        if (hostPort.startsWith("[")) {
            val close = hostPort.indexOf(']')
            if (close < 0) refuse("not a host")
            host = hostPort.substring(0, close + 1)
            val after = hostPort.substring(close + 1)
            port = if (after.isEmpty()) null else if (after.startsWith(":")) after.substring(1) else refuse("not a host")
            if (!IPV6.matches(host)) refuse("not a host")
        } else {
            val colon = hostPort.indexOf(':')
            host = if (colon >= 0) hostPort.substring(0, colon) else hostPort
            port = if (colon >= 0) hostPort.substring(colon + 1) else null
            if (!HOSTNAME.matches(host)) refuse("not a host")
        }
        if (port != null) {
            if (!allowPort) refuse("not a host")
            val number = port.toIntOrNull()
            if (number == null || number !in 1..65535 || port.length > 5) refuse("not a port")
        }
        val name = host.lowercase()
        return if (port != null) "$name:$port" else name
    }

    /** A user name that is really a secret: a known token's prefix, or a long random-looking string. */
    fun looksLikeToken(user: String): Boolean {
        if (TOKEN_PREFIXES.any { user.startsWith(it) }) return true
        if (user.length >= 32 && user.all { it.isLetterOrDigit() || it == '_' || it == '-' } &&
            user.any { it.isDigit() } && user.any { it.isLetter() }
        ) {
            return true
        }
        return false
    }

    private fun percentDecoded(text: String): String = try {
        java.net.URLDecoder.decode(text.replace("+", "%2B"), "UTF-8")
    } catch (malformed: IllegalArgumentException) {
        text
    }

    private fun refuse(why: String): Nothing = throw GitRefused(GitFailure.BAD_REQUEST, why)

    private val SCHEME = Regex("^([A-Za-z][A-Za-z0-9+.-]*)://")
    private val HOSTNAME = Regex("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?)*$")
    private val IPV6 = Regex("^\\[[0-9A-Fa-f:.]+]$")

    /** GitHub's, GitLab's, Bitbucket's and Hugging Face's token prefixes. */
    private val TOKEN_PREFIXES = listOf(
        "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_",
        "glpat-", "gldt-", "glptt-", "glrt-",
        "ATBB", "ATCTT",
        "hf_",
    )
}
