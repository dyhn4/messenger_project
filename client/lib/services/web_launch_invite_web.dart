import 'package:web/web.dart' as web;

import 'invite_share.dart' show isPlausibleInviteToken;

/// 웹 앱 주소의 `?invite=<코드>`를 꺼내고 주소창에서는 지운다(새로 고침·북마크·화면 공유로 코드가 남거나 퍼지지 않게 — 서버는
/// Referrer-Policy: no-referrer라 다른 사이트로 새지는 않는다). 코드 모양이 아니면 무시한다. 없으면 null.
String? takeLaunchInviteToken() {
  final uri = Uri.base;
  final raw = uri.queryParameters['invite'];
  if (raw == null) return null;
  final rest = Map<String, String>.of(uri.queryParameters)..remove('invite');
  final clean = uri.replace(queryParameters: rest.isEmpty ? null : rest);
  web.window.history.replaceState(
    null,
    '',
    clean.toString().replaceFirst(RegExp(r'\?$'), ''),
  );
  final token = raw.trim();
  return isPlausibleInviteToken(token) ? token : null;
}
