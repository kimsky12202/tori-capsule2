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

// Provide unity-classes.jar as compileOnly to every subproject that declares a compileOnly
// configuration. This lets flutter_unity_widget resolve UnityPlayer /
// IUnityPlayerLifecycleEvents without coupling to the project name or evaluation order.
subprojects {
    afterEvaluate {
        if (configurations.findByName("compileOnly") != null) {
            listOf("unity-classes.jar", "classes.jar").forEach { jarName ->
                val jar = rootProject.file("unityLibrary/unityLibrary/libs/$jarName")
                if (jar.exists()) {
                    dependencies.add("compileOnly", files(jar))
                }
            }
        }
    }
}

// Move conflicting flat-file Mapbox AARs bundled by Unity from `implementation` to
// `compileOnly` inside the unityLibrary project.  This keeps them on the compile
// classpath so Unity code compiles, but stops them from being packaged into the APK
// where they would duplicate the newer version pulled in by mapbox_maps_flutter.
gradle.projectsEvaluated {
    rootProject.findProject(":unityLibrary")?.let { unityLib ->
        val implConfig = unityLib.configurations.findByName("implementation") ?: return@let
        val compileOnly = unityLib.configurations.findByName("compileOnly")
        val conflictingPrefixes = listOf(
            "common-ndk27",
            "common-0.",
            "loader-",
            "logger-",
        )
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
