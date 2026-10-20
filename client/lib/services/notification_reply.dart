import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_android/shared_preferences_android.dart';

import '../l10n/tr.dart';
import 'message_outbox.dart' show newClientId;
import 'notification_service.dart';
import 'pinned_tls.dart';
import 'session.dart';

/// 알림에서 바로 답장(안드로이드 — 메시지 알림의 "답장" 칸, NotificationService.showMessage의 replyable). 칸에 쓴 글은 화면 없는 별도
/// 엔진(flutter_local_notifications가 띄우는 백그라운드 isolate — 앱이 켜져 있어도 같다)의 [onNotificationActionBackground]로 와서 서버의
/// `POST /api/push-reply`로 보낸다(server/src/pushReply.js). 로그인 토큰은 1시간이면 끝나 앱이 꺼진 뒤에는 못 쓰므로, 채팅 푸시에 실려 온
/// **답장 표**(그 기기·사람·방에만 — main.dart의 FCM 핸들러가 방마다 저장)를 먼저 쓰고, 표가 없거나(앱이 켜져 있어 소켓으로 받아 그린
/// 알림) 거절되면 저장된 AccessToken으로 한 번 더 한다. 보냈으면 서버가 그 방을 읽은 것으로 하고 여기서는 그 방 알림을 지운다. 못 보냈으면
/// 그 방 알림 자리에 이유를 띄운다(누르면 그 방이 열린다).

/// 알림 답장 칸의 action id.
const replyActionId = 'reply';

/// 방마다 마지막으로 받은 답장 표를 두는 SharedPreferences 열쇠(앞에 붙는 `flutter.`은 [legacyPrefsAsync]가 다루는 방식대로 부르는 쪽이 붙인다).
String replyTicketPrefsKey(String roomId) => 'push_reply_ticket.$roomId';

/// Session이 쓰는 레거시 SharedPreferences 파일을 백그라운드 isolate에서 매번 새로 읽는다(main.dart FCM 핸들러의 설명과 같다 — 열쇠 앞에
/// `flutter.`을 직접 붙여야 같은 값을 본다).
SharedPreferencesAsync legacyPrefsAsync() => SharedPreferencesAsync(
  options: SharedPreferencesAsyncAndroidOptions(
    backend: SharedPreferencesAndroidBackendLibrary.SharedPreferences,
    originalSharedPreferencesOptions:
        const AndroidSharedPreferencesStoreOptions(
          fileName: 'FlutterSharedPreferences',
        ),
  ),
);

/// 알림 답장 요청 하나 — 표가 있으면 표로(로그인 토큰 없이), 없으면 [token]으로 방을 밝혀 보낸다. 둘 다 없으면 null.
({Map<String, String> headers, Map<String, dynamic> body})? pushReplyRequest({
  required String roomId,
  required String text,
  required String clientId,
  String? ticket,
  String? token,
}) {
  final headers = {'Content-Type': 'application/json; charset=utf-8'};
  if (ticket != null && ticket.isNotEmpty) {
    return (
      headers: headers,
      body: {'ticket': ticket, 'text': text, 'clientId': clientId},
    );
  }
  if (token == null || token.isEmpty) return null;
  return (
    headers: {...headers, 'Authorization': 'Bearer $token'},
    body: {'roomId': roomId, 'text': text, 'clientId': clientId},
  );
}

/// 보내기 결과 — 성공이면 [error]가 null.
typedef PushReplyResult = ({int status, String? error});

/// [serverUrl]로 답장을 보낸다 — 표로 보냈는데 401이면(기한이 지났거나 비밀번호를 바꿈) 토큰이 있을 때 토큰으로 한 번 더. 같은 글이 두 번
/// 들어가지 않게 두 번 다 같은 [clientId]를 쓴다(서버가 같은 임시 id면 처음 것을 돌려준다). [post]는 시험에서 바꿔 끼운다.
Future<PushReplyResult> sendPushReply({
  required String serverUrl,
  required String roomId,
  required String text,
  String? ticket,
  String? token,
  String? clientId,
  Future<({int status, String body})> Function(
    Uri uri,
    Map<String, String> headers,
    String body,
  )?
  post,
}) async {
  final id = clientId ?? newClientId();
  final send = post ?? _httpPost;
  final uri = Uri.parse('$serverUrl/api/push-reply');
  Future<PushReplyResult> attempt(String? t, String? tok) async {
    final req = pushReplyRequest(
      roomId: roomId,
      text: text,
      clientId: id,
      ticket: t,
      token: tok,
    );
    if (req == null) {
      return (status: 401, error: tr('다시 로그인한 뒤 앱에서 보내세요.'));
    }
    try {
      final res = await send(uri, req.headers, jsonEncode(req.body));
      if (res.status >= 200 && res.status < 300) {
        return (status: res.status, error: null);
      }
      String? message;
      try {
        message = (jsonDecode(res.body) as Map)['error'] as String?;
      } catch (_) {}
      return (
        status: res.status,
        error: message ?? tr('보내지 못했습니다. 앱을 열어 다시 보내세요.'),
      );
    } catch (_) {
      return (status: 0, error: tr('서버에 연결하지 못했습니다. 앱을 열어 다시 보내세요.'));
    }
  }

  final first = await attempt(ticket, ticket == null ? token : null);
  if (first.status == 401 &&
      ticket != null &&
      token != null &&
      token.isNotEmpty) {
    return attempt(null, token);
  }
  return first;
}

Future<({int status, String body})> _httpPost(
  Uri uri,
  Map<String, String> headers,
  String body,
) async {
  // HttpOverrides.global(PinnedTls)이 이 HttpClient도 이 서버의 인증서만 믿게 한다.
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.postUrl(uri);
    headers.forEach(req.headers.set);
    req.add(utf8.encode(body));
    final res = await req.close().timeout(const Duration(seconds: 20));
    final text = await res.transform(utf8.decoder).join();
    return (status: res.statusCode, body: text);
  } finally {
    client.close(force: true);
  }
}

/// 알림의 단추·답장 칸을 눌렀을 때(화면 없는 엔진) — 답장만 다룬다. NotificationService.init이 이 함수를 백그라운드 핸들러로 건다.
@pragma('vm:entry-point')
Future<void> onNotificationActionBackground(
  NotificationResponse response,
) async {
  if (response.actionId != replyActionId) return;
  final roomId = response.payload;
  final text = response.input?.trim() ?? '';
  if (roomId == null || roomId.isEmpty || text.isEmpty) return;
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  await AppLocale.load();
  await PinnedTls.installGlobalHttpOverrides();
  final prefs = legacyPrefsAsync();
  final serverUrl =
      await prefs.getString('flutter.${Session.kActiveServerUrlPrefsKey}') ??
      await prefs.getString('flutter.server_base_url');
  final notifications = NotificationService();
  await notifications.init(onTap: (_) {}, requestPermission: false);
  if (serverUrl == null) {
    await notifications.showReplyFailed(
      roomId: roomId,
      message: tr('다시 로그인한 뒤 앱에서 보내세요.'),
    );
    return;
  }
  final result = await sendPushReply(
    serverUrl: serverUrl,
    roomId: roomId,
    text: text,
    ticket: await prefs.getString('flutter.${replyTicketPrefsKey(roomId)}'),
    token: await prefs.getString('flutter.${Session.kAuthTokenPrefsKey}'),
  );
  if (result.error == null) {
    // 서버가 그 방을 읽은 것으로 했다 — 그 방 알림(과 쌓아 둔 기록)을 지운다.
    await notifications.cancelForRoom(roomId);
  } else {
    await notifications.showReplyFailed(roomId: roomId, message: result.error!);
  }
}
