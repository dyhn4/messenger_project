import 'dart:async';

import 'package:flutter/material.dart';

import '../models/login_security.dart';
import '../services/api_client.dart';
import '../services/passkey_flow.dart';
import 'sso_dialogs.dart' show openSsoUrl;
import '../l10n/tr.dart';

/// 보안 키·패스키(WebAuthn) 대화상자 — 브라우저를 열어 두고 결과를 기다린다(passkey_flow.dart). 회사 계정 로그인 대화상자
/// (sso_dialogs.dart)와 같은 모양이다: 기다리는 동안 돌아가는 표시와 취소, 실패하면 그 까닭과 "다시 시도".
///  - 비밀번호 없이 로그인([showPasskeyLoginDialog]) — 로그인 화면의 "보안 키·패스키로 로그인".
///  - 로그인 둘째 단계([showPasskeySecondFactorDialog]) — 비밀번호를 통과하고 받은 확인 표로 보안 키를 확인한다.
///  - 로그인 중 등록([showPasskeySetupDialog]) — 관리자가 2단계 인증을 꼭 쓰게 정했는데 아직 아무것도 없는 사람이 그 자리에서
///    보안 키를 등록하고 바로 들어온다.
/// 셋 다 끝나면 토큰([AuthResult]) — 취소·실패면 null.

/// 보안 키 흐름을 만든다 — 시험에서 바꿔 끼운다(브라우저 열기·결과를 묻는 간격). 앱에서는 늘 2초마다 묻는 기본 흐름.
@visibleForTesting
PasskeyFlow Function(ApiClient api) passkeyFlowFactory = _defaultPasskeyFlow;

PasskeyFlow _defaultPasskeyFlow(ApiClient api) =>
    PasskeyFlow(api: api, openUrl: openSsoUrl);

/// 대화상자가 할 일 — 비밀번호 없이 로그인·둘째 단계·로그인 중 등록.
enum _PasskeyStep { login, secondFactor, setup }

/// 보안 키·패스키로 바로(비밀번호 없이) 로그인 → 토큰(취소·실패면 null).
Future<AuthResult?> showPasskeyLoginDialog(
  BuildContext context, {
  required ApiClient api,
}) => _show(context, api: api, step: _PasskeyStep.login);

/// 로그인 둘째 단계 — 확인 표 [ticket]으로 보안 키를 확인 → 토큰(취소·실패면 null).
Future<AuthResult?> showPasskeySecondFactorDialog(
  BuildContext context, {
  required ApiClient api,
  required String ticket,
}) => _show(context, api: api, step: _PasskeyStep.secondFactor, ticket: ticket);

/// 로그인 중 보안 키 등록(관리자가 2단계 인증을 꼭 쓰게 정한 사람 — 설정 확인 표 [ticket]) → 토큰(취소·실패면 null).
Future<AuthResult?> showPasskeySetupDialog(
  BuildContext context, {
  required ApiClient api,
  required String ticket,
}) => _show(context, api: api, step: _PasskeyStep.setup, ticket: ticket);

Future<AuthResult?> _show(
  BuildContext context, {
  required ApiClient api,
  required _PasskeyStep step,
  String? ticket,
}) => showDialog<AuthResult>(
  context: context,
  // 브라우저에서 키를 쓰는 동안 바깥을 눌러 닫히면 결과를 놓친다 — 닫기는 취소 단추로만.
  barrierDismissible: false,
  builder: (_) =>
      _PasskeyDialog(step: step, ticket: ticket, flow: passkeyFlowFactory(api)),
);

class _PasskeyDialog extends StatefulWidget {
  final _PasskeyStep step;
  final String? ticket;
  final PasskeyFlow flow;
  const _PasskeyDialog({required this.step, this.ticket, required this.flow});

  @override
  State<_PasskeyDialog> createState() => _PasskeyDialogState();
}

class _PasskeyDialogState extends State<_PasskeyDialog> {
  /// 실패했을 때의 까닭 — null이면 아직 브라우저에서 기다리는 중.
  String? _failure;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    // 창이 닫히면(취소·로그인 화면을 떠남) 더 묻지 않는다.
    widget.flow.cancel();
    super.dispose();
  }

  Future<PasskeyPollResult> _start() => switch (widget.step) {
    _PasskeyStep.login => widget.flow.login(),
    _PasskeyStep.secondFactor => widget.flow.secondFactor(widget.ticket!),
    _PasskeyStep.setup => widget.flow.register(ticket: widget.ticket),
  };

  Future<void> _run() async {
    // 다시 시도면 실패 글을 걷고 다시 기다린다(처음에는 이미 비어 있다 — initState 안에서는 setState를 부르지 않는다).
    if (_failure != null) setState(() => _failure = null);
    PasskeyPollResult result;
    try {
      result = await _start();
    } catch (e) {
      // 시작부터 막혔다(서버가 거절 — 이 서버에서 못 쓰거나 확인 표가 지났다 등). ApiException은 이미 화면 언어로 옮겨져 있다.
      result = PasskeyFailed(e.toString());
    }
    if (!mounted || widget.flow.cancelled) return;
    switch (result) {
      case PasskeyDone(
        :final accessToken,
        :final refreshToken,
        :final userId,
        :final username,
      ):
        Navigator.of(context).pop(
          AuthResult(
            accessToken: accessToken,
            refreshToken: refreshToken,
            userId: userId,
            username: username,
          ),
        );
      case PasskeyFailed(:final message):
        setState(() => _failure = message);
      default:
        // 로그인 중에는 오지 않는 답(내 프로필 등록 완료·아직 기다림) — 토큰이 없으니 다시 시도하게 한다.
        setState(() => _failure = tr('보안 키를 확인하지 못했습니다.'));
    }
  }

  String get _title => switch (widget.step) {
    _PasskeyStep.login => tr('보안 키·패스키로 로그인'),
    _PasskeyStep.secondFactor => tr('보안 키로 확인'),
    _PasskeyStep.setup => tr('보안 키·패스키 등록'),
  };

  String get _waitingText => widget.step == _PasskeyStep.setup
      ? tr('브라우저에서 이 계정에 쓸 보안 키·패스키를 등록하세요. 끝나면 여기서 저절로 이어집니다.')
      : tr('브라우저에서 보안 키·패스키로 확인하세요. 끝나면 여기서 저절로 이어집니다.');

  Widget _body() {
    final failure = _failure;
    if (failure != null) {
      return Text(failure, key: const ValueKey('passkey-failed'));
    }
    return Column(
      key: const ValueKey('passkey-waiting'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(
          _waitingText,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final failed = _failure != null;
    return AlertDialog(
      title: Text(_title),
      content: SizedBox(width: 400, child: _body()),
      actions: [
        TextButton(
          key: const ValueKey('passkey-cancel'),
          onPressed: () {
            widget.flow.cancel();
            Navigator.of(context).pop();
          },
          child: Text(failed ? tr('닫기') : tr('취소')),
        ),
        if (failed)
          FilledButton(
            key: const ValueKey('passkey-retry'),
            onPressed: () => unawaited(_run()),
            child: Text(tr('다시 시도')),
          ),
      ],
    );
  }
}
