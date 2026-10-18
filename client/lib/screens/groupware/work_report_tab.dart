import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../models/groupware_forms.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import 'groupware_screen.dart' show GroupwareChanges;
import '../../l10n/tr.dart';

/// 그룹웨어 "업무일지" 탭 — 일일·주간 업무보고(서버 groupwareReports.js). "내 보고"에 한 일·할 일·이슈를 쓰고(조직도 상위자에게
/// 간다 — 위에 받는 사람이 보인다), "팀 현황"에서 내가 검토하는 사람들의 보고를 읽고 댓글을 단다(안 쓴 사람이 위로). 주간 보고는
/// 그 주의 일일 보고를 "한 일"로 불러올 수 있다.

class WorkReportTab extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final GroupwareChanges changes;
  final Session session;
  const WorkReportTab({
    super.key,
    required this.api,
    required this.ctx,
    required this.changes,
    required this.session,
  });

  @override
  State<WorkReportTab> createState() => _WorkReportTabState();
}

class _WorkReportTabState extends State<WorkReportTab> {
  WorkReportKind _kind = WorkReportKind.daily;
  bool _team = false;

  /// 보고 있는 기간 시작일 — null이면 오늘·이번 주.
  String? _period;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<WorkReportKind>(
                key: const ValueKey('report-kind'),
                showSelectedIcon: false,
                segments: [
                  for (final k in WorkReportKind.values)
                    ButtonSegment(value: k, label: Text(k.label)),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() {
                  _kind = s.first;
                  _period = null;
                }),
              ),
              SegmentedButton<bool>(
                key: const ValueKey('report-view'),
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: false, label: Text(tr('내 보고'))),
                  ButtonSegment(value: true, label: Text(tr('팀 현황'))),
                ],
                selected: {_team},
                onSelectionChanged: (s) => setState(() => _team = s.first),
              ),
            ],
          ),
        ),
        Expanded(
          child: _team
              ? _TeamReports(
                  key: ValueKey('team-${_kind.wire}'),
                  api: widget.api,
                  changes: widget.changes,
                  kind: _kind,
                  period: _period,
                  onPeriod: (p) => setState(() => _period = p),
                )
              : _MyReport(
                  key: ValueKey('mine-${_kind.wire}-$_period'),
                  api: widget.api,
                  changes: widget.changes,
                  kind: _kind,
                  period: _period,
                  onPeriod: (p) => setState(() => _period = p),
                ),
        ),
      ],
    );
  }
}

/// 기간 넘기기 ◀ 10/07(수) ▶ — 아직 오지 않은 기간으로는 못 간다.
class _PeriodBar extends StatelessWidget {
  final WorkReportKind kind;
  final String start;
  final String end;
  final String current;
  final ValueChanged<String> onPeriod;
  const _PeriodBar({
    required this.kind,
    required this.start,
    required this.end,
    required this.current,
    required this.onPeriod,
  });

  @override
  Widget build(BuildContext context) {
    final isCurrent = start == current;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          key: const ValueKey('report-prev'),
          tooltip: kind == WorkReportKind.weekly ? tr('지난주') : tr('전날'),
          onPressed: () => onPeriod(shiftPeriod(start, kind, -1)),
          icon: const Icon(Icons.chevron_left),
        ),
        Text(
          periodLabel(kind, start, end) +
              (isCurrent
                  ? (kind == WorkReportKind.weekly
                        ? tr(' · 이번 주')
                        : tr(' · 오늘'))
                  : ''),
          key: const ValueKey('report-period'),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        IconButton(
          key: const ValueKey('report-next'),
          tooltip: kind == WorkReportKind.weekly ? tr('다음 주') : tr('다음 날'),
          onPressed: isCurrent
              ? null
              : () => onPeriod(shiftPeriod(start, kind, 1)),
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }
}

// ── 내 보고 ─────────────────────────────────────────────────────────────

class _MyReport extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareChanges changes;
  final WorkReportKind kind;
  final String? period;
  final ValueChanged<String> onPeriod;
  const _MyReport({
    super.key,
    required this.api,
    required this.changes,
    required this.kind,
    required this.period,
    required this.onPeriod,
  });

  @override
  State<_MyReport> createState() => _MyReportState();
}

class _MyReportState extends State<_MyReport> {
  MyWorkReportPage? _page;
  WorkReport? _detail;
  String? _error;
  final _done = TextEditingController();
  final _plan = TextEditingController();
  final _issues = TextEditingController();
  bool _saving = false;

  /// 입력칸을 서버 값으로 채운 적이 있는지 — 쓰는 중에 다른 기기의 변경(groupware:changed)이 와도 지우지 않게.
  bool _filled = false;

  @override
  void initState() {
    super.initState();
    widget.changes.addListener(_reload);
    _load();
  }

  @override
  void dispose() {
    widget.changes.removeListener(_reload);
    _done.dispose();
    _plan.dispose();
    _issues.dispose();
    super.dispose();
  }

  void _reload() => _load(keepInputs: true);

  Future<void> _load({bool keepInputs = false}) async {
    try {
      final page = await widget.api.myWorkReport(
        widget.kind,
        periodStart: widget.period,
      );
      final detail = page.report == null
          ? null
          : await widget.api.workReport(page.report!.id);
      if (!mounted) return;
      setState(() {
        _page = page;
        _detail = detail;
        _error = null;
        if (!keepInputs || !_filled) {
          _done.text = page.report?.done ?? '';
          _plan.text = page.report?.plan ?? '';
          _issues.text = page.report?.issues ?? '';
          _filled = true;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _save() async {
    final page = _page!;
    setState(() => _saving = true);
    try {
      await widget.api.saveWorkReport(
        kind: widget.kind,
        periodStart: page.periodStart,
        done: _done.text,
        plan: _plan.text,
        issues: _issues.text,
      );
      if (!mounted) return;
      showAppToast(
        context,
        page.report == null ? tr('업무일지를 올렸습니다.') : tr('업무일지를 고쳤습니다.'),
      );
      _filled = false;
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 주간 보고 — 그 주의 일일 보고를 "한 일"로 불러온다(이미 쓴 글 뒤에 붙인다).
  Future<void> _importDaily() async {
    final page = _page!;
    try {
      final daily = await widget.api.myDailyReports(
        page.periodStart,
        page.periodEnd,
      );
      if (!mounted) return;
      if (daily.isEmpty) {
        showAppToast(context, tr('이 주에 쓴 일일 보고가 없습니다.'));
        return;
      }
      final lines = [
        for (final r in daily)
          if ((r.done ?? '').trim().isNotEmpty)
            '[${periodLabel(WorkReportKind.daily, r.periodStart, r.periodEnd)}] ${r.done!.trim()}',
      ];
      setState(() {
        final existing = _done.text.trim();
        _done.text = [if (existing.isNotEmpty) existing, ...lines].join('\n');
      });
    } catch (e) {
      if (mounted) showAppToast(context, '$e');
    }
  }

  Future<void> _delete() async {
    final report = _page?.report;
    if (report == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('업무일지 삭제')),
        content: Text(tr('이 업무일지와 댓글을 지울까요?')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: Text(tr('취소')),
          ),
          TextButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: Text(tr('삭제')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.api.deleteWorkReport(report.id);
      _filled = false;
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '$e');
    }
  }

  Widget _field(
    String label,
    TextEditingController c,
    String key, {
    String? hint,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      key: ValueKey(key),
      controller: c,
      minLines: 3,
      maxLines: 10,
      maxLength: 5000,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        alignLabelWithHint: true,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final page = _page;
    if (page == null) {
      return Center(
        child: _error != null
            ? Text(_error!)
            : const CircularProgressIndicator(),
      );
    }
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final report = page.report;
    final detail = _detail;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        _PeriodBar(
          kind: page.kind,
          start: page.periodStart,
          end: page.periodEnd,
          current: page.currentPeriodStart,
          onPeriod: widget.onPeriod,
        ),
        Text(
          page.reviewers.isEmpty
              ? tr('받는 사람: 그룹웨어 관리자(조직도에 상위자가 없습니다)')
              : tr('받는 사람: {p0}', {
                  'p0': page.reviewers.map((r) => r.name).join(', '),
                }),
          key: const ValueKey('report-reviewers'),
          style: TextStyle(fontSize: 13, color: hint),
        ),
        if (report != null) ...[
          const SizedBox(height: 4),
          Text(
            report.reads.isEmpty
                ? tr('아직 아무도 확인하지 않았습니다.')
                : tr('확인: {p0}', {
                    'p0': report.reads.map((r) => r.name).join(', '),
                  }),
            key: const ValueKey('report-reads'),
            style: TextStyle(
              fontSize: 13,
              color: report.reads.isEmpty ? hint : Colors.green.shade700,
            ),
          ),
        ],
        const SizedBox(height: 12),
        _field(tr('한 일'), _done, 'report-done'),
        if (page.kind == WorkReportKind.weekly)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('report-import-daily'),
              onPressed: _importDaily,
              icon: const Icon(Icons.playlist_add, size: 18),
              label: Text(tr('이번 주 일일 보고 불러오기')),
            ),
          ),
        _field(tr('할 일'), _plan, 'report-plan'),
        _field(tr('이슈·건의(선택)'), _issues, 'report-issues'),
        Row(
          children: [
            FilledButton(
              key: const ValueKey('report-save'),
              onPressed: _saving ? null : _save,
              child: Text(report == null ? tr('올리기') : tr('고치기')),
            ),
            if (report != null) ...[
              const SizedBox(width: 8),
              TextButton(
                key: const ValueKey('report-delete'),
                onPressed: _delete,
                child: Text(tr('삭제')),
              ),
            ],
          ],
        ),
        if (detail != null && detail.comments.isNotEmpty) ...[
          const Divider(height: 32),
          Text(
            tr('댓글 {detail.comments.length}', {
              'detail.comments.length': detail.comments.length,
            }),
            style: theme.textTheme.titleSmall,
          ),
          for (final c in detail.comments) _CommentLine(c),
        ],
      ],
    );
  }
}

class _CommentLine extends StatelessWidget {
  final WorkReportComment c;
  const _CommentLine(this.c);

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final t = c.createdAt;
    return Padding(
      key: ValueKey('report-comment-${c.id}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${c.userName} · ${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
            style: TextStyle(fontSize: 12, color: hint),
          ),
          Text(c.text),
        ],
      ),
    );
  }
}

// ── 팀 현황 ─────────────────────────────────────────────────────────────

class _TeamReports extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareChanges changes;
  final WorkReportKind kind;
  final String? period;
  final ValueChanged<String> onPeriod;
  const _TeamReports({
    super.key,
    required this.api,
    required this.changes,
    required this.kind,
    required this.period,
    required this.onPeriod,
  });

  @override
  State<_TeamReports> createState() => _TeamReportsState();
}

class _TeamReportsState extends State<_TeamReports> {
  WorkReportTeam? _team;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.changes.addListener(_load);
    _load();
  }

  @override
  void didUpdateWidget(covariant _TeamReports old) {
    super.didUpdateWidget(old);
    if (old.period != widget.period) _load();
  }

  @override
  void dispose() {
    widget.changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final team = await widget.api.teamWorkReports(
        widget.kind,
        periodStart: widget.period,
      );
      if (mounted) setState(() => _team = team);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final team = _team;
    if (team == null) {
      return Center(
        child: _error != null
            ? Text(_error!)
            : const CircularProgressIndicator(),
      );
    }
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    return ListView(
      children: [
        _PeriodBar(
          kind: team.kind,
          start: team.periodStart,
          end: team.periodEnd,
          current: team.currentPeriodStart,
          onPeriod: widget.onPeriod,
        ),
        if (!team.canReview)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              tr('검토할 사람이 없습니다. 조직도에서 나를 상위자로 둔 사람의 업무일지가 여기에 모입니다.'),
              textAlign: TextAlign.center,
              style: TextStyle(color: hint),
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              tr('제출 {team.submittedCount}/{team.roster.length}', {
                'team.submittedCount': team.submittedCount,
                'team.roster.length': team.roster.length,
              }),
              key: const ValueKey('team-report-count'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          for (final r in team.roster)
            ListTile(
              key: ValueKey('team-report-${r.userId}'),
              enabled: r.report != null,
              title: Text(r.name),
              subtitle: r.report == null
                  ? Text(
                      tr('아직 안 썼습니다'),
                      style: TextStyle(color: theme.colorScheme.error),
                    )
                  : Text(
                      (r.report!.done ?? r.report!.plan ?? '').replaceAll(
                        '\n',
                        ' ',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
              trailing: r.report == null
                  ? null
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (r.report!.commentCount > 0) ...[
                          Icon(
                            Icons.mode_comment_outlined,
                            size: 14,
                            color: hint,
                          ),
                          Text(
                            ' ${r.report!.commentCount}  ',
                            style: TextStyle(fontSize: 12, color: hint),
                          ),
                        ],
                        Icon(
                          r.report!.readByMe
                              ? Icons.done_all
                              : Icons.fiber_new_outlined,
                          size: 18,
                          color: r.report!.readByMe
                              ? Colors.green.shade700
                              : theme.colorScheme.primary,
                        ),
                      ],
                    ),
              onTap: r.report == null
                  ? null
                  : () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => WorkReportScreen(
                            api: widget.api,
                            reportId: r.report!.id,
                          ),
                        ),
                      );
                      _load();
                    },
            ),
        ],
      ],
    );
  }
}

/// 다른 사람의 업무일지 — 본문과 댓글, 댓글 쓰기(연 순간 서버가 "확인함"을 남긴다).
class WorkReportScreen extends StatefulWidget {
  final GroupwareApi api;
  final String reportId;
  const WorkReportScreen({
    super.key,
    required this.api,
    required this.reportId,
  });

  @override
  State<WorkReportScreen> createState() => _WorkReportScreenState();
}

class _WorkReportScreenState extends State<WorkReportScreen> {
  WorkReport? _r;
  String? _error;
  final _comment = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await widget.api.workReport(widget.reportId);
      if (mounted) setState(() => _r = r);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _send() async {
    final text = _comment.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.api.commentWorkReport(widget.reportId, text);
      _comment.clear();
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Widget _section(String label, String? text) {
    if (text == null || text.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          SelectableText(text),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          r == null
              ? tr('업무일지')
              : '${r.userName} · ${r.kind.label} ${periodLabel(r.kind, r.periodStart, r.periodEnd)}',
        ),
      ),
      body: r == null
          ? Center(
              child: _error != null
                  ? Text(_error!)
                  : const CircularProgressIndicator(),
            )
          : Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _section(tr('한 일'), r.done),
                      _section(tr('할 일'), r.plan),
                      _section(tr('이슈·건의'), r.issues),
                      const Divider(),
                      Text(
                        tr('댓글 {r.comments.length}', {
                          'r.comments.length': r.comments.length,
                        }),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      for (final c in r.comments) _CommentLine(c),
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const ValueKey('report-comment-input'),
                            controller: _comment,
                            maxLength: 1000,
                            decoration: InputDecoration(
                              hintText: tr('댓글'),
                              isDense: true,
                              counterText: '',
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (_) => _send(),
                          ),
                        ),
                        IconButton(
                          key: const ValueKey('report-comment-send'),
                          tooltip: tr('보내기'),
                          onPressed: _sending ? null : _send,
                          icon: const Icon(Icons.send),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
