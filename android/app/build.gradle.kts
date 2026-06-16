import java.text.SimpleDateFormat
import java.util.Date

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

val buildTime: String = SimpleDateFormat("yyyyMMdd_HHmm").format(Date())
val buildCode: Int    = SimpleDateFormat("yyyyMMddHH").format(Date()).toInt()

android {
    ndkVersion = "28.2.13676358"
    namespace = "com.example.my_taxi_app"
    compileSdk = 36

    compileOptions {
        // Απαιτείται από flutter_local_notifications 17+
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    androidComponents {
        onVariants { variant ->
            variant.outputs.forEach { output ->
                if (output is com.android.build.api.variant.impl.VariantOutputImpl) {
                    output.outputFileName.set("AthensTaxi_v${variant.name}_${buildTime}.apk")
                }
            }
        }
    }

    kotlin {
        compilerOptions {
            jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
        }
    }

    defaultConfig {
        applicationId = "com.example.my_taxi_app"
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = buildCode
        versionName = "1.0.$buildTime"
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

// Desugar library για να δουλέψει το flutter_local_notifications 17+
// σε παλαιότερα Android (java.time.* APIs).
dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

tasks.whenTaskAdded {
    if (name == "assembleDebug" || name == "assembleRelease") {
        doLast {
            listOf("app-debug.apk", "app-release.apk").forEach { apkName ->
                val apk = file("${rootDir}/../build/app/outputs/flutter-apk/$apkName")
                if (apk.exists()) {
                    val type = if (apkName.contains("release")) "release" else "debug"
                    val renamed = file("${rootDir}/../build/app/outputs/flutter-apk/AthensTaxi_v1.0.${buildTime}_${type}.apk")
                    apk.renameTo(renamed)
                }
            }
        }
    }
}

flutter {
    source = "../.."
}
