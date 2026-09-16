import java.util.Properties
import java.io.FileInputStream

val keystoreProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) FileInputStream(f).use { load(it) }
}
plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.dsh.invest_tracker"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.dsh.invest_tracker"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
        // 正式发布用 key.properties 里的签名；文件不存在时退回 debug 便于本机调试
        signingConfig = if (keystoreProps.getProperty("storeFile") != null) {
            signingConfigs.create("release") {
                storeFile = file("../" + keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        } else {
            signingConfigs.getByName("debug")
        }
            // ML Kit 引用了未打包的语种模型类，需要 proguard-rules.pro 里的 -dontwarn
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// 中文 OCR 模型要**显式**打进包：
// 插件 google_mlkit_text_recognition 里 `com.google.mlkit:text-recognition`（拉丁）是
// implementation（会进包），而 `text-recognition-chinese` 只是 compileOnly（只编译期可见）。
// 少了这一句，release 包的 assets/mlkit-google-ocr-models 里就只有 Latn 模型，
// 代码里用 TextRecognitionScript.chinese 去识别中文时底层原生库直接崩 —— 表现就是
// 「拍照导入选完图 App 退出」。打进包后离线可用，也不需要 Google 服务。
dependencies {
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
}

flutter {
    source = "../.."
}
