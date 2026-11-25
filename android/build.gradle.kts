// Medya motoru: Android yerel ortam eklentisi (Java, Media3 Transformer).
// Kotlin eklentisi kullanılmaz; AGP 8 ve AGP 9 (yerleşik Kotlin) ile uyumludur.
group = "com.gamestudio100.medya_motoru"
version = "1.0"

buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.android.tools.build:gradle:8.13.1")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "com.gamestudio100.medya_motoru"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        minSdk = 24
    }
}

dependencies {
    // video_player_android ile aynı Media3 sürümü (karışık sürüm desteklenmez).
    val media3 = "1.9.2"
    implementation("androidx.media3:media3-transformer:$media3")
    implementation("androidx.media3:media3-effect:$media3")
    implementation("androidx.media3:media3-common:$media3")
    implementation("androidx.annotation:annotation:1.9.1")
    // Cihaz üzerinde yapay zekâ (arka plan silme, büyütme, renklendirme).
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.22.0")
    // Saf Java zamanlama yardımcıları (RecordClock, AudioTimeline) için JVM birim testleri.
    testImplementation("junit:junit:4.13.2")
}
