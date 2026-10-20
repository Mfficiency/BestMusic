import java.io.FileInputStream
import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Signing: the SAME upload key as the phone app (android/key.properties).
// The Wearable Data Layer only connects the phone and the watch app when
// both have the same applicationId and the same signing certificate.
// storeFile in key.properties is relative to android/app (the phone's app
// module resolves it with file()), so it is resolved against that folder
// here too; an absolute path stays as it is.
val keyProperties = Properties()
val keyPropertiesFile = rootDir.resolve("../android/key.properties")
if (keyPropertiesFile.exists()) {
    FileInputStream(keyPropertiesFile).use { keyProperties.load(it) }
}
val hasReleaseKey = listOf("keyAlias", "keyPassword", "storeFile", "storePassword")
    .all { !keyProperties.getProperty(it).isNullOrBlank() }
// tool\build.ps1 release sets this: a published watch APK must carry the
// upload key, never the debug fallback below.
if (System.getenv("REQUIRE_RELEASE_KEY") == "1" && !hasReleaseKey) {
    throw GradleException("REQUIRE_RELEASE_KEY=1 but android/key.properties is missing or incomplete")
}

// x.y.z from the repo's pubspec.yaml (`version: x.y.z+build`), so the watch
// carries the phone app's version unless -PversionName says otherwise.
val pubspecVersion: String = run {
    val pubspec = rootDir.resolve("../pubspec.yaml")
    val line = if (pubspec.exists()) {
        pubspec.readLines().firstOrNull { it.startsWith("version:") }
    } else {
        null
    }
    line?.substringAfter(":")?.trim()?.substringBefore("+")?.ifEmpty { null } ?: "0.0.0"
}

android {
    // The Kotlin package / R class live under <applicationId>.wear; the
    // applicationId itself must be the phone app's (see signing above).
    namespace = "com.mfficiency.best_music.wear"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.mfficiency.best_music"
        minSdk = 30
        targetSdk = 34
        versionCode = (findProperty("buildNumber") ?: System.getenv("BUILD_NUMBER") ?: "1")
            .toString().trim().toInt()
        versionName = (findProperty("versionName") ?: pubspecVersion).toString()
    }

    signingConfigs {
        // The phone's committed debug keystore (standard public debug
        // credentials), so a local debug watch build pairs with a local
        // debug phone build.
        getByName("debug") {
            storeFile = rootDir.resolve("../android/app/debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
        if (hasReleaseKey) {
            create("release") {
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
                storeFile = rootDir.resolve("../android/app")
                    .resolve(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.wear.compose:compose-material:1.4.1")
    implementation("androidx.wear.compose:compose-foundation:1.4.1")
    implementation("com.google.android.gms:play-services-wearable:18.2.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.9.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
