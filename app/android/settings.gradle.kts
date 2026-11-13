pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // Pins follow the Flutter 3.50.0 template (verified from flutter/flutter source,
    // packages/flutter_tools/lib/src/android/gradle_utils.dart and the Gradle plugin's
    // DependencyVersionChecker.kt: 3.50.0 refuses AGP below 9.1.1 and KGP below 2.4.10,
    // and warns below these). Upgraded together in Phase 4 W1 (owner, 2026-11-12).
    // AGP is the 9.3 line's latest patch, 9.3.3, not the template's 9.3.1: 9.3.0 and
    // 9.3.1 bundle a lint that crashes on JDK 17 in every release build
    // (NoSuchMethodError List.removeLast(), Google issue 522845800, fixed in 9.3.2),
    // and 9.3.3 fixes D8/R8 bugs, among them dex files that fail verification.
    // t1's runtime modules were built on AGP 8.13.2; they build on these pins once
    // vendored (Phase 4 W2-W3), with any reconciliation only where CI proves it necessary.
    id("com.android.application") version "9.3.3" apply false
    id("org.jetbrains.kotlin.android") version "2.4.20" apply false
}

include(":app")
rootProject.name = "codeforge"

// The vendored sealed-runtime kernel (Phase 4 W2; native/PROVENANCE.md): a plain Java
// library at the repository's root, tested on the JVM by `:native:sealed-runtime:test`.
// The parent project points at the repository's native/ as well, so no directory is
// assumed under app/android. Nothing depends on the module until W3's RuntimeHost.
include(":native:sealed-runtime")
project(":native").projectDir = file("../../native")
project(":native:sealed-runtime").projectDir = file("../../native/sealed-runtime")
