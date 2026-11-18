plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The ABIs this build targets (app/android/build.gradle.kts, Phase 4 W3).
@Suppress("UNCHECKED_CAST")
val codeforgeAbis = rootProject.extra["codeforgeAbis"] as List<String>

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
        // CodeForge ships arm64-v8a and x86_64, nothing 32-bit (Phase 4 W3,
        // PHASE_4_PLAN §2), and a build only the ABIs it targets: Flutter's plugin
        // set all three of its own when it was applied, and a library's native
        // code would otherwise bring an ABI the engine was not built for.
        ndk {
            abiFilters.clear()
            abiFilters.addAll(codeforgeAbis)
        }
        // The runtime's instrumented tests (src/androidTest; the gate's runtime
        // group runs them on the emulator).
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    packaging {
        jniLibs {
            // The runtime's executables ship as JNI libraries (lib*.so). Packaged
            // the legacy way they are compressed in the APK, and Android extracts
            // them at install as real files in nativeLibraryDir, the one place an
            // app targeting API 29+ may execve() from: invariant 1 of
            // docs/RUNTIME_INTEGRATION.md §2. The merged manifest's
            // android:extractNativeLibs follows (tool/ci/check_manifest.py).
            useLegacyPackaging = true
            // The exec probe is an executable, not a library: never stripped.
            keepDebugSymbols += "**/libharnessprobe.so"
        }
    }

    androidResources {
        // The runtime's userland zip is compressed already.
        noCompress += "zip"
    }

    // An APK with the runtime is about 170 MB: give an emulator time to install it.
    installation {
        timeOutInMs = 10 * 60 * 1000
    }

    // The release key (Phase 5 W1, docs/BUILD_AND_RELEASE.md §4), from the
    // environment: the release workflow (.github/workflows/release.yml) points
    // it at Play's upload key for the App Bundle and at the owner's release key
    // for the APK, or at a throwaway key it makes for a dry run. Without it a
    // release build is debug-signed, so `flutter run --release` works locally;
    // nothing signed that way is published.
    val releaseStore = providers.environmentVariable("CODEFORGE_SIGNING_STORE_FILE").orNull
    if (!releaseStore.isNullOrBlank()) {
        signingConfigs {
            create("release") {
                storeFile = file(releaseStore)
                storePassword = providers.environmentVariable("CODEFORGE_SIGNING_STORE_PASSWORD").orNull
                keyAlias = providers.environmentVariable("CODEFORGE_SIGNING_KEY_ALIAS").orNull
                keyPassword = providers.environmentVariable("CODEFORGE_SIGNING_KEY_PASSWORD").orNull
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
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
    // The runtime core (Phase 4 W3): t1's adapter, the preload and the payload,
    // with the kernel (:native:sealed-runtime) behind it.
    implementation(project(":native:runtime-core"))

    // JVM unit tests of the host's own logic (src/test): the backup policy
    // and its rules files since Phase 3 W1, the runtime host since Phase 4 W3.
    // CI runs :app:testDebugUnitTest.
    testImplementation("junit:junit:4.13.2")

    // The runtime's instrumented tests (src/androidTest), on a device. Their
    // APK runs in the app's process, and AGP leaves out of it whatever the
    // debug app already contains, resolving it to the app's versions. Flutter's
    // integration_test plugin (a dev dependency, which only release builds leave
    // out) puts the androidx.test 1.3.0 train into the debug app: runner 1.3.0
    // with junit 4.12. So these stay on that train; a newer one fails to resolve
    // (CI 43804216240). That train's androidx.test.ext:junit brings core 1.3.0,
    // whose activities lack android:exported, which fails the manifest merge
    // for apps that target Android 12 or later (CI 43805853809). So the tests
    // are plain JUnit4 classes, which AndroidJUnitRunner runs without it.
    androidTestImplementation("junit:junit:4.12")
    androidTestImplementation("androidx.test:runner:1.3.0")
    // ActivityTestRule, for integration_test's FlutterTestRunner (Phase 4 W5:
    // the session store's sync modes on a Test Lab phone, androidTest's
    // syncmodes/SyncModesTest.java). The same train's version, which
    // integration_test already puts into the debug app.
    androidTestImplementation("androidx.test:rules:1.2.0")
}
