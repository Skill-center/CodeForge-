plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.codeforge.app"
    // Flutter 3.50.0 resolves compileSdk=36, targetSdk=36, ndk=28.2.13676358.
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.codeforge.app"
        // Owner decision 2026-11-05: minSdk 26 (ADR-0007). Phase 4 reconciles against
        // the vendored runtime's minSdk 29 with emulator evidence; no silent changes.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Phase 1: debug-signed so `flutter run --release` works locally.
            // Release signing arrives with the runtime/release work (ADR-0010);
            // CI never publishes an artifact signed this way.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // JVM unit tests of the host's own logic (src/test): the backup policy
    // and its rules files since Phase 3 W1. CI runs :app:testDebugUnitTest.
    testImplementation("junit:junit:4.13.2")
}
