import 'package:flutter/material.dart';

import '../models/mail_settings.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/app_toast.dart';

/// 관리자 콘솔 "메일" 탭 — 서버가 메일을 보낼 SMTP 계정과 멘션 요약 메일 설정(server/src/admin.js /admin/mail).
///
/// 도메인이 없어도 네이버·Gmail 같은 메일 계정의 SMTP(앱 비밀번호)로 보낼 수 있고, 도메인이 생기면 회사 메일·발송 서비스의
/// 값으로 바꾸기만 하면 된다. 값을 넣고 저장 → 시험 메일이 성공 → "메일 기능 사용"을 켜는 순서다(서버가 그 순서를 지킨다 —
/// 연결 값을 바꾸면 다시 꺼지고 시험부터 해야 한다). 비밀번호는 서버가 다시 내려주지 않아 "설정됨"으로만 보이고, 바꿀 때만 넣는다.
class AdminMailTab extends StatefulWidget {
  final Session session;
  const AdminMailTab({super.key, required this.session});

  @override
  State<AdminMailTab> createState() => _AdminMailTabState();
}

class _AdminMailTabState extends State<AdminMailTab> {
  MailSettings? _settings;
  bool _loaded = false;
  String? _error;
  bool _saving = false;
  bool _testing = false;
  String? _testError;

  final _host = TextEditingController();
  final _port = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _fromAddress = TextEditingController();
  final _fromName = TextEditingController();
  late final _testTo = TextEditingController(text: widget.session.email ?? '');
  String _security = 'starttls';
  String? _presetNote;

  @override
  void initState() {
    super.initState();
    for (final c in [
      _host,
      _port,
      _username,
      _password,
      _fromAddress,
      _fromName,
    ]) {
      c.addListener(_refresh);
    }
    _load();
  }

  @override
  void dispose() {
    for (final c in [
      _host,
      _port,
      _username,
      _password,
      _fromAddress,
      _fromName,
      _testTo,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _refresh() => setState(() {});

  void _apply(MailSettings s) {
    _settings = s;
    _host.text = s.host;
    _port.text = s.port?.toString() ?? '';
    _security = s.security;
    _username.text = s.username;
    _password.clear();
    _fromAddress.text = s.fromAddress;
    _fromName.text = s.fromName;
  }

  Future<void> _load() async {
    try {
      final s = await widget.session.api!.fetchMailSettings();
      if (!mounted) return;
      setState(() {
        _loaded = true;
        if (s != null) _apply(s);
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loaded = true;
          _error = e.toString();
        });
      }
    }
  }

  /// 저장하지 않은 연결 값이 있는지 — 있으면 시험·켜기 전에 저장부터 하게 한다.
  bool get _dirty {
    final s = _settings;
    if (s == null) return false;
    return _host.text.trim() != s.host ||
        _port.text.trim() != (s.port?.toString() ?? '') ||
        _security != s.security ||
        _username.text.trim() != s.username ||
        _password.text.isNotEmpty ||
        _fromAddress.text.trim() != s.fromAddress ||
        _fromName.text.trim() != s.fromName;
  }

  void _usePreset(SmtpPreset preset) {
    setState(() {
      _host.text = preset.host;
      _port.text = preset.port.toString();
      _security = preset.security;
      _presetNote = preset.note;
    });
  }

  Future<void> _save() async {
    final portText = _port.text.trim();
    final port = portText.isEmpty ? null : int.tryParse(portText);
    if (portText.isNotEmpty && port == null) {
      showAppToast(context, '포트는 숫자로 넣으세요.');
      return;
    }
    setState(() => _saving = true);
    try {
      final s = await widget.session.api!.updateMailSettings(
        host: _host.text.trim(),
        port: port,
        clearPort: port == null,
        security: _security,
        username: _username.text.trim(),
        password: _password.text.isEmpty ? null : _password.text,
        fromAddress: _fromAddress.text.trim(),
        fromName: _fromName.text.trim(),
      );
      if (!mounted) return;
      setState(() => _apply(s));
      showAppToast(
        context,
        s.testedAt == null ? '저장했습니다. 시험 메일을 보내 확인하세요.' : '저장했습니다.',
      );
    } catch (e) {
      if (mounted) showAppToast(context, '실패: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _sendTest() async {
    final to = _testTo.text.trim();
    if (to.isEmpty) {
      showAppToast(context, '시험 메일을 받을 주소를 넣으세요.');
      return;
    }
    setState(() {
      _testing = true;
      _testError = null;
    });
    try {
      final s = await widget.session.api!.sendTestMail(to);
      if (!mounted) return;
      setState(() => _settings = s);
      showAppToast(context, '시험 메일을 보냈습니다. $to 메일함을 확인하세요.');
    } catch (e) {
      if (mounted) setState(() => _testError = e.toString());
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  /// 메일 기능·요약 설정처럼 바로 저장하는 값.
  Future<void> _update(
    Future<MailSettings> Function() call, {
    String? done,
  }) async {
    setState(() => _saving = true);
    try {
      final s = await call();
      if (!mounted) return;
      setState(() => _settings = s);
      // 켜고 끄면 앱 화면(가입·찾기·초대)도 바로 맞춘다.
      await widget.session.refreshMailEnabled();
      if (mounted && done != null) showAppToast(context, done);
    } catch (e) {
      if (mounted) showAppToast(context, '실패: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!_loaded) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null) return Text(_error!);
    final s = _settings;
    if (s == null) {
      return Text(
        '이 서버 버전은 메일 기능을 지원하지 않습니다. 서버를 업데이트하세요.',
        style: TextStyle(color: theme.colorScheme.error),
      );
    }
    final hint = theme.hintColor;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '메일을 켜면 가입할 때 이메일을 확인하고, 아이디·비밀번호를 이메일로 찾고(보안 질문 대신), 초대 링크를 메일로 '
            '보내고, 오래 접속하지 않은 사람에게 안 읽은 멘션을 메일로 알립니다. 도메인이 없어도 네이버·Gmail 같은 메일 '
            '계정으로 보낼 수 있고, 나중에 회사 메일이 생기면 값만 바꾸면 됩니다. 메일이 꺼져 있으면 지금처럼 동작합니다.',
            style: theme.textTheme.bodySmall?.copyWith(color: hint),
          ),
          const SizedBox(height: 12),
          _MailStatusCard(settings: s, dirty: _dirty),
          const SizedBox(height: 4),
          SwitchListTile(
            key: const ValueKey('admin-mail-enabled'),
            contentPadding: EdgeInsets.zero,
            title: const Text('메일 기능 사용'),
            subtitle: Text(
              s.testedAt == null
                  ? '아래 값을 저장하고 시험 메일이 성공해야 켤 수 있습니다.'
                  : '시험 통과: ${formatDateTime(s.testedAt!)}',
              style: TextStyle(fontSize: 12, color: hint),
            ),
            value: s.enabled,
            onChanged: _saving || (!s.enabled && (s.testedAt == null || _dirty))
                ? null
                : (v) => _update(
                    () => widget.session.api!.updateMailSettings(enabled: v),
                    done: v ? '메일 기능을 켰습니다.' : '메일 기능을 껐습니다.',
                  ),
          ),
          const Divider(height: 28),
          Text('보내는 메일 계정(SMTP)', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final preset in smtpPresets)
                ActionChip(
                  label: Text('${preset.label} 값 채우기'),
                  onPressed: () => _usePreset(preset),
                ),
            ],
          ),
          if (_presetNote != null) ...[
            const SizedBox(height: 6),
            Text(
              _presetNote!,
              style: theme.textTheme.bodySmall?.copyWith(color: hint),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _host,
            decoration: const InputDecoration(
              labelText: 'SMTP 서버 주소',
              hintText: '예: smtp.naver.com',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _security,
                  decoration: const InputDecoration(
                    labelText: '연결 보안',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'ssl', child: Text('SSL (보통 465)')),
                    DropdownMenuItem(
                      value: 'starttls',
                      child: Text('STARTTLS (보통 587)'),
                    ),
                    DropdownMenuItem(
                      value: 'none',
                      child: Text('없음 (사내 메일 서버)'),
                    ),
                  ],
                  onChanged: (v) => setState(() => _security = v ?? _security),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 120,
                child: TextField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: '포트',
                    hintText: '${s.defaultPortFor(_security)}',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _username,
            decoration: const InputDecoration(
              labelText: '계정',
              hintText: '보통 전체 메일 주소 — 예: tangotalk@naver.com',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: InputDecoration(
              labelText: s.passwordConfigured
                  ? '새 비밀번호 (바꿀 때만)'
                  : '비밀번호 (앱 비밀번호)',
              helperText: s.passwordConfigured ? '비밀번호: 설정됨' : null,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _fromAddress,
            decoration: const InputDecoration(
              labelText: '보내는 주소 (선택)',
              hintText: '비우면 계정 주소 — Gmail·네이버는 계정 주소로만 보낼 수 있습니다',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _fromName,
            decoration: const InputDecoration(
              labelText: '보내는 이름 (선택)',
              hintText: '비우면 TangoTalk',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const ValueKey('admin-mail-save'),
              onPressed: _saving || !_dirty ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('저장'),
            ),
          ),
          const Divider(height: 28),
          Text('시험 메일', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _testTo,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: '받을 주소',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 48,
                child: OutlinedButton(
                  key: const ValueKey('admin-mail-test'),
                  onPressed: _testing || _dirty || !s.complete
                      ? null
                      : _sendTest,
                  child: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('시험 메일 보내기'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _dirty
                ? '바꾼 값을 먼저 저장하세요.'
                : !s.complete
                ? '서버 주소·포트·보내는 주소(또는 메일 주소 모양의 계정)를 넣고 저장하세요.'
                : '저장된 값으로 한 통 보내 봅니다. 성공하면 메일 기능을 켤 수 있습니다.',
            style: theme.textTheme.bodySmall?.copyWith(color: hint),
          ),
          if (_testError != null) ...[
            const SizedBox(height: 6),
            Text(_testError!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const Divider(height: 28),
          ..._buildDigest(context, s),
        ],
      ),
    );
  }

  List<Widget> _buildDigest(BuildContext context, MailSettings s) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final digest = s.digest;
    return [
      Text('멘션 요약 메일', style: theme.textTheme.titleSmall),
      const SizedBox(height: 4),
      Text(
        '정한 날수 넘게 접속하지 않은 사람에게, 그 사이 쌓인 안 읽은 멘션을 매일 아침 9시에 메일로 모아 보냅니다(같은 사람에게는 '
        '그 날수에 한 번까지). 이메일을 확인했고 알림 설정에서 끄지 않은 사람만 받습니다.',
        style: theme.textTheme.bodySmall?.copyWith(color: hint),
      ),
      SwitchListTile(
        key: const ValueKey('admin-mail-digest'),
        contentPadding: EdgeInsets.zero,
        title: const Text('멘션 요약 메일 보내기'),
        value: digest.enabled,
        onChanged: _saving
            ? null
            : (v) => _update(
                () => widget.session.api!.updateMailSettings(digestEnabled: v),
              ),
      ),
      Row(
        children: [
          const Expanded(child: Text('접속하지 않은 기간')),
          DropdownButton<int>(
            value: digest.days.clamp(digest.daysMin, digest.daysMax),
            items: [
              for (final d in const [1, 2, 3, 5, 7, 14, 30])
                if (d >= digest.daysMin && d <= digest.daysMax)
                  DropdownMenuItem(value: d, child: Text('$d일 넘게')),
              if (!const [1, 2, 3, 5, 7, 14, 30].contains(digest.days))
                DropdownMenuItem(
                  value: digest.days,
                  child: Text('${digest.days}일 넘게'),
                ),
            ],
            onChanged: _saving || !digest.enabled
                ? null
                : (v) {
                    if (v == null) return;
                    _update(
                      () =>
                          widget.session.api!.updateMailSettings(digestDays: v),
                    );
                  },
          ),
        ],
      ),
      SwitchListTile(
        key: const ValueKey('admin-mail-digest-preview'),
        contentPadding: EdgeInsets.zero,
        title: const Text('메시지 미리보기 넣기'),
        subtitle: Text(
          '켜면 멘션된 메시지의 앞부분이 메일에 들어갑니다 — 메시지 내용이 메일 서비스(네이버·Gmail 등)로 나간다는 뜻이라 '
          '기본으로 꺼 둡니다. 끄면 방 이름·보낸 사람·시각만 보냅니다. 비밀 대화는 어느 쪽이든 넣지 않습니다.',
          style: TextStyle(fontSize: 12, color: hint),
        ),
        value: digest.preview,
        onChanged: _saving || !digest.enabled
            ? null
            : (v) => _update(
                () => widget.session.api!.updateMailSettings(digestPreview: v),
              ),
      ),
    ];
  }
}

/// 메일 상태 카드 — DDNS 탭의 상태 카드와 같은 모양.
class _MailStatusCard extends StatelessWidget {
  final MailSettings settings;
  final bool dirty;
  const _MailStatusCard({required this.settings, required this.dirty});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color, label, line) = mailStatusLook(
      settings,
      theme,
      dirty: dirty,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    text: '메일 기능',
                    children: [
                      TextSpan(
                        text: '  ·  $label',
                        style: TextStyle(color: color),
                      ),
                    ],
                  ),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(line, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// 상태 카드의 아이콘·색·이름·설명.
(IconData, Color, String, String) mailStatusLook(
  MailSettings s,
  ThemeData theme, {
  bool dirty = false,
}) {
  if (s.ready) {
    return (
      Icons.mark_email_read_outlined,
      Colors.green.shade700,
      '켜짐',
      '${s.effectiveFrom ?? ''}(으)로 보냅니다.',
    );
  }
  if (!s.complete || dirty) {
    return (
      Icons.mail_outline,
      theme.hintColor,
      '꺼짐',
      '보내는 메일 계정을 넣고 저장한 뒤 시험 메일을 보내 보세요.',
    );
  }
  if (s.testedAt == null) {
    return (
      Icons.outgoing_mail,
      theme.colorScheme.tertiary,
      '시험 필요',
      '저장된 값으로 시험 메일을 보내 성공하면 켤 수 있습니다.',
    );
  }
  return (
    Icons.mail_outline,
    theme.hintColor,
    '꺼짐',
    '시험을 통과했습니다. "메일 기능 사용"을 켜면 동작합니다.',
  );
}
