import 'dart:async';

import '../models/login_security.dart';
import 'api_client.dart';
import 'sso_flow.dart' show pkceChallenge, randomVerifier;
import '../l10n/tr.dart';

/// 보안 키·패스키(WebAuthn) 한 번의 흐름 — 서버에 시작을 청해 받은 주소(웹 앱 주소의 작은 페이지)를 브라우저로 열고, 브라우저에서
/// 키를 쓸 때까지 2초마다 결과를 묻는다(server/src/webauthn.js). 회사 계정 로그인([SsoFlow])과 같은 길이라 PC·안드로이드·아이폰·웹이
/// 모두 같게 동작하고, 앱마다 따로 WebAuthn을 붙이지 않아도 된다(키는 그 웹 주소의 도메인에 묶인다).
///
/// 시작할 때 만든 무작위 검증값의 해시만 서버에 보내고 결과를 물을 때 원문을 같이 보낸다 — 페이지 주소를 엿본 사람은 결과(토큰)를
/// 가져갈 수 없다.
class PasskeyFlow {
  PasskeyFlow({
    required this.api,
    required this.openUrl,
    this.pollInterval = const Duration(seconds: 2),
    this.timeout = const Duration(minutes: 5),
    String Function()? newVerifier,
  }) : _newVerifier = newVerifier ?? randomVerifier;

  final ApiClient api;

  /// 페이지 주소를 브라우저로 연다 — 못 열었으면 false.
  final Future<bool> Function(Uri url) openUrl;
  final Duration pollInterval;
  final Duration timeout;
  final String Function() _newVerifier;
  bool _cancelled = false;

  /// 기다리기를 멈춘다(취소 단추).
  void cancel() => _cancelled = true;

  bool get cancelled => _cancelled;

  /// 비밀번호 없이 로그인 → [PasskeyDone] | [PasskeyFailed].
  Future<PasskeyPollResult> login() =>
      _run((challenge) => api.passkeyLoginStart(challenge));

  /// 로그인 둘째 단계(비밀번호를 통과하고 받은 확인 표 [ticket]) → [PasskeyDone] | [PasskeyFailed].
  Future<PasskeyPollResult> secondFactor(String ticket) =>
      _run((challenge) => api.passkeySecondStart(ticket, challenge));

  /// 등록 — 내 프로필이면 [PasskeyRegistered], 로그인 중(설정 확인 표 [ticket])이면 토큰까지 [PasskeyDone].
  Future<PasskeyPollResult> register({String? name, String? ticket}) => _run(
    (challenge) =>
        api.passkeyRegisterStart(challenge, name: name, ticket: ticket),
  );

  Future<PasskeyPollResult> _run(
    Future<({String state, String url})> Function(String challenge) start,
  ) async {
    _cancelled = false;
    final verifier = _newVerifier();
    final started = await start(await pkceChallenge(verifier));
    if (!await openUrl(Uri.parse(started.url))) {
      return PasskeyFailed(tr('브라우저를 열지 못했습니다.'));
    }
    final deadline = DateTime.now().add(timeout);
    while (!_cancelled) {
      if (DateTime.now().isAfter(deadline)) {
        return PasskeyFailed(tr('보안 키 확인 시간이 지났습니다. 다시 해 보세요.'));
      }
      await Future<void>.delayed(pollInterval);
      if (_cancelled) break;
      final PasskeyPollResult result;
      try {
        result = await api.passkeyPoll(started.state, verifier);
      } catch (_) {
        // 잠깐 연결이 끊겼으면 다음 차례에 다시 묻는다.
        continue;
      }
      if (result is! PasskeyPending) return result;
    }
    return PasskeyFailed(tr('보안 키 확인을 취소했습니다.'));
  }
}
