package dev.codeforge.app.runtime

import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import android.os.Handler
import android.os.Looper
import android.system.Os
import android.system.OsConstants
import android.util.Log
import dev.codeforge.app.terminal.SessionKeeper
import dev.codeforge.runtime.core.HarnessConfig
import io.flutter.plugin.common.BinaryMessenger
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * The runtime host (Phase 4 W3; docs/RUNTIME_INTEGRATION.md §3): Dart's typed
 * API to the sealed runtime (pigeons/runtime_api.dart), over the process's
 * one [RuntimeHub]. Orchestration only: the hub owns the state and its worker
 * thread, [SealedRuntime] does the work, and this class turns their snapshots
 * into Pigeon's messages, as answers and as RuntimeEvents. Since W4 it also
 * runs commands (`exec`) and the tool probes (`tools`).
 *
 * One per Flutter engine. The hub outlives it: an engine attached again finds
 * the runtime where it was, and an install never runs twice.
 */
class RuntimeHost(context: Context, messenger: BinaryMessenger) : RuntimeApi {
    private val hub = RuntimeHubs.get(context)
    private val events = RuntimeEvents(messenger)
    private val listener: (RuntimeStatus) -> Unit = { status ->
        events.changed(status.toMessage()) { }
    }

    init {
        hub.addListener(listener)
    }

    /** The engine is going: no more events to it. */
    fun close() {
        hub.removeListener(listener)
    }

    override fun status(callback: (Result<RuntimeStatusMessage>) -> Unit) {
        hub.status { callback(Result.success(it.toMessage())) }
    }

    override fun start(callback: (Result<RuntimeStatusMessage>) -> Unit) {
        hub.start { callback(Result.success(it.toMessage())) }
    }

    override fun reinstall(callback: (Result<RuntimeStatusMessage>) -> Unit) {
        hub.reinstall { callback(Result.success(it.toMessage())) }
    }

    override fun audit(callback: (Result<RuntimeStatusMessage>) -> Unit) {
        hub.audit { callback(Result.success(it.toMessage())) }
    }

    override fun exec(request: ExecRequestMessage, callback: (Result<ExecResultMessage>) -> Unit) {
        val command = CommandRequest(
            program = request.program,
            arguments = request.arguments,
            directory = request.directory?.let(::File),
            timeoutMs = request.timeoutMs ?: CommandRunner.DEFAULT_TIMEOUT_MS,
            outputLimit = request.outputLimit?.toInt() ?: CommandRunner.DEFAULT_OUTPUT_LIMIT,
        )
        hub.exec(command) { result -> callback(Result.success(result.toMessage())) }
    }

    override fun tools(callback: (Result<ToolsMessage>) -> Unit) {
        hub.tools { report ->
            RuntimeHubs.log(report)
            callback(Result.success(report.toMessage()))
        }
    }

    override fun size(callback: (Result<RuntimeSizeMessage>) -> Unit) {
        hub.sizes { sizes ->
            callback(
                Result.success(
                    RuntimeSizeMessage(
                        prefixBytes = sizes.prefixBytes,
                        prefixFiles = sizes.prefixFiles.toLong(),
                        nativeLibraryBytes = sizes.nativeLibraryBytes,
                        apkBytes = sizes.apkBytes,
                    ),
                ),
            )
        }
    }
}

/** A snapshot as Pigeon's message. */
internal fun RuntimeStatus.toMessage(): RuntimeStatusMessage =
    RuntimeStatusMessage(
        revision = revision,
        state = state.code,
        done = done.toLong(),
        total = total.toLong(),
        auditing = auditing,
        abi = abi,
        payloadId = payloadId,
        info = info,
        problem = problem?.code,
        detail = detail,
        installMs = installMs,
        warmStartMs = warmStartMs,
        relinked = relinked?.toLong(),
        audit = audit?.let { audit ->
            RuntimeAuditMessage(
                outsideApk = audit.outsideApk.toLong(),
                outsideScripts = audit.outsideScripts.toLong(),
                shipped = audit.shipped.toLong(),
                scanned = audit.scanned.toLong(),
                truncated = audit.truncated,
                millis = audit.millis,
                report = audit.report,
                failure = audit.failure,
            )
        },
    )

/** A command's result as Pigeon's message. */
internal fun CommandResult.toMessage(): ExecResultMessage =
    ExecResultMessage(
        exitCode = exitCode?.toLong(),
        signal = signal?.toLong(),
        stdout = stdout.text,
        stderr = stderr.text,
        stdoutBytes = stdout.bytes,
        stderrBytes = stderr.bytes,
        stdoutTruncated = stdout.truncated,
        stderrTruncated = stderr.truncated,
        durationMs = durationMs,
        failure = failure?.code,
        detail = detail,
        leftovers = leftovers.toLong(),
        remaining = remaining.toLong(),
    )

/** The tool probes as Pigeon's message. */
internal fun ToolsReport.toMessage(): ToolsMessage =
    ToolsMessage(
        tools = tools.map { tool ->
            ToolMessage(
                tool = tool.tool,
                packageName = tool.packageName,
                version = tool.version,
                pinned = tool.pinned,
                health = tool.health.code,
                detail = tool.detail,
                millis = tool.millis,
            )
        },
        millis = millis,
        failure = failure,
    )

/**
 * The process's one [RuntimeHub]: one worker thread (below normal priority,
 * so the editor stays smooth while 14,000 files are written), answers and
 * events on Android's main thread, and the runtime where t1's HarnessPaths
 * puts it (files/coding-harness, which Android's backup never takes: its
 * rules list what it may, xml/backup_rules.xml).
 */
object RuntimeHubs {
    private const val TAG = "CodeForgeRuntime"

    /** Commands, probes and terminal starts at once (Phase 5 W2: a bounded pool); more wait their turn. */
    const val COMMAND_THREADS = 16

    /** Where projects live, in the app's files: the folders a terminal may start in (SearchHost's too). */
    const val PROJECTS = "workspaces"

    /**
     * Where folders' run copies live, in the app's files (Phase 5 W4,
     * ADR-0013; the storage broker writes them): a terminal may start in one.
     * Android's backup never takes them (xml/backup_rules.xml lists what it may).
     */
    const val COPIES = "copies"

    @Volatile
    private var hub: RuntimeHub? = null

    fun get(context: Context): RuntimeHub =
        hub ?: synchronized(this) {
            hub ?: create(context.applicationContext).also { hub = it }
        }

    private fun create(app: Context): RuntimeHub {
        val main = Handler(Looper.getMainLooper())
        val worker = Executors.newSingleThreadExecutor { task ->
            Thread(task, "codeforge-runtime").apply {
                isDaemon = true
                priority = Thread.NORM_PRIORITY - 1
            }
        }
        // Commands run beside the worker (Phase 4 W4), at most COMMAND_THREADS
        // at once (Phase 5 W2); the rest wait in order, and idle threads end.
        val threads = AtomicInteger()
        val commandThreads = ThreadPoolExecutor(
            COMMAND_THREADS,
            COMMAND_THREADS,
            30L,
            TimeUnit.SECONDS,
            LinkedBlockingQueue<Runnable>(),
        ) { task ->
            Thread(task, "codeforge-command-${threads.incrementAndGet()}").apply { isDaemon = true }
        }.apply { allowCoreThreadTimeOut(true) }
        // HarnessPaths creates its folders: made on the worker or a command
        // thread, never the main thread, and once for both.
        val config = lazy { HarnessConfig.builder(app).build() }
        val created = RuntimeHub(
            runtimeFactory = { SealedRuntime(AssetPayloadSource(app), config.value) },
            worker = worker,
            deliver = { task -> main.post(task) },
            apkBytes = { apkBytes(app) },
            commandsFactory = {
                RuntimeCommands.create(
                    config = config.value,
                    // The last resort when a launcher outlives its own kill
                    // phase: SIGKILL to its whole process group.
                    killGroup = { group -> Os.kill(-group, OsConstants.SIGKILL) },
                    // A terminal may start in a project's folder, named by Dart, resolved here (E3).
                    projects = File(app.filesDir, PROJECTS),
                    // ...or in a folder's run copy, likewise (Phase 5 W4).
                    copies = File(app.filesDir, COPIES),
                    // The language servers the APK carries (Phase 6 W2, W3).
                    serverSource = AssetPayloadSource(app),
                )
            },
            commandExecutor = commandThreads,
        )
        created.addListener { status -> log(status) }
        // The foreground service runs while any terminal session runs (Phase 5 W5).
        created.addTerminalListener(SessionKeeper(app, created))
        // Under memory pressure, hidden sessions keep less of their output;
        // no session is ended to free memory (Phase 5 W5). The language
        // servers are stopped instead (Phase 6 W3, the owner's decision of
        // 2026-11-22: they are the first thing the app gives up); Dart starts
        // a server again when it is next needed.
        app.registerComponentCallbacks(
            object : ComponentCallbacks2 {
                override fun onTrimMemory(level: Int) {
                    if (level == ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN || level < ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) return
                    val stopped = created.languageServers()?.stopAll(LspEnd.MEMORY) ?: 0
                    if (stopped > 0) Log.i(TAG, "memory pressure (level $level): $stopped language servers stopped")
                    val trimmed = created.terminals()?.trimHidden() ?: 0
                    // The emulator gate reads this line as it is ("(level N): <n> hidden",
                    // emulator_gate.sh's sessions_trim): keep its form, and the servers' apart.
                    if (trimmed > 0) Log.i(TAG, "memory pressure (level $level): $trimmed hidden terminal buffers trimmed")
                }

                override fun onConfigurationChanged(newConfig: Configuration) {}

                @Deprecated("Deprecated in Android", ReplaceWith("onTrimMemory"))
                override fun onLowMemory() {
                    created.languageServers()?.stopAll(LspEnd.MEMORY)
                    created.terminals()?.trimHidden()
                }
            },
        )
        return created
    }

    /** The tool probes in the device log (the gate reads them). */
    fun log(report: ToolsReport) {
        Log.i(
            TAG,
            "tools ${report.millis} ms: " + report.tools.joinToString(" ") { tool ->
                "${tool.tool}=${tool.version ?: "-"}/${tool.health.code}"
            } + (report.failure?.let { " failure=$it" } ?: ""),
        )
    }

    private fun apkBytes(app: Context): Long {
        val info = app.applicationInfo
        var bytes = File(info.sourceDir).length()
        for (split in info.splitSourceDirs ?: emptyArray()) bytes += File(split).length()
        return bytes
    }

    /** Each state change once, in the device log (the gate reads it). */
    private var lastLogged: String? = null

    private fun log(status: RuntimeStatus) {
        val key = "${status.state.code}/${status.problem?.code}/${status.auditing}"
        if (key == lastLogged) return
        lastLogged = key
        val audit = status.audit
        Log.i(
            TAG,
            "runtime ${status.state.code} abi=${status.abi} payload=${status.payloadId} " +
                "problem=${status.problem?.code} installMs=${status.installMs} " +
                "warmStartMs=${status.warmStartMs} relinked=${status.relinked} " +
                "auditing=${status.auditing} outsideApk=${audit?.outsideApk} " +
                "shipped=${audit?.shipped} auditMs=${audit?.millis}" +
                (status.detail?.let { " detail=$it" } ?: ""),
        )
    }
}
