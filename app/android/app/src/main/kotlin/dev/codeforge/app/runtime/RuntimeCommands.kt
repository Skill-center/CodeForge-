package dev.codeforge.app.runtime

import dev.codeforge.runtime.core.HarnessConfig
import java.io.File

/**
 * The runtime's command side (Phase 4 W4), made once per process when the
 * first command or probe comes (RuntimeHub): the environment, the sessions,
 * the runner and the probes, over one runtime root.
 */
class RuntimeCommands(
    val environment: RuntimeEnvironment,
    val sessions: SessionRegistry,
    val runner: CommandRunner,
    val toolchain: Toolchain,
) {
    companion object {
        /** The launcher in the APK's native library directory (native/runtime-core). */
        const val LAUNCHER = "libcodeforge-spawn.so"

        fun create(
            config: HarnessConfig,
            killGroup: (Int) -> Unit,
            host: Map<String, String> = System.getenv(),
            launcher: File? = config.nativeLibraryDirectory?.let { File(it, LAUNCHER) },
        ): RuntimeCommands {
            val environment = RuntimeEnvironment(config, host)
            val sessions = SessionRegistry(killGroup)
            val runner = CommandRunner(
                environment = environment,
                launcher = launcher ?: File(LAUNCHER),
                sessions = sessions,
                statusDirectory = File(environment.root, "codeforge/sessions"),
            )
            val toolchain = Toolchain(run = runner::run, present = { name -> File(environment.bin, name).exists() })
            return RuntimeCommands(environment, sessions, runner, toolchain)
        }
    }
}
