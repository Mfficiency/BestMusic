import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}


val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
val hasReleaseKeystore = listOf("keyAlias", "keyPassword", "storeFile", "storePassword")
    .all { !keystoreProperties.getProperty(it).isNullOrBlank() }
// `tool\build.ps1 release` (a published laptop channel build) sets this: such
// a build must be signed with the upload key, never the debug fallback below.
if (System.getenv("REQUIRE_RELEASE_KEY") == "1" && !hasReleaseKeystore) {
    throw GradleException("REQUIRE_RELEASE_KEY=1 but android/key.properties is missing or incomplete")
}

// Release channel (dev / staging / main) = the branch a laptop build came
// from (BUILD_CHANNEL, set by tool\build.ps1 release). All three build the
// SAME app: one applicationId and one name for every channel, so a phone has
// one Best Music that updates to the highest build number of any channel.
// The channel only reaches Dart (--dart-define, shown next to the version on
// the About page); here it is just validated.
val buildChannel = (System.getenv("BUILD_CHANNEL") ?: "").trim().lowercase().ifEmpty { "main" }
if (buildChannel !in setOf("main", "staging", "dev")) {
    throw GradleException("BUILD_CHANNEL must be dev, staging or main (got '$buildChannel')")
}
android {
    // Namespace and Kotlin package stay com.mfficiency.best_todo_2 (Best
    // Music used to be a flavor of the BestToDo repo): placed widgets and
    // the share target are stored by component name, so renaming them would
    // break them on every phone that updates. The applicationId is Best
    // Music's own.
    namespace = "com.mfficiency.best_todo_2"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        applicationId = "com.mfficiency.best_music"
        // androidx.work (pulled in transitively via glance/home_widget)
        // requires a minSdk of at least 23; 26 is what Best Music has always
        // shipped with (lowering it would change nothing on existing phones).
        minSdk = maxOf(26, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        // Laptop channel builds pass --build-number=BUILD_NUMBER (minutes
        // since 2020-01-01 UTC of the built commit), which lands here.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    if (hasReleaseKeystore) {
        signingConfigs {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    // Use a committed, fixed debug keystore (standard public debug
    // credentials) instead of the per-machine/per-CI-run ~/.android
    // keystore, so every build is signed with the same key and updates
    // install in place. The release build falls back to this signing
    // config until a real release keystore (key.properties) is provided.
    signingConfigs {
        getByName("debug") {
            storeFile = file("debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            if (hasReleaseKeystore) {
                signingConfig = signingConfigs.getByName("release")
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.annotation:annotation:1.7.1")
    // androidx.core (NotificationCompat, ContextCompat, …): transitively
    // present anyway, pinned explicitly so it never shifts on a dependency
    // shuffle. (The in-app update installer is the mfficiency_updates
    // plugin's; it needs no FileProvider.)
    implementation("androidx.core:core:1.13.1")
    // MediaBrowserCompat/MediaControllerCompat for the widget's like /
    // dislike / heart buttons (same version audio_service uses).
    implementation("androidx.media:media:1.7.0")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.10.3")
    testImplementation("androidx.test:core:1.5.0")
}

// home_widget 0.8.1 declares `androidx.glance:glance-appwidget:1.+`, which now
// resolves to 1.3.0-alpha01 and demands compileSdk 37 + AGP 9.1.0. Pin to the
// latest stable 1.1.x until we're ready to bump the Android toolchain.
//
// Same story one level down, and it broke the release build on 2026-08-15:
// WorkManager came in unpinned and picked up the freshly published
// `androidx.work:work-runtime-ktx:2.12.0-rc01`, which declares minSdk 24 —
// the manifest merger then refused this app's minSdk 23 and every
// `assembleRelease` failed at `:app:processReleaseMainManifest`, with no code
// change of ours involved. Pinned to the last line that still supports 23, so
// a new upstream pre-release can't take the build out again. (minSdk is 26 as
// of 0.2.9+300 — see defaultConfig — so the work-runtime clash no longer bites,
// but the pins stay put to keep the toolchain bump deliberate.)
configurations.all {
    resolutionStrategy {
        force("androidx.glance:glance-appwidget:1.1.1")
        force("androidx.glance:glance:1.1.1")
        force("androidx.work:work-runtime:2.10.0")
        force("androidx.work:work-runtime-ktx:2.10.0")
    }
}
