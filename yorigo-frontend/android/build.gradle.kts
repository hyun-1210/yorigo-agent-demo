allprojects {
    repositories {
        // 공식 저장소를 우선해 현재 Flutter 엔진이 쓰이도록 한다.
        // 로컬 미러는 CDN 장애 시 fallback 전용(존재할 때만).
        google()
        mavenCentral()
        val localFlutterMaven = file("${rootProject.projectDir}/../.flutter_maven")
        if (localFlutterMaven.exists()) {
            maven {
                url = uri(localFlutterMaven)
            }
        }
    }
    
    // Force all subprojects (including plugins) to use Java 17
    afterEvaluate {
        // Check if it's an Android project (app or library)
        if (plugins.hasPlugin("com.android.application") || plugins.hasPlugin("com.android.library")) {
            configure<com.android.build.gradle.BaseExtension> {
                compileOptions {
                    sourceCompatibility = JavaVersion.VERSION_17
                    targetCompatibility = JavaVersion.VERSION_17
                }
            }
        }
        
        // Also configure standard Java tasks just in case
        tasks.withType<JavaCompile>().configureEach {
            sourceCompatibility = JavaVersion.VERSION_17.toString()
            targetCompatibility = JavaVersion.VERSION_17.toString()
        }
        
        // Kotlin compilation tasks (subprojects / plugins)
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
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

subprojects {
    pluginManager.withPlugin("com.android.library") {
        dependencies {
            add("implementation", "androidx.annotation:annotation:1.9.1")
            add("implementation", "androidx.core:core:1.15.0")
            add("implementation", "androidx.lifecycle:lifecycle-common:2.8.7")
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
