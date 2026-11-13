// CodeForge's build script for the vendored sealed-runtime kernel: t1's
// sealed-runtime/build.gradle, translated to the Kotlin DSL with the same settings
// (native/PROVENANCE.md). The sources and tests are t1's, changed only in their package.
//
// Pure Java on purpose: the kernel must compile and test without an Android SDK, so
// `./gradlew :native:sealed-runtime:test` (run from app/android) runs it on any JVM.
// CI runs it in the "Sealed runtime tests" step (Phase 4 W2, gate G2).
plugins {
    `java-library`
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}

tasks.test {
    useJUnit()
    testLogging {
        events("failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}
