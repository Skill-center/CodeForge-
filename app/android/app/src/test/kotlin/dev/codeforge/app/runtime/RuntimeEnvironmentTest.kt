package dev.codeforge.app.runtime

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The commands' environment (Phase 4 W4; docs/SECURITY.md §2): built from
 * nothing, with the runtime's own folders, the preload's paths, and the
 * interpreters' homes for what the payload carries.
 */
class RuntimeEnvironmentTest {
    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var root: File
    private lateinit var libraries: File

    @Before
    fun setUp() {
        root = temp.newFolder("harness")
        libraries = temp.newFolder("lib")
    }

    private fun environment(host: Map<String, String> = emptyMap()) =
        RuntimeEnvironment(TestPayload.configFor(root, libraries), host)

    @Test
    fun nothingComesFromTheAppsProcessButAndroidsLocations() {
        val host = mapOf(
            "ANDROID_ROOT" to "/system",
            "ANDROID_DATA" to "/data",
            "ANDROID_TZDATA_ROOT" to "/apex/com.android.tzdata",
            "CODEFORGE_CANARY_TOKEN" to "secret",
            "BOOTCLASSPATH" to "/apex/x.jar",
            "PATH" to "/usr/bin:/bin",
            "LD_PRELOAD" to "/data/evil.so",
            "HOME" to "/data/user/0/app",
        )
        val environment = environment(host)
        val variables = environment.variables(environment.home)
        assertEquals("/system", variables["ANDROID_ROOT"])
        assertEquals("/data", variables["ANDROID_DATA"])
        assertEquals("/apex/com.android.tzdata", variables["ANDROID_TZDATA_ROOT"])
        assertFalse(variables.containsKey("CODEFORGE_CANARY_TOKEN"))
        assertFalse(variables.values.any { it.contains("secret") })
        assertFalse(variables.containsKey("BOOTCLASSPATH"))
        assertFalse("no preload in this native library folder", variables.containsKey("LD_PRELOAD"))
        assertEquals("${environment.bin.absolutePath}:/system/bin", variables["PATH"])
        assertEquals(environment.home.absolutePath, variables["HOME"])
    }

    @Test
    fun homeTmpdirAndXdgLiveInTheRuntimesRoot() {
        val environment = environment()
        environment.prepare()
        val variables = environment.variables(environment.home)
        val rootPath = root.absolutePath + File.separator
        for (name in listOf("HOME", "TMPDIR", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "PWD")) {
            val value = variables[name]!!
            assertTrue("$name=$value", value.startsWith(rootPath))
            assertTrue("$name=$value is a folder", File(value).isDirectory)
        }
        assertEquals(File(environment.prefix, "tmp").absolutePath, variables["TMPDIR"])
        assertEquals("C.UTF-8", variables["LANG"])
        assertEquals("dumb", variables["TERM"])
    }

    @Test
    fun thePreloadsPathsStayInTheRootfs() {
        val environment = environment()
        val variables = environment.variables(environment.home)
        val prefix = environment.prefix
        assertEquals(prefix.absolutePath, variables["TERMUX__PREFIX"])
        assertEquals(prefix.parentFile!!.absolutePath, variables["TERMUX__ROOTFS"])
        assertEquals(prefix.parentFile!!.parentFile!!.absolutePath, variables["TERMUX_APP__DATA_DIR"])
        assertTrue(variables["TERMUX_APP__DATA_DIR"]!!.endsWith("rootfs/data/data/com.termux"))
        assertEquals(environment.lib.absolutePath, variables["LD_LIBRARY_PATH"])
    }

    @Test
    fun thePreloadIsSetWhenTheAppCarriesIt() {
        File(libraries, RuntimeEnvironment.PRELOAD).writeBytes(byteArrayOf(0x7f, 0x45, 0x4c, 0x46))
        File(libraries, "libtermux-exec-ld-preload.so").writeText("not ours")
        val environment = environment()
        val variables = environment.variables(environment.home)
        assertEquals(File(libraries, RuntimeEnvironment.PRELOAD).absolutePath, variables["LD_PRELOAD"])
    }

    @Test
    fun theInterpretersFindTheirHomesInThePrefix() {
        val environment = environment()
        val lib = environment.lib
        File(lib, "python3.14/encodings").mkdirs()
        File(lib, "node_modules/npm").mkdirs()
        File(lib, "ruby/4.0.0/x86_64-linux-android").mkdirs()
        File(lib, "ruby/4.0.0/x86_64-linux-android/rbconfig.rb").writeText("module RbConfig; end\n")
        File(lib, "ruby/3.9.0").mkdirs()
        File(lib, "ruby/gems/4.0.0/specifications").mkdirs()
        File(lib, "ruby/site_ruby/4.0.0").mkdirs()
        File(lib, "perl5/5.44.0/x86_64-android/CORE").mkdirs()
        File(lib, "perl5/site_perl/5.44.0").mkdirs()
        File(environment.prefix, "etc/tls").mkdirs()
        File(environment.prefix, "etc/tls/cert.pem").writeText("-----BEGIN CERTIFICATE-----\n")

        val variables = environment.variables(environment.home)
        assertEquals(environment.prefix.absolutePath, variables["PYTHONHOME"])
        assertEquals(File(lib, "node_modules").absolutePath, variables["NODE_PATH"])
        assertEquals("npm's pin comes with the app", "false", variables["NPM_CONFIG_UPDATE_NOTIFIER"])
        assertEquals(File(lib, "ruby/gems/4.0.0").absolutePath, variables["GEM_HOME"])
        assertEquals(
            listOf("ruby/site_ruby/4.0.0", "ruby/4.0.0", "ruby/4.0.0/x86_64-linux-android")
                .joinToString(":") { File(lib, it).absolutePath },
            variables["RUBYLIB"],
        )
        assertEquals(
            listOf("perl5/site_perl/5.44.0", "perl5/5.44.0/x86_64-android", "perl5/5.44.0")
                .joinToString(":") { File(lib, it).absolutePath },
            variables["PERL5LIB"],
        )
        assertEquals(File(environment.prefix, "etc/tls/cert.pem").absolutePath, variables["SSL_CERT_FILE"])
    }

    @Test
    fun aPayloadWithoutInterpretersSetsNoneOfTheirVariables() {
        val environment = environment()
        val variables = environment.variables(environment.home)
        for (name in listOf("PYTHONHOME", "NODE_PATH", "NPM_CONFIG_UPDATE_NOTIFIER", "GEM_HOME", "RUBYLIB", "PERL5LIB", "SSL_CERT_FILE", "GIT_EXEC_PATH", "GIT_TEMPLATE_DIR")) {
            assertNull(name, variables[name])
        }
    }

    @Test
    fun gitFindsItsProgramsAndTemplatesInThePrefix() {
        val environment = environment()
        File(environment.prefix, "libexec/git-core").mkdirs()
        File(environment.prefix, "share/git-core/templates").mkdirs()
        val variables = environment.variables(environment.home)
        assertEquals(File(environment.prefix, "libexec/git-core").absolutePath, variables["GIT_EXEC_PATH"])
        assertEquals(File(environment.prefix, "share/git-core/templates").absolutePath, variables["GIT_TEMPLATE_DIR"])
        assertEquals("a terminal's git finds them too", variables["GIT_EXEC_PATH"], environment.variables(environment.home, terminal = true)["GIT_EXEC_PATH"])
    }

    @Test
    fun theNewestVersionFolderWins() {
        val folder = temp.newFolder("versions")
        for (name in listOf("3.9.0", "4.0.0", "4.0.10", "4.0.9", "notes", "gems")) File(folder, name).mkdirs()
        assertEquals("4.0.10", RuntimeEnvironment.newestVersion(folder))
        assertNull(RuntimeEnvironment.newestVersion(File(folder, "absent")))
        assertTrue(RuntimeEnvironment.compareVersions("5.44.0", "5.9.1") > 0)
    }
}
