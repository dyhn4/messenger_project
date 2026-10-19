/// 아이폰 앱이 FCM(APNs)을 켜는 데 쓰는 번들 ID — 안드로이드 패키지명과 같다(client/ios Runner의 PRODUCT_BUNDLE_IDENTIFIER).
const iosBundleId = 'com.teamtalk.messenger';

/// Firebase 콘솔에서 아이폰 앱을 등록하면 받는 설정 파일(GoogleService-Info.plist — XML plist)에서 FCM에 쓰는 값만 읽는다.
/// 관리자 콘솔 "FCM 설정"의 [GoogleService-Info.plist 열기]가 쓴다 — 파일을 앱에 넣지 않고 값만 서버에 둔다(fcm_config_cache.dart).
/// API 키·앱 ID·프로젝트 ID·발신자 번호 중 하나라도 없으면 null. [bundleId]는 확인용(없을 수 있다).
({
  String apiKey,
  String appId,
  String projectId,
  String senderId,
  String? bundleId,
})?
parseGoogleServiceInfoPlist(String xml) {
  String? value(String key) {
    final match = RegExp(
      '<key>\\s*${RegExp.escape(key)}\\s*</key>\\s*<string>([^<]*)</string>',
    ).firstMatch(xml);
    final text = match?.group(1)?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  final apiKey = value('API_KEY');
  final appId = value('GOOGLE_APP_ID');
  final projectId = value('PROJECT_ID');
  final senderId = value('GCM_SENDER_ID');
  if (apiKey == null ||
      appId == null ||
      projectId == null ||
      senderId == null) {
    return null;
  }
  return (
    apiKey: apiKey,
    appId: appId,
    projectId: projectId,
    senderId: senderId,
    bundleId: value('BUNDLE_ID'),
  );
}
