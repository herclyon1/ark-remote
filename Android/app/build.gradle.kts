import java.util.Properties

plugins {
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.android.application)
    id("skip-build-plugin")
}

skip {
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.fromTarget(libs.versions.jvm.get().toString())
    }
}

android {
    namespace = group as String
    compileSdk = libs.versions.android.sdk.compile.get().toInt()
    // the installed NDK (skip-env.sh ANDROID_NDK_HOME); without it AGP looks for its own default NDK version,
    // does not find it, and packages the .so files unstripped ("Unable to strip the following libraries")
    ndkVersion = "30.0.16248370"
    compileOptions {
        sourceCompatibility = JavaVersion.toVersion(libs.versions.jvm.get())
        targetCompatibility = JavaVersion.toVersion(libs.versions.jvm.get())
    }
    packaging {
        jniLibs {
            // no keepDebugSymbols: AGP strips the .debug_* sections from the Swift .so files
            pickFirsts.add("**/*.so")
            // compress JNI .so files: a smaller APK for Skip Fuse apps, at some cost at install time
            useLegacyPackaging = true
        }
        // compress the dex files too: with minSdk >= 28 AGP stores them uncompressed (DexPackaging.kt); ~14.5 MB of dex
        // gzips to ~4.9 MB, so the APK download shrinks ~9.5 MB at the cost of that much more space after install
        dex {
            useLegacyPackaging = true
        }
    }

    defaultConfig {
        minSdk = libs.versions.android.sdk.min.get().toInt()
        targetSdk = libs.versions.android.sdk.compile.get().toInt()
        // arm64 phones only: armeabi-v7a and x86_64 each added ~130 MB of Swift libraries
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
        // skip.tools.skip-build-plugin will automatically use Skip.env properties for:
        // applicationId = ANDROID_APPLICATION_ID ?? PRODUCT_BUNDLE_IDENTIFIER
        // versionCode = CURRENT_PROJECT_VERSION
        // versionName = MARKETING_VERSION
    }

    buildFeatures {
        buildConfig = true
    }

    lint {
        disable.add("Instantiatable")
        disable.add("MissingPermission")
    }

    dependenciesInfo {
        // Disables dependency metadata when building APKs.
        includeInApk = false
        // Disables dependency metadata when building Android App Bundles.
        includeInBundle = false
    }

    // default signing configuration tries to load from keystore.properties
    // see: https://skip.dev/docs/deployment/#export-signing
    // The repo is public, so the key lives outside it: when there is no Android/app/keystore.properties,
    // read ~/.config/ark/ark-remote-signing.properties (same keys: keyAlias, storeFile, storePassword, keyPassword).
    signingConfigs {
        val keystorePropertiesFile = file("keystore.properties").takeIf { it.isFile }
            ?: File(System.getProperty("user.home"), ".config/ark/ark-remote-signing.properties")
        create("release") {
            if (keystorePropertiesFile.isFile) {
                val keystoreProperties = Properties()
                keystoreProperties.load(keystorePropertiesFile.inputStream())
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            } else {
                // when there is no keystore.properties file, fall back to signing with debug config
                logger.warn("w: no release signing properties at ${keystorePropertiesFile}; the release build is signed with the DEBUG key")
                keyAlias = signingConfigs.getByName("debug").keyAlias
                keyPassword = signingConfigs.getByName("debug").keyPassword
                storeFile = signingConfigs.getByName("debug").storeFile
                storePassword = signingConfigs.getByName("debug").storePassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            isDebuggable = false // can be set to true for debugging release build, but needs to be false when uploading to store
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

// Local unit tests (src/test, run on the JVM: gradle :app:testDebugUnitTest). JUnit 4.13.2 is the current JUnit 4
// release. "By default, the source files for local unit tests are placed in module-name/src/test/."
// (https://developer.android.com/training/testing/local-tests)
dependencies {
    testImplementation("junit:junit:4.13.2")
}
