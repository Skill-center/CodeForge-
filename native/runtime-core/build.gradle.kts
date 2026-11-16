// CodeForge's own build script for the runtime core (Phase 4 W3;
// docs/RUNTIME_INTEGRATION.md §2, native/PROVENANCE.md).
//
// An Android library, `dev.codeforge.runtime.core`, holding three things:
//   * t1's Android adapter over the sealed kernel (HarnessConfig, HarnessPaths
//     and exec/SealedPayloadInstaller), vendored with the packages renamed;
//   * the preload: t1's harness-exec.c (the LD_PRELOAD path translator), built
//     by ndk-build (src/main/jni/Android.mk), and t1's harness-probe.c (the exec
//     probe), built below as a PIE executable named libharnessprobe.so, both
//     with 16 KB page alignment;
//   * the sealed payload of one ABI, built from runtime/pins.json at build time:
//     the userland zip and its manifests become generated assets, and the
//     executables generated jniLibs. The app packages native libraries the
//     legacy way, so Android extracts the executables into nativeLibraryDir,
//     the one place an app targeting API 29+ may execve() from.
//
// Which ABIs a build targets, and which one carries the payload, the root
// project decides from Flutter's `target-platform` (app/android/build.gradle.kts).
// A Flutter host's library subproject like this one gets the Kotlin plugin from
// Flutter's Gradle plugin (android.builtInKotlin=false); it has no Kotlin source.

import com.android.build.api.dsl.LibraryExtension
import java.nio.file.Files
import javax.inject.Inject

plugins {
    id("com.android.library")
}

@Suppress("UNCHECKED_CAST")
val codeforgeAbis = rootProject.extra["codeforgeAbis"] as List<String>

@Suppress("UNCHECKED_CAST")
val payloadAbis = rootProject.extra["codeforgePayloadAbis"] as List<String>

// native/runtime-core -> the repository's root, where runtime/ is. (Named
// apart from SealedPayloadTask.repositoryRoot, which the task's configuration
// block below would otherwise see instead.)
val repoDir: File = projectDir.resolve("../..").canonicalFile

// AGP 9's own DSL type: its legacy `android {}` accessor for a library is an
// error-level deprecation (the app's still builds through Flutter's).
configure<LibraryExtension> {
    namespace = "dev.codeforge.runtime.core"
    // Flutter 3.50.0's values, which the app reads from Flutter itself
    // (app/android/app/build.gradle.kts); a library cannot.
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    defaultConfig {
        // ADR-0007, as the app's.
        minSdk = 26
        ndk {
            abiFilters.addAll(codeforgeAbis)
        }
        externalNativeBuild {
            ndkBuild {
                // t1's flags, without -Werror: the C files are vendored
                // unchanged, so a new compiler's new warning must not stop the
                // build (the log keeps it).
                cFlags += listOf("-std=c11", "-Wall", "-Wextra", "-Os", "-fno-stack-protector")
            }
        }
    }

    externalNativeBuild {
        ndkBuild {
            path = file("src/main/jni/Android.mk")
            // In the build directory, not the default .cxx/ beside the sources.
            buildStagingDirectory = layout.buildDirectory.dir("ndk-build").get().asFile
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    // The kernel: plain Java, tested on any JVM (:native:sealed-runtime:test).
    api(project(":native:sealed-runtime"))
}

/**
 * The exec probe: t1's harness-probe.c as a PIE executable named
 * libharnessprobe.so, one per ABI. ndk-build's executables have no `lib*.so`
 * name, so AGP would not package them; this is t1's own way
 * (terminal-emulator/build.gradle, buildExecProbe). Phase 4 W5's ExecModelTest
 * runs it from nativeLibraryDir, through a prefix symlink and from a `#!` line.
 */
abstract class ExecProbeTask : DefaultTask() {
    @get:Inject
    abstract val execOperations: ExecOperations

    @get:InputFile
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val source: RegularFileProperty

    @get:Input
    abstract val abis: ListProperty<String>

    @get:Input
    abstract val minSdk: Property<Int>

    @get:Internal
    abstract val ndkDirectory: DirectoryProperty

    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    @TaskAction
    fun build() {
        val os = System.getProperty("os.name", "").lowercase()
        val host = when {
            os.contains("mac") -> "darwin-x86_64"
            os.contains("windows") -> "windows-x86_64"
            else -> "linux-x86_64"
        }
        val bin = ndkDirectory.get().asFile.resolve("toolchains/llvm/prebuilt/$host/bin")
        if (!bin.isDirectory) {
            throw GradleException("NDK clang not found at $bin")
        }
        val triples = mapOf("arm64-v8a" to "aarch64-linux-android", "x86_64" to "x86_64-linux-android")
        val out = outputDirectory.get().asFile
        out.deleteRecursively()
        out.mkdirs()
        for (abi in abis.get()) {
            val triple = triples[abi] ?: throw GradleException("no NDK target for $abi")
            val compiler = bin.resolve("$triple${minSdk.get()}-clang")
            if (!compiler.isFile) {
                throw GradleException("Missing NDK compiler $compiler")
            }
            val output = out.resolve("$abi/libharnessprobe.so")
            output.parentFile.mkdirs()
            execOperations.exec {
                commandLine(
                    compiler.absolutePath, "-O2", "-fPIE", "-pie",
                    // 16 KB pages (Play, API 35+), as t1 builds it.
                    "-Wl,-z,max-page-size=16384", "-Wl,-z,common-page-size=16384",
                    "-o", output.absolutePath, source.get().asFile.absolutePath,
                )
            }
            if (!output.isFile) {
                throw GradleException("The exec probe was not produced: $output")
            }
            logger.lifecycle("exec probe: $abi/libharnessprobe.so (${output.length()} bytes)")
        }
    }
}

/**
 * One ABI's sealed payload, from the pins: t1's pipeline, with CodeForge's pins
 * in front of it (runtime/README.md). `pins.py bootstrap` and `pins.py fetch`
 * hand over exactly the pinned files, each verified against its SHA-256, from
 * the cache or the network, and fail closed when one is gone;
 * build-sealed-payload.py splits them into the userland zip, its manifests and
 * the executables; `pins.py info` describes the payload for Settings > Runtime.
 *
 * The cache is runtime/generated/cache, the one CI keeps under the pins' hash
 * (.github/workflows/ci.yml). The work happens in the task's temporary
 * directory; the two halves are then moved to where AGP wants them.
 */
abstract class SealedPayloadTask : DefaultTask() {
    @get:Inject
    abstract val execOperations: ExecOperations

    @get:Input
    abstract val abi: Property<String>

    /** runtime/pins.json and the scripts that read it. */
    @get:InputFiles
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val sources: ConfigurableFileCollection

    @get:Internal
    abstract val repositoryRoot: DirectoryProperty

    @get:Internal
    abstract val cache: DirectoryProperty

    @get:OutputDirectory
    abstract val assetsDirectory: DirectoryProperty

    @get:OutputDirectory
    abstract val jniLibsDirectory: DirectoryProperty

    @TaskAction
    fun build() {
        val abi = abi.get()
        val arch = if (abi == "arm64-v8a") "aarch64" else "x86_64"
        val root = repositoryRoot.get().asFile
        val cachePath = cache.get().asFile.absolutePath
        val work = temporaryDir
        work.deleteRecursively()
        work.mkdirs()
        val bootstrap = work.resolve("bootstrap")
        val debs = work.resolve("debs")
        val payload = work.resolve("payload")
        val transcript = work.resolve("build-sealed-payload.log")

        fun python(vararg arguments: String) {
            execOperations.exec {
                workingDir = root
                commandLine(listOf("python3") + arguments.toList())
            }
        }

        python("runtime/pins.py", "bootstrap", "--arch", arch, "--cache", cachePath,
            "--out", bootstrap.absolutePath)
        python("runtime/pins.py", "fetch", "--arch", arch, "--cache", cachePath,
            "--out", debs.absolutePath)
        try {
            python("runtime/build-sealed-payload.py",
                "--bootstrap", bootstrap.resolve("bootstrap-$arch.zip").absolutePath,
                "--abi", abi, "--deb-dir", debs.absolutePath,
                "--out", payload.absolutePath, "--log", transcript.absolutePath)
        } catch (failure: Exception) {
            // The builder writes its own transcript: the reason a payload is not
            // sealed (a library missing, say) would otherwise be lost.
            if (transcript.isFile) {
                logger.error(transcript.readLines().takeLast(40).joinToString("\n"))
            }
            throw GradleException("the sealed payload for $abi did not build", failure)
        }
        python("runtime/pins.py", "info", "--arch", arch,
            "--out", payload.resolve("assets/runtime-info-$abi.json").absolutePath)

        // Both halves into the directories AGP chose: a rename, not a copy.
        moveInto(payload.resolve("assets"), assetsDirectory.get().asFile)
        moveInto(payload.resolve("jniLibs"), jniLibsDirectory.get().asFile)
        val assets = assetsDirectory.get().asFile.listFiles()?.size ?: 0
        val libraries = jniLibsDirectory.get().asFile.resolve(abi).listFiles()?.size ?: 0
        logger.lifecycle("sealed payload $abi: $assets assets, $libraries executables as JNI libraries")
        work.deleteRecursively()
    }

    private fun moveInto(from: File, to: File) {
        if (!from.isDirectory) {
            throw GradleException("the payload has no ${from.name}/: $from")
        }
        to.deleteRecursively()
        to.parentFile.mkdirs()
        // Imported: in a build script `java` alone would be the Java extension.
        Files.move(from.toPath(), to.toPath())
    }
}

fun taskSuffix(value: String): String =
    value.split('-', '_').joinToString("") { part -> part.replaceFirstChar { it.uppercase() } }

androidComponents {
    onVariants { variant ->
        val name = taskSuffix(variant.name)
        val probe = tasks.register<ExecProbeTask>("execProbe$name") {
            source.set(layout.projectDirectory.file("src/main/jni/harness-probe.c"))
            abis.set(codeforgeAbis)
            minSdk.set(26)
            ndkDirectory.set(sdkComponents.ndkDirectory)
        }
        variant.sources.jniLibs?.addGeneratedSourceDirectory(probe, ExecProbeTask::outputDirectory)
        for (abi in payloadAbis) {
            val payload = tasks.register<SealedPayloadTask>("sealedPayload$name${taskSuffix(abi)}") {
                this.abi.set(abi)
                sources.from(
                    repoDir.resolve("runtime/pins.json"),
                    repoDir.resolve("runtime/pins.py"),
                    repoDir.resolve("runtime/fetch-core-debs.py"),
                    repoDir.resolve("runtime/build-sealed-payload.py"),
                )
                repositoryRoot.set(repoDir)
                cache.set(repoDir.resolve("runtime/generated/cache"))
            }
            variant.sources.assets?.addGeneratedSourceDirectory(payload, SealedPayloadTask::assetsDirectory)
            variant.sources.jniLibs?.addGeneratedSourceDirectory(payload, SealedPayloadTask::jniLibsDirectory)
        }
    }
}
