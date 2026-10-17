import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/admin.dart';
import '../models/team.dart';
import '../services/api_client.dart' show PositionOption;
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/admin_org_edit_dialog.dart';
import '../widgets/app_toast.dart';
import '../widgets/avatar_utils.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/muted_scrollbar.dart';
import '../widgets/role_badge.dart';
import '../widgets/sort_menu_button.dart';
import '../widgets/team_avatar.dart';
import '../widgets/grab_cursors.dart';
import 'admin_backup_tab.dart';
import 'admin_ddns_tab.dart';
import 'admin_login_security_tab.dart';
import 'admin_mail_tab.dart';
import 'admin_stickers_tab.dart';

/// 서버 운영자 전용 관리자 콘솔. 팀 설정(팀 안의 관리)과 달리 **서버 전체**를 다룬다 —
/// 운영 현황 / 회원 / 팀 / 감사 로그 / FCM 설정 / DDNS / 이모티콘 일곱 탭. DDNS 탭에는 DuckDNS 자동 갱신과
/// 아이폰용 웹 앱 주소(정식 인증서) 상태가 함께 있다(admin_ddns_tab.dart).
///
/// 여기 있는 모든 동작은 서버 src/admin.js가 매 요청마다 isServerAdmin을 다시 확인하므로,
/// 이 화면이 열려 있다는 것만으로 권한이 생기지는 않는다.
Future<void> showAdminConsole(BuildContext context, Session session) {
  return showDialog<void>(
    context: context,
    builder: (_) => AdminConsoleScreen(session: session),
  );
}

class AdminConsoleScreen extends StatelessWidget {
  final Session session;
  const AdminConsoleScreen({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 10,
      child: FloatingDialog(
        title: '서버 관리',
        maxWidth: 820,
        maxHeight: 720,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(text: '운영 현황'),
                Tab(text: '회원'),
                Tab(text: '팀'),
                Tab(text: '감사 로그'),
                Tab(text: 'FCM 설정'),
                Tab(text: 'DDNS'),
                Tab(text: '메일'),
                Tab(text: '로그인 보안'),
                Tab(text: '백업'),
                Tab(text: '이모티콘'),
              ],
            ),
            const SizedBox(height: 12),
            Flexible(
              child: TabBarView(
                children: [
                  _StatsTab(session: session),
                  _UsersTab(session: session),
                  _TeamsTab(session: session),
                  _AuditTab(session: session),
                  _FcmTab(session: session),
                  AdminDdnsTab(session: session),
                  AdminMailTab(session: session),
                  AdminLoginSecurityTab(session: session),
                  AdminBackupTab(session: session),
                  AdminStickersTab(session: session),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────────── 운영 현황 ─────────────────────────────

class _StatsTab extends StatefulWidget {
  final Session session;
  const _StatsTab({required this.session});

  @override
  State<_StatsTab> createState() => _StatsTabState();
}

class _StatsTabState extends State<_StatsTab> {
  ServerStats? _stats;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final stats = await widget.session.api!.fetchServerStats();
      if (mounted) setState(() => _stats = stats);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _save({
    String? teamCreation,
    String? orgScope,
    String? teamInviteLinkCreation,
    String? projectCreation,
    String? groupwareScope,
  }) async {
    setState(() => _saving = true);
    try {
      await widget.session.api!.updateServerSettings(
        teamCreation: teamCreation,
        orgScope: orgScope,
        teamInviteLinkCreation: teamInviteLinkCreation,
        projectCreation: projectCreation,
        groupwareScope: groupwareScope,
      );
      if (orgScope != null) await widget.session.refreshOrgInfo();
      // 범위가 바뀌면 결재함도 달라진다 — 메뉴의 결재 뱃지를 새로 센다.
      if (orgScope != null || groupwareScope != null) {
        await widget.session.refreshGroupwarePending();
      }
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '실패: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    final stats = _stats;
    if (stats == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _StatCard(label: '회원', value: '${stats.users}명'),
              _StatCard(label: '팀', value: '${stats.teams}개'),
              _StatCard(label: '대화방', value: '${stats.rooms}개'),
              _StatCard(label: '전체 메시지', value: '${stats.messages}건'),
              _StatCard(label: '오늘 메시지·댓글', value: '${stats.messagesToday}건'),
              _StatCard(label: '첨부 용량', value: _formatBytes(stats.uploadBytes)),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            '서버 시작: ${formatDateTime(stats.serverStartedAt)}',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
          ),
          const _SectionDivider(),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '팀 생성 권한',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '팀을 새로 만들 수 있는 최소 등급입니다. 준회원은 어느 설정에서도 팀을 만들 수 없고, '
            '서버 운영자는 설정과 무관하게 항상 만들 수 있습니다.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<String>(
              segments: [
                for (final level in teamCreationLevels)
                  ButtonSegment(
                    value: level,
                    label: Text(teamCreationLabel(level)),
                  ),
              ],
              selected: {stats.teamCreation},
              onSelectionChanged: _saving
                  ? null
                  : (s) => _save(teamCreation: s.first),
            ),
          ),
          const _SectionDivider(),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '팀 초대 링크 생성 권한',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '"팀 초대 링크"로 가입하면 지정한 팀에 자동 합류하고 등급도 자동으로 부여됩니다. '
            '이 링크를 만들 수 있는 최소 등급입니다. 준회원은 어느 설정에서도 만들 수 없고, '
            '서버 운영자는 설정과 무관하게 항상 만들 수 있습니다.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<String>(
              segments: [
                for (final level in teamCreationLevels)
                  ButtonSegment(
                    value: level,
                    label: Text(teamCreationLabel(level)),
                  ),
              ],
              selected: {stats.teamInviteLinkCreation},
              onSelectionChanged: _saving
                  ? null
                  : (s) => _save(teamInviteLinkCreation: s.first),
            ),
          ),
          const _SectionDivider(),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '프로젝트 생성 권한',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '"프로젝트"(업무 관리 공간)를 새로 만들 수 있는 최소 등급입니다. 준회원은 어느 '
            '설정에서도 만들 수 없고, 서버 운영자는 설정과 무관하게 항상 만들 수 있습니다. '
            '이미 만들어진 프로젝트에 초대받아 참여하는 것은 이 설정과 무관합니다.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<String>(
              segments: [
                for (final level in teamCreationLevels)
                  ButtonSegment(
                    value: level,
                    label: Text(teamCreationLabel(level)),
                  ),
              ],
              selected: {stats.projectCreation},
              onSelectionChanged: _saving
                  ? null
                  : (s) => _save(projectCreation: s.first),
            ),
          ),
          const _SectionDivider(),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '팀·직책 관리',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '팀 단위로 두면 한 사람이 팀마다 다른 직책을 가질 수 있고, 각 팀에서 팀 설정으로 정합니다. '
            '계정 단위로 두면 조직도가 하나로 통일되고, 여기 회원 탭에서 아래 직책 목록 중 하나를 골라 정합니다.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'team', label: Text('팀 단위')),
                ButtonSegment(value: 'account', label: Text('계정 단위')),
              ],
              selected: {stats.orgScope},
              onSelectionChanged: _saving
                  ? null
                  : (s) => _save(orgScope: s.first),
            ),
          ),
          const _SectionDivider(),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '그룹웨어 범위',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '전자결재·연차·출퇴근을 팀마다 따로 둘지, 회사 전체 하나로 둘지 정합니다. "팀·직책 설정을 따름"이면 위 설정이 '
            '계정 단위일 때 회사 전체, 팀 단위일 때 팀마다입니다. 바꾸면 이전 범위의 결재·근태 기록은 그 범위에 남아 새 범위에서는 '
            '보이지 않으니, 운영을 시작하기 전에 정하세요.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<String>(
              key: const ValueKey('admin-groupware-scope'),
              segments: const [
                ButtonSegment(value: 'org', label: Text('팀·직책 설정을 따름')),
                ButtonSegment(value: 'team', label: Text('팀마다')),
                ButtonSegment(value: 'server', label: Text('회사 전체')),
              ],
              selected: {stats.groupwareScope},
              onSelectionChanged: _saving
                  ? null
                  : (s) => _save(groupwareScope: s.first),
            ),
          ),
          const _SectionDivider(),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '직책 목록',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '팀·직책 관리가 "계정 단위"일 때, 회원 탭의 직책 수정에서 자유 입력 대신 이 목록 '
            '중 하나를 고르게 합니다.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 8),
          _PositionOptionsEditor(session: widget.session),
        ],
      ),
    );
  }
}

/// "운영 현황" 탭의 항목 사이 구분선.
class _SectionDivider extends StatelessWidget {
  const _SectionDivider();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 20),
    child: Divider(height: 1),
  );
}

/// "직책 목록" 관리 — 끌어다 놓아 서열을 바꾸는 칩 + 끝의 "+" 버튼(누르면 이름 입력 팝업).
/// `_StatsTab`과 별도 위젯으로 뺀 이유는 이 목록 자체의 로딩/에러 상태가 위 서버
/// 설정(orgScope 등)과 독립적이기 때문이다.
class _PositionOptionsEditor extends StatefulWidget {
  final Session session;
  const _PositionOptionsEditor({required this.session});

  @override
  State<_PositionOptionsEditor> createState() => _PositionOptionsEditorState();
}

class _PositionOptionsEditorState extends State<_PositionOptionsEditor> {
  List<PositionOption>? _options;
  String? _error;
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final options = await widget.session.fetchPositionOptions();
      if (mounted) setState(() => _options = options);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _add() async {
    final label = await showDialog<String>(
      context: context,
      builder: (_) => const _AddPositionDialog(),
    );
    if (label == null || !mounted) return;
    setState(() => _adding = true);
    try {
      final created = await widget.session.createPositionOption(label);
      if (mounted) setState(() => _options = [...?_options, created]);
    } catch (e) {
      if (mounted) showAppToast(context, '실패: $e');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _delete(PositionOption option) async {
    try {
      await widget.session.deletePositionOption(option.id);
      if (mounted) {
        setState(
          () => _options = _options?.where((o) => o.id != option.id).toList(),
        );
      }
    } catch (e) {
      if (mounted) showAppToast(context, '실패: $e');
    }
  }

  // 끄는 동안의 미리보기 순서 — 끌고 있는 칩이 다른 칩 위에 올라갈 때마다 그 자리로 옮겨서
  // 나머지 칩들이 밀려나 보이게 하고, 손을 놓으면 이 순서를 저장한다. null이면 끄는 중이 아님.
  List<PositionOption>? _preview;

  void _dragStarted() => setState(() => _preview = [...?_options]);

  void _dragOver(String draggedId, String targetId) {
    final list = _preview;
    if (list == null) return;
    final from = list.indexWhere((o) => o.id == draggedId);
    final to = list.indexWhere((o) => o.id == targetId);
    if (from == -1 || to == -1 || from == to) return;
    setState(() => list.insert(to, list.removeAt(from)));
  }

  /// 손을 놓으면(칩 밖에 놓아도) 미리보기 순서를 그대로 확정한다. 화면을 먼저 바꾸고, 저장에
  /// 실패하면 다시 불러온다.
  Future<void> _dragEnded() async {
    final list = _preview;
    final before = _options;
    setState(() => _preview = null);
    if (list == null || before == null) return;
    final ids = [for (final o in list) o.id];
    if (listEquals(ids, [for (final o in before) o.id])) return;
    setState(() => _options = list);
    try {
      final updated = await widget.session.reorderPositionOptions(ids);
      if (mounted) setState(() => _options = updated);
    } catch (e) {
      if (mounted) showAppToast(context, '순서를 바꾸지 못했습니다: $e');
      await _load();
    }
  }

  /// 회원가입 기본 직책 변경 — [id]가 null이면 해제. 서버 API는 토글이라, 해제는 지금 기본값을
  /// 한 번 더 토글하고, 지정은 새 항목을 토글한다(기존 기본값은 서버가 알아서 내린다).
  Future<void> _setDefault(String? id) async {
    final current = _options?.where((o) => o.isDefault).firstOrNull;
    if (id == current?.id) return;
    final toggleId = id ?? current!.id;
    try {
      final updated = await widget.session.toggleDefaultPositionOption(
        toggleId,
      );
      if (mounted) setState(() => _options = updated);
    } catch (e) {
      if (mounted) showAppToast(context, '실패: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Text(_error!);
    final options = _preview ?? _options;
    if (options == null) {
      return const SizedBox(
        height: 24,
        width: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    final hint = Theme.of(context).hintColor;
    final defaultId = _options!.where((o) => o.isDefault).firstOrNull?.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '직책을 끌어서 옮기면 서열을 바꿀 수 있습니다(왼쪽이 위).',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: hint),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final option in options)
              _PositionOptionPill(
                key: ValueKey(option.id),
                option: option,
                onDragStarted: _dragStarted,
                onDragOver: (draggedId) => _dragOver(draggedId, option.id),
                onDragEnded: _dragEnded,
                onDelete: () => _delete(option),
              ),
            IconButton.filledTonal(
              tooltip: '직책 추가',
              icon: _adding
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add, size: 18),
              visualDensity: VisualDensity.compact,
              onPressed: _adding ? null : _add,
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Text('회원가입 시 기본 직책', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(width: 10),
            _DefaultPositionPicker(
              options: _options!,
              selectedId: defaultId,
              onSelected: _setDefault,
            ),
          ],
        ),
      ],
    );
  }
}

/// "회원가입 시 기본 직책" 선택 버튼 — 직책 칩과 같은 알약 모양 버튼을 누르면 목록이 아래로
/// 펼쳐진다. 기본값이 있으면 버튼을 강조색으로 칠해 지정돼 있다는 게 한눈에 보이게 한다.
class _DefaultPositionPicker extends StatelessWidget {
  final List<PositionOption> options;
  final String? selectedId;
  final ValueChanged<String?> onSelected;
  const _DefaultPositionPicker({
    required this.options,
    required this.selectedId,
    required this.onSelected,
  });

  // PopupMenuButton은 null 값을 "메뉴 닫힘"으로 보므로 "지정 안 함"은 빈 문자열로 표시한다.
  static const _none = '';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = options.where((o) => o.id == selectedId).firstOrNull;
    final fg = selected != null
        ? scheme.onPrimaryContainer
        : scheme.onSurfaceVariant;

    PopupMenuItem<String> item(String value, String label) => PopupMenuItem(
      value: value,
      height: 40,
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: value == (selectedId ?? _none)
                ? Icon(Icons.check, size: 18, color: scheme.primary)
                : null,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: value == _none
                ? TextStyle(color: Theme.of(context).hintColor)
                : null,
          ),
        ],
      ),
    );

    return PopupMenuButton<String>(
      tooltip: '기본 직책 선택',
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onSelected: (v) => onSelected(v == _none ? null : v),
      itemBuilder: (_) => [
        item(_none, '지정 안 함'),
        const PopupMenuDivider(),
        for (final o in options) item(o.id, o.label),
      ],
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
        decoration: BoxDecoration(
          color: selected != null
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              selected?.label ?? '지정 안 함',
              style: TextStyle(
                color: fg,
                fontWeight: selected != null ? FontWeight.w600 : null,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.expand_more, size: 18, color: fg),
          ],
        ),
      ),
    );
  }
}

/// "FCM 설정" 편집기 — 클라이언트 초기화용 4개 값(비밀값은 아니지만 항상 google-services.json
/// 에서 통째로 불러오는 값이라 굳이 입력창으로 보여주지 않고 "열기" 버튼 + 설정 여부 문구로만
/// 표시한다)과 서버 발송용 서비스 계정 키(붙여넣기 전용 — 서버가 private_key를 절대 다시
/// 내려주지 않으므로 항상 빈 채로 시작하고, 현재 설정 여부만 위에 문구로 보여준다).
class _FcmSettingsEditor extends StatefulWidget {
  final Session session;
  const _FcmSettingsEditor({required this.session});

  @override
  State<_FcmSettingsEditor> createState() => _FcmSettingsEditorState();
}

class _FcmSettingsEditorState extends State<_FcmSettingsEditor> {
  FcmSettings? _settings;
  String? _error;
  bool _saving = false;
  final _apiKey = TextEditingController();
  final _appId = TextEditingController();
  final _projectId = TextEditingController();
  final _senderId = TextEditingController();
  final _serviceAccountJson = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _apiKey.dispose();
    _appId.dispose();
    _projectId.dispose();
    _senderId.dispose();
    _serviceAccountJson.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final settings = await widget.session.api!.fetchFcmSettings();
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _apiKey.text = settings.apiKey;
        _appId.text = settings.appId;
        _projectId.text = settings.projectId;
        _senderId.text = settings.messagingSenderId;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// google-services.json을 읽어서 4개 값을 입력창에 채워 넣기만 한다(바로 저장하지 않음) —
  /// 파일 형식이 예상과 다를 수 있어서, 사람이 채워진 값을 한 번 보고 "저장"을 눌러야
  /// 실제로 반영된다.
  Future<void> _pickGoogleServicesJson() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final file = result?.files.single;
    // 웹은 경로 없이 바이트만 온다 — xFile이 둘 다 감싼다.
    if (file == null || (file.path == null && file.bytes == null)) return;
    try {
      final json =
          jsonDecode(await file.xFile.readAsString()) as Map<String, dynamic>;
      final projectInfo = json['project_info'] as Map<String, dynamic>?;
      final clients = json['client'] as List?;
      final client = clients?.isNotEmpty == true
          ? clients!.first as Map<String, dynamic>
          : null;
      final apiKeys = client?['api_key'] as List?;
      final apiKey = apiKeys?.isNotEmpty == true
          ? (apiKeys!.first as Map<String, dynamic>)['current_key'] as String?
          : null;
      final appId =
          (client?['client_info'] as Map<String, dynamic>?)?['mobilesdk_app_id']
              as String?;
      final projectId = projectInfo?['project_id'] as String?;
      final senderId = projectInfo?['project_number'] as String?;
      if (apiKey == null ||
          appId == null ||
          projectId == null ||
          senderId == null) {
        throw '필요한 값(api_key/mobilesdk_app_id/project_id/project_number)을 찾지 못했습니다.';
      }
      setState(() {
        _apiKey.text = apiKey;
        _appId.text = appId;
        _projectId.text = projectId;
        _senderId.text = senderId;
      });
      if (mounted) {
        showAppToast(
          context,
          'google-services.json에서 값을 불러왔습니다. 확인 후 저장을 누르세요.',
        );
      }
    } catch (e) {
      if (mounted) {
        showAppToast(context, 'google-services.json을 읽지 못했습니다: $e');
      }
    }
  }

  /// firebase-service-account.json을 읽어서 붙여넣기 칸에 채워 넣기만 한다(바로 저장하지
  /// 않음) — 실제 형식 검증(type/private_key/client_email)은 저장 시 서버가 한다.
  Future<void> _pickServiceAccountJson() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final file = result?.files.single;
    if (file == null || (file.path == null && file.bytes == null)) return;
    try {
      final content = await file.xFile.readAsString();
      jsonDecode(content); // 최소한 JSON 형식인지만 여기서 미리 확인.
      setState(() => _serviceAccountJson.text = content);
      if (mounted) {
        showAppToast(context, '서비스 계정 키를 불러왔습니다. 저장을 눌러야 반영됩니다.');
      }
    } catch (e) {
      if (mounted) {
        showAppToast(context, '파일을 읽지 못했습니다: $e');
      }
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      // 서비스 계정은 붙여넣은 게 있을 때만 같이 보낸다 — 안 그러면 4개 값만 고치려다
      // 이미 설정된 서비스 계정을 빈 값으로 덮어써 날려버릴 수 있다(서버는 빈 문자열을
      // "설정 해제"로 해석한다 — admin.js 참고).
      final serviceAccountJson = _serviceAccountJson.text.trim();
      await widget.session.api!.updateFcmSettings(
        apiKey: _apiKey.text.trim(),
        appId: _appId.text.trim(),
        projectId: _projectId.text.trim(),
        messagingSenderId: _senderId.text.trim(),
        serviceAccountJson: serviceAccountJson.isEmpty
            ? null
            : serviceAccountJson,
      );
      _serviceAccountJson.clear();
      await _load();
      if (mounted) {
        showAppToast(context, 'FCM 설정을 저장했습니다.');
      }
    } catch (e) {
      if (mounted) {
        showAppToast(context, '실패: $e');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Text(_error!);
    final settings = _settings;
    if (settings == null) {
      return const SizedBox(
        height: 24,
        width: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _pickGoogleServicesJson,
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('google-services.json 열기'),
          ),
        ),
        const SizedBox(height: 12),
        // 이 4개 값은 비밀값이 아니지만(API 키는 앱 패키지명+SHA-1로 제한, Firebase 공식
        // 안내), 어차피 항상 파일에서 통째로 불러와 채우는 값이라 직접 눈으로 대조하거나
        // 고칠 일이 없다 — 서비스 계정 키와 같은 "열기 버튼 + 설정 여부" 방식으로 맞춘다.
        Text(
          _projectId.text.isEmpty
              ? 'Google 서비스 설정: 설정 안 됨'
              : 'Google 서비스 설정: 설정됨 (프로젝트 ID: ${_projectId.text})',
          style: TextStyle(
            color: _projectId.text.isEmpty
                ? Theme.of(context).colorScheme.error
                : null,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _pickServiceAccountJson,
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('서비스 계정 JSON 열기'),
          ),
        ),
        const SizedBox(height: 12),
        // google-services.json(위 4개 값)과 같은 방식 — 파일에서 통째로 불러와 채우는
        // 값이라 화면에 원문을 보여줄 필요가 없다(개인키가 그대로 노출되는 것도 막는다).
        // _serviceAccountJson은 화면에 안 보이는 내부 저장소일 뿐, 실제 값은 저장 버튼을
        // 눌러야 서버로 전송된다.
        Text(
          _serviceAccountJson.text.isNotEmpty
              ? '새 서비스 계정 키를 선택했습니다 — 저장을 눌러야 적용됩니다.'
              : settings.serviceAccountConfigured
              ? '서비스 계정: 설정됨 (${settings.serviceAccountEmail ?? '확인 불가'})'
              : '서비스 계정: 설정 안 됨 — 설정 전까지 푸시가 발송되지 않습니다.',
          style: TextStyle(
            color:
                _serviceAccountJson.text.isEmpty &&
                    !settings.serviceAccountConfigured
                ? Theme.of(context).colorScheme.error
                : null,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '서비스 계정 설정이 완료되면 다운받은 json 파일은 반드시 삭제해야 합니다.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: hint),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('저장'),
          ),
        ),
      ],
    );
  }
}

/// 직책 목록 한 항목: [이름 x]. 끄는 동안 다른 칩 위에 올라가면 [onDragOver]로 알려서
/// 부모가 미리보기 순서를 바꾸게 한다(나머지 칩이 밀려난다). 끌고 있는 칩의 자리에는 흐린
/// 칩 + 테두리로 "놓일 자리"를 보여준다.
class _PositionOptionPill extends StatelessWidget {
  final PositionOption option;
  final VoidCallback onDragStarted;
  final ValueChanged<String> onDragOver;
  final VoidCallback onDragEnded;
  final VoidCallback onDelete;
  const _PositionOptionPill({
    super.key,
    required this.option,
    required this.onDragStarted,
    required this.onDragOver,
    required this.onDragEnded,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final chip = _chip(context);
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) {
        if (d.data == option.id) return false;
        onDragOver(d.data);
        return true;
      },
      builder: (context, _, _) => MouseRegion(
        cursor: GrabCursors.open,
        child: Draggable<String>(
          data: option.id,
          onDragStarted: onDragStarted,
          onDragEnd: (_) => onDragEnded(),
          feedback: Material(
            color: Colors.transparent,
            elevation: 4,
            borderRadius: BorderRadius.circular(20),
            child: chip,
          ),
          childWhenDragging: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Theme.of(context).colorScheme.primary,
                width: 1.5,
              ),
            ),
            child: Opacity(opacity: 0.3, child: chip),
          ),
          child: chip,
        ),
      ),
    );
  }

  Widget _chip(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 10),
          Text(option.label),
          const SizedBox(width: 2),
          InkWell(
            onTap: onDelete,
            customBorder: const CircleBorder(),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(Icons.close, size: 14, color: hint),
            ),
          ),
          const SizedBox(width: 2),
        ],
      ),
    );
  }
}

/// 직책 목록의 "+" 버튼으로 여는 팝업 — 입력한 직책 이름(앞뒤 공백 제거)을 돌려준다.
class _AddPositionDialog extends StatefulWidget {
  const _AddPositionDialog();

  @override
  State<_AddPositionDialog> createState() => _AddPositionDialogState();
}

class _AddPositionDialogState extends State<_AddPositionDialog> {
  final _label = TextEditingController();

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  void _submit() {
    final label = _label.text.trim();
    if (label.isEmpty) return;
    Navigator.of(context).pop(label);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('직책 추가'),
      content: SizedBox(
        width: 320,
        child: TextField(
          controller: _label,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(
            labelText: '직책 이름',
            hintText: '예: 팀장',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _label,
          builder: (context, value, _) => FilledButton(
            onPressed: value.text.trim().isEmpty ? null : _submit,
            child: const Text('추가'),
          ),
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  const _StatCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 160,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).hintColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────── 회원 ─────────────────────────────

class _UsersTab extends StatefulWidget {
  final Session session;
  const _UsersTab({required this.session});

  @override
  State<_UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends State<_UsersTab> {
  List<AdminUser>? _users;
  String? _error;
  String _filter = '';
  final _scrollController = ScrollController();

  MemberSortField _sortField = MemberSortField.name;
  bool _sortAscending = true;
  List<PositionOption>? _positionOptions;

  @override
  void initState() {
    super.initState();
    _load();
    widget.session.fetchPositionOptions().then((list) {
      if (mounted) setState(() => _positionOptions = list);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final users = await widget.session.api!.fetchAdminUsers();
      if (mounted) setState(() => _users = users);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _replace(AdminUser updated) {
    setState(() {
      final list = [...?_users];
      final i = list.indexWhere((u) => u.id == updated.id);
      if (i >= 0) list[i] = updated;
      _users = list;
    });
  }

  /// 관리자 콘솔은 Dialog 안에서 뜨는 화면이라 SnackBar를 쓰면 다이얼로그 뒤쪽 Scaffold에
  /// 그려져 가려진다 — Overlay에 직접 꽂는 알약 토스트를 쓴다(app_toast.dart 참고).
  void _toast(String message) {
    if (!mounted) return;
    showAppToast(context, message);
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      _toast('실패: $e');
    }
  }

  Future<void> _toggleSuspend(AdminUser user) async {
    final suspend = !user.suspended;
    if (suspend) {
      final ok = await _confirm(
        title: '계정 정지',
        message:
            '${user.name} 님의 계정을 정지할까요?\n'
            '로그인과 실시간 연결이 즉시 끊기고, 다시 로그인할 수 없게 됩니다. 나중에 해제할 수 있습니다.',
        confirmLabel: '정지',
      );
      if (ok != true) return;
    }
    await _run(() async {
      _replace(await widget.session.api!.setUserSuspended(user.id, suspend));
      _toast(
        suspend ? '${user.name} 님을 정지했습니다.' : '${user.name} 님의 정지를 해제했습니다.',
      );
    });
  }

  Future<void> _logoutAll(AdminUser user) async {
    final ok = await _confirm(
      title: '강제 로그아웃',
      message: '${user.name} 님의 모든 기기에서 로그아웃시킬까요? 다시 로그인하면 정상적으로 사용할 수 있습니다.',
      confirmLabel: '로그아웃',
    );
    if (ok != true) return;
    await _run(() async {
      _replace(await widget.session.api!.logoutUserEverywhere(user.id));
      _toast('${user.name} 님을 모든 기기에서 로그아웃시켰습니다.');
    });
  }

  /// 2단계 인증 해제 — 휴대폰을 잃어버려 복구 코드도 없는 사람(다음 로그인부터 비밀번호만, 정책상 꼭 써야 하면 다시 켜게 된다).
  Future<void> _resetOtp(AdminUser user) async {
    final ok = await _confirm(
      title: '2단계 인증 해제',
      message:
          '${user.name} 님의 2단계 인증을 해제할까요? 휴대폰을 잃어버렸을 때만 하세요. 다음 로그인부터는 비밀번호만으로 들어오고, '
          '관리자가 2단계 인증을 꼭 쓰게 정했으면 그때 다시 켜게 됩니다.',
      confirmLabel: '해제',
    );
    if (ok != true) return;
    await _run(() async {
      _replace(await widget.session.api!.resetUserOtp(user.id));
      _toast('${user.name} 님의 2단계 인증을 해제했습니다.');
    });
  }

  Future<void> _changeRole(AdminUser user, String role) async {
    await _run(() async {
      _replace(await widget.session.api!.setUserRole(user.id, role));
      _toast('${user.name} 님을 ${accountRoleLabel(role)}(으)로 바꿨습니다.');
    });
  }

  Future<void> _editOrg(AdminUser user) async {
    // '계정 단위'일 때는 직책을 자유 입력 대신 "직책 목록"(운영 현황에서 관리)에서
    // 칩으로 고르게 한다 — 그 외(팀 단위)에는 자유 입력 그대로 쓴다. 소속 팀은 목록에
    // 이미 칩으로 보이고 여기서 바꿀 수 있는 값도 아니라 이 다이얼로그에는 없다.
    final options = widget.session.orgScope == 'account'
        ? await widget.session.fetchPositionOptions()
        : const <PositionOption>[];
    if (!mounted) return;
    final result = await showAdminOrgEditDialog(
      context,
      userName: user.name,
      orgScope: widget.session.orgScope,
      position: user.position,
      options: options,
    );
    if (result == null || !mounted) return;
    await _run(() async {
      _replace(
        await widget.session.api!.updateUserOrg(
          user.id,
          position: result.position,
        ),
      );
      _toast(
        result.position.isEmpty
            ? '${user.name} 님의 직책을 지웠습니다.'
            : '${user.name} 님의 직책을 "${result.position}"(으)로 바꿨습니다.',
      );
    });
  }

  Future<void> _toggleServerAdmin(AdminUser user) async {
    final grant = !user.isServerAdmin;
    final ok = await _confirm(
      title: grant ? '서버 운영자로 지정' : '서버 운영자 해제',
      message: grant
          ? '${user.name} 님에게 서버 관리 권한을 줄까요? 회원·팀·감사 로그를 모두 볼 수 있게 됩니다.'
          : '${user.name} 님의 서버 관리 권한을 해제할까요?',
      confirmLabel: grant ? '지정' : '해제',
    );
    if (ok != true) return;
    await _run(() async {
      _replace(await widget.session.api!.setUserServerAdmin(user.id, grant));
      _toast(
        grant
            ? '${user.name} 님을 서버 운영자로 지정했습니다.'
            : '${user.name} 님의 서버 운영자 권한을 해제했습니다.',
      );
    });
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SizedBox(width: 340, child: Text(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  /// 직책 목록에서의 서열 — 목록은 이미 서열순(작을수록 낮음)으로 오므로 그 안에서의
  /// 위치(index)가 곧 서열이다. 목록에 없거나(미등록·자유 입력 시절의 값) 아직 안
  /// 불러왔으면 맨 뒤로 보낸다.
  int _positionRank(String? label) {
    if (label == null || label.isEmpty) return 1 << 30;
    final index = _positionOptions?.indexWhere((o) => o.label == label) ?? -1;
    return index == -1 ? 1 << 30 : index;
  }

  List<AdminUser> _sortedUsers(List<AdminUser> list) {
    final users = List<AdminUser>.of(list);
    final cmp = switch (_sortField) {
      MemberSortField.name => (AdminUser a, AdminUser b) => a.name.compareTo(
        b.name,
      ),
      MemberSortField.role => (AdminUser a, AdminUser b) => _roleRank(
        a.role,
      ).compareTo(_roleRank(b.role)),
      MemberSortField.team => (AdminUser a, AdminUser b) => _teamSortKey(
        a,
      ).compareTo(_teamSortKey(b)),
      MemberSortField.position => (AdminUser a, AdminUser b) => _positionRank(
        a.position,
      ).compareTo(_positionRank(b.position)),
    };
    users.sort(_sortAscending ? cmp : (a, b) => cmp(b, a));
    return users;
  }

  String _teamSortKey(AdminUser user) =>
      user.teams.isEmpty ? '' : user.teams.map((t) => t.name).join(', ');

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    final users = _users;
    if (users == null) return const Center(child: CircularProgressIndicator());

    final filtered = users
        .where(
          (u) =>
              _filter.isEmpty ||
              u.name.toLowerCase().contains(_filter.toLowerCase()) ||
              u.username.toLowerCase().contains(_filter.toLowerCase()),
        )
        .toList();
    final list = _sortedUsers(filtered);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          decoration: InputDecoration(
            hintText: '이름·아이디 검색',
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 18),
            border: const OutlineInputBorder(),
            helperText: '총 ${users.length}명',
          ),
          onChanged: (v) => setState(() => _filter = v),
        ),
        const SizedBox(height: 8),
        _UsersTableHead(
          sortField: _sortField,
          sortAscending: _sortAscending,
          onSortChanged: (field, ascending) => setState(() {
            _sortField = field;
            _sortAscending = ascending;
          }),
        ),
        const Divider(height: 1),
        Expanded(
          child: MutedScrollbar(
            controller: _scrollController,
            child: ListView.separated(
              controller: _scrollController,
              itemCount: list.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final user = list[i];
                final isMe = user.id == widget.session.userId;
                if (user.deleted) {
                  return _DeletedUserRow(user: user);
                }
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        flex: 9,
                        child: Row(
                          children: [
                            CircleAvatar(
                              backgroundColor:
                                  parseHexColor(user.avatarColor) ??
                                  Theme.of(
                                    context,
                                  ).colorScheme.primaryContainer,
                              child: Text(
                                user.avatarEmoji ??
                                    (user.name.isEmpty
                                        ? '?'
                                        : user.name.substring(0, 1)),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          user.name,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      if (isMe)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            left: 6,
                                          ),
                                          child: Text(
                                            '(나)',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Theme.of(
                                                context,
                                              ).hintColor,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  Text(
                                    user.username,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: Theme.of(context).hintColor,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        flex: 5,
                        child: Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: _statusBadges(context, user),
                        ),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        flex: 9,
                        child: user.teams.isEmpty
                            ? Text(
                                '없음',
                                style: TextStyle(
                                  color: Theme.of(context).hintColor,
                                  fontStyle: FontStyle.italic,
                                ),
                              )
                            : Wrap(
                                spacing: 4,
                                runSpacing: 4,
                                children: [
                                  for (final team in user.teams)
                                    _TeamChip(team: team),
                                ],
                              ),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        flex: 5,
                        child: Text(
                          user.position?.isNotEmpty == true
                              ? user.position!
                              : '미등록',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Theme.of(context).hintColor,
                            fontStyle: user.position?.isNotEmpty == true
                                ? FontStyle.normal
                                : FontStyle.italic,
                          ),
                        ),
                      ),
                      // 제목 줄 맨 오른쪽의 정렬 단추와 같은 폭 — 폭이 다르면 칼럼들이 그 차이만큼 어긋난다.
                      SizedBox(
                        width: sortMenuButtonWidth,
                        child: PopupMenuButton<void>(
                          tooltip: '회원 관리',
                          position: PopupMenuPosition.under,
                          itemBuilder: (context) => [
                            // 계정 등급은 서버 운영자만 정한다 — 여기가 유일한 변경 지점이다.
                            for (final role in const [
                              'admin',
                              'member',
                              'guest',
                            ])
                              PopupMenuItem<void>(
                                onTap: () => _changeRole(user, role),
                                child: Row(
                                  children: [
                                    Icon(
                                      user.role == role
                                          ? Icons.radio_button_checked
                                          : Icons.radio_button_unchecked,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(accountRoleLabel(role)),
                                  ],
                                ),
                              ),
                            const PopupMenuDivider(),
                            PopupMenuItem<void>(
                              onTap: () => _editOrg(user),
                              child: const Row(
                                children: [
                                  Icon(Icons.badge_outlined, size: 20),
                                  SizedBox(width: 8),
                                  Text('직책 수정'),
                                ],
                              ),
                            ),
                            PopupMenuItem<void>(
                              onTap: () => _logoutAll(user),
                              child: const Row(
                                children: [
                                  Icon(Icons.logout, size: 20),
                                  SizedBox(width: 8),
                                  Text('모든 기기에서 로그아웃'),
                                ],
                              ),
                            ),
                            if (user.otpEnabled)
                              PopupMenuItem<void>(
                                key: const ValueKey('admin-user-otp-reset'),
                                onTap: () => _resetOtp(user),
                                child: const Row(
                                  children: [
                                    Icon(
                                      Icons.phonelink_lock_outlined,
                                      size: 20,
                                    ),
                                    SizedBox(width: 8),
                                    Text('2단계 인증 해제'),
                                  ],
                                ),
                              ),
                            PopupMenuItem<void>(
                              onTap: () => _toggleServerAdmin(user),
                              child: Row(
                                children: [
                                  const Icon(Icons.shield_outlined, size: 20),
                                  const SizedBox(width: 8),
                                  Text(
                                    user.isServerAdmin
                                        ? '서버 운영자 해제'
                                        : '서버 운영자로 지정',
                                  ),
                                ],
                              ),
                            ),
                            if (!isMe) ...[
                              const PopupMenuDivider(),
                              PopupMenuItem<void>(
                                onTap: () => _toggleSuspend(user),
                                child: Row(
                                  children: [
                                    Icon(
                                      user.suspended
                                          ? Icons.lock_open_outlined
                                          : Icons.block,
                                      size: 20,
                                      color: user.suspended
                                          ? null
                                          : Colors.redAccent,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      user.suspended ? '정지 해제' : '계정 정지',
                                      style: TextStyle(
                                        color: user.suspended
                                            ? null
                                            : Colors.redAccent,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// "회원" 탭 목록 위 칼럼 제목 — 실제 행(위의 itemBuilder)과 같은 비율(flex 10 / 12 / 7)로
/// 맞춰서, "회원"+"등급"은 붙여서 좁게, 그 다음 "팀"·"직책"은 넉넉한 간격으로 벌린다.
/// 맨 끝은 각 행의 PopupMenuButton 자리에 정렬 버튼을 대신 놓는다.
class _UsersTableHead extends StatelessWidget {
  final MemberSortField sortField;
  final bool sortAscending;
  final void Function(MemberSortField field, bool ascending) onSortChanged;

  const _UsersTableHead({
    required this.sortField,
    required this.sortAscending,
    required this.onSortChanged,
  });

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Theme.of(context).hintColor,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(flex: 9, child: Text('회원', style: style)),
          const SizedBox(width: 20),
          Expanded(flex: 5, child: Text('등급', style: style)),
          const SizedBox(width: 20),
          Expanded(flex: 9, child: Text('팀', style: style)),
          const SizedBox(width: 20),
          Expanded(flex: 5, child: Text('직책', style: style)),
          SortMenuButton<MemberSortField>(
            fields: const [
              MemberSortField.name,
              MemberSortField.role,
              MemberSortField.team,
              MemberSortField.position,
            ],
            labelOf: (f) => f.label,
            selectedField: sortField,
            ascending: sortAscending,
            onChanged: onSortChanged,
          ),
        ],
      ),
    );
  }
}

/// 계정 등급 서열(작을수록 낮음) — "등급 순" 정렬에 쓴다(server/src/permissions.js의
/// ROLE_RANK와 같다).
int _roleRank(String role) => switch (role) {
  'admin' => 2,
  'member' => 1,
  _ => 0,
};

/// 탈퇴한 회원의 행 — 이름·"탈퇴" 표시만 흐리게 보여주고 등급/팀/직책/관리 메뉴는 의미가
/// 없어서(계정이 이미 익명화됨) 아예 뺀다.
class _DeletedUserRow extends StatelessWidget {
  final AdminUser user;
  const _DeletedUserRow({required this.user});

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest,
            child: Icon(Icons.person_off_outlined, size: 18, color: hint),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              user.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: hint),
            ),
          ),
          const SizedBox(width: 10),
          Transform.translate(
            offset: const Offset(-10, 0),
            child: RoleBadge(
              label: '탈퇴',
              bg: Theme.of(context).colorScheme.surfaceContainerHighest,
              fg: hint,
            ),
          ),
        ],
      ),
    );
  }
}

/// 등급(관리자/정회원/준회원) + 정지됨/서버 운영자 뱃지들 — 색으로 한눈에 구분되게 한다.
List<Widget> _statusBadges(BuildContext context, AdminUser user) {
  final roleColors = roleBadgeColors(context, user.role);
  return [
    RoleBadge(
      label: accountRoleLabel(user.role),
      bg: roleColors.bg,
      fg: roleColors.fg,
    ),
    if (user.isServerAdmin)
      RoleBadge(
        label: '서버 운영자',
        bg: roleBadgeColors(context, 'op').bg,
        fg: roleBadgeColors(context, 'op').fg,
      ),
    if (user.suspended)
      RoleBadge(
        label: '정지됨',
        bg: roleBadgeColors(context, 'suspended').bg,
        fg: roleBadgeColors(context, 'suspended').fg,
      ),
  ];
}

/// 소속 팀 칩 — 팀마다(id 기준) 고정된 색을 골라서(`TeamAvatar`의 팔레트와 동일한 방식) 같은
/// 팀은 다른 화면에서도 항상 같은 색으로 보인다.
const _teamChipPalette = [
  Color(0xFF9575CD),
  Color(0xFF4C6EF5),
  Color(0xFF15AABF),
  Color(0xFF37B24D),
  Color(0xFFE64980),
  Color(0xFFFF6B35),
];

class _TeamChip extends StatelessWidget {
  final AdminUserTeam team;
  const _TeamChip({required this.team});

  @override
  Widget build(BuildContext context) {
    final color =
        _teamChipPalette[team.id.hashCode.abs() % _teamChipPalette.length];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        team.name,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ───────────────────────────── 팀 ─────────────────────────────

class _TeamsTab extends StatefulWidget {
  final Session session;
  const _TeamsTab({required this.session});

  @override
  State<_TeamsTab> createState() => _TeamsTabState();
}

class _TeamsTabState extends State<_TeamsTab> {
  List<AdminTeam>? _teams;
  String? _error;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final teams = await widget.session.api!.fetchAdminTeams();
      if (mounted) setState(() => _teams = teams);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    final teams = _teams;
    if (teams == null) return const Center(child: CircularProgressIndicator());
    if (teams.isEmpty) return const Center(child: Text('팀이 없습니다.'));

    return MutedScrollbar(
      controller: _scrollController,
      child: ListView.separated(
        controller: _scrollController,
        itemCount: teams.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final team = teams[i];
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: TeamAvatar(
              team: Team(
                id: team.id,
                name: team.name,
                iconEmoji: team.iconEmoji,
                iconColor: team.iconColor,
                iconUrl: team.iconUrl,
                createdAt: team.createdAt,
              ),
              resolveUrl: widget.session.resolveUrl,
            ),
            title: Text(team.name),
            subtitle: Text(
              '${team.memberCount}명'
              '${team.createdBy == null ? '' : ' · 만든 사람 ${team.createdBy}'}'
              ' · ${formatDateTime(team.createdAt)}',
            ),
          );
        },
      ),
    );
  }
}

// ───────────────────────────── 감사 로그 ─────────────────────────────

class _AuditTab extends StatefulWidget {
  final Session session;
  const _AuditTab({required this.session});

  @override
  State<_AuditTab> createState() => _AuditTabState();
}

class _AuditTabState extends State<_AuditTab> {
  static const _pageSize = 50;

  List<AuditLog>? _logs;
  int _total = 0;
  int _offset = 0;
  String? _action;
  String? _error;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final result = await widget.session.api!.fetchAuditLogs(
        action: _action,
        limit: _pageSize,
        offset: _offset,
      );
      if (mounted) {
        setState(() {
          _logs = result.logs;
          _total = result.total;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    final logs = _logs;
    if (logs == null) return const Center(child: CircularProgressIndicator());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text('행위'),
            const SizedBox(width: 12),
            DropdownButton<String?>(
              value: _action,
              hint: const Text('전체'),
              onChanged: (v) {
                setState(() {
                  _action = v;
                  _offset = 0;
                  _logs = null;
                });
                _load();
              },
              items: [
                const DropdownMenuItem<String?>(child: Text('전체')),
                for (final a in auditActionFilters)
                  DropdownMenuItem<String?>(
                    value: a,
                    child: Text(auditActionLabel(a)),
                  ),
              ],
            ),
            const Spacer(),
            Text(
              '$_total건',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).hintColor,
              ),
            ),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: logs.isEmpty
              ? const Center(child: Text('기록이 없습니다.'))
              : MutedScrollbar(
                  controller: _scrollController,
                  child: ListView.separated(
                    controller: _scrollController,
                    itemCount: logs.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) => _AuditRow(log: logs[i]),
                  ),
                ),
        ),
        if (_total > _pageSize) ...[
          const Divider(height: 1),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: _offset == 0
                    ? null
                    : () {
                        setState(() {
                          _offset -= _pageSize;
                          _logs = null;
                        });
                        _load();
                      },
              ),
              Text(
                '${_offset ~/ _pageSize + 1} / ${(_total / _pageSize).ceil()}',
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: _offset + _pageSize >= _total
                    ? null
                    : () {
                        setState(() {
                          _offset += _pageSize;
                          _logs = null;
                        });
                        _load();
                      },
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _AuditRow extends StatelessWidget {
  final AuditLog log;
  const _AuditRow({required this.log});

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  log.actionLabel,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  log.actorName,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                formatDateTime(log.createdAt),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: hint),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            [
              if (log.teamName != null) '[${log.teamName}]',
              if (log.targetLabel != null) '${log.targetLabel} →',
              log.detail ?? '',
            ].where((s) => s.isNotEmpty).join(' '),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────── FCM 설정 ─────────────────────────────

class _FcmTab extends StatelessWidget {
  final Session session;
  const _FcmTab({required this.session});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '푸시 알림(FCM)은 이 서버의 Firebase 프로젝트 값을 입력해야 동작합니다. '
            'Firebase 콘솔에서 프로젝트를 만들고 안드로이드 앱(패키지명 com.teamtalk.messenger)을 '
            '등록하면 "프로젝트 설정 > 일반"에서 google-services.json 파일을 다운로드하여 열기 버튼을 눌러 등록하면 아래 4개 값을 확인할 수 있습니다. 서비스 계정 키(발송용)는 '
            '"프로젝트 설정 > 서비스 계정 > 새 비공개 키 생성"으로 받은 JSON 파일도 열기 버튼으로 등록합니다.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 12),
          _FcmSettingsEditor(session: session),
        ],
      ),
    );
  }
}

/// "12.3MB"처럼 사람이 읽는 용량 표기.
String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)}${units[unit]}';
}
