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

    // Fix 2: Move conflicting flat-file Mapbox AARs bundled by Unity from
    // `implementation` to `compileOnly` inside the unityLibrary project so they
    // are not packaged into the APK (mapbox_maps_flutter provides a newer version).
    rootProject.findProject(":unityLibrary")?.let { unityLib ->
        val implConfig = unityLib.configurations.findByName("implementation") ?: return@let
        val compileOnly = unityLib.configurations.findByName("compileOnly")
        val conflictingPrefixes = listOf("common-ndk27", "common-0.", "loader-", "logger-")
        val toMove = implConfig.dependencies
            .filterIsInstance<org.gradle.api.artifacts.ExternalModuleDependency>()
            .filter { dep -> conflictingPrefixes.any { dep.name.startsWith(it) } }
            .toList()
        toMove.forEach { dep ->
            implConfig.dependencies.remove(dep)
            compileOnly?.dependencies?.add(dep)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
