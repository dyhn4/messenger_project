import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/integration.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/app_toast.dart';
import '../widgets/avatar_utils.dart' show AutomationAvatar;
import '../l10n/tr.dart';

/// "연결된 앱" — 내 계정으로 쓰도록 승인한 OAuth 앱(server/src/oauth.js)을 보고 연결을 끊는다. 앱이 브라우저로 서버의 승인 페이지를
/// 열면 그 페이지에 짧은 코드(ABCD-2345)가 보이고, 여기서 "코드로 승인" → 코드 넣기 → 앱·권한 확인 → 승인하면 브라우저가 앱으로
/// 돌아간다. 앱 토큰은 그 앱의 팀 안에서만 통하고, 연결을 끊으면 바로 막힌다. 정회원 이상(게스트는 서버가 막는다).
Future<void> showConnectedAppsDialog(BuildContext context, Session session) =>
    showDialog<void>(
      context: context,
      builder: (_) => ConnectedAppsDialog(session: session),
    );

/// 권한 한 개를 사람이 읽는 말로 — 모르는 권한(새 서버)은 이름 그대로.
String _scopeText(String scope) => switch (scope) {
  'read' => tr('읽기 — 내 팀·대화방·메시지·할 일·일정 보기'),
  'write' => tr('쓰기 — 내 이름으로 메시지·댓글·할 일·일정 만들기·고치기'),
  _ => scope,
};

class ConnectedAppsDialog extends StatefulWidget {
  final Session session;
  const ConnectedAppsDialog({super.key, required this.session});

  @override
  State<ConnectedAppsDialog> createState() => _ConnectedAppsDialogState();
}

class _ConnectedAppsDialogState extends State<ConnectedAppsDialog> {
  List<ConnectedApp>? _apps;
  String? _error;
  bool _busy = false;

  /// 방금 승인했다 — 연결(토큰 발급)은 브라우저가 앱으로 돌아가 앱이 코드를 바꿔야 생기므로 목록에 바로 안 보일 수 있다. 그 안내를 띄운다.
  bool _approvedPending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final apps = await widget.session.api!.fetchConnectedApps();
      if (mounted) setState(() => _apps = apps);
    } catch (e) {
      if (mounted) {
        setState(() => _error = tr('연결된 앱 목록을 불러오지 못했습니다: {e}', {'e': e}));
      }
    }
  }

  Future<void> _disconnect(ConnectedApp a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('연결 끊기')),
        content: Text(
          tr('{app} 연결을 끊을까요? 이 앱은 더 이상 내 이름으로 읽거나 쓸 수 없습니다', {
            'app': a.app.name,
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('취소')),
          ),
          FilledButton(
            key: const ValueKey('connected-app-remove-confirm'),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('연결 끊기')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.session.api!.disconnectApp(a.id);
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('연결을 끊지 못했습니다: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 코드 넣기 → 서버에서 요청 찾기(틀린·만료된 코드, 그 팀 멤버가 아님, 게스트면 서버 문구) → 앱·권한 확인 창 → 승인·거절 보내기.
  Future<void> _approveWithCode() async {
    final code = await showDialog<String>(
      context: context,
      builder: (_) => const _OAuthCodeDialog(),
    );
    if (code == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final OAuthRequestInfo info;
      try {
        info = await widget.session.api!.lookupOAuthRequest(code);
      } catch (e) {
        if (mounted) {
          showAppToast(context, tr('승인 요청을 찾지 못했습니다: {e}', {'e': e}));
        }
        return;
      }
      if (!mounted) return;
      final approve = await showDialog<bool>(
        context: context,
        builder: (_) => _OAuthConsentDialog(info: info),
      );
      // 창을 그냥 닫으면 아무것도 보내지 않는다 — 요청은 그대로 두었다가 만료된다.
      if (approve == null || !mounted) return;
      try {
        await widget.session.api!.answerOAuthRequest(
          info.id,
          code: code,
          approve: approve,
        );
      } catch (e) {
        if (mounted) showAppToast(context, tr('처리하지 못했습니다: {e}', {'e': e}));
        return;
      }
      if (!mounted) return;
      showAppToast(
        context,
        approve ? tr('승인했습니다. 브라우저로 돌아가세요.') : tr('거절했습니다.'),
      );
      if (approve) setState(() => _approvedPending = true);
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _subtitle(ConnectedApp a) {
    final parts = <String>[
      if (a.teamName != null && a.teamName!.isNotEmpty) a.teamName!,
      a.canWrite ? tr('읽기·쓰기') : tr('읽기'),
      if (a.lastUsedAt != null)
        tr('마지막 사용 {p0}', {'p0': formatPostDateTime(a.lastUsedAt!)})
      else if (a.createdAt != null)
        tr('승인 {p0}', {'p0': formatPostDateTime(a.createdAt!)}),
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final apps = _apps;
    final hint = Theme.of(context).hintColor;
    return AlertDialog(
      title: Text(tr('연결된 앱')),
      contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      content: SizedBox(
        width: 460,
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    TextButton(onPressed: _load, child: Text(tr('다시 시도'))),
                  ],
                ),
              )
            : apps == null
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      tr(
                        "내 계정으로 쓰도록 승인한 앱입니다. 브라우저에 승인 코드가 보이면 '코드로 승인'을 누르세요.",
                      ),
                      style: TextStyle(fontSize: 12, color: hint),
                    ),
                  ),
                  // 방금 승인 — 앱이 브라우저에서 연결을 마쳐야 목록에 생긴다. 다시 불러오기 단추를 같이 둔다.
                  if (_approvedPending)
                    Padding(
                      key: const ValueKey('connected-app-pending'),
                      padding: const EdgeInsets.fromLTRB(16, 0, 4, 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              tr('앱이 연결을 마치면 이 목록에 나타납니다.'),
                              style: TextStyle(fontSize: 12, color: hint),
                            ),
                          ),
                          TextButton(
                            onPressed: _busy ? null : _load,
                            child: Text(tr('새로 고침')),
                          ),
                        ],
                      ),
                    ),
                  if (apps.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: Text(
                          tr('연결된 앱이 없습니다.'),
                          style: TextStyle(color: hint),
                        ),
                      ),
                    ),
                  for (final a in apps)
                    ListTile(
                      key: ValueKey('connected-app-${a.id}'),
                      leading: AutomationAvatar(radius: 18, emoji: a.app.emoji),
                      title: Text(
                        a.app.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        _subtitle(a),
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: TextButton(
                        key: ValueKey('connected-app-remove-${a.id}'),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.redAccent,
                        ),
                        onPressed: _busy ? null : () => _disconnect(a),
                        child: Text(tr('연결 끊기')),
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('닫기')),
        ),
        FilledButton.icon(
          key: const ValueKey('connected-app-approve'),
          onPressed: _busy ? null : _approveWithCode,
          icon: const Icon(Icons.verified_user_outlined, size: 18),
          label: Text(tr('코드로 승인')),
        ),
      ],
    );
  }
}

/// 승인 코드 넣기 — 브라우저 승인 페이지의 코드(ABCD-2345). 소문자로 쳐도 대문자로 바꾸고 앞뒤 공백은 뺀다(서버도 다시 다듬는다).
class _OAuthCodeDialog extends StatefulWidget {
  const _OAuthCodeDialog();

  @override
  State<_OAuthCodeDialog> createState() => _OAuthCodeDialogState();
}

class _OAuthCodeDialogState extends State<_OAuthCodeDialog> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _code.text.trim().toUpperCase();
    if (code.isEmpty) return;
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('코드로 승인')),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('브라우저의 승인 페이지에 보이는 코드를 넣으세요.'),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).hintColor,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('oauth-code-field'),
              controller: _code,
              autofocus: true,
              maxLength: 20,
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              enableSuggestions: false,
              inputFormatters: [
                TextInputFormatter.withFunction(
                  (_, v) => v.copyWith(text: v.text.toUpperCase()),
                ),
              ],
              style: const TextStyle(fontSize: 20, letterSpacing: 2),
              decoration: InputDecoration(
                labelText: tr('승인 코드'),
                hintText: 'ABCD-2345',
                counterText: '',
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('oauth-code-confirm'),
          onPressed: _submit,
          child: Text(tr('확인')),
        ),
      ],
    );
  }
}

/// 승인 확인 — 어느 팀의 어떤 앱이 내 이름으로 무엇을 하려는지, 승인하면 어디로 돌아가는지, 언제까지인지 보여 준다. 승인 true, 거절 false.
class _OAuthConsentDialog extends StatelessWidget {
  final OAuthRequestInfo info;
  const _OAuthConsentDialog({required this.info});

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final team = info.teamName;
    final description = info.app.description;
    final expiresAt = info.expiresAt;
    // 남은 분 — 이미 지났거나 1분도 안 남았으면 1분으로 보인다(서버가 만료를 다시 확인한다).
    final minutesLeft = expiresAt
        ?.difference(DateTime.now())
        .inMinutes
        .clamp(1, 1 << 20);
    return AlertDialog(
      title: Text(tr('앱 승인')),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: AutomationAvatar(radius: 30, emoji: info.app.emoji),
              ),
              const SizedBox(height: 10),
              Center(
                child: Text(
                  info.app.name,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (team != null && team.isNotEmpty)
                Center(
                  child: Text(team, style: TextStyle(color: hint)),
                ),
              if (description != null && description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Center(child: Text(description, textAlign: TextAlign.center)),
              ],
              const SizedBox(height: 16),
              Text(
                tr('{app}이(가) 내 이름으로 다음을 하려고 합니다', {'app': info.app.name}),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              for (final s in info.scopes)
                Padding(
                  key: ValueKey('oauth-scope-$s'),
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        s == 'write'
                            ? Icons.edit_outlined
                            : Icons.visibility_outlined,
                        size: 18,
                        color: hint,
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_scopeText(s))),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              if (team != null && team.isNotEmpty)
                Text(
                  tr('이 앱은 {team} 안에서만 내 이름으로 읽거나 쓸 수 있습니다.', {'team': team}),
                  style: TextStyle(fontSize: 12, color: hint),
                ),
              if (info.redirectHost.isNotEmpty)
                Text(
                  tr('승인하면 {host}(으)로 돌아갑니다.', {'host': info.redirectHost}),
                  style: TextStyle(fontSize: 12, color: hint),
                ),
              if (minutesLeft != null)
                Text(
                  tr('{n}분 안에 승인하지 않으면 요청이 만료됩니다.', {'n': minutesLeft}),
                  style: TextStyle(fontSize: 12, color: hint),
                ),
              const SizedBox(height: 8),
              Text(
                tr('내가 직접 연 승인 페이지의 코드만 넣으세요. 남이 알려 준 코드는 승인하지 마세요.'),
                style: TextStyle(fontSize: 12, color: hint),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('oauth-deny'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(tr('거절')),
        ),
        FilledButton(
          key: const ValueKey('oauth-approve'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(tr('승인')),
        ),
      ],
    );
  }
}
