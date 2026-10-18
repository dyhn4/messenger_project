import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../models/login_security.dart';
import 'api_client.dart';
import '../l10n/tr.dart';

/// 회사 계정 로그인(SSO — Google·Microsoft) 한 번의 흐름 — 서버에 시작을 청해 받은 주소를 브라우저로 열고, 브라우저에서 로그인이
/// 끝날 때까지 2초마다 결과를 묻는다(server/src/sso.js). PC·안드로이드·아이폰·웹이 모두 같은 길이다 — 앱으로 돌아오는 주소(딥링크)에
/// 기대지 않아서 어느 플랫폼에서도 같게 동작한다.
///
/// 시작할 때 무작위 검증값([verifier])을 만들어 그 해시만 서버에 보내고, 결과를 물을 때 원문을 같이 보낸다 — 로그인 주소를 엿본
/// 사람은 결과(토큰)를 가져갈 수 없다(PKCE와 같은 방식). 같은 이메일의 계정에 잇는 단계([sendLinkCode]·[verifyLinkCode])도 같은
/// 검증값으로 한다.
class SsoFlow {
  SsoFlow({
    required this.api,
    required this.openUrl,
    this.pollInterval = const Duration(seconds: 2),
    this.timeout = const Duration(minutes: 10),
    String Function()? newVerifier,
  }) : _newVerifier = newVerifier ?? randomVerifier;

  final ApiClient api;

  /// 로그인 주소를 브라우저로 연다 — 못 열었으면 false.
  final Future<bool> Function(Uri url) openUrl;
  final Duration pollInterval;
  final Duration timeout;
  final String Function() _newVerifier;

  String? _state;
  String? _verifier;
  bool _cancelled = false;

  /// 기다리기를 멈춘다(취소 단추) — 다음 확인 차례에 [SsoFailed]로 끝난다.
  void cancel() => _cancelled = true;

  bool get cancelled => _cancelled;

  /// 로그인(또는 [link]면 로그인한 내 계정에 연결) — 끝까지 기다려 결과를 돌려준다. 같은 이메일의 계정이 있으면
  /// [SsoLinkRequired]로 멈춘다(그다음은 [sendLinkCode]·[verifyLinkCode]).
  Future<SsoPollResult> run(String provider, {bool link = false}) async {
    _cancelled = false;
    final verifier = _newVerifier();
    final started = await api.ssoStart(
      provider,
      await pkceChallenge(verifier),
      link: link,
    );
    _state = started.state;
    _verifier = verifier;
    if (!await openUrl(Uri.parse(started.authUrl))) {
      return SsoFailed(tr('브라우저를 열지 못했습니다.'));
    }
    final deadline = DateTime.now().add(timeout);
    while (!_cancelled) {
      if (DateTime.now().isAfter(deadline)) {
        return SsoFailed(tr('회사 계정 로그인 시간이 지났습니다. 다시 해 보세요.'));
      }
      await Future<void>.delayed(pollInterval);
      if (_cancelled) break;
      final SsoPollResult result;
      try {
        result = await api.ssoPoll(started.state, verifier);
      } catch (_) {
        // 잠깐 연결이 끊겼으면 다음 차례에 다시 묻는다.
        continue;
      }
      if (result is! SsoPending) return result;
    }
    return SsoFailed(tr('회사 계정 로그인을 취소했습니다.'));
  }

  /// 같은 이메일의 계정에 잇는 확인 코드를 그 이메일로 보낸다.
  Future<EmailCodeSent> sendLinkCode() => api.ssoLinkSend(_state!, _verifier!);

  /// 확인 코드를 넣어 잇고 로그인 토큰을 받는다.
  Future<AuthResult> verifyLinkCode(String code) =>
      api.ssoLinkVerify(_state!, _verifier!, code);
}

/// PKCE 검증값 — 32바이트 무작위를 base64url(패딩 없이 43자)로.
String randomVerifier() {
  final rnd = Random.secure();
  final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// PKCE S256 — base64url(sha256(verifier)), 패딩 없이(서버 ssoRules.js pkceChallenge와 같다).
Future<String> pkceChallenge(String verifier) async {
  final hash = await Sha256().hash(utf8.encode(verifier));
  return base64Url.encode(hash.bytes).replaceAll('=', '');
}
