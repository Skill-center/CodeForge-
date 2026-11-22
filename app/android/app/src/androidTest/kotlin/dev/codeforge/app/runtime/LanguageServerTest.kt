package dev.codeforge.app.runtime

import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import dev.codeforge.runtime.core.HarnessConfig
import java.io.File
import java.io.IOException
import java.net.URI
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.ceil
import org.json.JSONArray
import org.json.JSONObject
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runners.MethodSorters

/**
 * Phase 6 W1, the compatibility spike (docs/phases/PHASE_6_PLAN.md §3, gate
 * G1; docs/LSP_ARCHITECTURE.md §2): each candidate language server under the
 * sealed runtime's node, through the smoke suite, with its start, its first
 * diagnostics, its completion latency and its memory recorded.
 *
 *   * The candidates: Pyright 1.1.414 for Python, and typescript-language-server
 *     6.1.0 with TypeScript 6.0.3 for TypeScript.
 *   * Since W2 they come from the app's own assets, as they ship: the
 *     installer (LanguageServers) extracts each from its archive into the
 *     runtime's state folder, verifying every file against its manifest
 *     (runtime/language_servers.py builds both from the pins in
 *     runtime/language-servers/). In W1 they came from this test APK's
 *     assets. They are JavaScript: the runtime's node runs them, as Run runs
 *     a user's script, with no new program. LanguageServerInstallTest tests
 *     the install itself.
 *   * Since W3 the servers run through LspHost, as the app runs them: the
 *     launcher starts each in a project's folder, in its own session and
 *     process group under the session limits, with its stdin open, and the
 *     host carries whole messages both ways (LspFrameReader) and says how it
 *     ended. This test speaks JSON-RPC 2.0 over the host, as Dart will (W4).
 *
 * Tests a and b run the smoke suite on two files: initialize; the error in the
 * diagnostics; completion offering a known member, then 50 times repeated and
 * 50 times after an edit; definition across the two files; rename across both;
 * the error fixed and its diagnostic gone; shutdown and exit, with no process
 * of the server's group left. Tests c and d do the same, without definition,
 * rename and the fix, on a generated project of 200 files. Test e (W3)
 * refuses a second Pyright while one runs, then kills the running one's node
 * with SIGKILL: the host reports it as signaled, and nothing of its group is
 * left. Every figure goes to the device log (RUNTIME_GATE lsp_...) and to
 * files/runtime-gate/lsp-report.txt, which the gate copies out.
 */
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class LanguageServerTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val gate = File(context.filesDir, "runtime-gate")

    private fun record(key: String, value: Any?) {
        val line = "lsp_$key=$value"
        Log.i(TAG, "RUNTIME_GATE $line")
        gate.mkdirs()
        File(gate, REPORT).appendText(line + "\n")
    }

    @Test
    fun a_pyrightPassesTheSmokeSuite() {
        File(gate, REPORT).delete()
        val described = servers().available()
        record("servers", described.flatMap { it.packages }.joinToString(",") { "${it.name}@${it.version}" })
        record("device_sdk", Build.VERSION.SDK_INT)
        record("abi", Build.SUPPORTED_ABIS.firstOrNull())
        install("pyright")
        smoke(
            Case(
                id = "pyright",
                server = "pyright",
                language = "python",
                options = JSONObject(),
                configuration = { section -> pythonConfiguration(section) },
                files = mapOf("a.py" to PY_MAIN, "b.py" to PY_OTHER),
                main = "a.py",
                other = "b.py",
                error = "undefined_thing",
                completeAt = "greeter.greet()" to "greeter.".length,
                member = "greet",
                defineAt = "Greeter(\"world\")" to 0,
                renameAt = "greeter.greet()" to "greeter.".length,
                newName = "salute",
                fix = "print(message, undefined_thing)" to "print(message, greeter.name)",
                comment = "#",
                unresolvedImport = "pip",
            ),
        )
    }

    @Test
    fun b_typescriptPassesTheSmokeSuite() {
        val server = install("typescript")
        smoke(
            Case(
                id = "typescript",
                server = "typescript",
                language = "typescript",
                options = typescriptOptions(File(server.directory, "node_modules/typescript")),
                configuration = { JSONObject() },
                files = mapOf("a.ts" to TS_MAIN, "b.ts" to TS_OTHER, "tsconfig.json" to TS_CONFIG),
                main = "a.ts",
                other = "b.ts",
                error = "not assignable",
                completeAt = "greeter.greet()" to "greeter.".length,
                member = "greet",
                defineAt = "Greeter(\"world\")" to 0,
                renameAt = "greeter.greet()" to "greeter.".length,
                newName = "salute",
                fix = "const count: number = \"three\";" to "const count: number = 3;",
                comment = "//",
                unresolvedImport = null,
            ),
        )
    }

    @Test
    fun c_pyrightOnAGeneratedProject() {
        install("pyright")
        val files = pythonProject()
        record("pyright_project_files", files.size)
        smoke(
            Case(
                id = "pyright_project",
                server = "pyright",
                language = "python",
                options = JSONObject(),
                configuration = { section -> pythonConfiguration(section) },
                files = files,
                main = "main.py",
                other = null,
                error = "not_defined_anywhere",
                completeAt = "thing.double()" to "thing.".length,
                member = "double",
                defineAt = null,
                renameAt = null,
                newName = null,
                fix = null,
                comment = "#",
                unresolvedImport = null,
            ),
        )
    }

    @Test
    fun d_typescriptOnAGeneratedProject() {
        val server = install("typescript")
        val files = typescriptProject()
        record("typescript_project_files", files.size)
        smoke(
            Case(
                id = "typescript_project",
                server = "typescript",
                language = "typescript",
                options = typescriptOptions(File(server.directory, "node_modules/typescript")),
                configuration = { JSONObject() },
                files = files,
                main = "src/main.ts",
                other = null,
                error = "not assignable",
                completeAt = "thing.double()" to "thing.".length,
                member = "double",
                defineAt = null,
                renameAt = null,
                newName = null,
                fix = null,
                comment = "//",
                unresolvedImport = null,
            ),
        )
    }

    /** The smoke suite for one server (the class's comment says what each step checks). */
    private fun smoke(case: Case) {
        val root = File(projects(), case.id).canonicalFile
        root.deleteRecursively()
        for ((name, content) in case.files) {
            val file = File(root, name)
            file.parentFile?.mkdirs()
            file.writeText(content)
        }
        val main = File(root, case.main)
        var text = case.files.getValue(case.main)
        var version = 1
        val started = SystemClock.elapsedRealtime()
        val client = Client(case.id, case.configuration, JSONArray().put(JSONObject().put("uri", uriOf(root)).put("name", root.name)))
        val launched = host().start(case.server, LspWorkspace(project = case.id), client)
        assertNull("${case.id}: ${launched.failure?.code} ${launched.detail}", launched.failure)
        val process = launched.server!!
        client.attach(host(), process.handle)
        val server = client
        val group = awaitGroup(process)
        var exit: LspExit? = null
        try {
            val initialized = server.request("initialize", initializeParams(case, root), INITIALIZE_TIMEOUT_MS).first
            record("${case.id}_initialize_ms", SystemClock.elapsedRealtime() - started)
            val capabilities = (initialized as? JSONObject)?.optJSONObject("capabilities")
            val info = (initialized as? JSONObject)?.optJSONObject("serverInfo")
            record("${case.id}_server", info?.let { "${it.optString("name")} ${it.optString("version")}".trim() } ?: "unnamed")
            record("${case.id}_sync", syncKind(capabilities?.opt("textDocumentSync")))
            server.notify("initialized", JSONObject())

            val opened = SystemClock.elapsedRealtime()
            server.notify(
                "textDocument/didOpen",
                JSONObject().put(
                    "textDocument",
                    JSONObject().put("uri", uriOf(main)).put("languageId", case.language).put("version", version).put("text", text),
                ),
            )
            val first = server.awaitDiagnostics(main, DIAGNOSTICS_TIMEOUT_MS) { list -> mentions(list, case.error) }
            record("${case.id}_first_diagnostics_ms", if (first == null) "none" else SystemClock.elapsedRealtime() - opened)
            assertNotNull("${case.id}: no diagnostic naming ${case.error}; stderr: ${process.stderrTail().takeLast(2000)}", first)
            val diagnostics = first!!
            record(
                "${case.id}_diagnostics",
                "count=${diagnostics.length()} errors=${severities(diagnostics, 1)} " +
                    "error=${messages(diagnostics).firstOrNull { it.contains(case.error) }?.take(120)}",
            )
            case.unresolvedImport?.let { name ->
                val unresolved = messages(diagnostics).any { it.contains("\"$name\"") && it.contains("could not be resolved") }
                record("${case.id}_import_$name", if (unresolved) "unresolved" else "resolved")
            }
            SystemClock.sleep(SETTLE_MS)
            record("${case.id}_memory_idle", memory(group))

            val completion = JSONObject()
                .put("textDocument", JSONObject().put("uri", uriOf(main)))
                .put("position", positionOf(text, case.completeAt))
                .put("context", JSONObject().put("triggerKind", 2).put("triggerCharacter", "."))
            val cold = server.request("textDocument/completion", completion, REQUEST_TIMEOUT_MS)
            val labels = labelsOf(cold.first)
            record("${case.id}_completion_cold", "ms=${cold.second / 1000} items=${labels.size} member=${labels.contains(case.member)}")
            assertTrue("${case.id}: ${case.member} is not among ${labels.take(30)}", labels.contains(case.member))
            val repeated = LongArray(WARM) { server.request("textDocument/completion", completion, REQUEST_TIMEOUT_MS).second }
            record("${case.id}_completion_repeat_us", spread(repeated))
            val afterEdit = LongArray(WARM)
            for (index in 0 until WARM) {
                val lineCount = text.count { it == '\n' }
                val insert = "${case.comment} edit $index\n"
                version += 1
                server.notify("textDocument/didChange", change(main, version, lineCount, 0, lineCount, 0, insert))
                text += insert
                val answer = server.request("textDocument/completion", completion, REQUEST_TIMEOUT_MS)
                assertTrue("${case.id}: ${case.member} is gone after edit $index", labelsOf(answer.first).contains(case.member))
                afterEdit[index] = answer.second
            }
            record("${case.id}_completion_edit_us", spread(afterEdit))
            record("${case.id}_completion_edit_p95_under_budget", if (rank(afterEdit, 0.95) <= COMPLETION_BUDGET_US) 1 else 0)
            record("${case.id}_memory_after", memory(group))

            val other = case.other?.let { File(root, it) }
            if (other != null && case.defineAt != null) {
                val definition = server.request("textDocument/definition", at(main, positionOf(text, case.defineAt)), REQUEST_TIMEOUT_MS)
                val targets = locationsOf(definition.first)
                val found = targets.any { pathOf(it) == other.canonicalPath }
                record("${case.id}_definition", "ok=$found ms=${definition.second / 1000} targets=${targets.size}")
                assertTrue("${case.id}: the definition went to $targets", found)
            }
            if (other != null && case.renameAt != null && case.newName != null) {
                val where = positionOf(text, case.renameAt)
                val prepared = server.request("textDocument/prepareRename", at(main, where), REQUEST_TIMEOUT_MS)
                assertTrue("${case.id}: prepareRename refused the symbol", prepared.first != JSONObject.NULL)
                val renamed = server.request("textDocument/rename", at(main, where).put("newName", case.newName), REQUEST_TIMEOUT_MS)
                val edited = editedPaths(renamed.first)
                record("${case.id}_rename", "files=${edited.size} ms=${renamed.second / 1000} prepare_ms=${prepared.second / 1000}")
                assertTrue("${case.id}: the rename edited $edited", edited.containsAll(listOf(main.canonicalPath, other.canonicalPath)))
            }
            case.fix?.let { (broken, fixed) ->
                val rangeStart = positionOf(text, broken to 0)
                val rangeEnd = positionOf(text, broken to broken.length)
                version += 1
                val fixing = SystemClock.elapsedRealtime()
                server.notify(
                    "textDocument/didChange",
                    change(
                        main, version,
                        rangeStart.getInt("line"), rangeStart.getInt("character"),
                        rangeEnd.getInt("line"), rangeEnd.getInt("character"),
                        fixed,
                    ),
                )
                val cleared = server.awaitDiagnostics(main, DIAGNOSTICS_TIMEOUT_MS) { list -> !mentions(list, case.error) }
                record("${case.id}_cleared_ms", if (cleared == null) "none" else SystemClock.elapsedRealtime() - fixing)
                assertNotNull("${case.id}: the diagnostics still name ${case.error}", cleared)
            }

            val ending = SystemClock.elapsedRealtime()
            server.request("shutdown", null, REQUEST_TIMEOUT_MS)
            server.notify("exit", null)
            val ended = server.waitForExit(EXIT_TIMEOUT_MS)
            exit = ended
            record(
                "${case.id}_shutdown",
                "end=${ended?.end?.code} exit=${ended?.exitCode} ms=${SystemClock.elapsedRealtime() - ending} " +
                    "messages=${process.received.get()} sent=${process.sent.get()} largest_message=${server.largest} " +
                    "log_messages=${server.logMessages}",
            )
            assertNotNull("${case.id}: the server did not exit after exit", ended)
            assertEquals("${case.id}: how it ended", LspEnd.EXITED, ended!!.end)
            assertEquals("${case.id}: the server's exit code", 0, ended.exitCode)
        } finally {
            if (exit == null) {
                host().stop(process.handle)
                server.waitForExit(EXIT_TIMEOUT_MS)
            }
            awaitGone(group)
            val left = group?.let { groupMembers(it) } ?: emptyList()
            record("${case.id}_left", "group_found=${group != null} processes=${left.size}")
        }
        assertNotNull("${case.id}: the launcher's process was not found", group)
        assertEquals("${case.id}: processes of the server's group left", emptyList<Int>(), groupMembers(group!!))
    }

    /** The runtime's language servers (LspHost), made with the class's runtime. */
    private fun host(): LspHost = commands().languageServers ?: throw AssertionError("the runtime has no language servers")

    /** The launcher's process group, once it has written it (it does so at once). */
    private fun awaitGroup(process: LanguageServerProcess): Int? {
        val deadline = SystemClock.elapsedRealtime() + FIND_TIMEOUT_MS
        while (SystemClock.elapsedRealtime() < deadline) {
            process.group()?.let { return it }
            SystemClock.sleep(FIND_POLL_MS)
        }
        return null
    }

    /** Waits for [group] to have no process left, at most [EXIT_TIMEOUT_MS]. */
    private fun awaitGone(group: Int?) {
        if (group == null) return
        val deadline = SystemClock.elapsedRealtime() + EXIT_TIMEOUT_MS
        while (groupMembers(group).isNotEmpty() && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(FIND_POLL_MS)
    }

    /**
     * W3: while Pyright runs a second one is refused, with the running one's
     * handle; then its node is killed with SIGKILL, as the kernel's OOM killer
     * or a crash would end it. The host reports it as signaled, with the
     * signal, and nothing of its process group is left.
     */
    @Test
    fun e_aServerKilledWithSigkillIsReportedAndItsTreeIsGone() {
        val root = File(projects(), "crash").canonicalFile
        root.deleteRecursively()
        root.mkdirs()
        File(root, "a.py").writeText(PY_MAIN)
        File(root, "b.py").writeText(PY_OTHER)
        val folders = JSONArray().put(JSONObject().put("uri", uriOf(root)).put("name", root.name))
        val client = Client("crash", { section -> pythonConfiguration(section) }, folders)
        val launched = host().start("pyright", LspWorkspace(project = "crash"), client)
        assertNull("${launched.failure?.code} ${launched.detail}", launched.failure)
        val process = launched.server!!
        client.attach(host(), process.handle)
        val group = awaitGroup(process)
        assertNotNull("the launcher's group", group)
        val params = JSONObject()
            .put("processId", JSONObject.NULL)
            .put("rootUri", uriOf(root))
            .put("workspaceFolders", folders)
            .put("capabilities", JSONObject())
        client.request("initialize", params, INITIALIZE_TIMEOUT_MS)
        client.notify("initialized", JSONObject())

        val second = host().start("pyright", LspWorkspace(project = "crash"), Client("second", { JSONObject() }, folders))
        record("second_pyright", "${second.failure?.code} running=${second.running == process.handle}")
        assertEquals(LspFailure.ALREADY_RUNNING, second.failure)
        assertEquals(process.handle, second.running)

        val child = process.child()
        assertNotNull("the launcher names node's pid", child)
        val killed = SystemClock.elapsedRealtime()
        Os.kill(child!!, OsConstants.SIGKILL)
        val exit = client.waitForExit(EXIT_TIMEOUT_MS)
        record("crash", "${exit?.end?.code}:${exit?.signal}")
        record(
            "crash_detail",
            "ms=${SystemClock.elapsedRealtime() - killed} stderr_bytes=${exit?.stderr?.length} " +
                "leftovers=${exit?.leftovers} remaining=${exit?.remaining}",
        )
        assertNotNull("no exit after SIGKILL", exit)
        assertEquals(LspEnd.SIGNALED, exit!!.end)
        assertEquals(OsConstants.SIGKILL, exit.signal)
        awaitGone(group)
        record("crash_left", groupMembers(group!!).size)
        assertEquals("processes of the killed server's group left", emptyList<Int>(), groupMembers(group))
        assertNull("the host still lists it", host().get(process.handle))
    }

    private fun initializeParams(case: Case, root: File): JSONObject =
        JSONObject()
            .put("processId", JSONObject.NULL)
            .put("clientInfo", JSONObject().put("name", "codeforge-spike").put("version", "1"))
            .put("rootUri", uriOf(root))
            .put("workspaceFolders", JSONArray().put(JSONObject().put("uri", uriOf(root)).put("name", root.name)))
            .put("initializationOptions", case.options)
            .put(
                "capabilities",
                JSONObject()
                    .put("general", JSONObject().put("positionEncodings", JSONArray().put("utf-16")))
                    .put(
                        "workspace",
                        JSONObject().put("configuration", true).put("workspaceFolders", true)
                            .put("didChangeConfiguration", JSONObject().put("dynamicRegistration", true)),
                    )
                    .put(
                        "textDocument",
                        JSONObject()
                            .put("synchronization", JSONObject().put("didSave", true).put("dynamicRegistration", false))
                            .put(
                                "completion",
                                JSONObject().put("contextSupport", true).put(
                                    "completionItem",
                                    JSONObject().put("snippetSupport", false)
                                        .put("documentationFormat", JSONArray().put("markdown").put("plaintext")),
                                ),
                            )
                            .put("hover", JSONObject().put("contentFormat", JSONArray().put("markdown").put("plaintext")))
                            .put("definition", JSONObject().put("linkSupport", false))
                            .put("rename", JSONObject().put("prepareSupport", true))
                            .put("publishDiagnostics", JSONObject().put("relatedInformation", false)),
                    )
                    .put("window", JSONObject().put("workDoneProgress", true)),
            )

    private fun pythonConfiguration(section: String?): Any =
        when (section) {
            "python" -> JSONObject().put("pythonPath", File(commands().environment.bin, "python").absolutePath)
            "python.analysis" -> JSONObject().put("diagnosticMode", "openFilesOnly")
            else -> JSONObject()
        }

    /** typescript-language-server's options: this TypeScript, one tsserver process, no typings fetched from the network. */
    private fun typescriptOptions(typescript: File): JSONObject =
        JSONObject()
            .put("tsserver", JSONObject().put("path", File(typescript, "lib/tsserver.js").absolutePath).put("useSyntaxServer", "never"))
            .put("disableAutomaticTypingAcquisition", true)

    private fun servers(): LanguageServers = LanguageServers(AssetPayloadSource(context), commands().environment.root)

    /** The server [id] from the app's assets: installed by the first test that asks, reused by the rest. */
    private fun install(id: String): LanguageServers.Installed {
        val installed = servers().ensure(id)
        record("${id}_install", "reused=${installed.reused} files=${installed.files} ms=${installed.millis}")
        return installed
    }

    /** The memory of every process in the server's group: PSS and RSS, in KiB, from /proc. */
    private fun memory(group: Int?): String {
        if (group == null) return "unknown"
        val members = groupMembers(group)
        var pss = 0L
        var rss = 0L
        for (pid in members) {
            pss += pssKib(pid)
            rss += statusKib(pid, "VmRSS:")
        }
        return "pss_kib=$pss rss_kib=$rss processes=${members.size}"
    }

    private fun pssKib(pid: Int): Long {
        val rollup = File("/proc/$pid/smaps_rollup")
        val rows = try {
            if (rollup.exists()) rollup.readLines() else File("/proc/$pid/smaps").readLines()
        } catch (gone: IOException) {
            return 0L
        }
        return rows.filter { it.startsWith("Pss:") }.sumOf { kib(it) }
    }

    private fun statusKib(pid: Int, key: String): Long =
        try {
            File("/proc/$pid/status").readLines().firstOrNull { it.startsWith(key) }?.let { kib(it) } ?: 0L
        } catch (gone: IOException) {
            0L
        }

    private fun kib(line: String): Long = line.substringAfter(':').trim().removeSuffix("kB").trim().toLongOrNull() ?: 0L

    private fun groupMembers(group: Int): List<Int> =
        ownProcesses().filter { pid -> stat(pid)?.getOrNull(2)?.toIntOrNull() == group }

    /** The app's processes (its user id's), zombies aside. */
    private fun ownProcesses(): Set<Int> {
        val uid = Os.getuid().toString()
        return File("/proc").listFiles().orEmpty().mapNotNull { it.name.toIntOrNull() }
            .filter { pid -> uidOf(pid) == uid }
            .filter { pid -> stat(pid)?.getOrNull(0)?.firstOrNull() != 'Z' }
            .toSet()
    }

    private fun uidOf(pid: Int): String? =
        try {
            File("/proc/$pid/status").readLines().firstOrNull { it.startsWith("Uid:") }
                ?.substringAfter(':')?.trim()?.split(Regex("\\s+"))?.firstOrNull()
        } catch (gone: Exception) {
            null
        }

    private fun arguments(pid: Int): List<String> =
        try {
            String(File("/proc/$pid/cmdline").readBytes(), Charsets.UTF_8).split('\u0000').filter { it.isNotEmpty() }
        } catch (gone: Exception) {
            emptyList()
        }

    /** /proc/<pid>/stat after its command name: state, parent, group, ... */
    private fun stat(pid: Int): List<String>? =
        try {
            val content = File("/proc/$pid/stat").readText()
            content.substring(content.lastIndexOf(')') + 2).split(' ')
        } catch (gone: Exception) {
            null
        }

    companion object {
        private const val TAG = "CodeForgeRuntimeGate"
        private const val REPORT = "lsp-report.txt"
        private const val WARM = 50
        private const val INITIALIZE_TIMEOUT_MS = 120_000L
        private const val DIAGNOSTICS_TIMEOUT_MS = 240_000L
        private const val REQUEST_TIMEOUT_MS = 60_000L
        private const val EXIT_TIMEOUT_MS = 15_000L
        private const val SETTLE_MS = 2_000L
        private const val FIND_TIMEOUT_MS = 5_000L
        private const val FIND_POLL_MS = 50L

        /** PERFORMANCE §2: completion within 300 ms at the 95th percentile, warm (recorded here, judged in W6). */
        private const val COMPLETION_BUDGET_US = 300_000L

        private val PY_MAIN = lines(
            "import pip",
            "from b import Greeter",
            "",
            "greeter = Greeter(\"world\")",
            "message = greeter.greet()",
            "print(message, undefined_thing)",
        )
        private val PY_OTHER = lines(
            "class Greeter:",
            "    def __init__(self, name: str) -> None:",
            "        self.name = name",
            "",
            "    def greet(self) -> str:",
            "        return \"hello \" + self.name",
        )
        private val TS_MAIN = lines(
            "import { Greeter } from \"./b\";",
            "",
            "const greeter = new Greeter(\"world\");",
            "const message: string = greeter.greet();",
            "const count: number = \"three\";",
            "export { message, count };",
        )
        private val TS_OTHER = lines(
            "export class Greeter {",
            "  constructor(public name: string) {}",
            "",
            "  greet(): string {",
            "    return \"hello \" + this.name;",
            "  }",
            "}",
        )
        private val TS_CONFIG = lines(
            "{\"compilerOptions\": {\"strict\": true, \"target\": \"ES2022\", \"module\": \"ES2022\", " +
                "\"moduleResolution\": \"Bundler\", \"noEmit\": true}, \"include\": [\"*.ts\"]}",
        )
        private const val PROJECT_MODULES = 200

        private fun lines(vararg content: String): String = content.joinToString("\n", postfix = "\n")

        /** A Python project of 200 modules, and a main file that imports all of them and names one undefined thing. */
        private fun pythonProject(): Map<String, String> {
            val files = LinkedHashMap<String, String>()
            files["pkg/__init__.py"] = ""
            val imports = StringBuilder()
            for (index in 0 until PROJECT_MODULES) {
                val n = index.toString().padStart(3, '0')
                files["pkg/m$n.py"] = lines(
                    "class Thing$n:",
                    "    \"\"\"Thing number $index.\"\"\"",
                    "",
                    "    def __init__(self, value: int) -> None:",
                    "        self.value = value",
                    "",
                    "    def double(self) -> int:",
                    "        return self.value * 2",
                    "",
                    "    def describe(self) -> str:",
                    "        return \"thing $index: \" + str(self.value)",
                    "",
                    "",
                    "def make_$n(value: int) -> Thing$n:",
                    "    return Thing$n(value)",
                )
                imports.append("from pkg.m$n import make_$n\n")
            }
            val last = (PROJECT_MODULES - 1).toString().padStart(3, '0')
            files["main.py"] = imports.toString() + lines(
                "",
                "thing = make_$last(3)",
                "total = thing.double() + make_000(1).double()",
                "print(total, not_defined_anywhere)",
            )
            return files
        }

        /** The same project in TypeScript, with a tsconfig.json over src. */
        private fun typescriptProject(): Map<String, String> {
            val files = LinkedHashMap<String, String>()
            val imports = StringBuilder()
            for (index in 0 until PROJECT_MODULES) {
                val n = index.toString().padStart(3, '0')
                files["src/m$n.ts"] = lines(
                    "export class Thing$n {",
                    "  constructor(public value: number) {}",
                    "",
                    "  double(): number {",
                    "    return this.value * 2;",
                    "  }",
                    "",
                    "  describe(): string {",
                    "    return \"thing $index: \" + this.value;",
                    "  }",
                    "}",
                    "",
                    "export function make$n(value: number): Thing$n {",
                    "  return new Thing$n(value);",
                    "}",
                )
                imports.append("import { make$n } from \"./m$n\";\n")
            }
            val last = (PROJECT_MODULES - 1).toString().padStart(3, '0')
            files["src/main.ts"] = imports.toString() + lines(
                "",
                "const thing = make$last(3);",
                "const total: number = thing.double() + make000(1).double();",
                "const wrong: number = \"x\";",
                "export { total, wrong };",
            )
            files["tsconfig.json"] = lines(
                "{\"compilerOptions\": {\"strict\": true, \"target\": \"ES2022\", \"module\": \"ES2022\", " +
                    "\"moduleResolution\": \"Bundler\", \"noEmit\": true}, \"include\": [\"src\"]}",
            )
            return files
        }

        private fun uriOf(file: File): String = "file://" + file.canonicalPath

        private fun pathOf(uri: String): String? =
            try {
                URI(uri).path?.let { File(it).canonicalPath }
            } catch (bad: Exception) {
                null
            }

        /** The line and UTF-16 character of a marker in the text, plus an offset into it. */
        private fun positionOf(text: String, at: Pair<String, Int>): JSONObject {
            val found = text.indexOf(at.first)
            assertTrue("the fixture has no ${at.first}", found >= 0)
            val index = found + at.second
            val line = text.substring(0, index).count { it == '\n' }
            val lineStart = text.lastIndexOf('\n', index - 1) + 1
            return JSONObject().put("line", line).put("character", index - lineStart)
        }

        private fun at(file: File, position: JSONObject): JSONObject =
            JSONObject().put("textDocument", JSONObject().put("uri", uriOf(file))).put("position", JSONObject(position.toString()))

        /** An incremental didChange: one range replaced by [replacement]. */
        private fun change(file: File, version: Int, fromLine: Int, fromCharacter: Int, toLine: Int, toCharacter: Int, replacement: String) =
            JSONObject()
                .put("textDocument", JSONObject().put("uri", uriOf(file)).put("version", version))
                .put(
                    "contentChanges",
                    JSONArray().put(
                        JSONObject()
                            .put(
                                "range",
                                JSONObject()
                                    .put("start", JSONObject().put("line", fromLine).put("character", fromCharacter))
                                    .put("end", JSONObject().put("line", toLine).put("character", toCharacter)),
                            )
                            .put("text", replacement),
                    ),
                )

        private fun syncKind(sync: Any?): String =
            when (sync) {
                is Int -> sync.toString()
                is JSONObject -> sync.opt("change")?.toString() ?: "none"
                else -> "none"
            }

        private fun messages(list: JSONArray): List<String> =
            (0 until list.length()).mapNotNull { index -> list.optJSONObject(index)?.optString("message") }

        private fun mentions(list: JSONArray, text: String): Boolean = messages(list).any { it.contains(text) }

        private fun severities(list: JSONArray, severity: Int): Int =
            (0 until list.length()).count { index -> list.optJSONObject(index)?.optInt("severity") == severity }

        private fun labelsOf(result: Any): List<String> {
            val items = when (result) {
                is JSONArray -> result
                is JSONObject -> result.optJSONArray("items") ?: JSONArray()
                else -> JSONArray()
            }
            return (0 until items.length()).mapNotNull { index -> items.optJSONObject(index)?.optString("label") }
        }

        private fun locationsOf(result: Any): List<String> {
            val entries = when (result) {
                is JSONArray -> (0 until result.length()).mapNotNull { index -> result.optJSONObject(index) }
                is JSONObject -> listOf(result)
                else -> emptyList()
            }
            return entries.mapNotNull { entry -> entry.optString("uri").ifEmpty { entry.optString("targetUri") }.ifEmpty { null } }
        }

        /** The canonical paths a WorkspaceEdit changes, from `changes` and `documentChanges`. */
        private fun editedPaths(result: Any): Set<String> {
            val edit = result as? JSONObject ?: return emptySet()
            val uris = mutableSetOf<String>()
            edit.optJSONObject("changes")?.keys()?.forEach { uri -> uris.add(uri.toString()) }
            val changes = edit.optJSONArray("documentChanges")
            if (changes != null) {
                for (index in 0 until changes.length()) {
                    val uri = changes.optJSONObject(index)?.optJSONObject("textDocument")?.optString("uri")
                    if (!uri.isNullOrEmpty()) uris.add(uri)
                }
            }
            return uris.mapNotNull { pathOf(it) }.toSet()
        }

        /** The nearest-rank percentile [q] of [micros]. */
        private fun rank(micros: LongArray, q: Double): Long {
            val sorted = micros.sorted()
            return sorted[(ceil(q * sorted.size).toInt() - 1).coerceIn(0, sorted.size - 1)]
        }

        private fun spread(micros: LongArray): String =
            "n=${micros.size} p50=${rank(micros, 0.50)} p95=${rank(micros, 0.95)} max=${micros.maxOrNull()}"

        private var installed: RuntimeCommands? = null
        private var projectsDir: File? = null

        /** The class's projects' folder: each case's files are a project the server works in. */
        fun projects(): File {
            commands()
            return projectsDir!!
        }

        /** The payload installed once for the class, in a root of its own, and its command side. */
        @Synchronized
        fun commands(): RuntimeCommands {
            installed?.let { return it }
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val root = File(context.filesDir, "runtime-gate/lsp")
            root.deleteRecursively()
            val rootfs = File(root, "rootfs")
            val prefix = File(rootfs, "data/data/com.termux/files/usr")
            val config = HarnessConfig.Builder()
                .workspace(File(root, "workspace"))
                .home(File(root, "home"))
                .prefix(prefix)
                .rootfs(rootfs)
                .toolDirectory(File(prefix, "bin"))
                .libraryDirectory(File(prefix, "lib"))
                .nativeLibraryDirectory(File(context.applicationInfo.nativeLibraryDir))
                .build()
            val runtime = SealedRuntime(AssetPayloadSource(context), config)
            if (runtime.payload() == null) throw AssertionError("this APK carries no payload")
            runtime.install(null)
            val projectsFolder = File(root, "projects").apply { mkdirs() }
            projectsDir = projectsFolder
            val created = RuntimeCommands.create(
                config = config,
                killGroup = { group -> Os.kill(-group, OsConstants.SIGKILL) },
                projects = projectsFolder,
                serverSource = AssetPayloadSource(context),
            )
            installed = created
            return created
        }

        /** The class's runtime root goes once its tests are done: each gate class installs its own. */
        @JvmStatic
        @AfterClass
        fun removeTheRuntime() {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            installed?.languageServers?.stopAll()
            File(context.filesDir, "runtime-gate/lsp").deleteRecursively()
            installed = null
            projectsDir = null
        }
    }
}

/** One server's smoke suite: its fixture and where each step looks (null skips a step). */
private class Case(
    val id: String,
    /** The server's id in the APK (lsp/servers.json): LspHost starts it with its entry and arguments. */
    val server: String,
    val language: String,
    val options: JSONObject,
    val configuration: (String?) -> Any,
    val files: Map<String, String>,
    val main: String,
    val other: String?,
    val error: String,
    val completeAt: Pair<String, Int>,
    val member: String,
    val defineAt: Pair<String, Int>?,
    val renameAt: Pair<String, Int>?,
    val newName: String?,
    val fix: Pair<String, String>?,
    val comment: String,
    /** A third-party module the file imports: whether the server resolved it is recorded. */
    val unresolvedImport: String?,
)

/**
 * JSON-RPC 2.0 over LspHost (Phase 6 W3), as Dart will speak it (W4): the
 * host carries whole messages; this class numbers requests and waits for
 * their answers, answers the server's own requests at once, and queues its
 * diagnostics.
 */
private class Client(
    private val id: String,
    private val configuration: (String?) -> Any,
    private val folders: JSONArray,
) : LspListener {
    private var host: LspHost? = null
    private var handle: Long = -1L
    private val nextId = AtomicInteger(1)
    private val waiting = ConcurrentHashMap<Int, LinkedBlockingQueue<JSONObject>>()
    private val diagnostics = LinkedBlockingQueue<JSONObject>()
    private val exits = LinkedBlockingQueue<LspExit>()

    @Volatile
    private var exited: LspExit? = null

    /** The largest message the server wrote, in bytes. */
    @Volatile
    var largest = 0
        private set

    @Volatile
    var logMessages = 0
        private set

    fun attach(host: LspHost, handle: Long) {
        this.host = host
        this.handle = handle
    }

    override fun onMessage(handle: Long, message: String) {
        val bytes = message.toByteArray(Charsets.UTF_8).size
        if (bytes > largest) largest = bytes
        dispatch(JSONObject(message))
    }

    override fun onExit(exit: LspExit) {
        exited = exit
        exits.offer(exit)
    }

    /** Sends [method] and waits for its answer: the result (JSONObject.NULL for null) and the round trip in µs. */
    fun request(method: String, params: JSONObject?, timeoutMs: Long): Pair<Any, Long> {
        val number = nextId.getAndIncrement()
        val queue = LinkedBlockingQueue<JSONObject>()
        waiting[number] = queue
        val message = JSONObject().put("jsonrpc", "2.0").put("id", number).put("method", method)
        if (params != null) message.put("params", params)
        val started = System.nanoTime()
        send(message)
        val answer = try {
            queue.poll(timeoutMs, TimeUnit.MILLISECONDS)
        } finally {
            waiting.remove(number)
        }
        val micros = (System.nanoTime() - started) / 1_000L
        if (answer == null) {
            throw AssertionError("$id: no answer to $method in $timeoutMs ms (exit: ${exited?.end?.code}); stderr: ${exited?.stderr?.takeLast(STDERR_SHOWN)}")
        }
        val error = answer.optJSONObject("error")
        if (error != null) throw AssertionError("$id: $method failed: $error")
        return Pair(answer.opt("result") ?: JSONObject.NULL, micros)
    }

    fun notify(method: String, params: JSONObject?) {
        val message = JSONObject().put("jsonrpc", "2.0").put("method", method)
        if (params != null) message.put("params", params)
        send(message)
    }

    /** The next diagnostics for [file] that [accept] takes, or null once [timeoutMs] has passed. */
    fun awaitDiagnostics(file: File, timeoutMs: Long, accept: (JSONArray) -> Boolean): JSONArray? {
        val wanted = file.canonicalPath
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (true) {
            val left = deadline - SystemClock.elapsedRealtime()
            if (left <= 0) return null
            val params = diagnostics.poll(left, TimeUnit.MILLISECONDS) ?: return null
            val list = params.optJSONArray("diagnostics") ?: JSONArray()
            if (pathOf(params.optString("uri")) == wanted && accept(list)) return list
        }
    }

    /** The server's exit, or null when it has not exited within [timeoutMs]. */
    fun waitForExit(timeoutMs: Long): LspExit? = exited ?: exits.poll(timeoutMs, TimeUnit.MILLISECONDS)

    private fun send(message: JSONObject) {
        val target = host ?: throw AssertionError("$id: not attached to a server")
        val refused = target.send(handle, message.toString())
        if (refused != null) throw AssertionError("$id: the host refused a message: ${refused.code}")
    }

    private fun dispatch(message: JSONObject) {
        val method = message.optString("method", "")
        val hasId = message.has("id") && !message.isNull("id")
        when {
            method.isEmpty() && hasId -> waiting[message.optInt("id")]?.offer(message)
            method.isNotEmpty() && hasId -> answer(message, method)
            method == "textDocument/publishDiagnostics" -> message.optJSONObject("params")?.let { diagnostics.offer(it) }
            method == "window/logMessage" -> logMessages += 1
        }
    }

    /** Answers the server's own requests: its configuration, the workspace's folders, and null for the rest. */
    private fun answer(request: JSONObject, method: String) {
        val result: Any = when (method) {
            "workspace/configuration" -> {
                val items = request.optJSONObject("params")?.optJSONArray("items") ?: JSONArray()
                val answers = JSONArray()
                for (index in 0 until items.length()) {
                    val section = items.optJSONObject(index)?.optString("section")?.takeIf { it.isNotEmpty() }
                    answers.put(configuration(section))
                }
                answers
            }
            "workspace/workspaceFolders" -> folders
            else -> JSONObject.NULL
        }
        send(JSONObject().put("jsonrpc", "2.0").put("id", request.get("id")).put("result", result))
    }

    private companion object {
        const val STDERR_SHOWN = 2_000

        fun pathOf(uri: String): String? =
            try {
                URI(uri).path?.let { File(it).canonicalPath }
            } catch (bad: Exception) {
                null
            }
    }
}
