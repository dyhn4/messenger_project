import 'package:flutter/material.dart';

import '../../../models/app_user.dart';
import '../../../models/calendar.dart';
import '../../../services/calendar_controller.dart';
import '../../../services/session.dart';
import '../../../widgets/app_toast.dart';
import '../../home_screen.dart' show wideBreakpoint;
import '../../invite_members_screen.dart' show MemberPicker, MemberPickerFrame;
import '../calendar_common.dart';
import 'calendar_create.dart' show kCalendarNameMax, validateCalendarName;
import 'calendar_management_common.dart';
import '../../../l10n/tr.dart';

/// 멤버 권한 이름(서버 role 값 → 화면 문구).
final calendarRoleLabels = {
  'admin': tr('관리자'),
  'write': tr('쓰기'),
  'read': tr('읽기'),
};

final _roleHelp = tr('관리자: 설정·멤버 관리, 모든 일정 수정  ·  쓰기: 일정 만들기  ·  읽기: 보기만');

/// ⋯ 메뉴 "캘린더 설정" — 캘린더 관리자는 이름·공개 여부·멤버를 고치고, 그 밖의 멤버·구독자는 읽기 전용으로 보되
/// 색(나에게만 적용되는 개인 설정)은 바꿀 수 있다. 소유자만 삭제할 수 있다.
Future<void> showCalendarSettings(
  BuildContext context,
  Session session,
  CalendarController controller,
  CalendarInfo calendar,
) {
  return showCalendarSheet<void>(
    context,
    title: tr('캘린더 설정'),
    maxWidth: 560,
    child: CalendarSettingsView(
      session: session,
      controller: controller,
      calendar: calendar,
    ),
  );
}

/// 캘린더 설정 본문. 종류마다 보이는 것이 다르다 — 기본 캘린더는 공개/비공개(소유자)만, 팀 캘린더는 색만,
/// 공유 캘린더는 이름·공개·멤버·삭제까지(관리자). 서버 오류(`{error}`)는 토스트/인라인으로 그대로 보인다.
class CalendarSettingsView extends StatefulWidget {
  final Session session;
  final CalendarController controller;

  /// 처음 열 때의 캘린더. 이후 값은 [CalendarController]에서 다시 읽어 최신으로 그린다.
  final CalendarInfo calendar;
  const CalendarSettingsView({
    super.key,
    required this.session,
    required this.controller,
    required this.calendar,
  });

  @override
  State<CalendarSettingsView> createState() => _CalendarSettingsViewState();
}

class _CalendarSettingsViewState extends State<CalendarSettingsView> {
  late final _name = TextEditingController(text: widget.calendar.name);
  final _search = TextEditingController();

  List<CalendarMember>? _members;
  String? _membersError;

  /// 팀 멤버(id → 사용자) — 준회원 판별(읽기만 가능)과 이름 검색에 쓴다. 못 받아도 서버가 400으로 막는다.
  Map<String, AppUser> _team = {};
  String _addRole = 'write';
  bool _busy = false;

  CalendarInfo get _cal =>
      widget.controller.calendarById(widget.calendar.id) ?? widget.calendar;

  bool get _isShared => _cal.kind == 'shared';

  /// 이름·공개 여부·멤버를 고칠 수 있는 사람(캘린더 관리자). 팀 캘린더는 아무도 못 고친다.
  bool get _canManage => _cal.canEditSettings && _cal.kind != 'team';

  bool get _showMembers => _isShared && _canManage;

  @override
  void initState() {
    super.initState();
    if (_showMembers) {
      _loadMembers();
      _loadTeam();
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadMembers() async {
    setState(() => _membersError = null);
    try {
      final list = await widget.controller.fetchMembers(widget.calendar.id);
      if (!mounted) return;
      // 소유자를 맨 위로.
      setState(
        () => _members = [
          ...list.where((m) => m.isOwner),
          ...list.where((m) => !m.isOwner),
        ],
      );
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _membersError = calendarErrorText(e, tr('멤버를 불러오지 못했습니다.')),
      );
    }
  }

  Future<void> _loadTeam() async {
    try {
      final list = await widget.session.fetchTeamMembers();
      if (mounted) setState(() => _team = {for (final u in list) u.id: u});
    } catch (_) {
      // 검색 제안과 준회원 표시가 빠질 뿐, 조직도 선택과 서버 검증은 그대로 동작한다.
    }
  }

  bool _isGuestUser(String userId) => _team[userId]?.role == 'guest';

  void _toast(String message) => showAppToast(context, message);

  Future<void> _run(Future<void> Function() action, String failure) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) _toast(calendarErrorText(e, failure));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- 이름 · 공개 · 색 ----

  bool get _nameChanged => _name.text.trim() != _cal.name;

  Future<void> _saveName() {
    final error = validateCalendarName(_name.text);
    if (error != null) {
      _toast(error);
      return Future.value();
    }
    return _run(() async {
      final updated = await widget.controller.updateCalendar(
        _cal.id,
        name: _name.text.trim(),
      );
      _name.text = updated.name;
      if (mounted) _toast(tr('캘린더 이름을 바꿨습니다.'));
    }, tr('이름을 바꾸지 못했습니다.'));
  }

  Future<void> _setPublic(bool value) => _run(() async {
    await widget.controller.updateCalendar(_cal.id, isPublic: value);
  }, tr('공개 설정을 바꾸지 못했습니다.'));

  Future<void> _setColor(String hex) {
    if (hex.toUpperCase() == _cal.color.toUpperCase()) return Future.value();
    return _run(
      () => widget.controller.setColor(_cal, hex),
      tr('색을 바꾸지 못했습니다.'),
    );
  }

  // ---- 멤버 ----

  Future<void> _addUser(AppUser user, {bool quiet = false}) async {
    // 준회원은 읽기만 — 서버도 400으로 막지만 처음부터 읽기로 넣는다.
    final role = user.role == 'guest' ? 'read' : _addRole;
    final added = await widget.controller.addMember(
      _cal.id,
      userId: user.id,
      role: role,
    );
    if (!mounted) return;
    setState(() {
      _members = [
        ...(_members ?? const <CalendarMember>[]).where(
          (m) => m.userId != added.userId,
        ),
        // 응답에 이름이 비어 있어도 고른 사람의 이름으로 보인다.
        CalendarMember(
          userId: added.userId,
          name: added.name.isEmpty || added.name == added.userId
              ? user.name
              : added.name,
          role: added.role,
          isOwner: added.isOwner,
        ),
      ];
    });
    if (!quiet) _toast(tr('{user.name} 님을 추가했습니다.', {'user.name': user.name}));
  }

  Future<void> _addFromSuggestion(AppUser user) {
    _search.clear();
    return _run(() => _addUser(user), tr('멤버를 추가하지 못했습니다.'));
  }

  Future<List<AppUser>?> _openOrgPicker() {
    final existing = {
      for (final m in _members ?? const <CalendarMember>[]) m.userId,
    };
    Widget screen({required bool asDialog}) => MemberPickerFrame(
      title: tr('멤버 추가'),
      asDialog: asDialog,
      child: Builder(
        builder: (pickerContext) => MemberPicker(
          session: widget.session,
          excludeIds: {...existing, ?widget.session.userId},
          emptySelectedText: tr('추가할 멤버를 선택하세요.'),
          noMembersText: tr('추가할 수 있는 멤버가 없습니다.'),
          footer: Text(
            tr('준회원은 읽기 권한으로만 추가돼요.'),
            style: TextStyle(color: Theme.of(pickerContext).hintColor),
          ),
          actionsBuilder: (context, selected, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(tr('취소')),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('cal-org-confirm'),
                onPressed: selected.isEmpty
                    ? null
                    : () => Navigator.of(context).pop(selected),
                child: Text(
                  selected.isEmpty
                      ? tr('추가하기')
                      : tr('추가하기 ({selected.length})', {
                          'selected.length': selected.length,
                        }),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (MediaQuery.sizeOf(context).width >= wideBreakpoint) {
      return showDialog<List<AppUser>>(
        context: context,
        builder: (_) => screen(asDialog: true),
      );
    }
    return Navigator.of(context).push<List<AppUser>>(
      MaterialPageRoute(builder: (_) => screen(asDialog: false)),
    );
  }

  Future<void> _addFromOrg() async {
    final picked = await _openOrgPicker();
    if (picked == null || picked.isEmpty || !mounted) return;
    await _run(() async {
      var added = 0;
      final failures = <String>[];
      for (final u in picked) {
        try {
          await _addUser(u, quiet: true);
          added++;
        } catch (e) {
          failures.add('${u.name}: ${calendarErrorText(e, tr('추가하지 못했습니다.'))}');
        }
      }
      if (!mounted) return;
      if (failures.isEmpty) {
        _toast(tr('멤버 {added}명을 추가했습니다.', {'added': added}));
      } else {
        _toast(failures.join('\n'));
      }
    }, tr('멤버를 추가하지 못했습니다.'));
  }

  Future<void> _changeRole(CalendarMember m, String role) async {
    if (role == m.role) return;
    await _run(() async {
      await widget.controller.updateMemberRole(_cal.id, m.userId, role: role);
      if (!mounted) return;
      setState(() {
        _members = [
          for (final x in _members ?? const <CalendarMember>[])
            if (x.userId == m.userId)
              CalendarMember(
                userId: x.userId,
                name: x.name,
                role: role,
                isOwner: x.isOwner,
              )
            else
              x,
        ];
      });
      // 내 권한을 낮췄으면 더는 설정을 바꿀 수 없으니 창을 닫는다.
      if (m.userId == widget.session.userId) {
        await widget.controller.loadCalendars();
        if (mounted && !_cal.canEditSettings) {
          _toast(tr('이제 이 캘린더의 설정을 바꿀 수 없습니다.'));
          Navigator.of(context).pop();
        }
      }
    }, tr('권한을 바꾸지 못했습니다.'));
  }

  Future<void> _removeMember(CalendarMember m) async {
    final ok = await confirmCalendarAction(
      context,
      title: tr('멤버 내보내기'),
      message: tr('\'{m.name}\' 님을 이 캘린더에서 내보낼까요?', {'m.name': m.name}),
      confirmLabel: tr('내보내기'),
    );
    if (!ok || !mounted) return;
    await _run(() async {
      await widget.controller.removeMember(_cal.id, m.userId);
      if (!mounted) return;
      setState(() {
        _members = [
          for (final x in _members ?? const <CalendarMember>[])
            if (x.userId != m.userId) x,
        ];
      });
      _toast(tr('{m.name} 님을 내보냈습니다.', {'m.name': m.name}));
    }, tr('멤버를 내보내지 못했습니다.'));
  }

  // ---- 나가기 · 삭제 ----

  Future<void> _leave() async {
    final done = await leaveCalendarFlow(context, widget.controller, _cal);
    if (done && mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final done = await deleteCalendarFlow(context, widget.controller, _cal);
    if (done && mounted) Navigator.of(context).pop();
  }

  // ---- 화면 ----

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) => SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ..._buildInfo(context),
            if (_showMembers) ..._buildMembers(context),
            ..._buildFooterActions(context),
          ],
        ),
      ),
    );
  }

  String get _kindLabel => switch (_cal.kind) {
    'personal' => tr('기본 캘린더'),
    'team' => tr('팀 캘린더'),
    _ => tr('공유 캘린더'),
  };

  String get _roleLabel => _cal.role == 'subscriber'
      ? tr('구독 중')
      : (calendarRoleLabels[_cal.role] ?? _cal.role);

  List<Widget> _buildInfo(BuildContext context) {
    final theme = Theme.of(context);
    final cal = _cal;
    final nameEditable = _canManage && _isShared;
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return [
      Row(
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: calendarColor(cal.color),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tr('{_kindLabel} · 내 권한 {_roleLabel}', {
                '_kindLabel': _kindLabel,
                '_roleLabel': _roleLabel,
              }),
              style: hint,
            ),
          ),
        ],
      ),
      if (cal.kind == 'team')
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(tr('팀 캘린더는 설정이 없고, 색만 나에게 맞게 바꿀 수 있어요.'), style: hint),
        )
      else if (!_canManage)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            tr('캘린더 관리자만 이름·공개 여부·멤버를 바꿀 수 있어요. 색은 나에게만 적용되는 설정이라 바꿀 수 있어요.'),
            key: const ValueKey('cal-settings-readonly-note'),
            style: hint,
          ),
        ),
      const SizedBox(height: 16),
      Text(tr('캘린더 이름'), style: theme.textTheme.labelLarge),
      const SizedBox(height: 6),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('cal-settings-name'),
              controller: _name,
              enabled: nameEditable && !_busy,
              maxLength: kCalendarNameMax,
              buildCounter: nameEditable
                  ? null
                  : (
                      _, {
                      required currentLength,
                      required isFocused,
                      maxLength,
                    }) => null,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _saveName(),
            ),
          ),
          if (nameEditable && _nameChanged) ...[
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: FilledButton(
                key: const ValueKey('cal-settings-name-save'),
                onPressed: _busy || validateCalendarName(_name.text) != null
                    ? null
                    : _saveName,
                child: Text(tr('저장')),
              ),
            ),
          ],
        ],
      ),
      if (cal.kind == 'personal')
        Text(tr('기본 캘린더의 이름은 바꿀 수 없어요.'), style: hint),
      const SizedBox(height: 12),
      Text(tr('색 (나에게만 적용)'), style: theme.textTheme.labelLarge),
      const SizedBox(height: 8),
      CalendarColorGrid(selected: cal.color, onSelected: _setColor),
      if (cal.ownerName != null) ...[
        const SizedBox(height: 16),
        Row(
          children: [
            Text(tr('소유자'), style: theme.textTheme.labelLarge),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                cal.ownerName!,
                key: const ValueKey('cal-settings-owner'),
              ),
            ),
          ],
        ),
      ],
      if (cal.kind != 'team') ...[
        const SizedBox(height: 8),
        SwitchListTile(
          key: const ValueKey('cal-settings-public'),
          contentPadding: EdgeInsets.zero,
          title: Text(tr('공개')),
          subtitle: Text(
            cal.isPublic
                ? tr('팀원이 캘린더 이름으로 검색해서 구독할 수 있어요.')
                : tr('비공개 캘린더는 다른 팀원이 구독할 수 없어요.'),
          ),
          value: cal.isPublic,
          onChanged: _canManage && !_busy ? _setPublic : null,
        ),
      ],
    ];
  }

  List<Widget> _buildMembers(BuildContext context) {
    final theme = Theme.of(context);
    final existing = {
      for (final m in _members ?? const <CalendarMember>[]) m.userId,
    };
    final q = _search.text.trim().toLowerCase();
    final suggestions = q.isEmpty
        ? const <AppUser>[]
        : [
            for (final u in _team.values)
              if (!existing.contains(u.id) &&
                  (u.name.toLowerCase().contains(q) ||
                      u.username.toLowerCase().contains(q)))
                u,
          ].take(6).toList();
    return [
      const Divider(height: 32),
      Text(tr('멤버'), style: theme.textTheme.titleSmall),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 220,
            child: TextField(
              key: const ValueKey('cal-member-search'),
              controller: _search,
              decoration: InputDecoration(
                isDense: true,
                hintText: tr('이름으로 멤버 검색'),
                prefixIcon: Icon(Icons.search, size: 20),
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          OutlinedButton.icon(
            key: const ValueKey('cal-member-org'),
            onPressed: _busy ? null : _addFromOrg,
            icon: const Icon(Icons.account_tree_outlined, size: 18),
            label: Text(tr('조직도')),
          ),
          DropdownButton<String>(
            key: const ValueKey('cal-member-add-role'),
            value: _addRole,
            isDense: true,
            items: [
              for (final e in calendarRoleLabels.entries)
                DropdownMenuItem(
                  value: e.key,
                  child: Text(tr('추가 권한: {e.value}', {'e.value': e.value})),
                ),
            ],
            onChanged: (v) => setState(() => _addRole = v ?? _addRole),
          ),
        ],
      ),
      if (suggestions.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(top: 6),
          decoration: BoxDecoration(
            border: Border.all(color: theme.dividerColor),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            children: [
              for (final u in suggestions)
                ListTile(
                  key: ValueKey('cal-suggest-${u.id}'),
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text(u.name),
                  subtitle: Text(
                    u.role == 'guest'
                        ? tr('준회원 · 읽기 권한으로 추가돼요')
                        : (u.orgLine ?? u.username),
                  ),
                  onTap: _busy ? null : () => _addFromSuggestion(u),
                ),
            ],
          ),
        ),
      Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 8),
        child: Text(
          _roleHelp,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        ),
      ),
      if (_membersError != null)
        Row(
          children: [
            Expanded(
              child: Text(
                _membersError!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
            TextButton(onPressed: _loadMembers, child: Text(tr('다시 시도'))),
          ],
        )
      else if (_members == null)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        )
      else
        for (final m in _members!) _memberRow(context, m),
    ];
  }

  Widget _memberRow(BuildContext context, CalendarMember m) {
    final theme = Theme.of(context);
    final isSelf = m.userId == widget.session.userId;
    final guest = _isGuestUser(m.userId);
    return Padding(
      key: ValueKey('cal-member-${m.userId}'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          CircleAvatar(
            radius: 14,
            child: Text(
              m.name.isEmpty ? '?' : m.name.characters.first,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                text: m.name,
                children: [
                  if (isSelf)
                    TextSpan(
                      text: tr(' (나)'),
                      style: TextStyle(color: theme.hintColor),
                    ),
                  if (guest)
                    TextSpan(
                      text: tr(' · 준회원'),
                      style: TextStyle(color: theme.hintColor),
                    ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (m.isOwner)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                tr('소유자'),
                key: const ValueKey('cal-member-owner-badge'),
                style: TextStyle(color: theme.hintColor),
              ),
            )
          else
            DropdownButton<String>(
              key: ValueKey('cal-member-role-${m.userId}'),
              value: m.role,
              isDense: true,
              underline: const SizedBox.shrink(),
              items: [
                for (final e in calendarRoleLabels.entries)
                  DropdownMenuItem(
                    value: e.key,
                    // 준회원은 읽기만 고를 수 있다.
                    enabled: !(guest && e.key != 'read'),
                    child: Text(e.value),
                  ),
              ],
              onChanged: _busy ? null : (v) => _changeRole(m, v ?? m.role),
            ),
          if (m.isOwner || isSelf)
            const SizedBox(width: 40)
          else
            IconButton(
              key: ValueKey('cal-member-remove-${m.userId}'),
              tooltip: tr('내보내기'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.person_remove_outlined, size: 20),
              onPressed: _busy ? null : () => _removeMember(m),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildFooterActions(BuildContext context) {
    final cal = _cal;
    final error = Theme.of(context).colorScheme.error;
    final canDelete = cal.kind == 'shared' && cal.canDelete;
    final canLeave = !canDelete && (cal.isSubscriber || cal.isSharedMember);
    if (!canDelete && !canLeave) return const [];
    return [
      const Divider(height: 32),
      Align(
        alignment: Alignment.centerLeft,
        child: canDelete
            ? OutlinedButton.icon(
                key: const ValueKey('cal-settings-delete'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: error,
                  side: BorderSide(color: error),
                ),
                onPressed: _busy ? null : _delete,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: Text(tr('캘린더 삭제')),
              )
            : OutlinedButton.icon(
                key: const ValueKey('cal-settings-leave'),
                onPressed: _busy ? null : _leave,
                icon: const Icon(Icons.logout, size: 18),
                label: Text(cal.isSubscriber ? tr('구독 취소') : tr('나에게만 삭제')),
              ),
      ),
      if (canDelete)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            tr('삭제하면 캘린더의 모든 일정도 함께 삭제돼요.'),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
          ),
        ),
    ];
  }
}
