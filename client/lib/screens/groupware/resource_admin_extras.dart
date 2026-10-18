import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/groupware.dart' show ApprovalCandidate, minutesText;
import '../../models/groupware_resources.dart';
import '../../models/groupware_work.dart' show GroupwareOptions;
import '../../services/api_client.dart' show ApiException;
import '../../services/groupware_api.dart';
import '../../widgets/app_toast.dart';
import 'groupware_screen.dart' show GroupwareSectionHeader;
import 'resource_booking_extras.dart';
import '../../l10n/tr.dart';

/// 관리 탭 "회의실·자원" 후속([ResourcesAdminSection] — resource_tab.dart)의 조각들:
/// - [ResourceEditDialog] 자원 더하기·고치기 — 기본 칸과 예약 규칙(승인 필요·승인할 사람, 예약할 수 있는 사람, 요일·시간대, 한 번에 쓸 수
///   있는 시간, 태블릿 바로 예약 — 서버 resourcePolicy.js parseResourcePolicy). 규칙은 바뀐 것만 보낸다.
/// - [ResourceDisplayDialog] 회의실 앞 태블릿 화면(서버가 그리는 HTML — roomDisplay.js) 켜기·끄기·주소 바꾸기, 주소·QR.
/// - [ResourceStatsSection] 사용 통계(지난 7·30·90일).
/// - [BookingReminderOption] 예약 시작 전 알림(분 — 0이면 끔).

/// 한 번에 쓸 수 있는 시간 고르기(분 — null이면 제한 없음). 서버는 15분~7일.
const _maxMinuteChoices = <int?>[
  null,
  30,
  60,
  90,
  120,
  180,
  240,
  480,
  1440,
  4320,
  10080,
];

/// 예약 시작 전 알림 고르기(분 — 0이면 끔, 서버는 120분까지).
const _reminderChoices = [0, 5, 10, 15, 30, 60];

/// "HH:MM"(또는 "H:MM") → 하루 중 분(24:00까지) — 모양이 틀리면 null.
int? parseHourMinute(String text) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(text.trim());
  if (m == null) return null;
  final h = int.parse(m.group(1)!);
  final min = int.parse(m.group(2)!);
  if (h > 24 || min > 59 || (h == 24 && min != 0)) return null;
  return h * 60 + min;
}

bool _sameSet(List<String> a, List<String> b) =>
    a.length == b.length && a.toSet().containsAll(b);

bool _sameDays(List<int>? a, List<int>? b) {
  if (a == null || b == null) return a == b;
  return a.length == b.length && a.toSet().containsAll(b);
}

// ── 자원 더하기·고치기 ─────────────────────────────────────────────────

/// 자원 편집 창 — 저장하면 서버에 보낼 칸(`{kind, name, location, capacity, description}` + 바뀐 예약 규칙 칸), 그만두면 null.
/// 승인할 사람·예약할 수 있는 사람은 결재자 후보(api.candidates — 나 포함) 가운데서 고른다(서버도 같은 후보로 검사).
class ResourceEditDialog extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareResource? resource;
  const ResourceEditDialog({super.key, required this.api, this.resource});

  @override
  State<ResourceEditDialog> createState() => _ResourceEditDialogState();
}

class _ResourceEditDialogState extends State<ResourceEditDialog> {
  late final GroupwareResource? _orig = widget.resource;
  late String _kind = _orig?.kind ?? 'room';
  late final _name = TextEditingController(text: _orig?.name ?? '');
  late final _location = TextEditingController(text: _orig?.location ?? '');
  late final _capacity = TextEditingController(
    text: _orig?.capacity?.toString() ?? '',
  );
  late final _description = TextEditingController(
    text: _orig?.description ?? '',
  );
  // 예약 규칙.
  late bool _requiresApproval = _orig?.requiresApproval ?? false;
  late List<String> _approverIds = [...?_orig?.approverIds];
  late List<String> _allowedIds = [...?_orig?.allowedUserIds];
  late final Set<int> _days = {
    ...(_orig?.availableDays ?? const [0, 1, 2, 3, 4, 5, 6]),
  };
  late final _from = TextEditingController(
    text: _orig?.availableFrom == null
        ? ''
        : minutesText(_orig!.availableFrom!),
  );
  late final _to = TextEditingController(
    text: _orig?.availableTo == null ? '' : minutesText(_orig!.availableTo!),
  );
  late int? _maxMinutes = _orig?.maxMinutes;
  late bool _quickBook = _orig?.displayQuickBook ?? false;

  /// 결재자 후보(이름 보이기·고르기) — 못 받으면 빈 목록(고른 사람은 id만 남는다).
  List<ApprovalCandidate> _candidates = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.api
        .candidates(includeSelf: true)
        .then((c) {
          if (mounted) setState(() => _candidates = c);
        })
        .catchError((Object _) {});
  }

  @override
  void dispose() {
    for (final c in [_name, _location, _capacity, _description, _from, _to]) {
      c.dispose();
    }
    super.dispose();
  }

  String _namesOf(List<String> ids) {
    final byId = {for (final c in _candidates) c.id: c.name};
    return ids.map((id) => byId[id] ?? tr('(목록에 없는 사람)')).join(', ');
  }

  Future<void> _pickPeople({required bool approvers}) async {
    final picked = await showDialog<List<String>>(
      context: context,
      builder: (_) => _PeoplePickerDialog(
        title: approvers ? tr('승인할 사람') : tr('예약할 수 있는 사람'),
        candidates: _candidates,
        initial: approvers ? _approverIds : _allowedIds,
      ),
    );
    if (picked == null) return;
    setState(() {
      if (approvers) {
        _approverIds = picked;
      } else {
        _allowedIds = picked;
      }
    });
  }

  void _fail(String message) => setState(() => _error = message);

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return _fail(tr('이름을 넣으세요.'));
    final capacityText = _capacity.text.trim();
    final capacity = capacityText.isEmpty ? null : int.tryParse(capacityText);
    if (capacityText.isNotEmpty && (capacity == null || capacity < 1)) {
      return _fail(tr('수용 인원은 1 이상의 숫자로 넣으세요.'));
    }
    if (_days.isEmpty) return _fail(tr('예약할 수 있는 요일을 하나 이상 고르세요.'));
    final fromText = _from.text.trim();
    final toText = _to.text.trim();
    if (fromText.isEmpty != toText.isEmpty) {
      return _fail(tr('예약할 수 있는 시간대는 시작과 끝을 함께 넣으세요(비우면 언제나).'));
    }
    int? from;
    int? to;
    if (fromText.isNotEmpty) {
      from = parseHourMinute(fromText);
      to = parseHourMinute(toText);
      if (from == null || to == null) {
        return _fail(tr('시간대는 09:00처럼 넣으세요.'));
      }
      if (from >= to) return _fail(tr('시간대의 시작이 끝보다 앞이어야 합니다.'));
    }
    final days = _days.length == 7 ? null : (_days.toList()..sort());
    final o = _orig;
    // 예약 규칙은 바뀐 것만(새 자원이면 기본값과 다른 것만) — 기본 칸만 고치는 예전 모양 그대로 둔다.
    Navigator.of(context).pop({
      'kind': _kind,
      'name': name,
      'location': _location.text.trim(),
      'capacity': capacity,
      'description': _description.text.trim(),
      if (_requiresApproval != (o?.requiresApproval ?? false))
        'requiresApproval': _requiresApproval,
      if (!_sameSet(_approverIds, o?.approverIds ?? const []))
        'approverIds': _approverIds,
      if (!_sameSet(_allowedIds, o?.allowedUserIds ?? const []))
        'allowedUserIds': _allowedIds,
      if (!_sameDays(days, o?.availableDays)) 'availableDays': days,
      if (from != o?.availableFrom || to != o?.availableTo) ...{
        'availableFrom': from,
        'availableTo': to,
      },
      if (_maxMinutes != o?.maxMinutes) 'maxMinutes': _maxMinutes,
      if (_quickBook != (o?.displayQuickBook ?? false))
        'displayQuickBook': _quickBook,
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final maxChoices = [
      ..._maxMinuteChoices,
      if (!_maxMinuteChoices.contains(_maxMinutes)) _maxMinutes,
    ];
    return AlertDialog(
      title: Text(
        widget.resource == null ? tr('회의실·자원 더하기') : tr('회의실·자원 고치기'),
      ),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<String>(
                key: const ValueKey('resource-kind'),
                segments: [
                  for (final e in resourceKindLabels.entries)
                    ButtonSegment(value: e.key, label: Text(e.value)),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() => _kind = s.first),
              ),
              TextField(
                key: const ValueKey('resource-name'),
                controller: _name,
                maxLength: 30,
                decoration: InputDecoration(labelText: tr('이름')),
              ),
              TextField(
                key: const ValueKey('resource-location'),
                controller: _location,
                maxLength: 50,
                decoration: InputDecoration(labelText: tr('위치 (예: 3층)')),
              ),
              TextField(
                key: const ValueKey('resource-capacity'),
                controller: _capacity,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: tr('수용 인원')),
              ),
              TextField(
                key: const ValueKey('resource-description'),
                controller: _description,
                maxLength: 200,
                decoration: InputDecoration(labelText: tr('설명 (장비 목록 등)')),
              ),
              const SizedBox(height: 8),
              Text(tr('예약 규칙'), style: theme.textTheme.titleSmall),
              SwitchListTile(
                key: const ValueKey('resource-requires-approval'),
                contentPadding: EdgeInsets.zero,
                value: _requiresApproval,
                onChanged: (v) => setState(() => _requiresApproval = v),
                title: Text(tr('승인 필요')),
                subtitle: Text(
                  tr('잡으면 승인을 기다리고(그 시간은 막아 둠), 승인할 사람이 승인하면 확정됩니다.'),
                  style: TextStyle(fontSize: 12, color: hint),
                ),
              ),
              if (_requiresApproval)
                ListTile(
                  key: const ValueKey('resource-approvers'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('승인할 사람')),
                  subtitle: Text(
                    _approverIds.isEmpty
                        ? tr('비우면 그룹웨어 관리자가 승인합니다.')
                        : _namesOf(_approverIds),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _pickPeople(approvers: true),
                ),
              ListTile(
                key: const ValueKey('resource-allowed-users'),
                contentPadding: EdgeInsets.zero,
                title: Text(tr('예약할 수 있는 사람')),
                subtitle: Text(
                  _allowedIds.isEmpty
                      ? tr('모두 (그룹웨어 관리자는 늘 예약할 수 있습니다)')
                      : _namesOf(_allowedIds),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _pickPeople(approvers: false),
              ),
              const SizedBox(height: 4),
              Text(
                tr('예약할 수 있는 요일'),
                style: TextStyle(fontSize: 12, color: hint),
              ),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final d in resourceDayOrder)
                    FilterChip(
                      key: ValueKey('resource-day-$d'),
                      label: Text(resourceDayNames[d]),
                      selected: _days.contains(d),
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      onSelected: (on) => setState(() {
                        if (on) {
                          _days.add(d);
                        } else {
                          _days.remove(d);
                        }
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('resource-available-from'),
                      controller: _from,
                      keyboardType: TextInputType.datetime,
                      decoration: InputDecoration(
                        labelText: tr('시간대 시작'),
                        hintText: '09:00',
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text('~'),
                  ),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('resource-available-to'),
                      controller: _to,
                      keyboardType: TextInputType.datetime,
                      decoration: InputDecoration(
                        labelText: tr('시간대 끝'),
                        hintText: '18:00',
                      ),
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  tr('시간대를 비우면 언제나 예약할 수 있습니다.'),
                  style: TextStyle(fontSize: 12, color: hint),
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<int?>(
                key: const ValueKey('resource-max-minutes'),
                initialValue: _maxMinutes,
                isExpanded: true,
                decoration: InputDecoration(labelText: tr('한 번에 쓸 수 있는 시간')),
                items: [
                  for (final m in maxChoices)
                    DropdownMenuItem(
                      value: m,
                      child: Text(
                        m == null ? tr('제한 없음') : resourceDurationText(m),
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _maxMinutes = v),
              ),
              SwitchListTile(
                key: const ValueKey('resource-quick-book'),
                contentPadding: EdgeInsets.zero,
                value: _quickBook,
                onChanged: (v) => setState(() => _quickBook = v),
                title: Text(tr('태블릿에서 바로 예약')),
                subtitle: Text(
                  tr('회의실 앞 태블릿 화면에서 지금부터 15·30·60분을 바로 잡게 합니다.'),
                  style: TextStyle(fontSize: 12, color: hint),
                ),
              ),
              if (_error != null)
                Text(
                  _error!,
                  key: const ValueKey('resource-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
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
          key: const ValueKey('resource-save'),
          onPressed: _save,
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}

/// 사람 여럿 고르기(결재자 후보 중) — 이름·아이디로 거르고 체크. 고른 id 목록(후보에 없는 예전 id는 그대로 남긴다), 그만두면 null.
class _PeoplePickerDialog extends StatefulWidget {
  final String title;
  final List<ApprovalCandidate> candidates;
  final List<String> initial;
  const _PeoplePickerDialog({
    required this.title,
    required this.candidates,
    required this.initial,
  });

  @override
  State<_PeoplePickerDialog> createState() => _PeoplePickerDialogState();
}

class _PeoplePickerDialogState extends State<_PeoplePickerDialog> {
  late final Set<String> _picked = {...widget.initial};
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
              key: const ValueKey('people-picker-search'),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: tr('이름으로 찾기'),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            Expanded(
              child: widget.candidates.isEmpty
                  ? Center(child: Text(tr('고를 수 있는 사람이 없습니다.')))
                  : ListView(
                      children: [
                        for (final c in shown)
                          CheckboxListTile(
                            key: ValueKey('people-picker-${c.id}'),
                            dense: true,
                            value: _picked.contains(c.id),
                            onChanged: (v) => setState(() {
                              if (v == true) {
                                _picked.add(c.id);
                              } else {
                                _picked.remove(c.id);
                              }
                            }),
                            title: Text(c.name),
                            subtitle: Text(c.username),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(_picked.clear),
          child: Text(tr('모두 빼기')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('people-picker-done'),
          onPressed: () => Navigator.of(context).pop(_picked.toList()),
          child: Text(tr('고르기 ({n}명)', {'n': _picked.length})),
        ),
      ],
    );
  }
}

// ── 회의실 앞 태블릿 화면 ─────────────────────────────────────────────

/// 태블릿 화면 창 — 켜기·끄기(스위치), 켜져 있으면 주소(고를 수 있는 글 + 복사)와 QR, 주소 바꾸기(예전 주소는 더 이상 열리지 않음).
/// 화면 자체는 서버가 그린다(roomDisplay.js — 로그인 없이 지금 쓰는지·오늘 예약). [serverUrl]은 앱이 쓰는 서버 주소(경로 앞에 붙인다 —
/// 없으면 경로만). 바뀐 자원을 돌려준다(바뀐 것이 없으면 null).
class ResourceDisplayDialog extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareResource resource;
  final String? serverUrl;
  const ResourceDisplayDialog({
    super.key,
    required this.api,
    required this.resource,
    this.serverUrl,
  });

  @override
  State<ResourceDisplayDialog> createState() => _ResourceDisplayDialogState();
}

class _ResourceDisplayDialogState extends State<ResourceDisplayDialog> {
  late GroupwareResource _r = widget.resource;
  bool _changed = false;
  bool _busy = false;

  String? get _url {
    final path = _r.displayPath;
    if (path == null) return null;
    var base = widget.serverUrl ?? '';
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return '$base$path';
  }

  Future<void> _set(bool enabled, {bool rotate = false}) async {
    if (rotate) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(tr('주소를 바꿀까요?')),
          content: Text(
            tr('새 주소를 만들면 예전 주소는 더 이상 열리지 않습니다. 태블릿에서 새 주소를 다시 여세요.'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(tr('취소')),
            ),
            FilledButton(
              key: const ValueKey('resource-display-rotate-confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(tr('바꾸기')),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      final r = await widget.api.setResourceDisplay(_r.id, enabled: enabled);
      if (!mounted) return;
      setState(() {
        _r = r;
        _changed = true;
      });
      showAppToast(
        context,
        !enabled
            ? tr('태블릿 화면을 껐습니다.')
            : rotate
            ? tr('새 주소를 만들었습니다.')
            : tr('태블릿 화면을 켰습니다.'),
      );
    } catch (e) {
      if (mounted) {
        showAppToast(
          context,
          e is ApiException ? trServer(e.message) : tr('바꾸지 못했습니다.'),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final url = _url;
    return AlertDialog(
      title: Text(tr('{name} 태블릿 화면', {'name': _r.name})),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                tr(
                  '회의실 앞 태블릿의 브라우저로 이 주소를 여세요. 로그인 없이 지금 쓰는지·오늘 예약을 보여 줍니다. 주소를 아는 사람은 누구나 볼 수 있으니 공유하지 마세요.',
                ),
                style: TextStyle(fontSize: 13, color: hint),
              ),
              SwitchListTile(
                key: const ValueKey('resource-display-switch'),
                contentPadding: EdgeInsets.zero,
                value: url != null,
                onChanged: _busy ? null : (v) => _set(v),
                title: Text(url != null ? tr('켜짐') : tr('꺼짐')),
              ),
              if (url != null) ...[
                Center(
                  child: Container(
                    key: const ValueKey('resource-display-qr'),
                    color: Colors.white,
                    padding: const EdgeInsets.all(8),
                    child: QrImageView(data: url, size: 160),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        url,
                        key: const ValueKey('resource-display-url'),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('resource-display-copy'),
                      tooltip: tr('주소 복사'),
                      icon: const Icon(Icons.copy, size: 20),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: url));
                        if (context.mounted) {
                          showAppToast(context, tr('주소를 복사했습니다.'));
                        }
                      },
                    ),
                  ],
                ),
                if ((widget.serverUrl ?? '').isEmpty)
                  Text(
                    tr('앞에 서버 주소를 붙여 여세요.'),
                    style: TextStyle(fontSize: 12, color: hint),
                  ),
                const SizedBox(height: 4),
                Text(
                  _r.displayQuickBook
                      ? tr('태블릿에서 바로 예약: 켜짐 (자원 고치기에서 바꿉니다)')
                      : tr('태블릿에서 바로 예약: 꺼짐 (자원 고치기에서 바꿉니다)'),
                  style: TextStyle(fontSize: 12, color: hint),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('resource-display-rotate'),
                    onPressed: _busy ? null : () => _set(true, rotate: true),
                    icon: const Icon(Icons.autorenew, size: 18),
                    label: Text(tr('주소 바꾸기')),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          key: const ValueKey('resource-display-close'),
          onPressed: () => Navigator.of(context).pop(_changed ? _r : null),
          child: Text(tr('닫기')),
        ),
      ],
    );
  }
}

// ── 사용 통계 ──────────────────────────────────────────────────────────

/// 사용 통계(관리자 — GET /groupware/resources/stats) — 지난 7·30·90일, 자원마다 건수·쓴 시간·이용률·쓴 사람 수·많이 쓴 사람·요일별
/// 건수(작은 막대). 승인 기다리는 예약은 세지 않는다(서버).
class ResourceStatsSection extends StatefulWidget {
  final GroupwareApi api;
  const ResourceStatsSection({super.key, required this.api});

  @override
  State<ResourceStatsSection> createState() => ResourceStatsSectionState();
}

class ResourceStatsSectionState extends State<ResourceStatsSection> {
  int _days = 30;
  List<ResourceStatsRow>? _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// 지금 고른 기간으로 다시 받는다(자원이 바뀌었을 때 관리 칸이 부른다).
  Future<void> reload() async {
    final days = _days;
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      final rows = await widget.api.resourceStats(
        from: now - days * 86400000,
        to: now,
      );
      if (mounted && days == _days) {
        setState(() {
          _rows = rows;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is ApiException
              ? trServer(e.message)
              : tr('통계를 불러오지 못했습니다.'),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final rows = _rows;
    return Column(
      key: const ValueKey('resource-stats'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupwareSectionHeader(tr('사용 통계')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final d in const [7, 30, 90])
                ChoiceChip(
                  key: ValueKey('resource-stats-$d'),
                  label: Text(tr('지난 {d}일', {'d': d})),
                  selected: _days == d,
                  onSelected: (_) {
                    setState(() => _days = d);
                    reload();
                  },
                ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(_error!, style: TextStyle(fontSize: 12, color: hint)),
          )
        else if (rows != null && rows.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              tr('자원이 없습니다.'),
              style: TextStyle(fontSize: 12, color: hint),
            ),
          )
        else if (rows != null) ...[
          for (final r in rows) _StatsRow(r),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              tr(
                '이용률은 쓸 수 있는 시간(예약 규칙의 요일·시간대, 정하지 않았으면 평일 09:00~18:00) 가운데 확정된 예약이 차지한 비율입니다.',
              ),
              style: TextStyle(fontSize: 11, color: hint),
            ),
          ),
        ],
      ],
    );
  }
}

class _StatsRow extends StatelessWidget {
  final ResourceStatsRow row;
  const _StatsRow(this.row);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final u = row.utilization;
    final maxDay = row.byWeekday.fold<int>(0, (a, b) => b > a ? b : a);
    return Padding(
      key: ValueKey('resource-stats-row-${row.resourceId}'),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  row.name,
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                u == null
                    ? tr('이용률 —')
                    : tr('이용률 {u}%', {
                        'u': u == u.roundToDouble()
                            ? u.toStringAsFixed(0)
                            : u.toStringAsFixed(1),
                      }),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          Text(
            tr('{count}건 · {time} · {users}명이 씀', {
              'count': row.count,
              'time': resourceDurationText(row.minutes),
              'users': row.userCount,
            }),
            style: TextStyle(fontSize: 12, color: hint),
          ),
          if (row.topUsers.isNotEmpty)
            Text(
              tr('많이 쓴 사람: {names}', {
                'names': row.topUsers
                    .map(
                      (t) => tr('{name} {count}건', {
                        'name': t.name,
                        'count': t.count,
                      }),
                    )
                    .join(', '),
              }),
              style: TextStyle(fontSize: 12, color: hint),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          if (maxDay > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  for (final d in resourceDayOrder)
                    Expanded(
                      child: Tooltip(
                        message: tr('{day}요일 {n}건', {
                          'day': resourceDayNames[d],
                          'n': row.byWeekday.length > d ? row.byWeekday[d] : 0,
                        }),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              height: 18,
                              child: Align(
                                alignment: Alignment.bottomCenter,
                                child: FractionallySizedBox(
                                  heightFactor:
                                      ((row.byWeekday.length > d
                                                  ? row.byWeekday[d]
                                                  : 0) /
                                              maxDay)
                                          .clamp(0.06, 1.0),
                                  child: Container(
                                    width: 14,
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.primary
                                          .withValues(alpha: 0.7),
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Text(
                              resourceDayNames[d],
                              style: TextStyle(fontSize: 10, color: hint),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ── 예약 시작 전 알림 ──────────────────────────────────────────────────

/// 예약 시작 전 알림(관리자 — 범위 설정 bookingReminderMinutes, 0이면 끔). 잡은 사람에게 그 분 전에 푸시와 앱 안 알림(소켓
/// resource:reminder — Session.handleResourceReminder). 설정을 못 받으면 그리지 않는다.
class BookingReminderOption extends StatefulWidget {
  final GroupwareApi api;
  const BookingReminderOption({super.key, required this.api});

  @override
  State<BookingReminderOption> createState() => _BookingReminderOptionState();
}

class _BookingReminderOptionState extends State<BookingReminderOption> {
  GroupwareOptions? _options;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.api
        .options()
        .then((o) {
          if (mounted) setState(() => _options = o);
        })
        .catchError((Object _) {});
  }

  Future<void> _set(int minutes) async {
    setState(() => _busy = true);
    try {
      final o = await widget.api.updateOptions(bookingReminderMinutes: minutes);
      if (!mounted) return;
      setState(() => _options = o);
      showAppToast(
        context,
        minutes == 0
            ? tr('예약 알림을 껐습니다.')
            : tr('예약 시작 {m}분 전에 알립니다.', {'m': minutes}),
      );
    } catch (e) {
      if (mounted) {
        showAppToast(
          context,
          e is ApiException ? trServer(e.message) : tr('저장하지 못했습니다.'),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = _options;
    if (o == null) return const SizedBox.shrink();
    final current = o.bookingReminderMinutes;
    final choices = [
      ..._reminderChoices,
      if (!_reminderChoices.contains(current)) current,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          Flexible(child: Text(tr('예약 시작 전 알림'))),
          const SizedBox(width: 12),
          DropdownButton<int>(
            key: const ValueKey('booking-reminder-minutes'),
            value: current,
            items: [
              for (final m in choices)
                DropdownMenuItem(
                  value: m,
                  child: Text(m == 0 ? tr('끔') : tr('{m}분 전', {'m': m})),
                ),
            ],
            onChanged: _busy
                ? null
                : (v) {
                    if (v != null && v != current) _set(v);
                  },
          ),
        ],
      ),
    );
  }
}
