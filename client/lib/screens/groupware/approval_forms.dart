import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../l10n/tr.dart';

/// 결재선 — 결재자(순서대로)·결재자마다의 역할(결재·합의·전결)과 참조자. 신청 창과 결재선 선택기([ApprovalLinePicker])가 같이 본다.
class ApprovalLineController extends ChangeNotifier {
  final List<String> approverIds = [];
  final List<String> ccIds = [];

  /// 결재가 아닌 칸의 역할 — 이어진 합의는 한 단계(동시에 차례), 전결은 한 명.
  final Map<String, LineRole> roles = {};

  void setLine(
    List<String> approvers,
    List<String> cc, [
    Map<String, LineRole> lineRoles = const {},
  ]) {
    approverIds
      ..clear()
      ..addAll(approvers);
    ccIds
      ..clear()
      ..addAll(cc.where((id) => !approvers.contains(id)));
    roles
      ..clear()
      ..addAll({
        for (final e in lineRoles.entries)
          if (approvers.contains(e.key) && e.value != LineRole.approve)
            e.key: e.value,
      });
    notifyListeners();
  }

  LineRole roleOf(String id) => roles[id] ?? LineRole.approve;

  /// 역할을 다음 것으로(결재 → 합의 → 전결 → 결재). 전결은 한 명만이라 다른 사람의 전결은 결재로 돌린다.
  void cycleRole(String id) {
    final next = roleOf(id).next;
    if (next == LineRole.finalApprove) {
      roles.removeWhere((_, r) => r == LineRole.finalApprove);
    }
    if (next == LineRole.approve) {
      roles.remove(id);
    } else {
      roles[id] = next;
    }
    notifyListeners();
  }

  /// 결재자마다의 단계 번호(1부터) — 이어진 합의 칸은 같은 번호(서버 approvalRules.js validateApprovalLine과 같은 규칙).
  List<int> get stageNumbers {
    final out = <int>[];
    var stage = 0;
    for (final (i, id) in approverIds.indexed) {
      final agree = roleOf(id) == LineRole.agree;
      if (!(agree && i > 0 && roleOf(approverIds[i - 1]) == LineRole.agree)) {
        stage += 1;
      }
      out.add(stage);
    }
    return out;
  }

  void addApprover(String id) {
    if (approverIds.contains(id)) return;
    ccIds.remove(id);
    approverIds.add(id);
    notifyListeners();
  }

  void removeApprover(String id) {
    approverIds.remove(id);
    roles.remove(id);
    notifyListeners();
  }

  /// [index]번째 결재자를 [delta]만큼 옮긴다(위로 -1, 아래로 +1).
  void moveApprover(int index, int delta) {
    final to = index + delta;
    if (to < 0 || to >= approverIds.length) return;
    final id = approverIds.removeAt(index);
    approverIds.insert(to, id);
    notifyListeners();
  }

  void toggleCc(String id) {
    if (approverIds.contains(id)) return;
    ccIds.contains(id) ? ccIds.remove(id) : ccIds.add(id);
    notifyListeners();
  }
}

/// 결재선 고르기 — 저장한 결재선 불러오기, 결재자 추가·순서 바꾸기·빼기, 참조자, "이 결재선 저장". 처음에는 서버가 추천한 결재선
/// (최근에 저장한 것 — 나중에 조직도 상위자)을 채운다.
class ApprovalLinePicker extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final ApprovalLineController controller;
  const ApprovalLinePicker({
    super.key,
    required this.api,
    required this.ctx,
    required this.controller,
  });

  @override
  State<ApprovalLinePicker> createState() => _ApprovalLinePickerState();
}

class _ApprovalLinePickerState extends State<ApprovalLinePicker> {
  List<ApprovalCandidate>? _candidates;
  List<ApprovalLine> _lines = const [];

  /// 조직도의 상위자 사슬로 미리 채운 결재자(서버 suggestApprovalLine의 source 'org') — 지금 결재자가 그대로일 때만 안내를 보인다.
  List<String>? _orgPrefill;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
    _load();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() => setState(() {});

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        widget.api.candidates(),
        widget.api.approvalLines(),
      ]);
      if (!mounted) return;
      final candidates = results[0] as List<ApprovalCandidate>;
      final lines = results[1] as ApprovalLines;
      final known = {for (final c in candidates) c.id};
      setState(() {
        _candidates = candidates;
        _lines = lines.lines;
      });
      if (widget.controller.approverIds.isEmpty) {
        final approvers = lines.suggestedApproverIds
            .where(known.contains)
            .toList();
        widget.controller.setLine(
          approvers,
          lines.suggestedCcIds.where(known.contains).toList(),
          lines.suggestedRoles,
        );
        // 조직도 상위자로 채웠으면 그 사실을 알려 준다 — 결재선을 손으로 바꾸면 안내는 사라진다.
        if (lines.suggestedSource == 'org' && approvers.isNotEmpty) {
          setState(() => _orgPrefill = List.of(approvers));
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  String _nameOf(String id) {
    for (final c in _candidates ?? const <ApprovalCandidate>[]) {
      if (c.id == id) return c.name;
    }
    return tr('(알 수 없음)');
  }

  Future<String?> _pickPerson({
    required String title,
    required Set<String> exclude,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => _PersonPickerDialog(
        title: title,
        candidates: [
          for (final c in _candidates ?? const <ApprovalCandidate>[])
            if (!exclude.contains(c.id)) c,
        ],
      ),
    );
  }

  Future<void> _saveLine() async {
    final c = widget.controller;
    if (c.approverIds.isEmpty) {
      showAppToast(context, tr('결재자를 먼저 고르세요.'));
      return;
    }
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(title: tr('결재선 저장'), label: tr('결재선 이름')),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    try {
      final line = await widget.api.saveApprovalLine(
        name: name.trim(),
        approverIds: c.approverIds,
        ccIds: c.ccIds,
        roles: c.roles,
      );
      if (!mounted) return;
      setState(() => _lines = [line, ..._lines]);
      showAppToast(context, tr('결재선을 저장했습니다.'));
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    }
  }

  Future<void> _deleteLine(ApprovalLine line) async {
    try {
      await widget.api.deleteApprovalLine(line.id);
      if (mounted) {
        setState(() => _lines = _lines.where((l) => l.id != line.id).toList());
      }
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final c = widget.controller;
    if (_error != null) {
      return Text(_error!, style: TextStyle(color: theme.colorScheme.error));
    }
    if (_candidates == null) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final taken = {...c.approverIds, ...c.ccIds};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(tr('결재선'), style: theme.textTheme.titleSmall),
            const Spacer(),
            if (_lines.isNotEmpty)
              PopupMenuButton<ApprovalLine>(
                key: const ValueKey('approval-line-load'),
                tooltip: tr('저장한 결재선'),
                onSelected: (line) =>
                    c.setLine(line.approverIds, line.ccIds, line.roles),
                itemBuilder: (_) => [
                  for (final line in _lines)
                    PopupMenuItem(
                      value: line,
                      child: Row(
                        children: [
                          Expanded(child: Text(line.name)),
                          IconButton(
                            tooltip: tr('지우기'),
                            icon: const Icon(Icons.close, size: 16),
                            onPressed: () {
                              Navigator.of(context).pop();
                              _deleteLine(line);
                            },
                          ),
                        ],
                      ),
                    ),
                ],
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Text(tr('불러오기 ▾')),
                ),
              ),
            TextButton(onPressed: _saveLine, child: Text(tr('저장'))),
          ],
        ),
        if (_orgPrefill != null && listEquals(_orgPrefill, c.approverIds))
          Padding(
            key: const ValueKey('approval-line-org-hint'),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              tr('조직도의 상위자 순서로 결재자를 채웠습니다. 필요하면 빼거나 바꾸세요.'),
              style: TextStyle(fontSize: 12, color: hint),
            ),
          ),
        if (c.approverIds.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              tr(
                '결재자를 순서대로 고르세요. 앞사람이 승인해야 다음 사람에게 넘어갑니다. 이름 옆 역할을 눌러 합의(이어진 합의는 동시에)·전결(승인하면 남은 결재 생략)로 바꿀 수 있습니다.',
              ),
              style: TextStyle(fontSize: 12, color: hint),
            ),
          ),
        for (final (i, id) in c.approverIds.indexed)
          Row(
            key: ValueKey('approval-line-approver-$id'),
            children: [
              CircleAvatar(
                radius: 11,
                child: Text(
                  '${c.stageNumbers[i]}',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(_nameOf(id))),
              ActionChip(
                key: ValueKey('approval-line-role-$id'),
                visualDensity: VisualDensity.compact,
                tooltip: tr('역할 바꾸기(결재 → 합의 → 전결)'),
                label: Text(
                  c.roleOf(id).label,
                  style: TextStyle(
                    fontSize: 12,
                    color: c.roleOf(id) == LineRole.approve
                        ? hint
                        : theme.colorScheme.primary,
                  ),
                ),
                onPressed: () => c.cycleRole(id),
              ),
              IconButton(
                tooltip: tr('위로'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_upward, size: 16),
                onPressed: i == 0 ? null : () => c.moveApprover(i, -1),
              ),
              IconButton(
                tooltip: tr('아래로'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_downward, size: 16),
                onPressed: i == c.approverIds.length - 1
                    ? null
                    : () => c.moveApprover(i, 1),
              ),
              IconButton(
                tooltip: tr('빼기'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 16),
                onPressed: () => c.removeApprover(id),
              ),
            ],
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('approval-line-add-approver'),
            onPressed: c.approverIds.length >= widget.ctx.approversMax
                ? null
                : () async {
                    final id = await _pickPerson(
                      title: tr('결재자 추가'),
                      exclude: taken,
                    );
                    if (id != null) c.addApprover(id);
                  },
            icon: const Icon(Icons.person_add_alt, size: 18),
            label: Text(
              tr('결재자 추가 ({c.approverIds.length}/{widget.ctx.approversMax})', {
                'c.approverIds.length': c.approverIds.length,
                'widget.ctx.approversMax': widget.ctx.approversMax,
              }),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(tr('참조'), style: TextStyle(color: hint)),
            for (final id in c.ccIds)
              InputChip(
                label: Text(_nameOf(id)),
                onDeleted: () => c.toggleCc(id),
              ),
            ActionChip(
              avatar: const Icon(Icons.add, size: 16),
              label: Text(tr('참조자')),
              onPressed: c.ccIds.length >= widget.ctx.ccMax
                  ? null
                  : () async {
                      final id = await _pickPerson(
                        title: tr('참조자 추가'),
                        exclude: taken,
                      );
                      if (id != null) c.toggleCc(id);
                    },
            ),
          ],
        ),
      ],
    );
  }
}

class _PersonPickerDialog extends StatefulWidget {
  final String title;
  final List<ApprovalCandidate> candidates;
  const _PersonPickerDialog({required this.title, required this.candidates});

  @override
  State<_PersonPickerDialog> createState() => _PersonPickerDialogState();
}

class _PersonPickerDialogState extends State<_PersonPickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final shown = [
      for (final c in widget.candidates)
        if (q.isEmpty ||
            c.name.toLowerCase().contains(q) ||
            c.username.toLowerCase().contains(q))
          c,
    ];
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: tr('이름·아이디로 찾기'),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: shown.isEmpty
                  ? Center(
                      child: Text(
                        tr('고를 수 있는 사람이 없습니다(정회원 이상만 결재선에 넣을 수 있습니다).'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Theme.of(context).hintColor),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final c in shown)
                          ListTile(
                            key: ValueKey('person-${c.id}'),
                            title: Text(c.name),
                            subtitle: Text(c.username),
                            onTap: () => Navigator.of(context).pop(c.id),
                          ),
                      ],
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
      ],
    );
  }
}

class _NameDialog extends StatefulWidget {
  final String title;
  final String label;
  const _NameDialog({required this.title, required this.label});

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _text,
      autofocus: true,
      maxLength: 30,
      decoration: InputDecoration(labelText: widget.label),
      onSubmitted: (v) => Navigator.of(context).pop(v),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(tr('취소')),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_text.text),
        child: Text(tr('확인')),
      ),
    ],
  );
}

// ── 신청 창 ─────────────────────────────────────────────────────────────

/// 신청 창의 공통 틀 — 내용 칸들([fields]) 아래에 사유·결재선, 아래에 올리기 단추. [submit]이 서버에 올리고 문서를 돌려준다.
class ApprovalRequestDialog extends StatefulWidget {
  final String title;
  final GroupwareApi api;
  final GroupwareContext ctx;
  final List<Widget> Function(void Function(VoidCallback) setDialogState)
  fields;
  final String bodyLabel;

  /// 사유 칸을 보일지 — 양식(approval_form_widgets.dart)은 내용을 칸으로 받아 이 칸을 숨긴다.
  final bool showBody;

  /// 칸이 덜 찼으면 문구(올리지 않는다), 다 찼으면 null.
  final String? Function() validate;
  final Future<ApprovalDocument> Function({
    required String? body,
    required List<String> approverIds,
    required List<String> ccIds,
    required Map<String, LineRole> roles,
  })
  submit;
  const ApprovalRequestDialog({
    super.key,
    required this.title,
    required this.api,
    required this.ctx,
    required this.fields,
    required this.validate,
    required this.submit,
    this.bodyLabel = '사유',
    this.showBody = true,
  });

  @override
  State<ApprovalRequestDialog> createState() => _ApprovalRequestDialogState();
}

class _ApprovalRequestDialogState extends State<ApprovalRequestDialog> {
  final _line = ApprovalLineController();
  final _body = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _line.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final invalid = widget.validate();
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    if (_line.approverIds.isEmpty) {
      setState(() => _error = tr('결재자를 한 명 이상 고르세요.'));
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final doc = await widget.submit(
        body: _body.text.trim().isEmpty ? null : _body.text.trim(),
        approverIds: List.of(_line.approverIds),
        ccIds: List.of(_line.ccIds),
        roles: Map.of(_line.roles),
      );
      if (mounted) Navigator.of(context).pop(doc);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ...widget.fields(setState),
              const SizedBox(height: 12),
              if (widget.showBody)
                TextField(
                  key: const ValueKey('approval-request-body'),
                  controller: _body,
                  minLines: 2,
                  maxLines: 5,
                  maxLength: 2000,
                  decoration: InputDecoration(
                    labelText: tr(widget.bodyLabel),
                    border: const OutlineInputBorder(),
                  ),
                ),
              const SizedBox(height: 8),
              ApprovalLinePicker(
                api: widget.api,
                ctx: widget.ctx,
                controller: _line,
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
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
        FilledButton(
          key: const ValueKey('approval-request-submit'),
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(tr('결재 올리기')),
        ),
      ],
    );
  }
}

/// 날짜 고르기 단추.
class ApprovalDateField extends StatelessWidget {
  final String label;
  final String? value;
  final ValueChanged<String> onChanged;
  final DateTime? lastDate;
  const ApprovalDateField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.lastDate,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      icon: const Icon(Icons.event, size: 18),
      label: Text(value == null ? label : '$label ${shortDateText(value!)}'),
      onPressed: () async {
        final now = DateTime.now();
        final initial = value == null ? now : DateTime.parse(value!);
        final picked = await showDatePicker(
          context: context,
          initialDate: initial,
          firstDate: DateTime(now.year - 1),
          lastDate: lastDate ?? DateTime(now.year + 2),
        );
        if (picked != null) onChanged(dateKeyOf(picked));
      },
    );
  }
}

/// 휴가 신청 — 종류, 기간(반차는 하루), 사유, 결재선. [balance]가 있으면 남은 연차를 보여 준다. 올렸으면 그 문서.
Future<ApprovalDocument?> showLeaveRequestDialog(
  BuildContext context, {
  required GroupwareApi api,
  required GroupwareContext ctx,
  LeaveBalance? balance,
}) {
  // 관리자가 끈 종류는 고르지 못한다(groupwareOptions.js — 예전 신청의 이름을 보이려고 목록에는 남는다).
  final types = ctx.enabledLeaveTypes;
  var type = types.isNotEmpty ? types.first.key : 'annual';
  String? start;
  String? end;
  return showDialog<ApprovalDocument>(
    context: context,
    builder: (_) => ApprovalRequestDialog(
      title: tr('휴가 신청'),
      api: api,
      ctx: ctx,
      fields: (setState) {
        final info = ctx.leaveType(type);
        return [
          if (balance != null)
            Text(
              balance.known
                  ? tr('남은 연차 {p0}{p1}', {
                      'p0': halfDaysText(
                        (balance.remainingHalfDays ?? 0) -
                            balance.pendingHalfDays,
                      ),
                      'p1': balance.pendingHalfDays > 0
                          ? tr(' (결재 중 {p0} 제외)', {
                              'p0': halfDaysText(balance.pendingHalfDays),
                            })
                          : '',
                    })
                  : tr('입사일이 등록되지 않아 남은 연차를 계산할 수 없습니다(관리자에게 등록을 요청하세요).'),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).hintColor,
              ),
            ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            key: const ValueKey('leave-type'),
            initialValue: type,
            decoration: InputDecoration(
              labelText: tr('휴가 종류'),
              border: OutlineInputBorder(),
            ),
            items: [
              for (final t in types)
                DropdownMenuItem(
                  value: t.key,
                  child: Text(
                    t.deducts
                        ? t.label
                        : tr('{t.label} (연차 차감 없음)', {'t.label': t.label}),
                  ),
                ),
            ],
            onChanged: (v) => setState(() {
              type = v ?? type;
              if (ctx.leaveType(type)?.half ?? false) end = start;
            }),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              ApprovalDateField(
                label: info?.half ?? false ? tr('날짜') : tr('시작'),
                value: start,
                onChanged: (v) => setState(() {
                  start = v;
                  final keepEnd =
                      end != null &&
                      !(info?.half ?? false) &&
                      end!.compareTo(v) >= 0;
                  if (!keepEnd) end = v;
                }),
              ),
              if (!(info?.half ?? false))
                ApprovalDateField(
                  label: tr('끝'),
                  value: end,
                  onChanged: (v) => setState(() => end = v),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            tr('주말·공휴일은 빼고 근무일만 셉니다.'),
            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
          ),
        ];
      },
      validate: () {
        if (start == null) return tr('휴가 날짜를 고르세요.');
        if (end != null && end!.compareTo(start!) < 0) {
          return tr('끝나는 날이 시작하는 날보다 앞입니다.');
        }
        return null;
      },
      submit:
          ({
            required body,
            required approverIds,
            required ccIds,
            required roles,
          }) => api.submit(
            kind: ApprovalKind.leave,
            fields: {
              'leaveType': type,
              'startDate': start,
              'endDate': end ?? start,
            },
            body: body,
            approverIds: approverIds,
            ccIds: ccIds,
            roles: roles,
          ),
    ),
  );
}

/// 지출 결재 — 금액(원), 분류, 쓴 날, 영수증(최대 [GroupwareContext.attachmentsMax]개), 내용, 결재선.
Future<ApprovalDocument?> showExpenseRequestDialog(
  BuildContext context, {
  required GroupwareApi api,
  required GroupwareContext ctx,
  required Session session,
}) {
  final amount = TextEditingController();
  final title = TextEditingController();
  var category = ctx.expenseCategories.isNotEmpty
      ? ctx.expenseCategories.first
      : tr('기타');
  var spentOn = ctx.today;
  final receipts = <({String url, String name, int size, String? mimeType})>[];
  var uploading = false;
  return showDialog<ApprovalDocument>(
    context: context,
    builder: (dialogContext) => ApprovalRequestDialog(
      title: tr('지출 결재'),
      api: api,
      ctx: ctx,
      bodyLabel: tr('내용(어디에 무엇을)'),
      fields: (setState) => [
        TextField(
          controller: title,
          maxLength: 100,
          decoration: InputDecoration(
            labelText: tr('제목(비우면 자동)'),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          key: const ValueKey('expense-amount'),
          controller: amount,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: tr('금액(원)'),
            border: OutlineInputBorder(),
            suffixText: tr('원'),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: category,
                decoration: InputDecoration(
                  labelText: tr('분류'),
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final c in ctx.expenseCategories)
                    DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: (v) => setState(() => category = v ?? category),
              ),
            ),
            const SizedBox(width: 8),
            ApprovalDateField(
              label: tr('쓴 날'),
              value: spentOn,
              lastDate: DateTime.now(),
              onChanged: (v) => setState(() => spentOn = v),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final r in receipts)
              InputChip(
                label: Text(r.name, overflow: TextOverflow.ellipsis),
                onDeleted: () => setState(() => receipts.remove(r)),
              ),
            ActionChip(
              avatar: uploading
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.attach_file, size: 16),
              label: Text(
                tr('영수증 첨부 ({receipts.length}/{ctx.attachmentsMax})', {
                  'receipts.length': receipts.length,
                  'ctx.attachmentsMax': ctx.attachmentsMax,
                }),
              ),
              onPressed: uploading || receipts.length >= ctx.attachmentsMax
                  ? null
                  : () async {
                      final picked = await FilePicker.pickFiles(
                        allowMultiple: true,
                      );
                      final files = [
                        for (final f in picked?.files ?? const <PlatformFile>[])
                          if (f.path != null || f.bytes != null) f.xFile,
                      ].take(ctx.attachmentsMax - receipts.length).toList();
                      if (files.isEmpty) return;
                      setState(() => uploading = true);
                      try {
                        for (final f in files) {
                          final up = await session.api!.uploadFile(f);
                          setState(
                            () => receipts.add((
                              url: up.url,
                              name: up.fileName,
                              size: up.size,
                              mimeType: up.mimeType,
                            )),
                          );
                        }
                      } catch (e) {
                        if (dialogContext.mounted) {
                          showAppToast(
                            dialogContext,
                            tr('첨부 실패: {e}', {'e': e}),
                          );
                        }
                      } finally {
                        setState(() => uploading = false);
                      }
                    },
            ),
          ],
        ),
      ],
      validate: () {
        final value = int.tryParse(amount.text.replaceAll(',', '').trim());
        if (value == null || value <= 0) return tr('금액을 원 단위 숫자로 넣으세요.');
        if (uploading) return tr('영수증을 올리는 중입니다. 잠시 뒤 다시 누르세요.');
        return null;
      },
      submit:
          ({
            required body,
            required approverIds,
            required ccIds,
            required roles,
          }) => api.submit(
            kind: ApprovalKind.expense,
            fields: {
              'amount': int.parse(amount.text.replaceAll(',', '').trim()),
              'category': category,
              'spentOn': spentOn,
              'attachments': [
                for (final r in receipts)
                  {
                    'fileUrl': r.url,
                    'fileName': r.name,
                    'fileSize': r.size,
                    'mimeType': r.mimeType,
                  },
              ],
            },
            title: title.text.trim().isEmpty ? null : title.text.trim(),
            body: body,
            approverIds: approverIds,
            ccIds: ccIds,
            roles: roles,
          ),
    ),
  ).whenComplete(() {
    amount.dispose();
    title.dispose();
  });
}

/// 'HH:MM'인지.
bool isHmText(String value) {
  final m = RegExp(r'^(\d{2}):(\d{2})$').firstMatch(value.trim());
  return m != null &&
      int.parse(m.group(1)!) < 24 &&
      int.parse(m.group(2)!) < 60;
}

/// 근태 수정 — 고칠 날의 출근·퇴근 시각과 사유, 결재선. 승인되면 기록이 바뀌고 처음 값은 남는다.
Future<ApprovalDocument?> showAttendanceCorrectionDialog(
  BuildContext context, {
  required GroupwareApi api,
  required GroupwareContext ctx,
  required String workDate,
  AttendanceRecord? record,
}) {
  final clockIn = TextEditingController(
    text: record?.clockInAt == null
        ? minutesText(ctx.workStart)
        : clockText(record!.clockInAt),
  );
  final clockOut = TextEditingController(
    text: record?.clockOutAt == null
        ? minutesText(ctx.workEnd)
        : clockText(record!.clockOutAt),
  );
  return showDialog<ApprovalDocument>(
    context: context,
    builder: (_) => ApprovalRequestDialog(
      title: tr('근태 수정 ({p0})', {'p0': shortDateText(workDate)}),
      api: api,
      ctx: ctx,
      fields: (setState) => [
        Text(
          record == null
              ? tr('이날은 출퇴근 기록이 없습니다. 실제 출근·퇴근 시각을 넣으세요.')
              : tr('지금 기록: 출근 {p0} · 퇴근 {p1}', {
                  'p0': clockText(record.clockInAt),
                  'p1': clockText(record.clockOutAt),
                }),
          style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('attendance-fix-in'),
                controller: clockIn,
                decoration: InputDecoration(
                  labelText: tr('출근 (HH:MM)'),
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                key: const ValueKey('attendance-fix-out'),
                controller: clockOut,
                decoration: InputDecoration(
                  labelText: tr('퇴근 (HH:MM, 비우면 그대로)'),
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
      ],
      validate: () {
        if (!isHmText(clockIn.text)) {
          return tr('출근 시각을 HH:MM으로 넣으세요(예: 09:00).');
        }
        if (clockOut.text.trim().isNotEmpty && !isHmText(clockOut.text)) {
          return tr('퇴근 시각을 HH:MM으로 넣으세요.');
        }
        return null;
      },
      submit:
          ({
            required body,
            required approverIds,
            required ccIds,
            required roles,
          }) => api.submit(
            kind: ApprovalKind.attendance,
            fields: {
              'workDate': workDate,
              'clockIn': clockIn.text.trim(),
              'clockOut': clockOut.text.trim().isEmpty
                  ? null
                  : clockOut.text.trim(),
            },
            body: body,
            approverIds: approverIds,
            ccIds: ccIds,
            roles: roles,
          ),
    ),
  ).whenComplete(() {
    clockIn.dispose();
    clockOut.dispose();
  });
}

/// 신청이 끝났을 때 안내.
void toastSubmitted(BuildContext context, ApprovalDocument? doc) {
  if (doc == null) return;
  final first = doc.currentStep?.approverName;
  showAppToast(
    context,
    first == null
        ? tr('결재를 올렸습니다.')
        : tr('결재를 올렸습니다. {first}님이 결재할 차례입니다.', {'first': first}),
  );
}
