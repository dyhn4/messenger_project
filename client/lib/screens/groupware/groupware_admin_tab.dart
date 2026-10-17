import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../services/download_storage.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import 'approval_form_widgets.dart' show ApprovalFormsAdminSection;
import 'approval_forms.dart' show isHmText;
import 'approval_settings.dart' show ApprovalStatsSection;
import 'groupware_screen.dart';

/// 관리 탭(결재·근태 관리자만) — 근무 시간(지각·조퇴 기준), 구성원 입사일·연차 현황·연차 조정, 한 달 근태 요약과 엑셀.
/// 회사 전체 범위면 서버 운영자·관리자 등급, 팀 범위면 그 팀 소유자·관리자 등급이 본다(server groupwareScope.js).
class GroupwareAdminTab extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final GroupwareChanges changes;
  final Session session;

  /// 근무 시간을 바꿨을 때 — 화면이 범위 정보(근무 시간)를 다시 받는다.
  final VoidCallback? onContextChanged;
  const GroupwareAdminTab({
    super.key,
    required this.api,
    required this.ctx,
    required this.changes,
    required this.session,
    this.onContextChanged,
  });

  @override
  State<GroupwareAdminTab> createState() => _GroupwareAdminTabState();
}

class _GroupwareAdminTabState extends State<GroupwareAdminTab> {
  late final _workStart = TextEditingController(
    text: minutesText(widget.ctx.workStart),
  );
  late final _workEnd = TextEditingController(
    text: minutesText(widget.ctx.workEnd),
  );
  List<GroupwareMember>? _members;
  List<AttendanceSummaryRow>? _summary;
  late String _monthKey = widget.ctx.today.substring(0, 7);
  bool _saving = false;
  bool _exporting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.changes.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.changes.removeListener(_load);
    _workStart.dispose();
    _workEnd.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        widget.api.members(),
        widget.api.attendanceSummary(_monthKey),
      ]);
      if (!mounted) return;
      setState(() {
        _members = results[0] as List<GroupwareMember>;
        _summary = results[1] as List<AttendanceSummaryRow>;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _saveHours() async {
    if (!isHmText(_workStart.text) || !isHmText(_workEnd.text)) {
      showAppToast(context, '근무 시간을 HH:MM으로 넣으세요.');
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.api.setWorkHours(
        start: _workStart.text.trim(),
        end: _workEnd.text.trim(),
      );
      if (!mounted) return;
      showAppToast(context, '근무 시간을 저장했습니다.');
      widget.onContextChanged?.call();
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '실패: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editHireDate(GroupwareMember m) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: m.hireDate == null ? now : DateTime.parse(m.hireDate!),
      firstDate: DateTime(1970),
      lastDate: DateTime(now.year + 1),
      helpText: '${m.name}님의 입사일',
    );
    if (picked == null || !mounted) return;
    try {
      await widget.api.setHireDate(m.id, dateKeyOf(picked));
      if (mounted) {
        showAppToast(context, '${m.name}님의 입사일을 ${dateKeyOf(picked)}로 정했습니다.');
      }
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '실패: $e');
    }
  }

  Future<void> _adjust(GroupwareMember m) async {
    final result = await showDialog<({int halfDays, String reason})>(
      context: context,
      builder: (_) => _AdjustDialog(name: m.name),
    );
    if (result == null || !mounted) return;
    try {
      await widget.api.adjustLeave(
        m.id,
        halfDays: result.halfDays,
        reason: result.reason,
      );
      if (mounted) showAppToast(context, '${m.name}님의 연차를 조정했습니다.');
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '실패: $e');
    }
  }

  void _shiftMonth(int delta) {
    final parts = _monthKey.split('-');
    final next = DateTime(int.parse(parts[0]), int.parse(parts[1]) + delta);
    setState(() {
      _monthKey = '${next.year}-${next.month.toString().padLeft(2, '0')}';
      _summary = null;
    });
    _load();
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final name = '근태_${widget.ctx.scopeLabel}_$_monthKey.xlsx'.replaceAll(
        RegExp(r'[\\/:*?"<>|]'),
        '_',
      );
      final path = await widget.session.downloadAuthedFile(
        widget.api.attendanceExportPath(_monthKey),
        fileName: name,
      );
      await openLocalFile(path);
    } catch (e) {
      if (mounted) showAppToast(context, '실패: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    if (_error != null) return GroupwareEmpty(_error!);
    final members = _members;
    final summary = _summary;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text(
            '범위: ${widget.ctx.scope == 'server' ? '회사 전체' : '이 팀(${widget.ctx.teamName ?? ''})'}'
            ' — 바꾸려면 관리자 콘솔 → 운영 현황의 "그룹웨어 범위". 법정 연차는 입사일 기준으로 계산하고, 출근율 80% 미만·이월·회사가 더 주는 '
            '휴가는 "연차 조정"으로 맞춥니다.',
            style: TextStyle(fontSize: 12, color: hint),
          ),
        ),
        const GroupwareSectionHeader('근무 시간(지각·조퇴 기준)'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              SizedBox(
                width: 110,
                child: TextField(
                  key: const ValueKey('gw-work-start'),
                  controller: _workStart,
                  decoration: const InputDecoration(
                    labelText: '시작',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('~'),
              ),
              SizedBox(
                width: 110,
                child: TextField(
                  key: const ValueKey('gw-work-end'),
                  controller: _workEnd,
                  decoration: const InputDecoration(
                    labelText: '끝',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                key: const ValueKey('gw-work-save'),
                onPressed: _saving ? null : _saveHours,
                child: const Text('저장'),
              ),
            ],
          ),
        ),
        ApprovalFormsAdminSection(api: widget.api, changes: widget.changes),
        ApprovalStatsSection(api: widget.api, ctx: widget.ctx),
        const GroupwareSectionHeader('구성원 연차'),
        if (members == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          for (final m in members)
            ListTile(
              key: ValueKey('gw-member-${m.id}'),
              dense: true,
              title: Text('${m.name}${m.suspended ? ' (정지)' : ''}'),
              subtitle: Text(
                m.hireDate == null
                    ? '입사일 미등록 — 눌러서 등록'
                    : '입사 ${m.hireDate} · 생김 ${halfDaysText(m.grantedHalfDays ?? 0)} · 씀 ${halfDaysText(m.usedHalfDays)}'
                          '${m.pendingHalfDays > 0 ? ' · 결재 중 ${halfDaysText(m.pendingHalfDays)}' : ''}'
                          ' · 남음 ${halfDaysText(m.remainingHalfDays ?? 0)}',
                style: TextStyle(
                  color: m.hireDate == null ? theme.colorScheme.error : hint,
                ),
              ),
              onTap: () => _editHireDate(m),
              trailing: m.hireDate == null
                  ? null
                  : TextButton(
                      key: ValueKey('gw-adjust-${m.id}'),
                      onPressed: () => _adjust(m),
                      child: const Text('연차 조정'),
                    ),
            ),
        GroupwareSectionHeader(
          '월별 근태',
          trailing: FilledButton.tonalIcon(
            key: const ValueKey('gw-export'),
            onPressed: _exporting ? null : _export,
            icon: _exporting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download, size: 18),
            label: const Text('엑셀로 받기'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              IconButton(
                tooltip: '이전 달',
                onPressed: () => _shiftMonth(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              Text(
                '${_monthKey.substring(0, 4)}년 ${int.parse(_monthKey.substring(5))}월',
              ),
              IconButton(
                tooltip: '다음 달',
                onPressed: () => _shiftMonth(1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
        if (summary == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          for (final row in summary)
            ListTile(
              key: ValueKey('gw-summary-${row.userId}'),
              dense: true,
              title: Text(row.name),
              subtitle: Text(
                [
                  '출근 ${row.summary.daysWorked}일',
                  row.summary.hoursText,
                  if (row.summary.late > 0) '지각 ${row.summary.late}',
                  if (row.summary.earlyLeave > 0)
                    '조퇴 ${row.summary.earlyLeave}',
                  if (row.summary.missingClockOut > 0)
                    '퇴근 누락 ${row.summary.missingClockOut}',
                  if (row.summary.absent > 0) '결근 ${row.summary.absent}',
                  if (row.summary.leaveHalfDays > 0)
                    '휴가 ${halfDaysText(row.summary.leaveHalfDays)}',
                  if (row.summary.tripDays > 0) '출장 ${row.summary.tripDays}일',
                  if (row.summary.overtimeMinutes > 0)
                    '연장 ${row.summary.overtimeText}',
                ].join(' · '),
                style: TextStyle(color: hint),
              ),
            ),
      ],
    );
  }
}

/// 연차 조정 — 일수(0.5일 단위, 빼려면 −)와 사유.
class _AdjustDialog extends StatefulWidget {
  final String name;
  const _AdjustDialog({required this.name});

  @override
  State<_AdjustDialog> createState() => _AdjustDialogState();
}

class _AdjustDialogState extends State<_AdjustDialog> {
  final _days = TextEditingController();
  final _reason = TextEditingController();
  bool _subtract = false;
  String? _error;

  @override
  void dispose() {
    _days.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _done() {
    final value = double.tryParse(_days.text.trim());
    if (value == null ||
        value <= 0 ||
        (value * 2) != (value * 2).roundToDouble() ||
        value > 60) {
      setState(() => _error = '일수를 0.5일 단위로 넣으세요(최대 60일).');
      return;
    }
    if (_reason.text.trim().isEmpty) {
      setState(() => _error = '조정 사유를 쓰세요.');
      return;
    }
    final halfDays = (value * 2).round() * (_subtract ? -1 : 1);
    Navigator.of(
      context,
    ).pop((halfDays: halfDays, reason: _reason.text.trim()));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${widget.name}님 연차 조정'),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('더 주기')),
              ButtonSegment(value: true, label: Text('빼기')),
            ],
            selected: {_subtract},
            onSelectionChanged: (s) => setState(() => _subtract = s.first),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('gw-adjust-days'),
            controller: _days,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: '일수 (예: 1, 0.5)',
              border: OutlineInputBorder(),
              suffixText: '일',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('gw-adjust-reason'),
            controller: _reason,
            maxLength: 200,
            decoration: const InputDecoration(
              labelText: '사유 (예: 지난해 이월, 출근율 80% 미만)',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('취소'),
      ),
      FilledButton(
        key: const ValueKey('gw-adjust-ok'),
        onPressed: _done,
        child: const Text('조정'),
      ),
    ],
  );
}
