import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The upload key, if this machine has one. `android/key.properties` is
// gitignored and holds four lines; `tool/release_android.sh --keystore` makes
// a throwaway one for builds nobody publishes.
val signing = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
val hasUploadKey = signing.getProperty("storeFile") != null

android {
    namespace = "cg.billetenligne.bel_traveller"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "cg.billetenligne.bel_traveller"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // From pubspec's `version:`, or from `--build-number` / `--build-name`.
        // Play refuses a second upload at the same versionCode, so a release
        // that does not pass one is a release that can be built and not
        // shipped.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // The domain whose links open this app. It is a build input rather
        // than a constant because a staging deployment on another hostname
        // would otherwise claim `blt.cg` and be refused by an assetlinks file
        // it does not serve — which presents as "links stopped working" with
        // nothing in any log.
        manifestPlaceholders["belLinkHost"] =
            (findProperty("belLinkHost") as String?) ?: "blt.cg"
    }

    signingConfigs {
        create("release") {
            keyAlias = signing.getProperty("keyAlias")
            keyPassword = signing.getProperty("keyPassword")
            // Relative to `android/`, where key.properties is — not to `android/app/`,
            // which is what a bare `file()` would mean here.
            storeFile = signing.getProperty("storeFile")?.let { rootProject.file(it) }
            storePassword = signing.getProperty("storePassword")
        }
    }

    buildTypes {
        release {
            // With no key this build produces an **unsigned** artifact, which
            // will not install. That is the point. The alternative the Flutter
            // template ships — falling back to the debug key — produces an APK
            // that installs and runs and looks finished, signed with a
            // certificate whose password is `android` and which is on every
            // machine that has ever built an Android app: anybody at all can
            // publish an update to it. An agency sideloading that has
            // installed something a stranger can replace.
            signingConfig = if (hasUploadKey) {
                signingConfigs.getByName("release")
            } else {
                null
            }
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
