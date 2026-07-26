group = "io.ushakov.flutter_map_maplibre"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.3.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.0.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "io.ushakov.flutter_map_maplibre"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24

        // maplibre-native-ffi builds arm64-v8a and x86_64 only; this spike
        // built arm64 alone, which is what the Apple-Silicon emulator uses.
        ndk {
            abiFilters += listOf("arm64-v8a")
        }

        externalNativeBuild {
            cmake {
                // Must match how maplibre-native-ffi was built, or the C++
                // runtime symbols will not line up.
                arguments += listOf("-DANDROID_STL=c++_shared")
                cppFlags += listOf("-std=c++17", "-fexceptions", "-frtti")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Provides org.rustls.platformverifier.CertificateVerifier, which the Rust
    // HTTP stack calls through JNI to validate TLS against the platform trust
    // store. Without it every handshake fails and the style silently never
    // loads — the map renders nothing and reports no error.
    //
    // rustls-platform-verifier ships this only as an AAR inside the Rust crate,
    // never published to Maven Central. Consuming that AAR would force every
    // host app to declare a custom repository, because Gradle resolves a
    // library's POM dependencies in the *app's* context. The AAR holds nothing
    // but a 9K classes.jar (no resources, no transitive deps), so the jar is
    // vendored directly: local file deps are packaged into the consuming APK
    // with no host configuration at all.
    implementation(files("prebuilt/rustls-platform-verifier-0.1.1.jar"))

    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
}
