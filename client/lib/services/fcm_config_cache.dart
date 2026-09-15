import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 안드로이드에서만 쓰는 FCM(Firebase) 초기화 값의 로컬 캐시.
///
/// google-services.json을 앱 빌드에 박아넣는 예전 방식 대신, 고객사가 관리자 콘솔에서 자기
/// Firebase 프로젝트 값을 직접 입력하고(server/src/admin.js의 /admin/fcm-settings), 앱은
/// 그 값을 서버에서 받아와(GET /firebase-client-config) 여기 캐싱해둔다 — 그래야 APK 하나로
/// 모든 고객사가 쓸 수 있다.
///
/// 캐싱이 꼭 필요한 이유: 앱이 완전히 꺼진 뒤 FCM data-only 메시지를 받으면 OS가 새 격리
/// (isolate)에서 main()을 처음부터 다시 실행하는데(main.dart의
/// _firebaseMessagingBackgroundHandler), 이때는 네트워크 요청 없이 로컬 값만으로 즉시
/// Firebase.initializeApp()을 부를 수 있어야 한다.
class FcmConfigCache {
  // main.dart의 백그라운드 isolate(_firebaseMessagingBackgroundHandler)는 이 앱과 다른
  // SharedPreferences API(SharedPreferencesAsync + "flutter." 프리픽스)로 같은 키를 읽어야
  // 해서, 키 이름을 공개해 양쪽이 같은 문자열을 쓰게 한다.
  static const kApiKey = 'fcm_api_key';
  static const kAppId = 'fcm_app_id';
  static const kProjectId = 'fcm_project_id';
  static const kSenderId = 'fcm_messaging_sender_id';

  /// 네 값으로 FirebaseOptions를 만든다. 하나라도 없으면(아직 서버에서 못 받아왔거나 관리자가
  /// 설정 전) null — 호출부는 이 경우 Firebase 초기화 자체를 건너뛴다.
  static FirebaseOptions? fromValues({
    required String? apiKey,
    required String? appId,
    required String? projectId,
    required String? senderId,
  }) {
    if (apiKey == null ||
        appId == null ||
        projectId == null ||
        senderId == null) {
      return null;
    }
    return FirebaseOptions(
      apiKey: apiKey,
      appId: appId,
      messagingSenderId: senderId,
      projectId: projectId,
    );
  }

  /// 일반 앱 실행 경로(main(), Session)에서 쓰는 legacy SharedPreferences로 캐싱된 값을 읽는다.
  static FirebaseOptions? read(SharedPreferences prefs) => fromValues(
    apiKey: prefs.getString(kApiKey),
    appId: prefs.getString(kAppId),
    projectId: prefs.getString(kProjectId),
    senderId: prefs.getString(kSenderId),
  );

  /// 서버에서 받은 값을 저장한다. 이전 캐시와 하나라도 다르면 true를 돌려준다 — 호출부가
  /// "이번에 새로 초기화해야 하는지"를 판단하는 데 쓴다.
  static Future<bool> save(
    SharedPreferences prefs, {
    required String apiKey,
    required String appId,
    required String projectId,
    required String senderId,
  }) async {
    final changed =
        prefs.getString(kApiKey) != apiKey ||
        prefs.getString(kAppId) != appId ||
        prefs.getString(kProjectId) != projectId ||
        prefs.getString(kSenderId) != senderId;
    await prefs.setString(kApiKey, apiKey);
    await prefs.setString(kAppId, appId);
    await prefs.setString(kProjectId, projectId);
    await prefs.setString(kSenderId, senderId);
    return changed;
  }
}
