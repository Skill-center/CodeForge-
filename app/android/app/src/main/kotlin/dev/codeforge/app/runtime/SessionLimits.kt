package dev.codeforge.app.runtime

/**
 * The limits every terminal session runs under (Phase 5 W5; docs/SECURITY.md
 * §2.2). The launcher sets them before the shell starts, for it and
 * everything it starts (libcodeforge-spawn.so's `--fsize`, `--nproc` and
 * `--oom-score-adj`); a limit is only ever lowered and a score only raised,
 * never past what the system set. SessionServiceTest measures them on API 26
 * to 36 and on an arm64 phone.
 *
 * There is no limit on CPU time: a session runs for as long as the user lets
 * it. Run's one-shot commands keep their time limits (CommandRunner).
 */
data class SessionLimits(
    /**
     * RLIMIT_FSIZE: the largest file a session may write. A runaway write to
     * one file stops there (its writer gets SIGXFSZ) instead of filling the
     * storage the app shares with the system.
     */
    val fileBytes: Long?,
    /**
     * RLIMIT_NPROC: a fork fails while the app's user has this many processes
     * and threads. Linux counts all of the user's, the app's own threads
     * included, so it sits far above what the app and its sessions run
     * (measured), and stops a fork bomb long before the kernel's own limit,
     * which the app's threads would hit too.
     */
    val processes: Int?,
    /**
     * The sessions' oom_score_adj, raised to this: when the kernel itself must
     * kill for memory, it takes a session's processes before the app's, which
     * would take every session with it. Android's lmkd kills the app's
     * processes as a group and never looks at this.
     */
    val oomScoreAdj: Int?,
) {
    /** The launcher's options for these limits. */
    fun arguments(): List<String> = buildList {
        fileBytes?.let { add("--fsize"); add(it.toString()) }
        processes?.let { add("--nproc"); add(it.toString()) }
        oomScoreAdj?.let { add("--oom-score-adj"); add(it.toString()) }
    }

    companion object {
        /** What sessions run under. */
        val SESSION = SessionLimits(fileBytes = 4L shl 30, processes = 2048, oomScoreAdj = 800)

        /** No limits beyond the system's. */
        val NONE = SessionLimits(fileBytes = null, processes = null, oomScoreAdj = null)
    }
}
