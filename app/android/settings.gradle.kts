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
    // t1's runtime modules were built on AGP 8.13.2; they build on these pins once
    // vendored (Phase 4 W2-W3), with any reconciliation only where CI proves it necessary.
    id("com.android.application") version "9.3.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.20" apply false
}

include(":app")
rootProject.name = "codeforge"
