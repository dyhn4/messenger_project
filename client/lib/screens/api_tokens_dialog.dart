import 'package:flutter/material.dart';

import '../models/integration.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/app_toast.dart';
import '../widgets/integration_widgets.dart';
import '../l10n/tr.dart';

/// "API 토큰" — 내 이름으로 공개 API(/api/v1 — server/src/publicApi.js)를 부르는 개인 토큰을 만들고 지운다. 스크립트·자동화가
/// 대화방 목록·메시지를 읽거나(읽기) 내 이름으로 메시지를 보낼 때(쓰기) 쓴다. 토큰은 만들 때 한 번만 보인다. 정회원 이상.
Future<void> showApiTokensDialog(BuildContext context, Session session) =>
    showDialog<void>(
      context: context,
      builder: (_) => ApiTokensDialog(session: session),
    );

class ApiTokensDialog extends StatefulWidget {
  final Session session;
  const ApiTokensDialog({super.key, required this.session});

  @override
  State<ApiTokensDialog> createState() => _ApiTokensDialogState();
}

class _ApiTokensDialogState extends State<ApiTokensDialog> {
  List<ApiToken>? _tokens;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final tokens = await widget.session.api!.fetchApiTokens();
      if (mounted) setState(() => _tokens = tokens);
    } catch (e) {
      if (mounted) {
        setState(() => _error = tr('API 토큰 목록을 불러오지 못했습니다: {e}', {'e': e}));
      }
    }
  }

  Future<void> _create() async {
    final input = await showDialog<({String name, bool write, int? days})>(
      context: context,
      builder: (_) => const _CreateApiTokenDialog(),
    );
    if (input == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final (_, token) = await widget.session.api!.createApiToken(
        name: input.name,
        write: input.write,
        expiresInDays: input.days,
      );
      await _load();
      if (!mounted) return;
      final base = (widget.session.serverUrl ?? tr('https://서버주소')).replaceAll(
        RegExp(r'/+$'),
        '',
      );
      await showSecretRevealDialog(
        context,
        title: tr('API 토큰을 만들었습니다'),
        intro: tr('스크립트에서 요청 헤더에 Authorization: Bearer <토큰>으로 넣으세요.'),
        secret: token,
        children: [
          const SizedBox(height: 14),
          Text(tr('예시'), style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          CopyableSecretField(
            value:
                "curl -k -H 'Authorization: Bearer $token' $base/api/v1/teams",
            copiedText: tr('예시 명령을 복사했습니다.'),
          ),
          const SizedBox(height: 6),
          Text(
            tr(
              'GET /api/v1/me · /teams · /rooms?teamId= · /rooms/<방>/messages, 쓰기 권한이면 POST /rooms/<방>/messages {"text": "…"}. 비밀 대화는 API로 열 수 없습니다.',
            ),
            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
          ),
        ],
      );
    } catch (e) {
      if (mounted) {
        showAppToast(context, tr('API 토큰을 만들지 못했습니다: {e}', {'e': e}));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke(ApiToken t) async {
    final ok = await confirmIntegrationDelete(
      context,
      title: tr('API 토큰 지우기'),
      body: tr('"{t.name}" 토큰을 지울까요? 이 토큰을 쓰는 스크립트는 바로 멈춥니다.', {
        't.name': t.name,
      }),
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.session.api!.revokeApiToken(t.id);
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('지우지 못했습니다: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _subtitle(ApiToken t, DateTime now) {
    final parts = <String>[
      '${t.tokenPrefix}…',
      t.canWrite ? tr('읽기·쓰기') : tr('읽기'),
      if (t.expiresAt != null)
        t.expiredAt(now)
            ? tr('만료됨')
            : tr('{p0}까지', {'p0': formatPostDateTime(t.expiresAt!)}),
      t.lastUsedAt == null
          ? tr('아직 쓰지 않음')
          : tr('마지막 사용 {p0}', {'p0': formatPostDateTime(t.lastUsedAt!)}),
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final tokens = _tokens;
    final hint = Theme.of(context).hintColor;
    final now = DateTime.now();
    return AlertDialog(
      title: Text(tr('API 토큰')),
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
            : tokens == null
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
                        '스크립트·자동화가 내 이름으로 대화방을 읽거나 메시지를 보낼 때 씁니다. 토큰은 비밀번호처럼 다루세요.',
                      ),
                      style: TextStyle(fontSize: 12, color: hint),
                    ),
                  ),
                  if (tokens.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: Text(
                          tr('아직 만든 토큰이 없습니다.'),
                          style: TextStyle(color: hint),
                        ),
                      ),
                    ),
                  for (final t in tokens)
                    ListTile(
                      key: ValueKey('api-token-${t.id}'),
                      leading: Icon(
                        Icons.key_outlined,
                        color: t.expiredAt(now) ? hint : null,
                      ),
                      title: Text(
                        t.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        _subtitle(t, now),
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: IconButton(
                        key: ValueKey('api-token-delete-${t.id}'),
                        tooltip: tr('지우기'),
                        icon: const Icon(Icons.delete_outline),
                        onPressed: _busy ? null : () => _revoke(t),
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
          key: const ValueKey('api-token-create'),
          onPressed: _busy || tokens == null ? null : _create,
          icon: const Icon(Icons.add, size: 18),
          label: Text(tr('토큰 만들기')),
        ),
      ],
    );
  }
}

/// 토큰 만들기 — 이름, 권한(읽기 / 읽기·쓰기), 만료(30일·90일·1년·없음).
class _CreateApiTokenDialog extends StatefulWidget {
  const _CreateApiTokenDialog();

  @override
  State<_CreateApiTokenDialog> createState() => _CreateApiTokenDialogState();
}

class _CreateApiTokenDialogState extends State<_CreateApiTokenDialog> {
  final _name = TextEditingController();
  bool _write = false;
  int? _days = 90;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop((name: name, write: _write, days: _days));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('API 토큰 만들기')),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('api-token-name'),
              controller: _name,
              autofocus: true,
              maxLength: 40,
              decoration: InputDecoration(
                labelText: tr('이름'),
                hintText: tr('예: 배포 스크립트'),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 4),
            Text(tr('권한')),
            RadioGroup<bool>(
              groupValue: _write,
              onChanged: (v) => setState(() => _write = v ?? false),
              child: Column(
                children: [
                  RadioListTile<bool>(
                    key: ValueKey('api-token-read'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: false,
                    title: Text(tr('읽기 — 팀·대화방·메시지 보기')),
                  ),
                  RadioListTile<bool>(
                    key: ValueKey('api-token-write'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: true,
                    title: Text(tr('읽기·쓰기 — 내 이름으로 메시지 보내기까지')),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            DropdownButtonFormField<int?>(
              key: const ValueKey('api-token-expiry'),
              initialValue: _days,
              decoration: InputDecoration(labelText: tr('만료')),
              items: [
                DropdownMenuItem(value: 30, child: Text(tr('30일'))),
                DropdownMenuItem(value: 90, child: Text(tr('90일'))),
                DropdownMenuItem(value: 365, child: Text(tr('1년'))),
                DropdownMenuItem(value: null, child: Text(tr('만료 없음'))),
              ],
              onChanged: (v) => setState(() => _days = v),
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
          key: const ValueKey('api-token-confirm'),
          onPressed: _submit,
          child: Text(tr('만들기')),
        ),
      ],
    );
  }
}
