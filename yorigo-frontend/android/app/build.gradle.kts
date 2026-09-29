import java.io.FileInputStream
import java.io.InputStreamReader
import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

/** --- NEW: load key.properties if present --- **/
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProps = Properties()
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystorePropertiesFile.inputStream().use { input ->
        val reader: InputStreamReader = InputStreamReader(input, "UTF-8")
        keystoreProps.load(reader)
    }
}

android {
    namespace = "com.yorigo.mobile"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.yorigo.mobile"
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = flutter.versionCode     // bump for every Play upload
        versionName = flutter.versionName
    }

    /** --- NEW: signing configs --- **/
    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                val storeFileProp = keystoreProps.getProperty("storeFile") ?: ""
                val storeFileResolved = if (storeFileProp.startsWith("/") || storeFileProp.matches(Regex("^[A-Za-z]:.*"))) {
                    file(storeFileProp)  // Absolute path
                } else {
                    rootProject.file(storeFileProp)  // Relative path from android directory
                }
                
                val storePasswordProp = keystoreProps.getProperty("storePassword") ?: ""
                val keyPasswordProp = keystoreProps.getProperty("keyPassword") ?: ""
                val keyAliasProp = keystoreProps.getProperty("keyAlias") ?: ""
                storeFile = storeFileResolved
                storePassword = storePasswordProp
                keyAlias = keyAliasProp
                keyPassword = keyPasswordProp
            }
        }
    }

    buildTypes {
        release {
            // Use your real release key if present; otherwise fall back to debug (so local `flutter run --release` still works).
            signingConfig = if (hasReleaseKeystore)
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")

            // Optional but recommended for store builds:
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )

            // Ensure native debug symbols are generated for Play Console.
            ndk {
                debugSymbolLevel = "FULL"
            }
        }
        debug {
            // leave default debug signing
        }
    }

}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.lifecycle:lifecycle-runtime:2.8.7")
    implementation("androidx.lifecycle:lifecycle-common:2.8.7")
    implementation("androidx.core:core-ktx:1.15.0")
    // 로컬 Flutter embedding POM에 transitive가 없어 profile에서 누락됨
    implementation("com.getkeepsafe.relinker:relinker:1.4.5")
}

flutter {
    source = "../.."
}
