package dev.codeforge.app.runtime

import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executor

/** Where the runtime is. Each code travels to Dart. */
enum class RuntimeState(val code: String) {
    /** Nothing asked yet in this process. */
    UNKNOWN("unknown"),

    /** This APK carries no runtime for the device. */
    UNAVAILABLE("unavailable"),

    /** The APK carries one, and it is not installed (or not this payload). */
    NOT_INSTALLED("notInstalled"),

    /** This APK's payload is installed, and nothing started it in this process. */
    INSTALLED("installed"),

    /** Deciding: an earlier install is checked (the warm start), or not found. */
    CHECKING("checking"),

    /** Extracting and verifying the payload. */
    INSTALLING("installing"),

    /** Installed, verified and linked; see [RuntimeStatus.audit] for the audit. */
    READY("ready"),

    /** Installed, but the audit found executables outside the APK, or could not finish. */
    DEGRADED("degraded"),

    /** The install failed, and nothing was marked installed: see [RuntimeStatus.problem]. */
    FAILED("failed"),
}

/** One snapshot of the runtime, as Dart sees it. */
data class RuntimeStatus(
    /** Grows with every change: Dart keeps the newest snapshot it has seen. */
    val revision: Long = 0,
    val state: RuntimeState = RuntimeState.UNKNOWN,
    val abi: String? = null,
    val payloadId: String? = null,
    /** runtime-info-<abi>.json, as written by runtime/pins.py. */
    val info: String? = null,
    /** While installing: files written so far, and in all. */
    val done: Int = 0,
    val total: Int = 0,
    val problem: RuntimeProblem? = null,
    val detail: String? = null,
    /** How long this payload's install took (kept in the marker). */
    val installMs: Long? = null,
    /** How long this process's warm start took. */
    val warmStartMs: Long? = null,
    /** Executable links the warm start rewrote (an updated app moves its libraries). */
    val relinked: Int? = null,
    val audit: AuditResult? = null,
    /** The audit is running. */
    val auditing: Boolean = false,
)

/**
 * The runtime's one owner in the process (Phase 4 W3; RuntimeHost reaches
 * it through [RuntimeHubs]): one worker thread does everything that touches
 * the prefix, in order, so a start, a reinstall and an audit never overlap.
 * Every change is a new [RuntimeStatus] snapshot for the listeners, delivered
 * through [deliver] (Android's main thread), and so are the answers.
 *
 * The install is lazy: nothing happens until something calls [start] (the
 * workbench, when a workspace opens). A start is a warm start when this APK's
 * payload is installed, and an install otherwise; either way the audit runs
 * after it, at every start. READY comes only from a verified install or a
 * verified layout, never from a failed one. A failed install stays failed
 * until [reinstall]: the same payload would fail the same way.
 */
class RuntimeHub(
    private val runtimeFactory: () -> SealedRuntime,
    private val worker: Executor,
    private val deliver: (Runnable) -> Unit,
    private val apkBytes: () -> Long,
    private val clock: () -> Long = System::nanoTime,
) {
    private val lock = Any()
    private var current = RuntimeStatus()
    private val listeners = CopyOnWriteArrayList<(RuntimeStatus) -> Unit>()

    // The worker's own.
    private var runtime: SealedRuntime? = null
    private var lastProgressAt = Long.MIN_VALUE

    fun snapshot(): RuntimeStatus = synchronized(lock) { current }

    fun addListener(listener: (RuntimeStatus) -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: (RuntimeStatus) -> Unit) {
        listeners.remove(listener)
    }

    /** Answers with the status; the first call in a process looks first (no install). */
    fun status(answer: (RuntimeStatus) -> Unit) {
        if (snapshot().state != RuntimeState.UNKNOWN) {
            reply(answer)
            return
        }
        worker.execute {
            probe()
            reply(answer)
        }
    }

    /**
     * Starts the runtime, once per process: a warm start or an install, then
     * the audit. Answers at once (CHECKING when it starts now); the rest
     * arrives as status changes.
     */
    fun start(answer: (RuntimeStatus) -> Unit) {
        val accepted = synchronized(lock) {
            val idle = current.state == RuntimeState.UNKNOWN ||
                current.state == RuntimeState.NOT_INSTALLED ||
                current.state == RuntimeState.INSTALLED
            if (idle) {
                current = current.copy(revision = current.revision + 1, state = RuntimeState.CHECKING)
            }
            idle
        }
        if (accepted) {
            publish()
            worker.execute { runStart() }
        }
        reply(answer)
    }

    /** Removes the runtime and installs it again, then audits it. Answers at once. */
    fun reinstall(answer: (RuntimeStatus) -> Unit) {
        val accepted = synchronized(lock) { current.state != RuntimeState.INSTALLING }
        if (accepted) {
            worker.execute {
                probe()
                if (snapshot().state != RuntimeState.UNAVAILABLE) installThenAudit()
            }
        }
        reply(answer)
    }

    /** Audits an installed runtime again; answers with the status after it. */
    fun audit(answer: (RuntimeStatus) -> Unit) {
        worker.execute {
            probe()
            val state = snapshot().state
            if (state == RuntimeState.READY || state == RuntimeState.DEGRADED) auditNow()
            reply(answer)
        }
    }

    /** Measures what the runtime occupies; answers when done. */
    fun sizes(answer: (RuntimeSizes) -> Unit) {
        worker.execute {
            val sizes = try {
                runtime().sizes(apkBytes())
            } catch (failure: Exception) {
                RuntimeSizes(0L, 0, 0L, apkBytes())
            }
            deliver(Runnable { answer(sizes) })
        }
    }

    // ── The worker's side ──────────────────────────────────────────────

    private fun runtime(): SealedRuntime = runtime ?: runtimeFactory().also { runtime = it }

    /** Finds out, once, whether this APK carries a payload and whether it is installed. */
    private fun probe() {
        val state = snapshot().state
        if (state != RuntimeState.UNKNOWN && state != RuntimeState.CHECKING) return
        if (state == RuntimeState.CHECKING && snapshot().abi != null) return
        try {
            val sealed = runtime()
            val payload = sealed.payload()
            if (payload == null) {
                update { copy(state = RuntimeState.UNAVAILABLE, problem = RuntimeProblem.NO_PAYLOAD) }
                return
            }
            val installed = sealed.installed()
            update {
                copy(
                    state = if (this.state == RuntimeState.CHECKING) {
                        RuntimeState.CHECKING
                    } else if (installed != null) {
                        RuntimeState.INSTALLED
                    } else {
                        RuntimeState.NOT_INSTALLED
                    },
                    abi = payload.abi,
                    payloadId = payload.identity,
                    info = payload.info,
                    installMs = installed?.installMs,
                )
            }
        } catch (failure: Exception) {
            fail(failure)
        }
    }

    private fun runStart() {
        // The warm start, timed from here: finding the payload and the
        // marker, and the layout applied again. The audit comes after it.
        val started = clock()
        probe()
        if (snapshot().state != RuntimeState.CHECKING) return
        val installed = try {
            runtime().installed()
        } catch (failure: Exception) {
            null
        }
        if (installed != null) {
            try {
                val warm = runtime().warmStart()
                val millis = (clock() - started) / 1_000_000L
                update {
                    copy(
                        state = RuntimeState.READY,
                        installMs = installed.installMs,
                        warmStartMs = millis,
                        relinked = warm.relinked,
                        problem = null,
                        detail = null,
                        auditing = true,
                    )
                }
                auditNow()
                return
            } catch (failure: Exception) {
                // The layout could not be applied again: install afresh.
            }
        }
        installThenAudit()
    }

    private fun installThenAudit() {
        update {
            copy(
                state = RuntimeState.INSTALLING,
                done = 0,
                total = 0,
                problem = null,
                detail = null,
                audit = null,
                auditing = false,
                warmStartMs = null,
                relinked = null,
            )
        }
        lastProgressAt = Long.MIN_VALUE
        try {
            val result = runtime().install { done, total -> progress(done, total) }
            update {
                copy(
                    state = RuntimeState.READY,
                    done = this.total,
                    installMs = result.millis,
                    auditing = true,
                )
            }
        } catch (failure: Exception) {
            fail(failure)
            return
        }
        auditNow()
    }

    private fun auditNow() {
        update { copy(auditing = true) }
        val audit = try {
            runtime().audit()
        } catch (failure: Exception) {
            AuditResult(0, 0, 0, 0, true, failure.toString(), 0L, "the audit failed: $failure")
        }
        update {
            val usable = state == RuntimeState.READY || state == RuntimeState.DEGRADED
            when {
                !usable -> copy(audit = audit, auditing = false)
                audit.clean -> copy(state = RuntimeState.READY, audit = audit, auditing = false, problem = null, detail = null)
                else -> copy(
                    state = RuntimeState.DEGRADED,
                    audit = audit,
                    auditing = false,
                    problem = if (audit.outsideApk > 0) RuntimeProblem.OUTSIDE_APK else RuntimeProblem.AUDIT_INCOMPLETE,
                    detail = if (audit.outsideApk > 0) {
                        "${audit.outsideApk} executables outside the APK"
                    } else {
                        audit.failure ?: "the audit could not walk the whole prefix"
                    },
                )
            }
        }
    }

    /** At most every [PROGRESS_INTERVAL_NS], and always the last file. */
    private fun progress(done: Int, total: Int) {
        val now = clock()
        if (done < total && lastProgressAt != Long.MIN_VALUE && now - lastProgressAt < PROGRESS_INTERVAL_NS) return
        lastProgressAt = now
        update { copy(done = done, total = total) }
    }

    private fun fail(failure: Exception) {
        val typed = failure as? RuntimeFailure
            ?: RuntimeFailure(RuntimeProblem.UNEXPECTED, failure.toString(), failure)
        update {
            copy(
                state = RuntimeState.FAILED,
                problem = typed.problem,
                detail = typed.message,
                auditing = false,
            )
        }
    }

    private fun update(change: RuntimeStatus.() -> RuntimeStatus) {
        synchronized(lock) {
            val next = current.change()
            current = next.copy(revision = current.revision + 1)
        }
        publish()
    }

    private fun publish() {
        val status = snapshot()
        deliver(Runnable { for (listener in listeners) listener(status) })
    }

    private fun reply(answer: (RuntimeStatus) -> Unit) {
        val status = snapshot()
        deliver(Runnable { answer(status) })
    }

    companion object {
        /** About five progress notices a second. */
        const val PROGRESS_INTERVAL_NS = 200_000_000L
    }
}
