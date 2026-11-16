package dev.codeforge.app.runtime

/** How one tool of the runtime is. Each code travels to Dart. */
enum class ToolHealth(val code: String) {
    /** It ran, its libraries loaded, and it is the pinned version. */
    OK("ok"),

    /** It ran, and its version is not the pinned one (or there is no pin to compare). */
    MISMATCH("mismatch"),

    /** It did not run, failed, or said no version. */
    FAILED("failed"),

    /** The payload has no such program. */
    MISSING("missing"),

    /** The runtime is not ready, so nothing was probed. */
    UNAVAILABLE("unavailable"),
}

/** One probe's outcome. */
data class ToolReport(
    val tool: String,
    val packageName: String,
    /** What the tool said its version is. */
    val version: String?,
    /** Its package's pinned version (runtime/pins.json), as the payload records it. */
    val pinned: String?,
    val health: ToolHealth,
    /** The probe's first line of output, or why it failed. */
    val detail: String?,
    val millis: Long,
)

data class ToolsReport(
    val tools: List<ToolReport>,
    val millis: Long,
    /** Why nothing was probed, or null. */
    val failure: String? = null,
)

/** A tool's package and pinned version, from the payload's runtime-info JSON. */
data class ToolPin(val tool: String, val packageName: String, val version: String)

/**
 * The tool probes (Phase 4 W4, gate G4): node, python, git, bash, perl, ruby
 * and rg, each run once through the runtime's commands, each version
 * compared with its package's pin. CodeForge's own, in place of t1's
 * Toolchain, which only looks whether each program is there.
 *
 * Each probe is one command that prints the version first and proves the
 * tool's libraries load: python imports ssl, json and sqlite3 (t1's
 * SealedShellTest probe) through PYTHONHOME; node resolves npm through
 * NODE_PATH; perl loads strict and List::Util, an XS module, through
 * PERL5LIB; ruby loads rubygems and securerandom through RUBYLIB and reports
 * its gem folder.
 */
class Toolchain(
    private val run: (CommandRequest) -> CommandResult,
    /** Whether the runtime's bin has a program of that name. */
    private val present: (String) -> Boolean,
    private val clock: () -> Long = System::nanoTime,
) {
    /** One tool's probe: its program, its arguments, and where its version is in the output. */
    data class Probe(
        val tool: String,
        val packageName: String,
        val program: String,
        val arguments: List<String>,
        val version: Regex,
    )

    /** Runs every probe, one after another. */
    fun inspect(pins: Map<String, ToolPin>): ToolsReport {
        val started = clock()
        val reports = PROBES.map { probe -> inspect(probe, pins[probe.tool]) }
        return ToolsReport(reports, (clock() - started) / 1_000_000L)
    }

    fun inspect(probe: Probe, pin: ToolPin?): ToolReport {
        if (!present(probe.program)) {
            return ToolReport(probe.tool, probe.packageName, null, pin?.version, ToolHealth.MISSING, "the runtime has no ${probe.program}", 0L)
        }
        val started = clock()
        val result = run(
            CommandRequest(
                program = probe.program,
                arguments = probe.arguments,
                timeoutMs = PROBE_TIMEOUT_MS,
                outputLimit = PROBE_OUTPUT_LIMIT,
            ),
        )
        val millis = (clock() - started) / 1_000_000L
        val pinned = pin?.version
        fun report(version: String?, health: ToolHealth, detail: String?) =
            ToolReport(probe.tool, probe.packageName, version, pinned, health, detail, millis)

        if (result.failure != null) {
            return report(null, ToolHealth.FAILED, "${result.failure.code}: ${result.detail ?: ""} ${firstLines(result.stderr.text)}".trim())
        }
        val output = result.stdout.text.trim()
        if (result.exitCode != 0) {
            return report(null, ToolHealth.FAILED, "exit ${result.exitCode}: ${firstLines(result.stderr.text).ifEmpty { firstLines(output) }}")
        }
        val version = probe.version.find(output)?.groupValues?.get(1)
            ?: return report(null, ToolHealth.FAILED, "no version in: ${firstLines(output)}")
        val detail = output.lineSequence().firstOrNull()?.take(DETAIL_LIMIT)
        return when {
            pinned == null -> report(version, ToolHealth.MISMATCH, "no pinned version in this payload; $detail")
            version != upstream(pinned) -> report(version, ToolHealth.MISMATCH, "pinned ${upstream(pinned)}; $detail")
            else -> report(version, ToolHealth.OK, detail)
        }
    }

    companion object {
        const val PROBE_TIMEOUT_MS = 30_000L
        const val PROBE_OUTPUT_LIMIT = 16 * 1024
        private const val DETAIL_LIMIT = 300

        private val SEMVER = Regex("^(\\d+\\.\\d+\\.\\d+)")

        // runtime-info's "tools": [{"package": "...", "tool": "...", "version": "..."}, ...]
        private val TOOLS_LIST = Regex("\"tools\"\\s*:\\s*\\[(.*?)\\]", RegexOption.DOT_MATCHES_ALL)
        private val OBJECT = Regex("\\{([^{}]*)\\}")
        private val FIELD = Regex("\"(\\w+)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"")

        val PROBES: List<Probe> = listOf(
            Probe(
                "node", "nodejs", "node",
                listOf("-e", "process.stdout.write(process.versions.node + ' ' + require.resolve('npm/package.json') + '\\n')"),
                SEMVER,
            ),
            Probe(
                "python", "python", "python",
                listOf("-c", "import sys, ssl, json, sqlite3; print('%d.%d.%d' % sys.version_info[:3], ssl.OPENSSL_VERSION)"),
                SEMVER,
            ),
            Probe("git", "git", "git", listOf("--version"), Regex("""git version (\d+\.\d+\.\d+)""")),
            Probe("bash", "bash", "bash", listOf("-c", "echo \"\$BASH_VERSION\""), Regex("""^(\d+\.\d+(?:\.\d+)?)""")),
            Probe(
                "perl", "perl", "perl",
                listOf("-Mstrict", "-MList::Util=sum", "-e", "print substr(\$^V, 1), ' ', sum(1, 2), \"\\n\""),
                SEMVER,
            ),
            Probe(
                "ruby", "ruby", "ruby",
                listOf("-e", "require 'rubygems'; require 'securerandom'; puts \"#{RUBY_VERSION} #{Gem.dir}\""),
                SEMVER,
            ),
            Probe("rg", "ripgrep", "rg", listOf("--version"), Regex("""ripgrep (\d+\.\d+\.\d+)""")),
        )

        /**
         * A Debian version's upstream part: no epoch ("1:"), no package
         * revision ("-1"). perl's 5.44.0-1 says 5.44.0.
         */
        fun upstream(version: String): String =
            version.substringAfter(':').replace(Regex("""-[0-9][0-9A-Za-z.+~]*$"""), "")

        /** The tools' pins in runtime/pins.py's `info` JSON (its "tools" list), by tool. */
        fun pinsFrom(info: String?): Map<String, ToolPin> {
            if (info == null) return emptyMap()
            val list = TOOLS_LIST.find(info)?.groupValues?.get(1) ?: return emptyMap()
            val pins = LinkedHashMap<String, ToolPin>()
            for (entry in OBJECT.findAll(list)) {
                val fields = FIELD.findAll(entry.groupValues[1]).associate { it.groupValues[1] to it.groupValues[2] }
                val tool = fields["tool"] ?: continue
                val packageName = fields["package"] ?: continue
                val version = fields["version"] ?: continue
                pins[tool] = ToolPin(tool, packageName, version)
            }
            return pins
        }

        /** Every tool UNAVAILABLE: the runtime is not ready. */
        fun unavailable(why: String): ToolsReport =
            ToolsReport(
                PROBES.map { ToolReport(it.tool, it.packageName, null, null, ToolHealth.UNAVAILABLE, why, 0L) },
                0L,
                why,
            )

        private fun firstLines(text: String): String =
            text.trim().lineSequence().take(3).joinToString(" | ").take(DETAIL_LIMIT)
    }
}
