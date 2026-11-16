package dev.codeforge.app.runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The tool probes (Phase 4 W4, gate G4): each version read from its probe's
 * output and compared with its package's pin from the payload's
 * runtime-info JSON; a probe that fails, says no version or finds no
 * program is reported as such. The commands are the test's own here; the
 * emulator gate runs the real ones (RuntimeCommandsTest).
 */
class ToolchainTest {
    /** runtime/pins.py `info`'s JSON as it writes it: indented, keys sorted. */
    private val info = """
        {
          "abi": "x86_64",
          "bootstrap": "2026.02.12-r1+apt.android-7",
          "core": [
            {
              "package": "git",
              "version": "2.56.1"
            }
          ],
          "packages": 112,
          "tools": [
            {
              "package": "nodejs",
              "tool": "node",
              "version": "26.13.1"
            },
            {
              "package": "python",
              "tool": "python",
              "version": "3.14.10"
            },
            {
              "package": "git",
              "tool": "git",
              "version": "2.56.1"
            },
            {
              "package": "bash",
              "tool": "bash",
              "version": "5.3.9"
            },
            {
              "package": "perl",
              "tool": "perl",
              "version": "5.44.0-1"
            },
            {
              "package": "ruby",
              "tool": "ruby",
              "version": "4.0.9"
            },
            {
              "package": "ripgrep",
              "tool": "rg",
              "version": "15.2.0"
            }
          ]
        }
    """.trimIndent()

    /** What each tool prints when it is well. */
    private val healthy = mapOf(
        "node" to "26.13.1 /data/user/0/dev.codeforge.app/files/coding-harness/rootfs/data/data/com.termux/files/usr/lib/node_modules/npm/package.json\n",
        "python" to "3.14.10 OpenSSL 3.6.5 30 Sep 2026\n",
        "git" to "git version 2.56.1\n",
        "bash" to "5.3.9(1)-release\n",
        "perl" to "5.44.0 3\n",
        "ruby" to "4.0.9 /data/user/0/dev.codeforge.app/files/coding-harness/rootfs/data/data/com.termux/files/usr/lib/ruby/gems/4.0.0\n",
        "rg" to "ripgrep 15.2.0\n\nfeatures:+pcre2\n",
    )

    private fun ran(stdout: String, exitCode: Int = 0, stderr: String = "") = CommandResult(
        exitCode, null, CommandOutput(stdout, stdout.length.toLong(), false),
        CommandOutput(stderr, stderr.length.toLong(), false), 12L, null, null, 0, 0,
    )

    private fun toolchain(
        present: (String) -> Boolean = { true },
        answer: (CommandRequest) -> CommandResult = { request -> ran(healthy.getValue(request.program)) },
    ): Pair<Toolchain, MutableList<CommandRequest>> {
        val asked = mutableListOf<CommandRequest>()
        val toolchain = Toolchain(run = { request -> asked.add(request); answer(request) }, present = present)
        return toolchain to asked
    }

    @Test
    fun thePinsComeFromThePayloadsInfo() {
        val pins = Toolchain.pinsFrom(info)
        assertEquals(listOf("node", "python", "git", "bash", "perl", "ruby", "rg"), pins.keys.toList())
        assertEquals(ToolPin("rg", "ripgrep", "15.2.0"), pins["rg"])
        assertEquals("5.44.0-1", pins.getValue("perl").version)
        assertTrue(Toolchain.pinsFrom(null).isEmpty())
        assertTrue(Toolchain.pinsFrom("{\"abi\": \"x86_64\", \"bootstrap\": \"test\"}").isEmpty())
    }

    @Test
    fun everyToolIsItsPinnedVersion() {
        val (toolchain, asked) = toolchain()
        val report = toolchain.inspect(Toolchain.pinsFrom(info))
        assertEquals(7, report.tools.size)
        for (tool in report.tools) assertEquals(tool.tool + ": " + tool.detail, ToolHealth.OK, tool.health)
        val versions = report.tools.associate { it.tool to it.version }
        assertEquals("26.13.1", versions["node"])
        assertEquals("5.3.9", versions["bash"])
        assertEquals("5.44.0", versions["perl"])
        assertEquals("15.2.0", versions["rg"])
        assertEquals("5.44.0-1", report.tools.single { it.tool == "perl" }.pinned)
        assertEquals("3.14.10 OpenSSL 3.6.5 30 Sep 2026", report.tools.single { it.tool == "python" }.detail)
        // Each probe is one bounded command.
        assertEquals(listOf("node", "python", "git", "bash", "perl", "ruby", "rg"), asked.map { it.program })
        assertTrue(asked.all { it.timeoutMs == Toolchain.PROBE_TIMEOUT_MS && it.outputLimit == Toolchain.PROBE_OUTPUT_LIMIT })
        // The probes load each interpreter's libraries, not only its version.
        assertTrue(asked.single { it.program == "python" }.arguments.last().contains("import sys, ssl, json, sqlite3"))
        assertTrue(asked.single { it.program == "node" }.arguments.last().contains("require.resolve('npm/package.json')"))
        assertTrue(asked.single { it.program == "perl" }.arguments.contains("-MList::Util=sum"))
        assertTrue(asked.single { it.program == "ruby" }.arguments.last().contains("require 'rubygems'"))
    }

    @Test
    fun aVersionThatIsNotThePinnedOneIsAMismatch() {
        val (toolchain, _) = toolchain(answer = { request ->
            if (request.program == "python") ran("3.13.0 OpenSSL 3.0\n") else ran(healthy.getValue(request.program))
        })
        val python = toolchain.inspect(Toolchain.pinsFrom(info)).tools.single { it.tool == "python" }
        assertEquals(ToolHealth.MISMATCH, python.health)
        assertEquals("3.13.0", python.version)
        assertTrue(python.detail!!, python.detail!!.startsWith("pinned 3.14.10"))
    }

    @Test
    fun aToolWithoutAPinIsNotTakenForTheRightOne() {
        val (toolchain, _) = toolchain()
        val report = toolchain.inspect(emptyMap())
        assertTrue(report.tools.all { it.health == ToolHealth.MISMATCH })
        assertTrue(report.tools.first().detail!!.startsWith("no pinned version"))
    }

    @Test
    fun aProbeThatFailsSaysWhy() {
        val (toolchain, _) = toolchain(answer = { request ->
            when (request.program) {
                "ruby" -> ran("", exitCode = 1, stderr = "<internal:gem_prelude>:1:in 'require': cannot load such file -- rubygems.rb (LoadError)\n")
                "git" -> CommandResult.failed(CommandFailure.TIMED_OUT, "it ran past its time limit", 30_000L)
                "rg" -> ran("something else entirely\n")
                else -> ran(healthy.getValue(request.program))
            }
        })
        val tools = toolchain.inspect(Toolchain.pinsFrom(info)).tools.associateBy { it.tool }
        assertEquals(ToolHealth.FAILED, tools.getValue("ruby").health)
        assertNull(tools.getValue("ruby").version)
        assertTrue(tools.getValue("ruby").detail!!, tools.getValue("ruby").detail!!.contains("exit 1: <internal:gem_prelude>"))
        assertEquals(ToolHealth.FAILED, tools.getValue("git").health)
        assertTrue(tools.getValue("git").detail!!, tools.getValue("git").detail!!.startsWith("timed_out"))
        assertEquals(ToolHealth.FAILED, tools.getValue("rg").health)
        assertTrue(tools.getValue("rg").detail!!.startsWith("no version in"))
        assertEquals(ToolHealth.OK, tools.getValue("node").health)
    }

    @Test
    fun aProgramThePayloadLacksIsMissingAndNotRun() {
        val (toolchain, asked) = toolchain(present = { it != "ruby" })
        val ruby = toolchain.inspect(Toolchain.pinsFrom(info)).tools.single { it.tool == "ruby" }
        assertEquals(ToolHealth.MISSING, ruby.health)
        assertTrue(asked.none { it.program == "ruby" })
    }

    @Test
    fun theUpstreamVersionDropsTheEpochAndTheRevision() {
        assertEquals("5.44.0", Toolchain.upstream("5.44.0-1"))
        assertEquals("2026.11.05", Toolchain.upstream("1:2026.11.05-1"))
        assertEquals("3.6.5", Toolchain.upstream("1:3.6.5"))
        assertEquals("26.13.1", Toolchain.upstream("26.13.1"))
        assertEquals("10.6p2", Toolchain.upstream("10.6p2"))
        assertEquals("6.6.20260307+really6.5.20250830", Toolchain.upstream("6.6.20260307+really6.5.20250830"))
    }

    @Test
    fun whenTheRuntimeIsNotReadyNothingIsProbed() {
        val report = Toolchain.unavailable("the runtime is notInstalled")
        assertEquals(7, report.tools.size)
        assertTrue(report.tools.all { it.health == ToolHealth.UNAVAILABLE })
        assertEquals("the runtime is notInstalled", report.failure)
    }
}
