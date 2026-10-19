import 'dart:async';

import 'package:flutter/material.dart';

import '../models/backup_settings.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/app_toast.dart';
import '../widgets/attachment_widgets.dart' show formatFileSize;
import '../l10n/tr.dart';

/// 관리자 콘솔 "백업" 탭 — 서버 전체 백업(DB·설정·인증서, 외부 위치를 정하면 첨부파일까지)의 설정과 상태.
///
/// 백업은 서버가 매일 정한 시각에 스스로 하고(server/src/backup.js), "지금 백업"은 서버가 시작만 한 뒤 바로 답해서 이 화면이
/// 2초마다 진행 상황을 다시 받는다. 백업은 백업 암호로 암호화된다 — 암호는 서버가 다시 내려주지 않고, 백업 암호와 외부 백업
/// 위치를 바꿀 때는 운영자 계정 비밀번호를 다시 묻는다(서버가 확인한다). 복원은 서버 PC의 시작 메뉴 "복원"에서 한다.
class AdminBackupTab extends StatefulWidget {
  final Session session;
  const AdminBackupTab({super.key, required this.session});

  @override
  State<AdminBackupTab> createState() => _AdminBackupTabState();
}

class _AdminBackupTabState extends State<AdminBackupTab> {
  BackupSettings? _settings;
  bool _loaded = false;
  String? _error;
  bool _enabled = true;
  int _hour = 3;
  int _keep = 14;
  bool _saving = false;
  bool _starting = false;
  final _destination = TextEditingController();
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _destination.dispose();
    super.dispose();
  }

  /// 받은 설정을 화면에 — [fields]가 false면(진행 상황만 다시 받을 때) 관리자가 고치던 칸은 건드리지 않는다.
  void _apply(BackupSettings settings, {bool fields = true}) {
    _settings = settings;
    if (fields) {
      _enabled = settings.enabled;
      _hour = settings.hour;
      _keep = settings.keep;
      _destination.text = settings.destination ?? '';
    }
    _syncPolling(settings);
  }

  void _syncPolling(BackupSettings settings) {
    if (settings.run.busy && _poll == null) {
      _poll = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
    } else if (!settings.run.busy && _poll != null) {
      _poll!.cancel();
      _poll = null;
    }
  }

  Future<void> _load() async {
    try {
      final settings = await widget.session.api!.fetchBackupSettings();
      if (!mounted) return;
      setState(() {
        _loaded = true;
        if (settings != null) _apply(settings);
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

  Future<void> _refresh() async {
    try {
      final settings = await widget.session.api!.fetchBackupSettings();
      if (!mounted || settings == null) return;
      final wasBusy = _settings?.run.busy ?? false;
      setState(() => _apply(settings, fields: false));
      if (wasBusy && !settings.run.busy) _toastFinished(settings);
    } catch (_) {
      // 잠깐 못 받아도 다음 차례에 다시 받는다.
    }
  }

  void _toastFinished(BackupSettings settings) {
    final status = settings.status;
    final message = switch (status.result) {
      'ok' => tr('백업했습니다.'),
      'partial' => tr('서버 PC에는 백업했지만 외부 위치 복사에 실패했습니다: {p0}', {
        'p0': status.error ?? '',
      }),
      'failed' => tr('백업에 실패했습니다: {p0}', {
        'p0': status.error ?? tr('알 수 없는 이유'),
      }),
      _ => tr('백업이 끝났습니다.'),
    };
    showAppToast(context, message.trim(), duration: const Duration(seconds: 4));
  }

  Future<void> _saveSchedule() async {
    setState(() => _saving = true);
    try {
      final settings = await widget.session.api!.updateBackupSettings(
        enabled: _enabled,
        hour: _hour,
        keep: _keep,
      );
      if (!mounted) return;
      setState(() => _apply(settings));
      showAppToast(context, tr('저장했습니다.'));
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveDestination({bool clear = false}) async {
    final current = _settings?.destination ?? '';
    final next = clear ? '' : _destination.text.trim();
    if (next == current) {
      showAppToast(
        context,
        clear ? tr('외부 위치가 정해져 있지 않습니다.') : tr('바뀐 내용이 없습니다.'),
      );
      return;
    }
    final accountPassword = await _askAccountPassword(
      clear ? tr('외부 백업 위치 지우기') : tr('외부 백업 위치 저장'),
      clear
          ? tr(
              '외부 위치를 지우면 백업이 서버 PC에만 남고, 첨부파일은 백업되지 않습니다. 이미 외부 위치에 있는 백업은 지우지 않습니다.',
            )
          : tr(
              '서버가 그 위치에 실제로 쓸 수 있는지 확인한 뒤 저장합니다. NAS가 꺼져 있으면 확인에 시간이 걸릴 수 있습니다.',
            ),
    );
    if (accountPassword == null || !mounted) return;
    setState(() => _saving = true);
    try {
      final settings = await widget.session.api!.updateBackupSettings(
        destination: next,
        accountPassword: accountPassword,
      );
      if (!mounted) return;
      setState(() => _apply(settings));
      showAppToast(
        context,
        next.isEmpty
            ? tr('외부 백업 위치를 지웠습니다.')
            : tr('외부 백업 위치를 저장했습니다. 다음 백업부터 그곳에도 복사합니다.'),
      );
    } catch (e) {
      if (mounted) {
        showAppToast(
          context,
          tr('실패: {e}', {'e': e}),
          duration: const Duration(seconds: 5),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setPassword() async {
    final settings = _settings;
    if (settings == null) return;
    final result =
        await showDialog<({String password, String accountPassword})>(
          context: context,
          builder: (_) => _BackupPasswordDialog(
            changing: settings.passwordConfigured,
            minLength: settings.passwordMin,
          ),
        );
    if (result == null || !mounted) return;
    setState(() => _saving = true);
    try {
      final updated = await widget.session.api!.updateBackupSettings(
        password: result.password,
        accountPassword: result.accountPassword,
      );
      if (!mounted) return;
      setState(() => _apply(updated));
      showAppToast(
        context,
        settings.passwordConfigured
            ? tr('백업 암호를 바꿨습니다. 다음 백업부터 새 암호를 씁니다.')
            : tr('백업 암호를 정했습니다. 이제 매일 {updated.hour}시에 백업합니다.', {
                'updated.hour': updated.hour,
              }),
        duration: const Duration(seconds: 4),
      );
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _runNow() async {
    setState(() => _starting = true);
    try {
      final settings = await widget.session.api!.runBackupNow();
      if (!mounted) return;
      setState(() => _apply(settings, fields: false));
      showAppToast(context, tr('백업을 시작했습니다.'));
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// 운영자 계정 비밀번호를 다시 묻는다 — 취소하면 null.
  Future<String?> _askAccountPassword(String title, String message) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _AccountPasswordDialog(title: title, message: message),
    );
    return (result == null || result.isEmpty) ? null : result;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr(
              '회원·대화·설정이 든 DB와 서버 설정·인증서를 매일 백업합니다. NAS나 외장 드라이브를 외부 백업 위치로 정하면 그곳에 백업을 복사하고 첨부파일까지 맞춰 두어, 서버 PC가 고장 나도 새 PC에서 그대로 되살릴 수 있습니다. 백업은 백업 암호로 암호화됩니다.',
            ),
            style: theme.textTheme.bodySmall?.copyWith(color: hint),
          ),
          const SizedBox(height: 12),
          ..._buildBody(context),
        ],
      ),
    );
  }

  List<Widget> _buildBody(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    if (!_loaded) {
      return const [
        Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ];
    }
    if (_error != null) return [Text(_error!)];
    final settings = _settings;
    if (settings == null) {
      return [
        Text(
          tr('이 서버 버전은 백업 기능을 지원하지 않습니다. 서버를 업데이트하세요.'),
          style: TextStyle(color: theme.colorScheme.error),
        ),
      ];
    }
    final busy = _saving || settings.run.busy;
    return [
      _BackupStatusCard(
        settings: settings,
        starting: _starting,
        onRunNow:
            settings.passwordConfigured && !settings.run.busy && !_starting
            ? _runNow
            : null,
        onRefresh: _refresh,
      ),
      for (final warning in settings.warnings)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 18,
                color: Colors.orange.shade800,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  warning,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.orange.shade900,
                  ),
                ),
              ),
            ],
          ),
        ),
      const Divider(height: 32),

      // ── 백업 암호 ──
      _SectionTitle(tr('백업 암호')),
      Row(
        children: [
          Expanded(
            child: Text(
              settings.passwordConfigured
                  ? tr(
                      '설정됨 — 복원할 때 이 암호가 필요합니다. 잃어버리면 백업을 열 수 없으니 안전한 곳에 적어 두세요.',
                    )
                  : settings.passwordError ??
                        tr('아직 정하지 않았습니다 — 암호를 정해야 백업을 시작합니다.'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: settings.passwordConfigured
                    ? hint
                    : theme.colorScheme.error,
                fontWeight: settings.passwordConfigured
                    ? null
                    : FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: busy ? null : _setPassword,
            child: Text(
              settings.passwordConfigured ? tr('암호 바꾸기') : tr('암호 정하기'),
            ),
          ),
        ],
      ),
      const Divider(height: 32),

      // ── 자동 백업 ──
      _SectionTitle(tr('자동 백업')),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(tr('매일 자동으로 백업')),
        value: _enabled,
        onChanged: busy ? null : (v) => setState(() => _enabled = v),
      ),
      Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<int>(
              initialValue: _hour,
              decoration: InputDecoration(
                labelText: tr('백업 시각(서버 PC 기준)'),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (var h = 0; h < 24; h++)
                  DropdownMenuItem(
                    value: h,
                    child: Text(tr('매일 {h}시', {'h': h})),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (v) => setState(() => _hour = v ?? _hour),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<int>(
              initialValue: _keep,
              decoration: InputDecoration(
                labelText: tr('보관 개수'),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final n in _keepChoices(settings))
                  DropdownMenuItem(
                    value: n,
                    child: Text(tr('최근 {n}개', {'n': n})),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (v) => setState(() => _keep = v ?? _keep),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton(
          onPressed: busy ? null : _saveSchedule,
          child: Text(tr('저장')),
        ),
      ),
      const Divider(height: 32),

      // ── 외부 백업 위치 ──
      _SectionTitle(tr('외부 백업 위치')),
      Text(
        settings.fromServerPc
            ? tr(
                '외장 드라이브(예: E:\\TangoTalk백업)나 NAS 공유 폴더(예: \\\\NAS\\backup)를 넣으세요. 그 안에 "TangoTalk-Backup" 폴더를 만들어 씁니다. NAS는 서버 PC(컴퓨터 계정)에 쓰기 권한이 있어야 합니다.',
              )
            : tr(
                '외장 드라이브 경로(예: E:\\TangoTalk백업)를 넣으세요. NAS 공유 폴더(\\\\…)는 보안상 서버 PC에서 연 관리자 콘솔에서만 정할 수 있습니다.',
              ),
        style: theme.textTheme.bodySmall?.copyWith(color: hint),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _destination,
        enabled: !busy,
        decoration: InputDecoration(
          labelText: tr('외부 백업 위치'),
          hintText: tr('E:\\TangoTalk백업'),
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      const SizedBox(height: 8),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (settings.destination != null)
            TextButton(
              onPressed: busy ? null : () => _saveDestination(clear: true),
              child: Text(tr('지우기')),
            ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: busy ? null : _saveDestination,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(tr('확인 후 저장')),
          ),
        ],
      ),
      const Divider(height: 32),

      // ── 백업 목록 ──
      _SectionTitle(
        tr('서버 PC의 백업 ({settings.backups.length})', {
          'settings.backups.length': settings.backups.length,
        }),
      ),
      Text(
        settings.localDir,
        style: theme.textTheme.bodySmall?.copyWith(color: hint),
      ),
      const SizedBox(height: 4),
      if (settings.backups.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(tr('아직 백업이 없습니다.'), style: TextStyle(color: hint)),
        )
      else
        for (final b in settings.backups)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              b.kind == 'scheduled' ? Icons.schedule : Icons.touch_app_outlined,
              size: 20,
            ),
            title: Text(
              b.createdAt != null ? formatDateTime(b.createdAt!) : b.name,
            ),
            subtitle: Text(b.name),
            trailing: Text(
              '${b.kind == 'scheduled' ? tr('자동') : tr('수동')} · ${formatFileSize(b.bytes)}',
              style: theme.textTheme.bodySmall,
            ),
          ),
      const Divider(height: 32),

      // ── 복원 안내 ──
      _SectionTitle(tr('복원')),
      Text(
        tr(
          '복원은 서버 PC에서 시작 메뉴 "TangoTalk 서버 → 복원"을 실행해 백업 폴더(tangotalk_날짜_시각) 안의 manifest.json을 고르면 됩니다. 서버 PC가 고장 났다면 새 PC에 TangoTalk 서버를 설치한 뒤, 외부 백업 위치의 TangoTalk-Backup 폴더에서 같은 방법으로 복원하세요 — DB·설정·인증서와 첨부파일이 함께 돌아오고, 앱은 다시 페어링하지 않아도 됩니다(서버 주소가 같다면). 복원할 때 백업 암호가 필요합니다.',
        ),
        style: theme.textTheme.bodySmall?.copyWith(color: hint),
      ),
      const SizedBox(height: 8),
    ];
  }

  List<int> _keepChoices(BackupSettings s) {
    final values = {
      3,
      5,
      7,
      10,
      14,
      21,
      30,
      45,
      60,
      _keep,
    }.where((n) => n >= s.keepMin && n <= s.keepMax).toList()..sort();
    return values;
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
    ),
  );
}

/// 상태 카드 — DDNS·웹 앱 주소 카드와 같은 모양.
class _BackupStatusCard extends StatelessWidget {
  final BackupSettings settings;
  final bool starting;
  final VoidCallback? onRunNow;
  final VoidCallback onRefresh;
  const _BackupStatusCard({
    required this.settings,
    required this.starting,
    required this.onRunNow,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final (icon, color, label) = backupStatusLook(settings, theme);
    final run = settings.run;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 6, 6, 14),
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
                    text: tr('서버 백업'),
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
              IconButton(
                tooltip: tr('새로 고침'),
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh, size: 18),
              ),
              const SizedBox(width: 4),
              FilledButton.tonal(
                onPressed: onRunNow,
                child: starting || run.running
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(tr('지금 백업')),
              ),
              const SizedBox(width: 6),
            ],
          ),
          if (run.running && run.total != null && run.total! > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 10),
              child: LinearProgressIndicator(
                value: (run.done ?? 0) / run.total!,
              ),
            ),
          for (final line in backupStatusLines(settings))
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 10),
              child: Text(
                line,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: line.startsWith('※') ? hint : null,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 상태 카드 제목 옆의 아이콘·색·글.
(IconData, Color, String) backupStatusLook(BackupSettings s, ThemeData theme) {
  if (s.run.busy) {
    return (Icons.cloud_sync_outlined, theme.colorScheme.primary, tr('백업 중'));
  }
  if (!s.passwordConfigured) {
    return (Icons.error_outline, theme.colorScheme.error, tr('설정 필요'));
  }
  return switch (s.status.result) {
    'ok' => (Icons.cloud_done_outlined, Colors.green.shade700, tr('정상')),
    'partial' => (
      Icons.warning_amber_rounded,
      Colors.orange.shade800,
      tr('일부 실패'),
    ),
    'failed' => (Icons.error_outline, theme.colorScheme.error, tr('실패')),
    _ => (Icons.cloud_queue_outlined, theme.hintColor, tr('아직 없음')),
  };
}

/// 상태 카드 본문 줄들.
List<String> backupStatusLines(BackupSettings s) {
  final status = s.status;
  final run = s.run;
  final external = status.external;
  return [
    if (run.running)
      '${run.phase ?? tr('백업 중')}'
          '${run.total != null && run.total! > 0 ? ' (${run.done ?? 0}/${run.total})' : ''}',
    if (run.elsewhere) tr('서버 PC의 시작 메뉴 "백업"이 백업하고 있습니다.'),
    if (status.lastSuccessAt != null)
      tr('마지막 백업: {p0}{p1}', {
        'p0': formatDateTime(status.lastSuccessAt!),
        'p1': status.lastBackupBytes != null
            ? ' · ${formatFileSize(status.lastBackupBytes!)}'
            : '',
      }),
    if (status.result == 'failed' && status.lastAttemptAt != null)
      tr('실패: {p0} — {p1}', {
        'p0': formatDateTime(status.lastAttemptAt!),
        'p1': status.error ?? tr('알 수 없는 이유'),
      }),
    if (external != null && external.ok)
      tr('외부 위치: {external.path} — 첨부파일 {p0}개{p1}', {
        'external.path': external.path,
        'p0': external.uploadsTotal ?? 0,
        'p1': external.uploadsBytes != null
            ? '(${formatFileSize(external.uploadsBytes!)})'
            : '',
      }),
    if (external != null && external.ok && external.mailTotal != null)
      tr('회사 메일함 {p0}통{p1}', {
        'p0': external.mailTotal!,
        'p1': external.mailBytes != null
            ? '(${formatFileSize(external.mailBytes!)})'
            : '',
      }),
    if (external != null && !external.ok) ...[
      tr('외부 위치 복사 실패: {p0}', {'p0': external.error ?? tr('알 수 없는 이유')}),
      if (external.lastOkAt != null)
        tr('마지막 외부 복사 성공: {p0}', {'p0': formatDateTime(external.lastOkAt!)}),
    ],
    if (s.nextRunAt != null)
      tr('다음 자동 백업: {p0}', {'p0': formatDateTime(s.nextRunAt!)}),
    if (s.passwordConfigured && !s.enabled)
      tr('자동 백업이 꺼져 있습니다 — "지금 백업"으로만 백업합니다.'),
    tr('※ 서버가 꺼져 있던 동안 놓친 백업은 서버를 켜고 10분쯤 뒤에 합니다.'),
  ];
}

/// 운영자 계정 비밀번호 다시 확인 — 입력 칸의 컨트롤러는 대화상자가 닫히는 애니메이션이 끝난 뒤에 버린다(State.dispose).
class _AccountPasswordDialog extends StatefulWidget {
  final String title;
  final String message;
  const _AccountPasswordDialog({required this.title, required this.message});

  @override
  State<_AccountPasswordDialog> createState() => _AccountPasswordDialogState();
}

class _AccountPasswordDialogState extends State<_AccountPasswordDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.message),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(
                labelText: tr('내 계정 비밀번호'),
                helperText: tr('본인 확인을 위해 로그인 비밀번호를 한 번 더 넣으세요.'),
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.of(context).pop(v),
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
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(tr('확인')),
        ),
      ],
    );
  }
}

/// 백업 암호 정하기·바꾸기 — 새 암호 두 번과 운영자 계정 비밀번호를 받는다.
class _BackupPasswordDialog extends StatefulWidget {
  final bool changing;
  final int minLength;
  const _BackupPasswordDialog({
    required this.changing,
    required this.minLength,
  });

  @override
  State<_BackupPasswordDialog> createState() => _BackupPasswordDialogState();
}

class _BackupPasswordDialogState extends State<_BackupPasswordDialog> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _account = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    _account.dispose();
    super.dispose();
  }

  void _submit() {
    final pw = _password.text;
    final problem = pw.trim().length < widget.minLength
        ? tr('백업 암호는 {widget.minLength}자 이상으로 정하세요.', {
            'widget.minLength': widget.minLength,
          })
        : pw != _confirm.text
        ? tr('두 칸의 암호가 다릅니다.')
        : _account.text.isEmpty
        ? tr('내 계정 비밀번호를 넣으세요.')
        : null;
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    Navigator.of(context).pop((password: pw, accountPassword: _account.text));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.changing ? tr('백업 암호 바꾸기') : tr('백업 암호 정하기')),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  tr(
                    '이 암호를 잃어버리면 백업을 복원할 수 없습니다. 서버 PC가 아닌 안전한 곳에 적어 두세요.{p0}',
                    {
                      'p0': widget.changing
                          ? tr('\n이미 만든 백업은 그때의 암호로만 복원됩니다.')
                          : '',
                    },
                  ),
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _password,
                obscureText: true,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: tr('새 백업 암호'),
                  helperText: tr('{widget.minLength}자 이상', {
                    'widget.minLength': widget.minLength,
                  }),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _confirm,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: tr('새 백업 암호 확인'),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _account,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: tr('내 계정 비밀번호'),
                  helperText: tr('본인 확인을 위해 로그인 비밀번호를 한 번 더 넣으세요.'),
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _submit(),
              ),
              if (_problem != null) ...[
                const SizedBox(height: 8),
                Text(
                  _problem!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(onPressed: _submit, child: Text(tr('저장'))),
      ],
    );
  }
}
