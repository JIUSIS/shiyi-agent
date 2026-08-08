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

    lint {
        // 自用/开源分发，不发布 Google Play：忽略 Play 的 targetSdk 强制要求
        //（targetSdk=27 是内嵌 Termux 可执行所必需的 SELinux 兼容域技巧）。
        disable += "ExpiredTargetSdkVersion"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications 10+ 要求启用 core library desugaring
        //（即使不用 scheduled notifications 也需要）。
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.shiyi.agent"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        // targetSdk 降到 27：<28 的 app 使用 untrusted_app_27 兼容域，
        // 该域保留对 app_data_file 的 execute_no_trans（可直接 exec 内嵌 Termux ELF）。
        // Android 15/16 的标准策略对 targetSdk<35 也有同样豁免（主测试机可用）。
        // 坚果等国产 ROM 的 untrusted_app 域无此权限，必须走旧域才能跑终端。
        targetSdk = 27
        versionCode = 2
        versionName = "1.0.1"
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

dependencies {
    // flutter_local_notifications 10+ 的 core library desugaring 支持库。
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}

