allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}
// All project-level fixes run after every project is configured (avoids the
// "already evaluated" error that afterEvaluate triggers when evaluationDependsOn
// has already forced a project to evaluate).
gradle.projectsEvaluated {
    // Fix 0: Override unityLibrary's ndkVersion AND ndkPath to use the installed NDK 27.
    // Unity IL2CPP build.gradle sets ndkVersion=23.x and ndkPath=Unity's bundled NDK.
    // Neither matches the Android SDK NDK, causing BuildIl2CppTask to fail.
    rootProject.findProject(":unityLibrary")?.let { unityLib ->
        (unityLib.extensions.findByName("android") as? com.android.build.gradle.LibraryExtension)
            ?.let { android ->
                android.ndkVersion = "27.0.12077973"
                android.ndkPath = "C:\\Users\\Kimhajin\\AppData\\Local\\Android\\sdk\\ndk\\27.0.12077973"
            }
    }

    // Fix 1: Provide unity-classes.jar as compileOnly to every subproject so that
    // flutter_unity_widget can resolve UnityPlayer / IUnityPlayerLifecycleEvents.
    rootProject.subprojects.forEach { proj ->
        proj.configurations.findByName("compileOnly")?.let { config ->
            listOf("unity-classes.jar", "classes.jar").forEach { jarName ->
                val jar = rootProject.file("unityLibrary/unityLibrary/libs/$jarName")
                if (jar.exists()) {
                    config.dependencies.add(proj.dependencies.create(proj.files(jar)))
                }
            }
        }
    }

    // Fix 2: Move conflicting Mapbox deps from `implementation` to `compileOnly`
    // in the unityLibrary project so they are not packaged into the APK.
    // mapbox_maps_flutter provides the newer compatible versions at runtime.
    rootProject.findProject(":unityLibrary")?.let { unityLib ->
        val implConfig = unityLib.configurations.findByName("implementation") ?: return@let
        val compileOnly = unityLib.configurations.findByName("compileOnly")

        // Fix 2a: Named AARs – ExternalModuleDependency with no Maven group
        // (e.g. implementation(name:'common-ndk27-24.10.0', ext:'aar'))
        val externalToMove = implConfig.dependencies
            .filterIsInstance<org.gradle.api.artifacts.ExternalModuleDependency>()
            .filter { dep -> (dep.group ?: "").isEmpty() && !dep.name.startsWith("unity-") && dep.name != "classes" }
            .toList()
        externalToMove.forEach { dep ->
            implConfig.dependencies.remove(dep)
            compileOnly?.dependencies?.add(dep)
        }

        // Fix 2b: fileTree JARs – FileCollectionDependency
        // Unity puts all JARs via: implementation fileTree(dir:'libs', include:['*.jar'])
        // Split each fileTree into conflicting Mapbox JARs (→ compileOnly) and
        // everything else (kept as implementation so the Unity runtime still works).
        val mapboxJarPatterns = listOf(
            Regex("annotations-.*\\.jar"),
            Regex("mapbox-sdk-geojson-.*\\.jar"),
            Regex("mapbox-sdk-turf-.*\\.jar"),
            Regex("mapbox-sdk-services-.*\\.jar"),
        )
        val fileCollectionDeps = implConfig.dependencies
            .filterIsInstance<org.gradle.api.artifacts.FileCollectionDependency>()
            .toList()
        fileCollectionDeps.forEach { dep ->
            try {
                val all = dep.files.files.toList()
                val conflicting = all.filter { f -> mapboxJarPatterns.any { p -> p.matches(f.name) } }
                if (conflicting.isNotEmpty()) {
                    val keep = all - conflicting.toSet()
                    implConfig.dependencies.remove(dep)
                    if (keep.isNotEmpty()) {
                        implConfig.dependencies.add(unityLib.dependencies.create(unityLib.files(*keep.toTypedArray())))
                    }
                    compileOnly?.dependencies?.add(unityLib.dependencies.create(unityLib.files(*conflicting.toTypedArray())))
                }
            } catch (_: Exception) {}
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
