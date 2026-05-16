pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }

    resolutionStrategy {
        eachPlugin {
            if (requested.id.id.startsWith("com.android")) {
                useVersion("8.11.1")
            }
        }
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")

// Unity 라이브러리 - Unity Export 후 android/unityLibrary 폴더가 생성되면 활성화됨
val unityLibraryDir = file("unityLibrary/unityLibrary")
if (unityLibraryDir.exists()) {
    include(":unityLibrary")
    project(":unityLibrary").projectDir = unityLibraryDir

    // unityLibrary의 AAR 파일을 모든 프로젝트에서 찾을 수 있도록 등록
    gradle.allprojects {
        repositories {
            flatDir {
                dirs("${rootDir}/unityLibrary/unityLibrary/libs")
            }
        }
    }
}
