import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // google-services.json으로 빌드에 FCM 설정을 박아넣는 플러그인은 안 쓴다 — 고객사마다
    // 앱을 따로 빌드해야 하는 문제가 생기기 때문이다. 대신 Firebase는 런타임에
    // FirebaseOptions로 직접 초기화한다(main.dart, session.dart, fcm_config_cache.dart 참고).
}

// 릴리즈 서명 정보(../key.properties, git에 안 올라감 — README/키스토어 생성 절차 참고).
// 파일이 없으면(예: CI에서 릴리즈 빌드를 안 할 때) 그냥 비워두고 debug 서명으로 폴백한다.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.teamtalk.messenger"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.teamtalk.messenger"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String?
                keyPassword = keystoreProperties["keyPassword"] as String?
                storeFile = keystoreProperties["storeFile"]?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String?
            }
        }
    }

    buildTypes {
        release {
            // key.properties가 있으면 그걸로 서명(배포용 실제 키), 없으면 디버그 키로 폴백
            // (`flutter run --release`로 로컬 테스트만 할 때는 keystore가 없어도 되게).
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
        debug {
            // release와 동일한 키로 서명한다 — 안 그러면 실기기에 이미 release 키로 설치된
            // 앱(서버 업데이트로 받았거나 배포판을 설치한 경우) 위에 debug 빌드를 덮어씌울 때마다
            // "signatures do not match"로 설치가 거부되고, 지우고 새로 깔면 로그인 세션이
            // 날아간다. key.properties가 없는 환경(이 저장소를 처음 받은 다른 PC 등)에서는
            // 표준 디버그 키로 폴백해서 빌드가 그냥 되게 한다.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
