import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 签名密码从 local.properties（不入库）或环境变量 KEYSTORE_PASSWORD 读取，
// 避免把签名凭据提交进仓库。
val keystorePassword: String by lazy {
    val props = Properties()
    val f = rootProject.file("local.properties")
    if (f.exists()) f.inputStream().use { props.load(it) }
    props.getProperty("KEYSTORE_PASSWORD")
        ?: System.getenv("KEYSTORE_PASSWORD")
        ?: error(
            "缺少签名密码：请在 android/local.properties 或环境变量中设置 KEYSTORE_PASSWORD"
        )
}

android {
    namespace = "com.shiyi.agent"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.shiyi.agent"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        // targetSdk 降到 34：Android 15/16 对 targetSdk>=35 的 app 收紧
        // 「执行私有目录 ELF」的 SELinux 权限，降级走旧兼容行为（类似 Termux）。
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }

    signingConfigs {
        create("release") {
            storeFile = file("../../keystore.jks")
            storePassword = keystorePassword
            keyAlias = "shiyi"
            keyPassword = keystorePassword
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

