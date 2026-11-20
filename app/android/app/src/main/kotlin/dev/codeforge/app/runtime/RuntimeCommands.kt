package dev.codeforge.app.runtime

import dev.codeforge.runtime.core.HarnessConfig
import java.io.File
import java.util.concurrent.ScheduledThreadPoolExecutor

/**
 * The runtime's command side (Phase 4 W4), made once per process when the
 * first command, probe or terminal comes (RuntimeHub): the environment, the
 * sessions, the runner, the probes and since Phase 5 W2 the terminals, over
 * one runtime root.
 */
class RuntimeCommands(
    val environment: RuntimeEnvironment,
    val sessions: SessionRegistry,
    val runner: CommandRunner,
    val toolchain: Toolchain,
    val terminals: Terminals? = null,
) {
    companion object {
        /** The launcher in the APK's native library directory (native/runtime-core). */
        const val LAUNCHER = "libcodeforge-spawn.so"

        fun create(
            config: HarnessConfig,
            killGroup: (Int) -> Unit,
            host: Map<String, String> = System.getenv(),
            launcher: File? = config.nativeLibraryDirectory?.let { File(it, LAUNCHER) },
            /** Where projects live (`<filesDir>/workspaces`): the folders a terminal may start in. */
            projects: File? = null,
            /** Where folders' run copies live (`<filesDir>/copies`, Phase 5 W4): a terminal may start in one too. */
            copies: File? = null,
        ): RuntimeCommands {
            val environment = RuntimeEnvironment(config, host)
            val sessions = SessionRegistry(killGroup)
            val executable = launcher ?: File(LAUNCHER)
            val runner = CommandRunner(
                environment = environment,
                launcher = executable,
                sessions = sessions,
                statusDirectory = File(environment.root, "codeforge/sessions"),
            )
            val toolchain = Toolchain(run = runner::run, present = { name -> File(environment.bin, name).exists() })
            // One thread delivers every terminal's batches and changes, in order.
            val delivery = ScheduledThreadPoolExecutor(1) { task ->
                Thread(task, "codeforge-terminal-delivery").apply { isDaemon = true }
            }.apply { removeOnCancelPolicy = true }
            val terminalState = File(environment.root, "codeforge/terminal")
            val terminals = Terminals(
                environment = environment,
                launcher = executable,
                sessions = sessions,
                stateDirectory = terminalState,
                projects = projects,
                delivery = delivery,
                copies = copies,
                // The sessions on disk, for the next process's tombstones (Phase 5 W5).
                ledger = SessionLedger(File(terminalState, Terminals.LEDGER_FILE)),
            )
            return RuntimeCommands(environment, sessions, runner, toolchain, terminals)
        }
    }
}
