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

// ─── Parche directo al build.gradle de flutter_bluetooth_serial en la caché ──
// AGP finalizeDsl() bloquea compileSdk desde hooks de Gradle; la única vía
// determinista es reescribir el archivo fuente antes de que AAPT lo lea.
// NOTA: flutter pub get revierte el parche — re-ejecutar el build lo reaplicará.
tasks.register("patchBluetoothLibrary") {
    doFirst {
        val pubCacheDir = file("${System.getProperty("user.home")}/AppData/Local/Pub/Cache/hosted/pub.dev")
        if (pubCacheDir.exists()) {
            // Parchea TODOS los plugins que tengan build.gradle Android antiguo
            val targets = listOf("flutter_bluetooth_serial-", "flutter_sound-")
            pubCacheDir.listFiles()?.filter { dir ->
                targets.any { dir.name.startsWith(it) }
            }?.forEach { pluginDir ->
                val targetBuildGradle = file("${pluginDir.absolutePath}/android/build.gradle")
                if (targetBuildGradle.exists()) {
                    var content = targetBuildGradle.readText()

                    // Cubre entero, variable, rootProject.ext.X y cualquier otra forma
                    content = content.replace(Regex("""compileSdkVersion\s+.*"""), "compileSdkVersion 34")
                    content = content.replace(Regex("""targetSdkVersion\s+.*"""), "targetSdkVersion 34")

                    // Fallback: si ningún patrón coincidió, inyecta directamente
                    if (!content.contains("compileSdkVersion 34")) {
                        content = content.replace("android {", "android {\n    compileSdkVersion 34")
                    }

                    targetBuildGradle.writeText(content)
                    println("====== [PARCHE MAESTRO] ${pluginDir.name} → compileSdkVersion 34 ======")
                }
            }
        }
    }
}

// ─── Auto-namespace + dependencia del parche en todas las tareas de compilación ─
subprojects {
    val proj = this

    // Garantiza que el parche ocurra antes de compilación Y antes de AAPT (process/merge)
    proj.tasks.configureEach {
        if (name.contains("compile") || name.contains("verify") ||
            name.contains("process") || name.contains("merge")) {
            dependsOn(":patchBluetoothLibrary")
        }
    }

    // Inyector de namespace dinámico con fallback completo
    val namespaceHandler = { _: Plugin<*> ->
        val androidExtension = proj.extensions.findByName("android")
            as? com.android.build.api.dsl.CommonExtension<*, *, *, *, *, *>
        if (androidExtension != null && androidExtension.namespace == null) {
            val manifestFile = proj.file("src/main/AndroidManifest.xml")
            if (manifestFile.exists()) {
                val match = Regex("""package=["']([^"']+)["']""").find(manifestFile.readText())
                if (match != null) {
                    androidExtension.namespace = match.groupValues[1]
                } else {
                    androidExtension.namespace = proj.name.replace("_", ".").replace("-", ".")
                }
            } else {
                androidExtension.namespace = proj.name.replace("_", ".").replace("-", ".")
            }
        }
    }

    proj.plugins.withId("com.android.library", namespaceHandler)
    proj.plugins.withId("com.android.application", namespaceHandler)
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
