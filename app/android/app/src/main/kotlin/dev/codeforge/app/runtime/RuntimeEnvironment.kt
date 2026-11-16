package dev.codeforge.app.runtime

import dev.codeforge.runtime.core.HarnessConfig
import java.io.File
import java.io.IOException

/**
 * The environment of every runtime command (Phase 4 W4; docs/SECURITY.md §2).
 *
 * CodeForge's own, in place of t1's HarnessEnvironment: t1's `prepare()`
 * relocates the bootstrap and writes apt's configuration, which the sealed
 * runtime has no use for, and its `create()` starts from every variable of
 * the app's process. This one builds the environment from nothing:
 *
 *   * Only what the runtime needs. A short list of Android's own system
 *     locations comes from the app's process ([PASSED_FROM_ANDROID]); every
 *     other variable of the app's process stays out, so nothing the app holds
 *     reaches a command.
 *   * HOME, TMPDIR and the XDG directories in the runtime's root, in t1's
 *     HarnessPaths layout: never the user's project.
 *   * The paths the preload translates. harness-exec.c turns Termux's
 *     official paths (/data/data/com.termux/files/usr and its parents) into
 *     TERMUX__PREFIX, TERMUX__ROOTFS and TERMUX_APP__DATA_DIR, so scripts with
 *     official shebangs run. All three are inside the runtime's root (t1
 *     points the last at the app's data directory).
 *   * The preload is CodeForge's harness-exec only. Termux's termux-exec,
 *     which t1 also preloads, can run an ELF file from the app's storage
 *     through the system linker: exactly what the sealed model rules out.
 *   * The interpreters' homes, explicitly. An interpreter that lives in the
 *     APK cannot find its prefix (t1's docs/sealed-runtime-port.md): CPython
 *     derives it from /proc/self/exe, and perl and ruby have Termux's prefix
 *     compiled in. So PYTHONHOME, GEM_HOME, NODE_PATH, RUBYLIB and PERL5LIB
 *     point into the prefix, each only when the payload carries it.
 *
 * No Android type: the JVM tests build it over a folder.
 */
class RuntimeEnvironment(
    private val config: HarnessConfig,
    private val host: Map<String, String> = System.getenv(),
) {
    /** The runtime's root (files/coding-harness): the prefix's rootfs sits in it. */
    val root: File = config.rootfs?.parentFile ?: config.prefix.parentFile
    val prefix: File get() = config.prefix
    val bin: File get() = config.toolDirectory
    val lib: File get() = config.libraryDirectory
    val home: File get() = config.home

    /** Where projects live inside the runtime (t1's workspace). */
    val workspace: File get() = config.workspace

    /** TMPDIR: the prefix's tmp, as Termux and t1 have it. */
    val tmp: File get() = File(config.prefix, "tmp")
    val xdgData: File get() = File(root, "xdg/data")
    val xdgConfig: File get() = File(root, "xdg/config")
    val xdgState: File get() = File(root, "xdg/state")
    val xdgCache: File get() = File(root, "xdg/cache")

    /** CodeForge's preload in the APK's native library directory. */
    val preload: File? get() = config.nativeLibraryDirectory?.let { File(it, PRELOAD) }

    /** HOME, TMPDIR and the XDG directories, created when missing. Nothing else. */
    fun prepare() {
        for (directory in listOf(home, workspace, tmp, xdgData, xdgConfig, xdgState, xdgCache)) {
            if (!directory.isDirectory && !directory.mkdirs() && !directory.isDirectory) {
                throw IOException("could not create $directory")
            }
        }
    }

    /** Every variable a command running in [directory] gets, and nothing more. */
    fun variables(directory: File): Map<String, String> {
        val variables = LinkedHashMap<String, String>()
        for (name in PASSED_FROM_ANDROID) {
            val value = host[name]
            if (!value.isNullOrEmpty()) variables[name] = value
        }
        variables["PATH"] = "${bin.absolutePath}:/system/bin"
        variables["HOME"] = home.absolutePath
        variables["PWD"] = directory.absolutePath
        variables["TMPDIR"] = tmp.absolutePath
        variables["XDG_DATA_HOME"] = xdgData.absolutePath
        variables["XDG_CONFIG_HOME"] = xdgConfig.absolutePath
        variables["XDG_STATE_HOME"] = xdgState.absolutePath
        variables["XDG_CACHE_HOME"] = xdgCache.absolutePath
        variables["LANG"] = "C.UTF-8"
        variables["LC_ALL"] = "C.UTF-8"
        // One-shot commands have no terminal (Phase 5's sessions will).
        variables["TERM"] = "dumb"
        val shell = File(bin, "sh")
        variables["SHELL"] = if (shell.exists()) shell.absolutePath else "/system/bin/sh"
        variables["PREFIX"] = prefix.absolutePath
        // What harness-exec.c translates Termux's official paths to:
        // .../files/usr, .../files and the app's data directory, in the rootfs.
        val files = prefix.parentFile ?: prefix
        val appData = files.parentFile ?: files
        variables["TERMUX__PREFIX"] = prefix.absolutePath
        variables["TERMUX__ROOTFS"] = files.absolutePath
        variables["TERMUX_APP__DATA_DIR"] = appData.absolutePath
        // The payload's executables have Termux's lib in their run path, which
        // does not exist here; the prefix's lib has their libraries' links.
        variables["LD_LIBRARY_PATH"] = lib.absolutePath
        // Only when it is there: Android's linker refuses to start any process
        // whose LD_PRELOAD names a missing library.
        val library = preload
        if (library != null && library.isFile) variables["LD_PRELOAD"] = library.absolutePath
        val certificates = File(prefix, "etc/tls/cert.pem")
        if (certificates.isFile) variables["SSL_CERT_FILE"] = certificates.absolutePath
        val certificateDirectory = File(prefix, "etc/tls/certs")
        if (certificateDirectory.isDirectory) variables["SSL_CERT_DIR"] = certificateDirectory.absolutePath
        variables.putAll(interpreters())
        return variables
    }

    /** PYTHONHOME, NODE_PATH, GEM_HOME, RUBYLIB and PERL5LIB, for what the payload carries. */
    fun interpreters(): Map<String, String> {
        val variables = LinkedHashMap<String, String>()
        val libraries = lib.listFiles()?.filter { it.isDirectory } ?: emptyList()
        if (libraries.any { it.name.startsWith("python3.") }) {
            // CPython looks for lib/python3.X under it.
            variables["PYTHONHOME"] = prefix.absolutePath
        }
        val nodeModules = File(lib, "node_modules")
        if (nodeModules.isDirectory) variables["NODE_PATH"] = nodeModules.absolutePath

        val ruby = File(lib, "ruby")
        val rubyVersion = newestVersion(ruby)
        if (rubyVersion != null) {
            val gems = File(ruby, "gems/$rubyVersion")
            if (gems.isDirectory) variables["GEM_HOME"] = gems.absolutePath
            val standard = File(ruby, rubyVersion)
            val architecture = standard.listFiles()?.firstOrNull { File(it, "rbconfig.rb").isFile }?.name
            // Ruby's own order: site, vendor, then the standard library; each
            // with its architecture's directory after it.
            val paths = mutableListOf<File>()
            for (base in listOf(File(ruby, "site_ruby/$rubyVersion"), File(ruby, "vendor_ruby/$rubyVersion"), standard)) {
                paths.add(base)
                if (architecture != null) paths.add(File(base, architecture))
            }
            val existing = paths.filter { it.isDirectory }
            if (existing.isNotEmpty()) variables["RUBYLIB"] = existing.joinToString(":") { it.absolutePath }
        }

        val perl = File(lib, "perl5")
        val perlVersion = newestVersion(perl)
        if (perlVersion != null) {
            val standard = File(perl, perlVersion)
            val architecture = standard.listFiles()?.firstOrNull { File(it, "CORE").isDirectory }?.name
            // Perl's own order: site before core, each architecture's first.
            val paths = mutableListOf<File>()
            for (base in listOf(File(perl, "site_perl/$perlVersion"), standard)) {
                if (architecture != null) paths.add(File(base, architecture))
                paths.add(base)
            }
            val existing = paths.filter { it.isDirectory }
            if (existing.isNotEmpty()) variables["PERL5LIB"] = existing.joinToString(":") { it.absolutePath }
        }
        return variables
    }

    companion object {
        /** CodeForge's build of t1's harness-exec.c (native/runtime-core). */
        const val PRELOAD = "libharness-exec.so"

        /**
         * The variables a command may take from the app's process: where
         * Android itself is installed, which bionic, ICU and tzdata consult.
         * Paths of the system, never secrets.
         */
        val PASSED_FROM_ANDROID = listOf(
            "ANDROID_ROOT",
            "ANDROID_DATA",
            "ANDROID_ART_ROOT",
            "ANDROID_I18N_ROOT",
            "ANDROID_TZDATA_ROOT",
            "ANDROID_RUNTIME_ROOT",
        )

        private val VERSION = Regex("""\d+(\.\d+)+""")

        /** The subdirectory of [directory] named by the highest version (4.0.0, 5.44.0). */
        fun newestVersion(directory: File): String? =
            directory.listFiles()
                ?.filter { it.isDirectory && VERSION.matches(it.name) }
                ?.map { it.name }
                ?.maxWithOrNull { left, right -> compareVersions(left, right) }

        fun compareVersions(left: String, right: String): Int {
            val a = left.split('.').map { it.toIntOrNull() ?: 0 }
            val b = right.split('.').map { it.toIntOrNull() ?: 0 }
            for (index in 0 until maxOf(a.size, b.size)) {
                val difference = a.getOrElse(index) { 0 } - b.getOrElse(index) { 0 }
                if (difference != 0) return difference
            }
            return 0
        }
    }
}
