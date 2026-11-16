package dev.codeforge.app.runtime

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import dev.codeforge.runtime.core.HarnessConfig
import io.flutter.plugin.common.BinaryMessenger
import java.io.File
import java.util.concurrent.Executors

/**
 * The runtime host (Phase 4 W3; docs/RUNTIME_INTEGRATION.md §3): Dart's typed
 * API to the sealed runtime (pigeons/runtime_api.dart), over the process's
 * one [RuntimeHub]. Orchestration only: the hub owns the state and its worker
 * thread, [SealedRuntime] does the work, and this class turns their snapshots
 * into Pigeon's messages, as answers and as RuntimeEvents.
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

/**
 * The process's one [RuntimeHub]: one worker thread (below normal priority,
 * so the editor stays smooth while 14,000 files are written), answers and
 * events on Android's main thread, and the runtime where t1's HarnessPaths
 * puts it (files/coding-harness, which Android's backup never takes: its
 * rules list what it may, xml/backup_rules.xml).
 */
object RuntimeHubs {
    private const val TAG = "CodeForgeRuntime"

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
        val created = RuntimeHub(
            runtimeFactory = {
                // HarnessPaths creates its folders: on the worker, never the main thread.
                SealedRuntime(AssetPayloadSource(app), HarnessConfig.builder(app).build())
            },
            worker = worker,
            deliver = { task -> main.post(task) },
            apkBytes = { apkBytes(app) },
        )
        created.addListener { status -> log(status) }
        return created
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
