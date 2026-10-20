// Best Music's Wear OS companion: a standalone Gradle build, NOT part of
// android/settings.gradle.kts, so `flutter build apk` never sees it.
// See README.md here.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "best-music-wear"
include(":app")
