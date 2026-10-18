import 'dart:async' show Timer;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import 'line_rule_text.dart';
import '../../l10n/tr.dart';

/// 결재선 — 결재자(순서대로)·결재자마다의 역할(결재·합의·전결·후결)과 참조자. 신청 창과 결재선 선택기([ApprovalLinePicker])가 같이 본다.
class ApprovalLineController extends ChangeNotifier {
  final List<String> approverIds = [];
  final List<String> ccIds = [];

  /// 결재가 아닌 칸의 역할 — 이어진 합의는 한 단계(동시에 차례), 전결은 한 명, 후결은 맨 뒤에만(이어진 후결도 한 단계).
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
    // 후결 칸은 맨 뒤로(순서는 지킨다) — 저장한 결재선·추천은 이미 그렇지만 예전 것이 섞여도 서버가 거르지 않게.
    final posts = approverIds.where(isPost).toList();
    if (posts.isNotEmpty) {
      approverIds
        ..removeWhere(isPost)
        ..addAll(posts);
    }
    notifyListeners();
  }

  LineRole roleOf(String id) => roles[id] ?? LineRole.approve;

  /// 후결 칸인지.
  bool isPost(String id) => roleOf(id) == LineRole.post;

  /// 처음 후결 칸의 자리(없으면 결재자 수 — 새 결재자는 여기 앞에 넣는다).
  int get _firstPostIndex {
    final i = approverIds.indexWhere(isPost);
    return i < 0 ? approverIds.length : i;
  }

  /// 역할을 다음 것으로(결재 → 합의 → 전결 → 후결 → 결재). 전결은 한 명만이라 다른 사람의 전결은 결재로 돌린다.
  ///
  /// 후결은 결재선 맨 뒤에만(서버 validateApprovalLine) — 후결이 되는 사람은 다른 후결 칸 뒤, 맨 끝으로 옮기고, 후결에서 결재로
  /// 돌아갈 때는 자리를 그대로 둔다(맨 앞 후결 칸이라 순서가 깨지지 않는다 — 가운데 후결이면 후결 칸들 앞으로 옮긴다). 그 사람 말고는
  /// 후결 아닌 결재자가 없으면(혼자거나 모두 후결) 후결은 건너뛰고 그다음 역할로 — 이때 true를 돌려 부른 쪽이 안내를 띄운다.
  /// [allowFinal]이 false면(전결 규정이 맞는 문서 — 전결은 올릴 때 서버가 정한다) 전결도 건너뛴다.
  bool cycleRole(String id, {bool allowFinal = true}) {
    var next = roleOf(id).next;
    var postRefused = false;
    if (next == LineRole.finalApprove && !allowFinal) next = next.next;
    if (next == LineRole.post &&
        !approverIds.any((o) => o != id && !isPost(o))) {
      postRefused = true;
      next = next.next;
    }
    if (next == LineRole.finalApprove) {
      roles.removeWhere((_, r) => r == LineRole.finalApprove);
    }
    final wasPost = isPost(id);
    if (next == LineRole.approve) {
      roles.remove(id);
    } else {
      roles[id] = next;
    }
    if (next == LineRole.post) {
      // 맨 끝(다른 후결 칸 뒤)으로.
      approverIds
        ..remove(id)
        ..add(id);
    } else if (wasPost) {
      // 후결에서 벗어나면 후결 칸들 바로 앞으로(이미 거기면 그대로).
      approverIds.remove(id);
      approverIds.insert(_firstPostIndex, id);
    }
    notifyListeners();
    return postRefused;
  }

  /// 결재자마다의 단계 번호(1부터) — 이어진 합의 칸, 이어진 후결 칸은 같은 번호(서버 approvalRules.js validateApprovalLine과 같은 규칙).
  List<int> get stageNumbers {
    final out = <int>[];
    var stage = 0;
    for (final (i, id) in approverIds.indexed) {
      final role = roleOf(id);
      final shared = role == LineRole.agree || role == LineRole.post;
      if (!(shared && i > 0 && roleOf(approverIds[i - 1]) == role)) {
        stage += 1;
      }
      out.add(stage);
    }
    return out;
  }

  /// 결재자를 더한다 — 후결 칸이 있으면 그 앞에(후결은 맨 뒤에만).
  void addApprover(String id) {
    if (approverIds.contains(id)) return;
    ccIds.remove(id);
    approverIds.insert(_firstPostIndex, id);
    notifyListeners();
  }

  void removeApprover(String id) {
    approverIds.remove(id);
    roles.remove(id);
    notifyListeners();
  }

  /// [index]번째 결재자를 [delta]만큼 옮길 수 있는지 — 끝을 넘거나, 후결 칸과 후결 아닌 칸이 자리를 바꾸면(후결이 앞에 오면) 안 된다.
  bool canMove(int index, int delta) {
    final to = index + delta;
    if (index < 0 || index >= approverIds.length) return false;
    if (to < 0 || to >= approverIds.length) return false;
    return isPost(approverIds[index]) == isPost(approverIds[to]);
  }

  /// [index]번째 결재자를 [delta]만큼 옮긴다(위로 -1, 아래로 +1). 후결 칸의 앞뒤 경계는 넘지 않는다([canMove]).
  void moveApprover(int index, int delta) {
    if (!canMove(index, delta)) return;
    final id = approverIds.removeAt(index);
    approverIds.insert(index + delta, id);
    notifyListeners();
  }

  void toggleCc(String id) {
    if (approverIds.contains(id)) return;
    ccIds.contains(id) ? ccIds.remove(id) : ccIds.add(id);
    notifyListeners();
  }
}

/// 결재선 고르기의 전결 규정 안내 — "전결 규정: 팀장 이상의 첫 결재자가 전결합니다 (100만 원 이상 문서) — 올리면 저절로
/// 정해집니다." 뒤에, 역할 칩으로는 전결을 고를 수 없다는 말.
String finalRuleHintText(ApprovalFinalRule rule) {
  final amount = rule.minAmount == null
      ? ''
      : tr(' ({won} 이상 문서)', {'won': wonText(rule.minAmount!)});
  final main = tr(
    '전결 규정: {position} 이상의 첫 결재자가 전결합니다{amount} — 올리면 저절로 정해집니다.',
    {'position': rule.positionLabel, 'amount': amount},
  );
  return '$main ${tr('역할을 눌러도 전결은 고를 수 없습니다.')}';
}

/// 결재선 고르기 — 저장한 결재선 불러오기, 결재자 추가·순서 바꾸기·빼기, 참조자, "이 결재선 저장". 처음에는 서버가 추천한 결재선
/// (결재선 규칙 → 최근에 저장한 것 → 조직도 상위자, 서버 suggestApprovalLine)을 채운다. [kind]·[templateId]·금액([amountOf])을 주면
/// 그 문서에 맞는 결재선 규칙(서버 approvalLineRules.js)대로 추천받고, 금액이 바뀌면([amountChanges]) 잠시 뒤 다시 받는다 — 결재선을
/// 손으로 고치지 않았으면 새 추천으로 바꾸고, 고쳤으면 고친 것을 지키고 "다시 채우기"만 보인다.
class ApprovalLinePicker extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final ApprovalLineController controller;

  /// 결재 종류([ApprovalKind.wire]) — 주면 서버가 그 종류의 결재선 규칙으로 추천한다(없으면 예전처럼 규칙 없이).
  final String? kind;

  /// 관리자가 만든 양식(종류 'form')의 양식 id — 그 양식에만 건 규칙을 고르게.
  final String? templateId;

  /// 지금 문서 금액(원, 모르거나 비었으면 null) — 지출은 금액, 기안은 예산, 출장은 예상 경비, 구매는 품목 합계, 양식은 금액·품목 칸의 합.
  final int? Function()? amountOf;

  /// 금액이 바뀌었을 수 있을 때 알린다(입력칸 컨트롤러·양식 값) — 실제 금액이 바뀌었을 때만 다시 받는다.
  final Listenable? amountChanges;
  const ApprovalLinePicker({
    super.key,
    required this.api,
    required this.ctx,
    required this.controller,
    this.kind,
    this.templateId,
    this.amountOf,
    this.amountChanges,
  });

  @override
  State<ApprovalLinePicker> createState() => _ApprovalLinePickerState();
}

class _ApprovalLinePickerState extends State<ApprovalLinePicker> {
  /// 금액을 바꾼 뒤 이만큼 더 안 바뀌면 추천을 다시 받는다(글자마다 부르지 않게).
  static const _refetchDelay = Duration(milliseconds: 600);

  List<ApprovalCandidate>? _candidates;
  List<ApprovalLine> _lines = const [];

  /// 조직도의 상위자 사슬로 미리 채운 결재자(서버 suggestApprovalLine의 source 'org') — 지금 결재자가 그대로일 때만 안내를 보인다.
  List<String>? _orgPrefill;
  String? _error;

  /// 마지막으로 받은 추천(규칙 안내·"다시 채우기"에 쓴다).
  ApprovalLines? _suggestion;

  /// 마지막 추천을 채운 뒤 결재선을 손으로 고쳤는지 — 고쳤으면 새 추천이 와도 덮어쓰지 않는다.
  bool _touched = false;

  /// 추천을 채우는 중(controller.setLine) — 이때 바뀐 것은 손으로 고친 것이 아니다.
  bool _applying = false;

  /// 손으로 고친 뒤 추천이 바뀌었다 — "규칙이 바뀌었습니다 — 다시 채우기"를 보인다.
  bool _stale = false;

  /// 마지막으로 추천을 부탁한 금액 — 같은 금액이면 다시 부르지 않는다.
  int? _requestedAmount;
  Timer? _debounce;

  /// 다시 받기가 겹치면 마지막 것만 쓴다.
  int _fetchSeq = 0;
  late final Future<void> _initialLoad;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onLineChanged);
    widget.amountChanges?.addListener(_onAmountChanged);
    _requestedAmount = widget.amountOf?.call();
    _initialLoad = _load();
  }

  @override
  void didUpdateWidget(covariant ApprovalLinePicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onLineChanged);
      widget.controller.addListener(_onLineChanged);
    }
    if (oldWidget.amountChanges != widget.amountChanges) {
      oldWidget.amountChanges?.removeListener(_onAmountChanged);
      widget.amountChanges?.addListener(_onAmountChanged);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.controller.removeListener(_onLineChanged);
    widget.amountChanges?.removeListener(_onAmountChanged);
    super.dispose();
  }

  void _onLineChanged() {
    if (!_applying) _touched = true;
    setState(() {});
  }

  void _onAmountChanged() {
    final amount = widget.amountOf?.call();
    if (amount == _requestedAmount) return;
    _requestedAmount = amount;
    _debounce?.cancel();
    _debounce = Timer(_refetchDelay, _refetch);
  }

  Future<ApprovalLines> _fetchLines() => widget.api.approvalLines(
    kind: widget.kind,
    templateId: widget.templateId,
    amount: _requestedAmount,
  );

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        widget.api.candidates(),
        _fetchLines(),
      ]);
      if (!mounted) return;
      final candidates = results[0] as List<ApprovalCandidate>;
      final lines = results[1] as ApprovalLines;
      setState(() {
        _candidates = candidates;
        _lines = lines.lines;
        _suggestion = lines;
      });
      if (widget.controller.approverIds.isEmpty) {
        _apply(lines);
      } else {
        // 이미 결재선이 있으면(다시 연 창 등) 그대로 둔다 — 고친 것으로 본다.
        _touched = true;
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// 금액이 바뀐 뒤 추천을 다시 받는다 — 손으로 고치지 않았으면 새 추천으로 채우고, 고쳤으면 추천이 바뀌었을 때만 "다시 채우기"를 보인다.
  Future<void> _refetch() async {
    await _initialLoad;
    if (!mounted || _candidates == null) return;
    final seq = ++_fetchSeq;
    try {
      final lines = await _fetchLines();
      if (!mounted || seq != _fetchSeq) return;
      final previous = _suggestion;
      setState(() {
        _suggestion = lines;
        _lines = lines.lines;
      });
      if (!_touched) {
        _apply(lines);
      } else if (!_sameSuggestion(previous, lines)) {
        setState(() => _stale = true);
      }
    } catch (_) {
      // 다시 받기가 안 되면 지금 결재선을 그대로 쓴다(올릴 때 서버가 결재선을 다시 본다).
    }
  }

  /// 추천을 결재선에 채운다 — 고를 수 있는 사람만, 채운 뒤에는 "손대지 않음".
  void _apply(ApprovalLines lines) {
    final known = {for (final c in _candidates ?? const []) c.id};
    final approvers = lines.suggestedApproverIds.where(known.contains).toList();
    _applying = true;
    try {
      widget.controller.setLine(
        approvers,
        lines.suggestedCcIds.where(known.contains).toList(),
        lines.suggestedRoles,
      );
    } finally {
      _applying = false;
    }
    setState(() {
      _touched = false;
      _stale = false;
      // 조직도 상위자로 채웠으면 그 사실을 알려 준다 — 결재선을 손으로 바꾸면 안내는 사라진다.
      _orgPrefill = lines.suggestedSource == 'org' && approvers.isNotEmpty
          ? List.of(approvers)
          : null;
    });
  }

  static bool _sameSuggestion(ApprovalLines? a, ApprovalLines b) =>
      a != null &&
      a.suggestedSource == b.suggestedSource &&
      a.suggestedRule?.id == b.suggestedRule?.id &&
      listEquals(a.suggestedApproverIds, b.suggestedApproverIds) &&
      listEquals(a.suggestedCcIds, b.suggestedCcIds);

  String _nameOf(String id) {
    for (final c in _candidates ?? const <ApprovalCandidate>[]) {
      if (c.id == id) return c.name;
    }
    return tr('(알 수 없음)');
  }

  /// 지금 결재선이 추천과 같은지(고를 수 있는 사람만 견준다) — 같으면 "다시 채우기"는 필요 없다.
  bool _lineMatches(ApprovalLines lines) {
    final known = {for (final c in _candidates ?? const []) c.id};
    return listEquals(
          widget.controller.approverIds,
          lines.suggestedApproverIds.where(known.contains).toList(),
        ) &&
        listEquals(
          widget.controller.ccIds,
          lines.suggestedCcIds.where(known.contains).toList(),
        );
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
    final suggestion = _suggestion;
    final rule = suggestion?.suggestedSource == 'rule'
        ? suggestion?.suggestedRule
        : null;
    // 이 문서에 맞는 전결 규정 — 있으면 전결은 올릴 때 서버가 정하므로 역할 칩은 전결을 건너뛴다.
    final finalRule = suggestion?.finalRule;
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
        // 결재선 규칙으로 채웠으면 어느 규칙인지(관리 탭 목록과 같은 글 — line_rule_text.dart).
        if (rule != null)
          Padding(
            key: const ValueKey('approval-line-rule-hint'),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              tr('규칙: {rule}', {
                'rule': lineRuleSentence(rule, nameOf: _nameOf),
              }),
              style: TextStyle(fontSize: 12, color: hint),
            ),
          ),
        // 양식의 기본 결재선·참조자를 썼으면(서버 approvalFormDefaults.js) 그 양식 이름과 함께 알린다.
        if (suggestion?.suggestedFormName != null && !_touched)
          Padding(
            key: const ValueKey('approval-line-form-hint'),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              suggestion!.suggestedSource == 'form'
                  ? tr('"{form}" 양식의 기본 결재선으로 채웠습니다. 올리기 전에 고칠 수 있습니다.', {
                      'form': suggestion.suggestedFormName,
                    })
                  : tr('"{form}" 양식의 기본 참조자를 더했습니다.', {
                      'form': suggestion.suggestedFormName,
                    }),
              style: TextStyle(fontSize: 12, color: hint),
            ),
          ),
        // 전결 규정(서버 approvalFinalRules.js) — 어느 직책 이상이 전결하는지, 그리고 손으로 전결을 고를 수 없다는 것.
        if (finalRule != null)
          Padding(
            key: const ValueKey('approval-line-final-rule-hint'),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              finalRuleHintText(finalRule),
              style: TextStyle(fontSize: 12, color: theme.colorScheme.primary),
            ),
          ),
        // 손으로 고친 뒤 금액이 바뀌어 추천이 달라졌다 — 덮어쓰지 않고 다시 채울 수 있게만.
        if (_stale && suggestion != null && !_lineMatches(suggestion))
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('approval-line-refill'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
              onPressed: () => _apply(suggestion),
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(
                tr('규칙이 바뀌었습니다 — 다시 채우기'),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        if (c.approverIds.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              tr(
                '결재자를 순서대로 고르세요. 앞사람이 승인해야 다음 사람에게 넘어갑니다. 이름 옆 역할을 눌러 합의(이어진 합의는 동시에)·전결(승인하면 남은 결재 생략)·후결(결재가 끝난 뒤 확인 — 맨 뒤에만)로 바꿀 수 있습니다.',
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
                tooltip: finalRule != null
                    ? tr('역할 바꾸기(결재 → 합의 → 후결)')
                    : tr('역할 바꾸기(결재 → 합의 → 전결 → 후결)'),
                label: Text(
                  c.roleOf(id).label,
                  style: TextStyle(
                    fontSize: 12,
                    color: c.roleOf(id) == LineRole.approve
                        ? hint
                        : theme.colorScheme.primary,
                  ),
                ),
                onPressed: () {
                  // 전결 규정이 맞으면 전결은 건너뛴다. 후결 앞에 결재할 사람이 없으면 후결도 건너뛰고 알린다.
                  final refused = c.cycleRole(
                    id,
                    allowFinal: finalRule == null,
                  );
                  if (refused) {
                    showAppToast(context, tr('후결 앞에 결재할 사람이 한 명 이상 있어야 합니다.'));
                  }
                },
              ),
              IconButton(
                tooltip: tr('위로'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_upward, size: 16),
                onPressed: c.canMove(i, -1)
                    ? () => c.moveApprover(i, -1)
                    : null,
              ),
              IconButton(
                tooltip: tr('아래로'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_downward, size: 16),
                onPressed: c.canMove(i, 1) ? () => c.moveApprover(i, 1) : null,
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

  /// 결재선 규칙으로 추천받을 결재 종류·양식·금액 — [ApprovalLinePicker]의 kind·templateId·amountOf·amountChanges로 넘긴다.
  final String? lineKind;
  final String? lineTemplateId;
  final int? Function()? lineAmountOf;
  final Listenable? lineAmountChanges;

  /// 사유 칸에 미리 채울 글(예: 정산 지출의 "○○ 정산") — 없으면 빈 칸.
  final String? initialBody;
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
    this.lineKind,
    this.lineTemplateId,
    this.lineAmountOf,
    this.lineAmountChanges,
    this.initialBody,
  });

  @override
  State<ApprovalRequestDialog> createState() => _ApprovalRequestDialogState();
}

class _ApprovalRequestDialogState extends State<ApprovalRequestDialog> {
  final _line = ApprovalLineController();
  late final _body = TextEditingController(text: widget.initialBody);
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
    final ApprovalDocument doc;
    try {
      doc = await widget.submit(
        body: _body.text.trim().isEmpty ? null : _body.text.trim(),
        approverIds: List.of(_line.approverIds),
        ccIds: List.of(_line.ccIds),
        roles: Map.of(_line.roles),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _submitting = false;
        });
      }
      return;
    }
    // 닫은 뒤에는 다시 그리지 않는다 — 부르는 쪽이 창이 닫히자마자(whenComplete) 칸의 컨트롤러를 버려서, 닫히는 애니메이션 중에
    // setState로 다시 그리면 버린 컨트롤러를 쓰게 된다.
    if (mounted) Navigator.of(context).pop(doc);
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
                kind: widget.lineKind,
                templateId: widget.lineTemplateId,
                amountOf: widget.lineAmountOf,
                amountChanges: widget.lineAmountChanges,
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

/// 시간 연차 한 번에 쓸 수 있는 시간(1~7 — 8시간이면 연차, 서버 annualLeave.js HOURLY_LEAVE_MAX).
const kHourlyLeaveMax = 7;

/// 'HH:MM' → 하루 중 분(형식이 틀리면 null — 서버 annualLeave.js leaveRequestAmount와 같은 규칙).
int? leaveTimeMinutes(String text) {
  final m = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$').firstMatch(text.trim());
  return m == null ? null : int.parse(m[1]!) * 60 + int.parse(m[2]!);
}

/// 휴가 신청 — 종류, 기간(반차·시간 연차는 하루), 사유, 결재선. [balance]가 있으면 남은 연차를 보여 준다. 올렸으면 그 문서.
///
/// 시간 단위 연차(반반차 2시간 고정·시간 연차 1~7시간 — [LeaveTypeInfo.hourly])는 날짜 하나, 시작 시각('HH:MM' — 기본은 내 근무 시작),
/// 시간 수를 받고 "09:00~11:00 · 2시간 (연차 2시간)"처럼 끝 시각과 연차로 빠질 양(1시간 = 0.25 반일)을 바로 보여 준다. 올릴 때
/// `startTime`·`hours`를 함께 보낸다(반반차의 hours는 서버가 2시간으로 정한다).
///
/// [initialStart]·[initialEnd]('YYYY-MM-DD')를 주면 그 기간으로 미리 채운다(휴가 달력에서 날을 끌어 고른 기간 — leave_calendar.dart).
/// 거꾸로 주어도 앞뒤를 바로잡고, 처음 종류가 하루짜리(반차·시간 연차)면 시작 날 하나만 쓴다(종류를 바꿀 때와 같은 규칙).
Future<ApprovalDocument?> showLeaveRequestDialog(
  BuildContext context, {
  required GroupwareApi api,
  required GroupwareContext ctx,
  LeaveBalance? balance,
  String? initialStart,
  String? initialEnd,
}) {
  // 관리자가 끈 종류는 고르지 못한다(groupwareOptions.js — 예전 신청의 이름을 보이려고 목록에는 남는다).
  final types = ctx.enabledLeaveTypes;
  var type = types.isNotEmpty ? types.first.key : 'annual';
  // 미리 채울 기간 — 시작만 주면 하루, 끝이 앞이면 맞바꾼다.
  var first = initialStart ?? initialEnd;
  var last = initialEnd ?? initialStart;
  if (first != null && last != null && last.compareTo(first) < 0) {
    (first, last) = (last, first);
  }
  final firstInfo = ctx.leaveType(type);
  final firstSingle =
      (firstInfo?.half ?? false) || (firstInfo?.hourly ?? false);
  String? start = first;
  String? end = firstSingle ? first : last;
  // 시간 연차의 시작 시각('HH:MM')과 시간 수.
  var startTime = minutesText(ctx.myWorkStart ?? ctx.workStart);
  var hours = 1;
  int hoursOf(LeaveTypeInfo? info) => info?.fixedHours ?? hours;
  return showDialog<ApprovalDocument>(
    context: context,
    builder: (_) => ApprovalRequestDialog(
      title: tr('휴가 신청'),
      api: api,
      ctx: ctx,
      lineKind: ApprovalKind.leave.wire,
      fields: (setState) {
        final info = ctx.leaveType(type);
        final hourly = info?.hourly ?? false;
        // 하루만 고르는 종류 — 반차·시간 연차.
        final single = (info?.half ?? false) || hourly;
        final startMinutes = leaveTimeMinutes(startTime);
        final hint = Theme.of(context).hintColor;
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
              final next = ctx.leaveType(type);
              if ((next?.half ?? false) || (next?.hourly ?? false)) end = start;
            }),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              ApprovalDateField(
                label: single ? tr('날짜') : tr('시작'),
                value: start,
                onChanged: (v) => setState(() {
                  start = v;
                  final keepEnd =
                      end != null && !single && end!.compareTo(v) >= 0;
                  if (!keepEnd) end = v;
                }),
              ),
              if (!single)
                ApprovalDateField(
                  label: tr('끝'),
                  value: end,
                  onChanged: (v) => setState(() => end = v),
                ),
            ],
          ),
          if (hourly) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    key: const ValueKey('leave-start-time'),
                    initialValue: startTime,
                    keyboardType: TextInputType.datetime,
                    maxLength: 5,
                    decoration: InputDecoration(
                      labelText: tr('시작 시각'),
                      hintText: 'HH:MM',
                      counterText: '',
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(() => startTime = v.trim()),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: info?.fixedHours != null
                      ? InputDecorator(
                          decoration: InputDecoration(
                            labelText: tr('시간'),
                            isDense: true,
                            border: const OutlineInputBorder(),
                          ),
                          child: Text(
                            tr('{h}시간 고정', {'h': info!.fixedHours}),
                            key: const ValueKey('leave-hours-fixed'),
                          ),
                        )
                      : DropdownButtonFormField<int>(
                          key: const ValueKey('leave-hours'),
                          initialValue: hours,
                          isDense: true,
                          decoration: InputDecoration(
                            labelText: tr('시간'),
                            isDense: true,
                            border: const OutlineInputBorder(),
                          ),
                          items: [
                            for (var h = 1; h <= kHourlyLeaveMax; h++)
                              DropdownMenuItem(
                                value: h,
                                child: Text(tr('{h}시간', {'h': h})),
                              ),
                          ],
                          onChanged: (v) => setState(() => hours = v ?? hours),
                        ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              startMinutes == null
                  ? tr('시작 시각을 HH:MM으로 넣으세요.')
                  : tr('{start}~{end} · {hours}시간 (연차 {amount})', {
                      'start': minutesText(startMinutes),
                      'end': minutesText(startMinutes + hoursOf(info) * 60),
                      'hours': hoursOf(info),
                      'amount': halfDaysText(hoursOf(info) / 4),
                    }),
              key: const ValueKey('leave-hourly-summary'),
              style: TextStyle(fontSize: 12, color: hint),
            ),
          ],
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
        final info = ctx.leaveType(type);
        if (info?.hourly ?? false) {
          final m = leaveTimeMinutes(startTime);
          if (m == null) return tr('시작 시각을 HH:MM으로 넣으세요.');
          if (m + hoursOf(info) * 60 > 24 * 60) {
            return tr('시간 연차는 그날 안에서 끝나야 합니다.');
          }
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
              // 시간 연차는 하루 — 시작 시각과 시간 수(반반차는 정해진 2시간).
              if (ctx.leaveType(type)?.hourly ?? false) ...{
                'endDate': start,
                'startTime': minutesText(leaveTimeMinutes(startTime)!),
                'hours': hoursOf(ctx.leaveType(type)),
              } else
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
///
/// [settles]를 주면 그 승인된 구매 요청·출장 신청을 **정산**하는 지출이다(결재 상세의 "정산하기") — 위에 정산 대상 띠(문서 번호·
/// 예산)를 보이고, 금액은 예산(구매 품목 합계·출장 예상 경비 — [settleBudgetOf], 없으면 빈 칸)으로, 내용은 "○○ 정산"으로 미리
/// 채운다. 금액 아래에는 예산과의 차이를 바로바로 보여 주고, 올릴 때 `settlesId`를 함께 보내 서버가 두 결재를 잇는다(서버가
/// 내 결재·승인됨·살아 있는 정산 없음을 다시 확인한다 — settlementRules.js checkSettlement).
Future<ApprovalDocument?> showExpenseRequestDialog(
  BuildContext context, {
  required GroupwareApi api,
  required GroupwareContext ctx,
  required Session session,
  ApprovalDocument? settles,
}) {
  final budget = settles == null ? null : settleBudgetOf(settles);
  final amount = TextEditingController(
    text: budget != null && budget > 0 ? '$budget' : null,
  );
  final title = TextEditingController();
  var category = ctx.expenseCategories.isNotEmpty
      ? ctx.expenseCategories.first
      : tr('기타');
  var spentOn = ctx.today;
  final receipts = <({String url, String name, int size, String? mimeType})>[];
  var uploading = false;
  return showDialog<ApprovalDocument>(
    context: context,
    builder: (dialogContext) => _DisposeWithRoute(
      onDispose: () {
        amount.dispose();
        title.dispose();
      },
      child: ApprovalRequestDialog(
        title: tr('지출 결재'),
        api: api,
        ctx: ctx,
        // 금액을 바꾸면 그 금액에 맞는 결재선 규칙으로 다시 추천받는다(예: 100만 원 이상은 본부장까지).
        lineKind: ApprovalKind.expense.wire,
        lineAmountOf: () => expenseAmountOf(amount.text),
        lineAmountChanges: amount,
        bodyLabel: tr('내용(어디에 무엇을)'),
        initialBody: settles == null
            ? null
            : tr('{title} 정산', {'title': settles.title}),
        fields: (setState) => [
          if (settles != null) ...[
            _SettlesBanner(source: settles, budget: budget),
            const SizedBox(height: 12),
          ],
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
          // 정산이면 예산과의 차이 — 금액을 고칠 때마다 다시 그린다(예산을 모르면 숨긴다).
          if (budget != null)
            ListenableBuilder(
              listenable: amount,
              builder: (context, _) {
                final value = expenseAmountOf(amount.text);
                if (value == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 4, left: 4),
                  child: Text(
                    settleDiffText(value - budget),
                    key: const ValueKey('expense-settle-diff'),
                    style: TextStyle(
                      fontSize: 12,
                      color: value > budget
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).hintColor,
                    ),
                  ),
                );
              },
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
                          for (final f
                              in picked?.files ?? const <PlatformFile>[])
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
                // 정산 대상(승인된 구매 요청·출장 신청) — 서버가 확인하고 payload.settles로 적는다.
                'settlesId': ?settles?.id,
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
    ),
  );
}

/// 창(route)이 화면에서 완전히 빠질 때(닫히는 애니메이션까지 끝나고 위젯이 떨어질 때) [onDispose]를 부른다 — 창 밖에서 만든
/// 컨트롤러를 버리는 곳. showDialog(...).whenComplete에서 버리면 닫히는 동안 다시 그려질 때 버린 컨트롤러를 쓰게 된다. 아래 칸들이
/// 먼저 떨어져(리스너를 떼고) 나서 불린다.
class _DisposeWithRoute extends StatefulWidget {
  final VoidCallback onDispose;
  final Widget child;
  const _DisposeWithRoute({required this.onDispose, required this.child});

  @override
  State<_DisposeWithRoute> createState() => _DisposeWithRouteState();
}

class _DisposeWithRouteState extends State<_DisposeWithRoute> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 정산 금액과 예산의 차이 문구 — [diff]는 정산 금액 − 예산(원, +면 예산보다 많이 씀).
String settleDiffText(int diff) => diff > 0
    ? tr('예산보다 {won} 많습니다', {'won': wonText(diff)})
    : diff < 0
    ? tr('예산보다 {won} 적습니다', {'won': wonText(-diff)})
    : tr('예산과 같습니다');

/// 정산 지출 창 맨 위의 띠 — 무엇을 정산하는지(제목·문서 번호)와 예산(알 때만).
class _SettlesBanner extends StatelessWidget {
  final ApprovalDocument source;
  final int? budget;
  const _SettlesBanner({required this.source, required this.budget});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('expense-settles-banner'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.link, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('정산: {title}', {'title': source.title}),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  [
                    source.kindLabel,
                    ?source.docNumber,
                    if (budget != null)
                      tr('예산 {won}', {'won': wonText(budget!)}),
                  ].join(' · '),
                  style: TextStyle(fontSize: 12, color: theme.hintColor),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 지출 금액 입력칸의 값(원) — 쉼표는 빼고, 비었거나 0 이하·숫자가 아니면 null(결재선 규칙의 금액 기준을 고르지 않는다).
int? expenseAmountOf(String text) {
  final value = int.tryParse(text.replaceAll(',', '').trim());
  return value == null || value <= 0 ? null : value;
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
      lineKind: ApprovalKind.attendance.wire,
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
