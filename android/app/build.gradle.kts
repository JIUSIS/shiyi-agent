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
        // 自用/开源分发，不发布 Google Play：忽略 Play 的 targetSdk 强制要求。
        //（旧版曾降到 27 走 untrusted_app_27 兼容域；2026-08-16 起已切
        // proot + Alpine 架构 + KernelSU sepolicy 补丁，不再需要旧域技巧。）
        disable += "ExpiredTargetSdkVersion"
    }

    packaging {
        // proot 的 loader 必须解压到 nativeLibraryDir（apk_data_file 域，
        // 无 root 设备才能 execve）。extractNativeLibs=false 时该目录是空的，
        // PROOT_LOADER 指向不存在的文件，proot 直接起不来。
        jniLibs.useLegacyPackaging = true
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
        // targetSdk = 36（Android 16 最新）。旧版曾降到 27 走 untrusted_app_27
        // 兼容域以保留 app_data_file 的 execute_no_trans（直接 exec 内嵌
        // Termux ELF）；2026-08-16 起内嵌终端已切 proot + Alpine 架构，
        // SELinux 差异（apk link 硬链接被 neverallow 拒绝）由 KernelSU
        // sepolicy 补丁解决（见 TermuxRuntime._ensureApkLinkPolicy），
        // 无需再牺牲 targetSdk（新装 app 不再按旧版安卓设计渲染）。
        targetSdk = 36
        versionCode = 19
        versionName = "2.5.5"
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
        debug {
            // debug 变体也用正式签名（keystore.jks）：
            // 1) 覆盖安装到装有正式版的真机不会因签名不一致失败/清数据
            //    （与 AGENTS.md 的部署纪律一致：adb install -r 且签名一致）；
            // 2) debug 包仍可 run-as 备份/验证数据（release 包不可 run-as）。
            signingConfig = signingConfigs.getByName("release")
        }
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

