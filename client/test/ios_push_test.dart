import 'package:client/services/fcm_config_cache.dart';
import 'package:client/services/google_service_info.dart';
import 'package:client/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 아이폰 앱 푸시(APNs) — 관리자 콘솔이 읽는 GoogleService-Info.plist, 기기마다 고르는 Firebase 값, OS가 그린 푸시를 눌렀을 때 열 곳,
/// 뒤로 간 아이폰에서 앱이 직접 그리는 알림 끄기.

const _plist = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>API_KEY</key>
	<string>AIzaIosKey</string>
	<key>GCM_SENDER_ID</key>
	<string>123456789012</string>
	<key>PLIST_VERSION</key>
	<string>1</string>
	<key>BUNDLE_ID</key>
	<string>com.teamtalk.messenger</string>
	<key>PROJECT_ID</key>
	<string>tangotalk-demo</string>
	<key>IS_GCM_ENABLED</key>
	<true></true>
	<key>GOOGLE_APP_ID</key>
	<string>1:123456789012:ios:abcdef</string>
</dict>
</plist>
''';

void main() {
  group('GoogleService-Info.plist', () {
    test('FCM에 쓰는 값과 번들 ID를 읽는다', () {
      final info = parseGoogleServiceInfoPlist(_plist)!;
      expect(info.apiKey, 'AIzaIosKey');
      expect(info.appId, '1:123456789012:ios:abcdef');
      expect(info.projectId, 'tangotalk-demo');
      expect(info.senderId, '123456789012');
      expect(info.bundleId, iosBundleId);
    });

    test('필요한 값이 하나라도 없으면 null — 다른 plist·google-services.json', () {
      expect(
        parseGoogleServiceInfoPlist(_plist.replaceAll('GOOGLE_APP_ID', 'X')),
        isNull,
      );
      expect(parseGoogleServiceInfoPlist('{"project_info": {}}'), isNull);
      // 값이 빈 칸이어도 없는 것으로 본다.
      expect(
        parseGoogleServiceInfoPlist(
          _plist.replaceAll(
            '<string>AIzaIosKey</string>',
            '<string> </string>',
          ),
        ),
        isNull,
      );
    });
  });

  group('FcmConfigCache.fromServerConfig', () {
    const config = {
      'apiKey': 'android-key',
      'appId': '1:1:android:a',
      'projectId': 'p',
      'messagingSenderId': '1',
      'iosApiKey': 'ios-key',
      'iosAppId': '1:1:ios:b',
    };

    test('아이폰은 iOS 앱 값, 안드로이드는 안드로이드 값 — 프로젝트·발신자는 같다', () {
      final ios = FcmConfigCache.fromServerConfig(config, ios: true)!;
      expect(ios.apiKey, 'ios-key');
      expect(ios.appId, '1:1:ios:b');
      expect(ios.projectId, 'p');
      expect(ios.messagingSenderId, '1');
      final android = FcmConfigCache.fromServerConfig(config, ios: false)!;
      expect(android.apiKey, 'android-key');
      expect(android.appId, '1:1:android:a');
    });

    test('아이폰 값이 없는 서버(예전 서버·아직 안 넣음)면 아이폰은 FCM을 켜지 않는다', () {
      final old = {...config}
        ..remove('iosApiKey')
        ..remove('iosAppId');
      expect(FcmConfigCache.fromServerConfig(old, ios: true), isNull);
      expect(FcmConfigCache.fromServerConfig(old, ios: false), isNotNull);
      expect(FcmConfigCache.fromServerConfig(null, ios: true), isNull);
    });
  });

  group('NotificationService.fcmTapPayload', () {
    test('채팅·멘션·비밀 대화 요청은 그 방', () {
      for (final kind in [
        'message',
        'comment',
        'announcement',
        'mention',
        'secretInvite',
      ]) {
        expect(
          NotificationService.fcmTapPayload({'kind': kind, 'roomId': 'r1'}),
          'r1',
        );
      }
    });

    test('통화·프로젝트·결재·메일은 앱이 그린 알림과 같은 payload', () {
      expect(
        NotificationService.fcmTapPayload({'kind': 'call', 'roomId': 'r1'}),
        '${NotificationService.callPayloadPrefix}r1',
      );
      expect(
        NotificationService.fcmTapPayload({
          'kind': 'project',
          'projectId': 'p1',
          'taskId': 't1',
        }),
        '${NotificationService.projectPayloadPrefix}p1',
      );
      expect(
        NotificationService.fcmTapPayload({
          'kind': 'groupware',
          'documentId': 'd1',
          'teamId': '',
        }),
        NotificationService.approvalPayload('d1', ''),
      );
      expect(
        NotificationService.fcmTapPayload({'kind': 'mail'}),
        NotificationService.mailPayload,
      );
    });

    test('열 곳을 모르면 null', () {
      expect(NotificationService.fcmTapPayload({}), isNull);
      expect(NotificationService.fcmTapPayload({'kind': 'call'}), isNull);
      expect(NotificationService.fcmTapPayload({'kind': 'project'}), isNull);
      expect(
        NotificationService.fcmTapPayload({'kind': 'message', 'roomId': ''}),
        isNull,
      );
    });
  });

  test('아이폰이 뒤에 있어 서버 푸시로 받는 동안은 앱이 알림을 그리지 않는다', () async {
    final notifications = NotificationService()..deferToRemotePush = true;
    // 플러그인을 초기화하지 않았다 — 그리려 했다면 여기서 던진다.
    await notifications.showMessage(title: '김철수', body: '안녕', roomId: 'r1');
    await notifications.showIncomingCall(roomId: 'r1', callerName: '김철수');
    await notifications.showProjectNotification(
      title: '업무',
      body: '배정',
      projectId: 'p1',
    );
    await notifications.showApprovalNotification(
      title: '결재',
      body: '요청',
      documentId: 'd1',
    );
    await notifications.showMailNotification(title: '메일', body: '새 메일');
  });
}
