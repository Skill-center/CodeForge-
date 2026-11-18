package dev.codeforge.app.search

/**
 * A search's include and exclude globs, with ripgrep's `-g` rules (Phase 4
 * W6; ripgrep's ignore crate, overrides.rs), so a scan leaves out exactly
 * what ripgrep leaves out of a project:
 * - **gitignore's syntax:** a glob without a slash matches a name at any
 *   depth; one with a slash, a path from the searched folder (a leading
 *   slash is dropped). A trailing slash matches folders only. `*` and `?`
 *   stop at a slash, `**` does not. `[...]`, `[!...]` and `{a,b}` work, and
 *   a backslash makes the next character plain.
 * - **The last glob that matches decides:** an include searches the file,
 *   an exclude leaves it out (a folder, with everything in it). Excludes
 *   come after includes, so an exclude wins over an include.
 * - **With includes, a file that matches none is left out.** Folders are
 *   entered unless an exclude matches them.
 */
class GlobFilter(includes: List<String>, excludes: List<String>) {
    private class Rule(val regex: Regex, val include: Boolean, val folderOnly: Boolean, val anchored: Boolean)

    private val rules: List<Rule> = includes.map { rule(it, include = true) } + excludes.map { rule(it, include = false) }
    private val hasIncludes = includes.isNotEmpty()

    /** Whether to search the file, or enter the folder, at [path] (named [name]). */
    fun accepts(path: String, name: String, isDirectory: Boolean): Boolean {
        var decision: Boolean? = null
        for (rule in rules) {
            if (rule.folderOnly && !isDirectory) continue
            if (rule.regex.matches(if (rule.anchored) path else name)) decision = rule.include
        }
        return decision ?: (isDirectory || !hasIncludes)
    }

    companion object {
        private const val WILDCARDS = "*?[{"

        /**
         * The globs as both engines take them: blanks dropped, and a glob
         * with no wildcard also standing for everything inside it, as VS
         * Code reads `src` in its include field: `src` adds a glob for
         * every path below any folder named `src`, and `a/b` one for every
         * path below `a/b`. (Spelled out in the tests: a slash and a star
         * would open a comment here, as Kotlin nests them.)
         */
        fun expand(globs: List<String>): List<String> {
            val out = ArrayList<String>()
            for (raw in globs) {
                val glob = raw.trim()
                if (glob.isEmpty()) continue
                out.add(glob)
                if (glob.none { it in WILDCARDS } && !glob.endsWith("/")) {
                    val bare = glob.removePrefix("/")
                    out.add(if ('/' in glob) "$glob/**" else "**/$bare/**")
                }
            }
            return out
        }

        /** Throws IllegalArgumentException naming the glob when it can't be read. */
        private fun rule(glob: String, include: Boolean): Rule {
            var body = glob
            val folderOnly = body.endsWith("/") && body.length > 1
            if (folderOnly) body = body.dropLast(1)
            val anchored = '/' in body
            if (body.startsWith("/")) body = body.substring(1)
            if (body.isEmpty()) throw IllegalArgumentException("The glob \"$glob\" matches nothing.")
            return Rule(regexOf(body, glob), include, folderOnly, anchored)
        }

        /** [body] as a regular expression over a '/'-separated path. */
        internal fun regexOf(body: String, glob: String = body): Regex {
            val out = StringBuilder()
            var braces = 0
            var i = 0
            while (i < body.length) {
                val c = body[i]
                when {
                    c == '*' && i + 1 < body.length && body[i + 1] == '*' -> {
                        val atStart = i == 0 || body[i - 1] == '/'
                        val after = i + 2
                        when {
                            atStart && after < body.length && body[after] == '/' -> {
                                out.append("(?:.*/)?")
                                i = after + 1
                                continue
                            }
                            atStart && after == body.length -> out.append(".*")
                            else -> out.append("[^/]*")
                        }
                        i = after
                        continue
                    }
                    c == '*' -> out.append("[^/]*")
                    c == '?' -> out.append("[^/]")
                    c == '[' -> {
                        val close = classEnd(body, i)
                        if (close < 0) {
                            out.append("\\[")
                        } else {
                            out.append(classOf(body.substring(i + 1, close)))
                            i = close
                        }
                    }
                    c == '{' -> {
                        braces += 1
                        out.append("(?:")
                    }
                    c == '}' && braces > 0 -> {
                        braces -= 1
                        out.append(")")
                    }
                    c == ',' && braces > 0 -> out.append("|")
                    c == '\\' && i + 1 < body.length -> {
                        out.append(Regex.escape(body[i + 1].toString()))
                        i += 1
                    }
                    else -> out.append(Regex.escape(c.toString()))
                }
                i += 1
            }
            if (braces > 0) throw IllegalArgumentException("The glob \"$glob\" opens a { it never closes.")
            return Regex(out.toString())
        }

        /** The index of the `]` closing the class that opens at [open], or -1. */
        private fun classEnd(body: String, open: Int): Int {
            var i = open + 1
            if (i < body.length && (body[i] == '!' || body[i] == '^')) i += 1
            if (i < body.length && body[i] == ']') i += 1
            while (i < body.length) {
                if (body[i] == ']') return i
                i += 1
            }
            return -1
        }

        private fun classOf(inner: String): String {
            val out = StringBuilder("[")
            var rest = inner
            if (rest.startsWith("!") || rest.startsWith("^")) {
                out.append('^')
                rest = rest.substring(1)
            }
            for (ch in rest) {
                if (ch == '\\' || ch == '[' || ch == ']' || ch == '&' || ch == '^') out.append('\\')
                out.append(ch)
            }
            // A class never matches the separator, as in gitignore.
            out.append(if (inner.startsWith("!") || inner.startsWith("^")) "/]" else "]")
            return if (inner.startsWith("!") || inner.startsWith("^")) out.toString() else "(?:(?!/)$out)"
        }
    }
}
