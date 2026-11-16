allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// The ABIs a build targets, and the one it carries the sealed runtime for
// (Phase 4 W3; docs/RUNTIME_INTEGRATION.md §2, docs/BUILD_AND_RELEASE.md §3).
// The app (its abiFilters) and native/runtime-core (its native code and the
// payload) both read these two lists.
//
// Flutter passes the platforms it builds as `target-platform` (android-arm64,
// android-x64; its three defaults when unset). CodeForge ships arm64-v8a and
// x86_64 and nothing 32-bit. The payload is about 200 MB per ABI, so it goes
// into a build that targets exactly one ABI, and no APK carries two: the
// emulator gate's builds are x86_64, the phone's and Test Lab's arm64-v8a. A
// build for both (a plain `flutter build apk --debug`) carries none. The
// project property `codeforgePayload` decides instead when set: `none`, or
// ABIs, comma-separated; CI's builds that test no runtime set it to none
// through the environment (ORG_GRADLE_PROJECT_codeforgePayload=none).
val shippedAbis = listOf("arm64-v8a", "x86_64")
val flutterAbis = mapOf(
    "android-arm" to "armeabi-v7a",
    "android-arm64" to "arm64-v8a",
    "android-x64" to "x86_64",
)
val targetPlatforms = (findProperty("target-platform") as String?)
    ?.split(",")
    ?.map { it.trim() }
    ?.filter { it.isNotEmpty() }
val codeforgeAbis = targetPlatforms
    ?.mapNotNull { flutterAbis[it] }
    ?.filter { it in shippedAbis }
    ?.distinct()
    ?: shippedAbis
if (codeforgeAbis.isEmpty()) {
    throw GradleException(
        "CodeForge ships arm64-v8a and x86_64; this build targets $targetPlatforms",
    )
}
val requestedPayload = (findProperty("codeforgePayload") as String?)?.trim().orEmpty()
val codeforgePayloadAbis = when (requestedPayload) {
    "" -> if (codeforgeAbis.size == 1) codeforgeAbis else emptyList()
    "none" -> emptyList()
    else -> requestedPayload.split(",").map { it.trim() }.filter { it.isNotEmpty() }
}
for (abi in codeforgePayloadAbis) {
    if (abi !in codeforgeAbis) {
        throw GradleException(
            "codeforgePayload names $abi, which this build does not target ($codeforgeAbis)",
        )
    }
}
extra["codeforgeAbis"] = codeforgeAbis
extra["codeforgePayloadAbis"] = codeforgePayloadAbis
logger.lifecycle(
    "CodeForge ABIs: ${codeforgeAbis.joinToString()}; sealed runtime payload: " +
        (codeforgePayloadAbis.joinToString().ifEmpty { "none" }),
)

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
