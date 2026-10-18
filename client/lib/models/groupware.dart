// 그룹웨어(전자결재·연차·출퇴근)의 데이터 모양 — 서버 API(server/src/groupware.js)를 그대로 옮긴 것.
//
// 휴가 양은 서버처럼 반일 단위 정수(halfDays — 하루 = 2, 반차 = 1)로 다루고, 날짜는 'YYYY-MM-DD' 글자, 시각은 epoch ms다.

import '../l10n/tr.dart';

/// 결재 종류 — 서버 approvalRules.js APPROVAL_KINDS. 휴가·지출·근태 수정은 전용 화면이 있고, 그 밖은 양식으로 올린다(서버
/// approvalForms.js — 기본 양식 넷과 관리자가 만든 양식 'form').
enum ApprovalKind {
  leave('leave', '휴가'),
  expense('expense', '지출'),
  attendance('attendance', '근태 수정'),
  draft('draft', '기안'),
  trip('trip', '출장'),
  purchase('purchase', '구매'),
  overtime('overtime', '연장근무'),
  form('form', '양식');

  final String wire;
  final String _labelKo;

  /// 화면에 보일 이름(지금 언어 — l10n/tr.dart).
  String get label => tr(_labelKo);
  const ApprovalKind(this.wire, this._labelKo);

  /// 양식으로 올리는 종류인지(문서의 칸 정의·값을 payload의 fields·values로 그린다).
  bool get isForm => index >= ApprovalKind.draft.index;

  static ApprovalKind fromWire(String? value) =>
      values.firstWhere((k) => k.wire == value, orElse: () => form);
}

/// 양식 칸 종류 — 서버 approvalForms.js FORM_FIELD_TYPES.
enum FormFieldType {
  text('text', '한 줄 글'),
  textarea('textarea', '여러 줄 글'),
  number('number', '숫자'),
  money('money', '금액(원)'),
  date('date', '날짜'),
  dateRange('dateRange', '기간'),
  timeRange('timeRange', '시간대'),
  select('select', '고르기'),
  items('items', '품목 표'),

  /// 이 범위의 사람을 골라 넣는 칸(값은 [{id, name}] — 그때의 이름). [FormFieldDef.multiple]이면 여러 명.
  person('person', '사람'),

  /// 관리자가 정한 열([FormFieldDef.columns])대로 줄마다 값을 넣는 표(값은 {rows: [[…]], totals: [열마다 합계 | null]}).
  table('table', '표');

  final String wire;
  final String _labelKo;

  /// 화면에 보일 이름(지금 언어 — l10n/tr.dart).
  String get label => tr(_labelKo);
  const FormFieldType(this.wire, this._labelKo);

  static FormFieldType fromWire(String? value) =>
      values.firstWhere((t) => t.wire == value, orElse: () => text);
}

/// 표 칸의 열 종류 — 서버 approvalForms.js TABLE_COLUMN_TYPES.
enum FormTableColumnType {
  text('text', '글'),
  number('number', '숫자'),
  money('money', '금액(원)'),
  date('date', '날짜');

  final String wire;
  final String _labelKo;

  /// 화면에 보일 이름(지금 언어 — l10n/tr.dart).
  String get label => tr(_labelKo);
  const FormTableColumnType(this.wire, this._labelKo);

  static FormTableColumnType fromWire(String? value) =>
      values.firstWhere((t) => t.wire == value, orElse: () => text);
}

/// 표 칸의 열 하나(이름·종류).
class FormTableColumn {
  final String label;
  final FormTableColumnType type;
  const FormTableColumn({
    required this.label,
    this.type = FormTableColumnType.text,
  });

  factory FormTableColumn.fromJson(Map<String, dynamic> json) =>
      FormTableColumn(
        label: json['label'] as String? ?? '',
        type: FormTableColumnType.fromWire(json['type'] as String?),
      );

  Map<String, dynamic> toJson() => {'label': label, 'type': type.wire};
}

/// 표 칸에 넣을 수 있는 열·줄 수(서버 approvalForms.js TABLE_COLUMNS_MAX·TABLE_ROWS_MAX), 사람 칸의 사람 수(FORM_PEOPLE_MAX),
/// 칸 설명 길이(FORM_FIELD_HELP_MAX).
const kFormTableColumnsMax = 8;
const kFormTableRowsMax = 50;
const kFormPeopleMax = 10;
const kFormFieldHelpMax = 100;

/// 양식의 칸 하나. [key]는 서버가 매기고 양식을 고쳐도 그대로다(순서를 바꿔도 같은 칸 — 새 칸은 ''로 보낸다).
class FormFieldDef {
  final String key;
  final String label;
  final FormFieldType type;
  final bool required;
  final List<String> options;

  /// 칸 설명 — 신청 창의 입력칸 아래에 보인다(없으면 null).
  final String? help;

  /// 사람 칸 — 여러 명을 고를 수 있는지.
  final bool multiple;

  /// 표 칸 — 열들.
  final List<FormTableColumn> columns;
  const FormFieldDef({
    required this.key,
    required this.label,
    required this.type,
    this.required = false,
    this.options = const [],
    this.help,
    this.multiple = false,
    this.columns = const [],
  });

  factory FormFieldDef.fromJson(Map<String, dynamic> json) => FormFieldDef(
    key: json['key'] as String? ?? '',
    label: json['label'] as String? ?? '',
    type: FormFieldType.fromWire(json['type'] as String?),
    required: json['required'] == true,
    options: (json['options'] as List? ?? const [])
        .whereType<String>()
        .toList(),
    help: json['help'] as String?,
    multiple: json['multiple'] == true,
    columns: [
      for (final c in json['columns'] as List? ?? const [])
        if (c is Map) FormTableColumn.fromJson(c.cast<String, dynamic>()),
    ],
  );

  /// 관리자 양식 만들기·고치기에 보낼 모양 — 이미 있는 칸은 [key]를 함께 보내 순서를 바꿔도 같은 칸으로 남게 한다.
  Map<String, dynamic> toDefinitionJson() => {
    if (key.isNotEmpty) 'key': key,
    'label': label,
    'type': type.wire,
    'required': required,
    if (help != null && help!.trim().isNotEmpty) 'help': help!.trim(),
    if (type == FormFieldType.select) 'options': options,
    if (type == FormFieldType.person) 'multiple': multiple,
    if (type == FormFieldType.table)
      'columns': [for (final c in columns) c.toJson()],
  };
}

/// 양식의 기본 결재선 한 칸(사람·역할 — 서버 approvalFormDefaults.js).
typedef FormDefaultLineEntry = ({String userId, LineRole role});

/// 결재 양식 — 기본 양식(id 'builtin:종류')과 관리자가 만든 양식. 서버 GET /groupware/forms.
class ApprovalForm {
  final String id;
  final ApprovalKind kind;
  final bool builtin;
  final String name;
  final String? description;
  final List<FormFieldDef> fields;
  final bool allowAttachments;
  final bool enabled;

  /// 기본 결재선(비었으면 정하지 않음 — 결재선 규칙·조직도 상위자로)과 기본 참조자. 새 결재를 쓸 때 미리 채운다(서버
  /// approvalFormDefaults.js — 올리는 사람이 고칠 수 있다).
  final List<FormDefaultLineEntry> defaultLine;
  final List<String> defaultCcIds;
  const ApprovalForm({
    required this.id,
    required this.kind,
    required this.builtin,
    required this.name,
    this.description,
    this.fields = const [],
    this.allowAttachments = false,
    this.enabled = true,
    this.defaultLine = const [],
    this.defaultCcIds = const [],
  });

  /// 기본 결재선이나 기본 참조자가 있는지.
  bool get hasDefaults => defaultLine.isNotEmpty || defaultCcIds.isNotEmpty;

  factory ApprovalForm.fromJson(Map<String, dynamic> json) => ApprovalForm(
    id: json['id'] as String,
    kind: ApprovalKind.fromWire(json['kind'] as String?),
    builtin: json['builtin'] == true,
    name: json['name'] as String? ?? '',
    description: json['description'] as String?,
    fields: [
      for (final f in json['fields'] as List? ?? const [])
        FormFieldDef.fromJson((f as Map).cast<String, dynamic>()),
    ],
    allowAttachments: json['allowAttachments'] == true,
    enabled: json['enabled'] != false,
    defaultLine: [
      for (final e in json['defaultLine'] as List? ?? const [])
        if (e is Map && e['userId'] is String)
          (
            userId: e['userId'] as String,
            role: LineRole.fromWire(e['role'] as String?),
          ),
    ],
    defaultCcIds: (json['defaultCcIds'] as List? ?? const [])
        .whereType<String>()
        .toList(),
  );
}

/// 양식 칸 값을 한 줄 글로(상세·목록) — 비었으면 null.
String? formValueText(FormFieldDef field, Object? value) {
  if (value == null) return null;
  switch (field.type) {
    case FormFieldType.money:
      return wonText((value as num).toInt());
    case FormFieldType.number:
      final n = value as num;
      return n == n.roundToDouble() ? n.toInt().toString() : n.toString();
    case FormFieldType.dateRange:
      final m = (value as Map).cast<String, dynamic>();
      final start = m['start'] as String? ?? '';
      final end = m['end'] as String? ?? start;
      return start == end ? start : '$start ~ $end';
    case FormFieldType.timeRange:
      final m = (value as Map).cast<String, dynamic>();
      final minutes = (m['minutes'] as num?)?.toInt() ?? 0;
      final h = minutes ~/ 60;
      final mm = minutes % 60;
      final length = mm == 0
          ? tr('{h}시간', {'h': h})
          : (h == 0
                ? tr('{mm}분', {'mm': mm})
                : tr('{h}시간 {mm}분', {'h': h, 'mm': mm}));
      return '${m['start']} ~ ${m['end']}${m['overnight'] == true ? tr('(다음 날)') : ''} ($length)';
    case FormFieldType.items:
      final m = (value as Map).cast<String, dynamic>();
      return tr('{p0}건 · 합계 {p1}', {
        'p0': (m['rows'] as List? ?? const []).length,
        'p1': wonText((m['total'] as num?)?.toInt() ?? 0),
      });
    case FormFieldType.person:
      return formPeopleOf(value).map((p) => p.name).join(', ');
    case FormFieldType.table:
      final m = (value as Map).cast<String, dynamic>();
      return tr('{n}줄', {'n': (m['rows'] as List? ?? const []).length});
    default:
      return value.toString();
  }
}

/// 사람 칸의 값(문서에 적힌 [{id, name}]) → 목록.
List<({String id, String name})> formPeopleOf(Object? value) => [
  for (final p in value is List ? value : const [])
    if (p is Map)
      (id: p['id'] as String? ?? '', name: p['name'] as String? ?? ''),
];

/// 표 칸의 한 칸 값을 글로 — 열 종류대로(금액은 원, 비었으면 '').
String formTableCellText(FormTableColumn column, Object? value) {
  if (value == null) return '';
  switch (column.type) {
    case FormTableColumnType.money:
      return value is num ? wonText(value.toInt()) : '$value';
    case FormTableColumnType.number:
      if (value is! num) return '$value';
      return value == value.roundToDouble()
          ? value.toInt().toString()
          : value.toString();
    default:
      return '$value';
  }
}

/// 구매 요청·출장 신청을 정산하는 지출 결재(서버 settlementRules.js settlementOf — 승인된 것, 없으면 결재 중, 없으면 최근 것).
class ApprovalSettlement {
  final String id;
  final String? docNumber;
  final String title;
  final ApprovalStatus status;

  /// 정산 금액(원).
  final int? amount;
  const ApprovalSettlement({
    required this.id,
    this.docNumber,
    required this.title,
    required this.status,
    this.amount,
  });

  factory ApprovalSettlement.fromJson(Map<String, dynamic> json) =>
      ApprovalSettlement(
        id: json['id'] as String? ?? '',
        docNumber: json['docNumber'] as String?,
        title: json['title'] as String? ?? '',
        status: ApprovalStatus.fromWire(json['status'] as String?),
        amount: (json['amount'] as num?)?.toInt(),
      );
}

/// 지출 결재가 정산하는 원래 결재(지출 payload.settles — 올릴 때의 제목·번호·예산).
class ApprovalSettles {
  final String id;
  final ApprovalKind kind;
  final String title;
  final String? docNumber;

  /// 원래 결재의 예산(구매 합계·출장 예상 경비 — 없으면 null).
  final int? budget;
  const ApprovalSettles({
    required this.id,
    required this.kind,
    required this.title,
    this.docNumber,
    this.budget,
  });

  factory ApprovalSettles.fromJson(Map<String, dynamic> json) =>
      ApprovalSettles(
        id: json['id'] as String? ?? '',
        kind: ApprovalKind.fromWire(json['kind'] as String?),
        title: json['title'] as String? ?? '',
        docNumber: json['docNumber'] as String?,
        budget: (json['budget'] as num?)?.toInt(),
      );
}

/// 정산할 수 있는 결재 종류(서버 settlementRules.js SETTLE_KINDS).
const kSettleKinds = {ApprovalKind.purchase, ApprovalKind.trip};

/// 원래 결재의 예산(원) — 구매는 품목 합계, 출장은 예상 경비. 없으면 null(서버 settleBudgetOf).
int? settleBudgetOf(ApprovalDocument doc) {
  final p = doc.payload;
  if (doc.kind == ApprovalKind.purchase) {
    return (p['total'] as num?)?.toInt() ??
        (((p['values'] as Map?)?['items'] as Map?)?['total'] as num?)?.toInt();
  }
  if (doc.kind == ApprovalKind.trip) {
    return ((p['values'] as Map?)?['cost'] as num?)?.toInt();
  }
  return null;
}

/// 결재 상태 — 서버 approvalRules.js APPROVAL_STATUSES.
enum ApprovalStatus {
  pending('pending', '진행 중'),
  approved('approved', '승인'),
  rejected('rejected', '반려'),
  withdrawn('withdrawn', '회수'),
  canceled('canceled', '취소');

  final String wire;
  final String _labelKo;

  /// 화면에 보일 이름(지금 언어 — l10n/tr.dart).
  String get label => tr(_labelKo);
  const ApprovalStatus(this.wire, this._labelKo);

  static ApprovalStatus fromWire(String? value) =>
      values.firstWhere((s) => s.wire == value, orElse: () => pending);
}

/// 결재선 한 칸의 상태.
enum ApprovalStepStatus {
  waiting('waiting', '대기'),
  pending('pending', '결재 차례'),
  approved('approved', '승인'),
  rejected('rejected', '반려'),

  /// 전결로 생략된 칸.
  skipped('skipped', '생략');

  final String wire;
  final String _labelKo;

  /// 화면에 보일 이름(지금 언어 — l10n/tr.dart).
  String get label => tr(_labelKo);
  const ApprovalStepStatus(this.wire, this._labelKo);

  static ApprovalStepStatus fromWire(String? value) =>
      values.firstWhere((s) => s.wire == value, orElse: () => waiting);
}

/// 결재선 칸의 역할 — 서버 approvalRules.js LINE_ROLES. 이어진 합의 칸은 한 단계(동시에 차례), 전결은 승인하면 남은 칸을 생략한다.
enum LineRole {
  approve('approve', '결재'),
  agree('agree', '합의'),
  finalApprove('final', '전결');

  final String wire;
  final String _labelKo;

  /// 화면에 보일 이름(지금 언어 — l10n/tr.dart).
  String get label => tr(_labelKo);
  const LineRole(this.wire, this._labelKo);

  static LineRole fromWire(String? value) =>
      values.firstWhere((r) => r.wire == value, orElse: () => approve);

  /// 결재선에서 눌러 바꿀 때의 다음 역할(결재 → 합의 → 전결 → 결재).
  LineRole get next => values[(index + 1) % values.length];
}

/// 서버에 보낼 역할 묶음 — 결재가 아닌 칸만 { userId: 'agree' | 'final' }.
Map<String, String> rolesToJson(Map<String, LineRole> roles) => {
  for (final e in roles.entries)
    if (e.value != LineRole.approve) e.key: e.value.wire,
};

Map<String, LineRole> rolesFromJson(Object? json) => {
  if (json is Map)
    for (final e in json.entries)
      e.key as String: LineRole.fromWire(e.value as String?),
};

/// 대결(부재 중 대신 결재) 설정 — 서버 GET /groupware/delegations.
class ApprovalDelegation {
  final String id;
  final String userId;
  final String userName;
  final String delegateId;
  final String delegateName;
  final String startDate;
  final String endDate;
  final String? reason;
  const ApprovalDelegation({
    required this.id,
    required this.userId,
    required this.userName,
    required this.delegateId,
    required this.delegateName,
    required this.startDate,
    required this.endDate,
    this.reason,
  });

  factory ApprovalDelegation.fromJson(Map<String, dynamic> json) =>
      ApprovalDelegation(
        id: json['id'] as String,
        userId: json['userId'] as String? ?? '',
        userName: json['userName'] as String? ?? '',
        delegateId: json['delegateId'] as String? ?? '',
        delegateName: json['delegateName'] as String? ?? '',
        startDate: json['startDate'] as String? ?? '',
        endDate: json['endDate'] as String? ?? '',
        reason: json['reason'] as String?,
      );

  /// [today]에 효력이 있는지.
  bool activeOn(String today) =>
      startDate.compareTo(today) <= 0 && today.compareTo(endDate) <= 0;
}

/// 결재 통계의 한 줄(종류별·전체) — 서버 approvalRules.js approvalStats.
class ApprovalStatsRow {
  final String label;
  final int total;
  final int pending;
  final int approved;
  final int rejected;
  final int withdrawn;
  final int canceled;
  final double? avgHours;
  const ApprovalStatsRow({
    this.label = '',
    this.total = 0,
    this.pending = 0,
    this.approved = 0,
    this.rejected = 0,
    this.withdrawn = 0,
    this.canceled = 0,
    this.avgHours,
  });

  factory ApprovalStatsRow.fromJson(Map<String, dynamic> j) {
    int n(String k) => (j[k] as num?)?.toInt() ?? 0;
    return ApprovalStatsRow(
      label: j['label'] as String? ?? '',
      total: n('total'),
      pending: n('pending'),
      approved: n('approved'),
      rejected: n('rejected'),
      withdrawn: n('withdrawn'),
      canceled: n('canceled'),
      avgHours: (j['avgHours'] as num?)?.toDouble(),
    );
  }
}

/// 결재자별 통계.
class ApproverStatsRow {
  final String userId;
  final String name;
  final int decided;
  final int approved;
  final int rejected;
  final int proxied;
  final int waiting;
  final double? avgHours;
  const ApproverStatsRow({
    required this.userId,
    required this.name,
    this.decided = 0,
    this.approved = 0,
    this.rejected = 0,
    this.proxied = 0,
    this.waiting = 0,
    this.avgHours,
  });

  factory ApproverStatsRow.fromJson(Map<String, dynamic> j) {
    int n(String k) => (j[k] as num?)?.toInt() ?? 0;
    return ApproverStatsRow(
      userId: j['userId'] as String? ?? '',
      name: j['name'] as String? ?? '',
      decided: n('decided'),
      approved: n('approved'),
      rejected: n('rejected'),
      proxied: n('proxied'),
      waiting: n('waiting'),
      avgHours: (j['avgHours'] as num?)?.toDouble(),
    );
  }
}

class ApprovalStats {
  final String from;
  final String to;
  final ApprovalStatsRow totals;
  final List<ApprovalStatsRow> byKind;
  final List<ApproverStatsRow> byApprover;
  const ApprovalStats({
    required this.from,
    required this.to,
    required this.totals,
    this.byKind = const [],
    this.byApprover = const [],
  });

  factory ApprovalStats.fromJson(Map<String, dynamic> j) => ApprovalStats(
    from: j['from'] as String? ?? '',
    to: j['to'] as String? ?? '',
    totals: ApprovalStatsRow.fromJson(
      (j['totals'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    byKind: [
      for (final r in j['byKind'] as List? ?? const [])
        ApprovalStatsRow.fromJson((r as Map).cast<String, dynamic>()),
    ],
    byApprover: [
      for (final r in j['byApprover'] as List? ?? const [])
        ApproverStatsRow.fromJson((r as Map).cast<String, dynamic>()),
    ],
  );
}

/// "3.5시간" / "2일 4시간" — 평균 처리 시간 글자(없으면 '—').
String hoursText(double? hours) {
  if (hours == null) return '—';
  if (hours < 24) {
    return tr('{p0}시간', {
      'p0': hours == hours.roundToDouble()
          ? hours.toInt()
          : hours.toStringAsFixed(1),
    });
  }
  final days = hours ~/ 24;
  final rest = (hours - days * 24).round();
  return rest == 0
      ? tr('{days}일', {'days': days})
      : tr('{days}일 {rest}시간', {'days': days, 'rest': rest});
}

/// 결재함 — 서버 GET /groupware/documents?box=.
enum ApprovalBox {
  inbox('inbox', '결재할 문서'),
  mine('mine', '내가 올린 문서'),
  done('done', '결재한 문서'),
  cc('cc', '참조 문서'),
  all('all', '전체 문서');

  final String wire;
  final String _labelKo;

  /// 화면에 보일 이름(지금 언어 — l10n/tr.dart).
  String get label => tr(_labelKo);
  const ApprovalBox(this.wire, this._labelKo);
}

DateTime? _time(Object? v) =>
    v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;

/// 반일 단위 → "3일" / "2.5일" — 서버 annualLeave.js halfDaysText와 같다.
String halfDaysText(int halfDays) {
  final text = halfDays % 2 == 0
      ? '${halfDays ~/ 2}'
      : (halfDays / 2).toStringAsFixed(1);
  return tr('{text}일', {'text': text});
}

/// 하루 중 분 → 'HH:MM'.
String minutesText(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

/// 시각 → 'HH:MM'(기기 시간대).
String clockText(DateTime? at) =>
    at == null ? '--:--' : minutesText(at.hour * 60 + at.minute);

/// 'YYYY-MM-DD' → "10/19".
String shortDateText(String key) => key.length >= 10
    ? '${int.parse(key.substring(5, 7))}/${int.parse(key.substring(8, 10))}'
    : key;

/// [d]의 'YYYY-MM-DD'(기기 날짜).
String dateKeyOf(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 금액 → "12,000원".
String wonText(int amount) {
  final digits = amount.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return tr('{buffer}원', {'buffer': buffer});
}

/// 휴가 종류 — 서버 annualLeave.js LEAVE_TYPES.
class LeaveTypeInfo {
  final String key;
  final String label;
  final bool deducts;
  final bool half;

  /// 지금 신청할 수 있는지(관리자가 끈 종류는 예전 신청의 이름을 보이려고 목록에 남는다).
  final bool enabled;

  /// 기본 종류인지(관리자가 더한 종류는 false — 이름·차감 여부를 바꿀 수 있다).
  final bool builtin;
  const LeaveTypeInfo({
    required this.key,
    required this.label,
    required this.deducts,
    required this.half,
    this.enabled = true,
    this.builtin = true,
  });

  factory LeaveTypeInfo.fromJson(Map<String, dynamic> json) => LeaveTypeInfo(
    key: json['key'] as String,
    label: json['label'] as String? ?? json['key'] as String,
    deducts: json['deducts'] as bool? ?? false,
    half: json['half'] as bool? ?? false,
    enabled: json['enabled'] as bool? ?? true,
    builtin: json['builtin'] as bool? ?? true,
  );

  Map<String, dynamic> toJson() => {
    'key': key,
    'label': label,
    'enabled': enabled,
    if (!builtin) 'deducts': deducts,
  };
}

/// 유연근무 — 사람마다의 근무 형태(서버 workRules.js). 없으면 범위의 근무 시간.
class WorkSchedule {
  /// 'staggered'(시차출퇴근) | 'core'(선택근무) | 'free'(자율 출퇴근).
  final String mode;
  final String label;
  final int? start;
  final int? end;
  final int? coreStart;
  final int? coreEnd;
  const WorkSchedule({
    required this.mode,
    required this.label,
    this.start,
    this.end,
    this.coreStart,
    this.coreEnd,
  });

  static WorkSchedule? fromJson(Object? json) {
    if (json is! Map) return null;
    int? n(String k) => (json[k] as num?)?.toInt();
    return WorkSchedule(
      mode: json['mode'] as String? ?? 'free',
      label: json['label'] as String? ?? '',
      start: n('start'),
      end: n('end'),
      coreStart: n('coreStart'),
      coreEnd: n('coreEnd'),
    );
  }

  /// "시차출퇴근 07:00~16:00" / "선택근무(핵심 10:00~15:00)" / "자율 출퇴근".
  String get description => switch (mode) {
    'staggered' => '$label ${minutesText(start ?? 0)}~${minutesText(end ?? 0)}',
    'core' => tr('{label}(핵심 {p0}~{p1})', {
      'label': label,
      'p0': minutesText(coreStart ?? 0),
      'p1': minutesText(coreEnd ?? 0),
    }),
    _ => label,
  };
}

/// 하루 근로 나누기 — 서버 workRules.js workBreakdown(퇴근을 눌러야 계산).
class WorkBreakdown {
  final int workedMinutes;
  final int breakMinutes;
  final int netMinutes;
  final int overtimeMinutes;
  final int holidayMinutes;
  final int nightMinutes;
  const WorkBreakdown({
    this.workedMinutes = 0,
    this.breakMinutes = 0,
    this.netMinutes = 0,
    this.overtimeMinutes = 0,
    this.holidayMinutes = 0,
    this.nightMinutes = 0,
  });

  factory WorkBreakdown.fromJson(Object? json) {
    if (json is! Map) return const WorkBreakdown();
    int n(String k) => (json[k] as num?)?.toInt() ?? 0;
    return WorkBreakdown(
      workedMinutes: n('workedMinutes'),
      breakMinutes: n('breakMinutes'),
      netMinutes: n('netMinutes'),
      overtimeMinutes: n('overtimeMinutes'),
      holidayMinutes: n('holidayMinutes'),
      nightMinutes: n('nightMinutes'),
    );
  }
}

/// 한 주(월~일) 근로시간 — 서버 workRules.js weeklySummary. [status] 'ok' | 'warn'(48시간 이상) | 'over'(52시간 넘음).
class WeeklyHours {
  final String weekStart;
  final String weekEnd;
  final int netMinutes;
  final int overtimeMinutes;
  final int holidayMinutes;
  final int nightMinutes;
  final String status;
  const WeeklyHours({
    required this.weekStart,
    required this.weekEnd,
    this.netMinutes = 0,
    this.overtimeMinutes = 0,
    this.holidayMinutes = 0,
    this.nightMinutes = 0,
    this.status = 'ok',
  });

  static WeeklyHours? fromJson(Object? json) {
    if (json is! Map) return null;
    int n(String k) => (json[k] as num?)?.toInt() ?? 0;
    return WeeklyHours(
      weekStart: json['weekStart'] as String? ?? '',
      weekEnd: json['weekEnd'] as String? ?? '',
      netMinutes: n('netMinutes'),
      overtimeMinutes: n('overtimeMinutes'),
      holidayMinutes: n('holidayMinutes'),
      nightMinutes: n('nightMinutes'),
      status: json['status'] as String? ?? 'ok',
    );
  }
}

/// 분 → "8시간 30분" / "45분" / "0시간".
String durationText(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0 && m == 0) return tr('0시간');
  if (m == 0) return tr('{h}시간', {'h': h});
  if (h == 0) return tr('{m}분', {'m': m});
  return tr('{h}시간 {m}분', {'h': h, 'm': m});
}

/// 출근 형태 — 서버 workRules.js CLOCK_IN_MODES.
final clockInModeLabels = {
  'office': tr('사무실'),
  'field': tr('외근'),
  'remote': tr('재택'),
};

/// 그룹웨어 화면을 열 때 받는 값 — 범위, 관리자인지, 근무 시간, 고를 것들(휴가 종류·지출 분류), 내가 결재할 문서 수.
class GroupwareContext {
  /// 'team'(팀마다) | 'server'(회사 전체).
  final String scope;

  /// 관리자 콘솔의 설정 값 — 'org' | 'team' | 'server'.
  final String scopeSetting;
  final String? teamId;
  final String? teamName;
  final bool isManager;
  final int workStart;
  final int workEnd;
  final String today;
  final String? hireDate;
  final int pendingForMe;
  final List<LeaveTypeInfo> leaveTypes;
  final List<String> expenseCategories;
  final int approversMax;
  final int ccMax;
  final int attachmentsMax;

  /// 지금 사내 와이파이인지(서버가 본 내 접속 주소).
  final bool inLan;

  /// 내 서명·도장(서명 링크) — 없으면 null.
  final String? signatureUrl;

  /// 내 근무 형태(유연근무 — 없으면 null)와 그 기준의 근무 시작·끝(분).
  final WorkSchedule? schedule;
  final int? myWorkStart;
  final int? myWorkEnd;

  /// 주 52시간(분)과 주의 선(48시간).
  final int weeklyLimitMinutes;
  final int weeklyWarnMinutes;

  const GroupwareContext({
    required this.scope,
    required this.scopeSetting,
    this.teamId,
    this.teamName,
    required this.isManager,
    required this.workStart,
    required this.workEnd,
    required this.today,
    this.hireDate,
    required this.pendingForMe,
    required this.leaveTypes,
    required this.expenseCategories,
    this.approversMax = 5,
    this.ccMax = 10,
    this.attachmentsMax = 5,
    this.inLan = false,
    this.signatureUrl,
    this.schedule,
    this.myWorkStart,
    this.myWorkEnd,
    this.weeklyLimitMinutes = 52 * 60,
    this.weeklyWarnMinutes = 48 * 60,
  });

  /// 신청할 수 있는(켜진) 휴가 종류.
  List<LeaveTypeInfo> get enabledLeaveTypes => [
    for (final t in leaveTypes)
      if (t.enabled) t,
  ];

  factory GroupwareContext.fromJson(Map<String, dynamic> json) {
    final limits =
        (json['limits'] as Map?)?.cast<String, dynamic>() ?? const {};
    return GroupwareContext(
      scope: json['scope'] as String? ?? 'team',
      scopeSetting: json['scopeSetting'] as String? ?? 'org',
      teamId: json['teamId'] as String?,
      teamName: json['teamName'] as String?,
      isManager: json['isManager'] as bool? ?? false,
      workStart: (json['workStart'] as num?)?.toInt() ?? 540,
      workEnd: (json['workEnd'] as num?)?.toInt() ?? 1080,
      today: json['today'] as String? ?? dateKeyOf(DateTime.now()),
      hireDate: json['hireDate'] as String?,
      pendingForMe: (json['pendingForMe'] as num?)?.toInt() ?? 0,
      leaveTypes: [
        for (final t in (json['leaveTypes'] as List? ?? const []))
          LeaveTypeInfo.fromJson((t as Map).cast<String, dynamic>()),
      ],
      expenseCategories: (json['expenseCategories'] as List? ?? const [])
          .cast<String>(),
      approversMax: (limits['approversMax'] as num?)?.toInt() ?? 5,
      ccMax: (limits['ccMax'] as num?)?.toInt() ?? 10,
      attachmentsMax: (limits['attachmentsMax'] as num?)?.toInt() ?? 5,
      inLan: json['inLan'] as bool? ?? false,
      signatureUrl: json['signatureUrl'] as String?,
      schedule: WorkSchedule.fromJson(json['schedule']),
      myWorkStart: (json['myWorkStart'] as num?)?.toInt(),
      myWorkEnd: (json['myWorkEnd'] as num?)?.toInt(),
      weeklyLimitMinutes:
          (json['weeklyLimitMinutes'] as num?)?.toInt() ?? 52 * 60,
      weeklyWarnMinutes:
          (json['weeklyWarnMinutes'] as num?)?.toInt() ?? 48 * 60,
    );
  }

  LeaveTypeInfo? leaveType(String? key) {
    for (final t in leaveTypes) {
      if (t.key == key) return t;
    }
    return null;
  }

  String get scopeLabel =>
      scope == 'server' ? tr('회사 전체') : (teamName ?? tr('팀'));
}

/// 결재자·참조자 후보.
class ApprovalCandidate {
  final String id;
  final String name;
  final String username;
  const ApprovalCandidate({
    required this.id,
    required this.name,
    required this.username,
  });

  factory ApprovalCandidate.fromJson(Map<String, dynamic> json) =>
      ApprovalCandidate(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        username: json['username'] as String? ?? '',
      );
}

/// 저장한 결재선.
class ApprovalLine {
  final String id;
  final String name;
  final List<String> approverIds;
  final List<String> ccIds;

  /// 결재가 아닌 칸의 역할(합의·전결).
  final Map<String, LineRole> roles;
  const ApprovalLine({
    required this.id,
    required this.name,
    required this.approverIds,
    required this.ccIds,
    this.roles = const {},
  });

  factory ApprovalLine.fromJson(Map<String, dynamic> json) => ApprovalLine(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    approverIds: (json['approverIds'] as List? ?? const []).cast<String>(),
    ccIds: (json['ccIds'] as List? ?? const []).cast<String>(),
    roles: rolesFromJson(json['roles']),
  );
}

/// 저장한 결재선들과 새 결재에 미리 채울 결재선(서버 approvalRules.js suggestApprovalLine).
class ApprovalLines {
  final List<ApprovalLine> lines;
  final List<String> suggestedApproverIds;
  final List<String> suggestedCcIds;

  /// 추천이 어디서 왔는지 — 'form'(양식의 기본 결재선) | 'rule'(결재선 규칙) | 'org'(조직도의 상위자 사슬) | 'saved'(가장 최근에
  /// 저장한 결재선) | null(추천 없음).
  final String? suggestedSource;

  /// 양식의 기본 결재선·참조자를 썼으면 그 양식 이름("양식 기본 결재선: 구매 요청" — 참조자만 더했을 때도).
  final String? suggestedFormName;

  /// 추천에 쓴 결재선 규칙('rule'일 때 — "규칙: 지출 100만 원 이상 — 본부장까지"로 보인다).
  final ApprovalLineRule? suggestedRule;

  /// 추천 결재선의 역할(저장한 결재선에서 온 경우).
  final Map<String, LineRole> suggestedRoles;
  const ApprovalLines({
    this.lines = const [],
    this.suggestedApproverIds = const [],
    this.suggestedCcIds = const [],
    this.suggestedSource,
    this.suggestedRoles = const {},
    this.suggestedRule,
    this.suggestedFormName,
  });

  factory ApprovalLines.fromJson(Map<String, dynamic> json) {
    final suggested = (json['suggested'] as Map?)?.cast<String, dynamic>();
    return ApprovalLines(
      lines: [
        for (final l in (json['lines'] as List? ?? const []))
          ApprovalLine.fromJson((l as Map).cast<String, dynamic>()),
      ],
      suggestedApproverIds: (suggested?['approverIds'] as List? ?? const [])
          .cast<String>(),
      suggestedCcIds: (suggested?['ccIds'] as List? ?? const []).cast<String>(),
      suggestedSource: suggested?['source'] as String?,
      suggestedRoles: rolesFromJson(suggested?['roles']),
      suggestedRule: suggested?['rule'] is Map
          ? ApprovalLineRule.fromJson(
              (suggested!['rule'] as Map).cast<String, dynamic>(),
            )
          : null,
      suggestedFormName: (suggested?['form'] as Map?)?['name'] as String?,
    );
  }
}

class ApprovalStep {
  final String id;
  final int order;

  /// 단계 — 같은 단계의 칸(합의)은 함께 차례가 된다.
  final int stage;
  final LineRole role;
  final String? approverId;
  final String approverName;
  final ApprovalStepStatus status;
  final String? comment;
  final DateTime? decidedAt;

  /// 대결로 대신 결정한 사람(본인이 했으면 null).
  final String? actedByName;

  /// 승인할 때의 서명·도장(서명 링크).
  final String? signatureUrl;
  const ApprovalStep({
    required this.id,
    required this.order,
    int? stage,
    this.role = LineRole.approve,
    this.approverId,
    required this.approverName,
    required this.status,
    this.comment,
    this.decidedAt,
    this.actedByName,
    this.signatureUrl,
  }) : stage = stage ?? order;

  factory ApprovalStep.fromJson(Map<String, dynamic> json) => ApprovalStep(
    id: json['id'] as String,
    order: (json['order'] as num?)?.toInt() ?? 0,
    stage: (json['stage'] as num?)?.toInt(),
    role: LineRole.fromWire(json['role'] as String?),
    approverId: json['approverId'] as String?,
    approverName: json['approverName'] as String? ?? tr('(알 수 없음)'),
    status: ApprovalStepStatus.fromWire(json['status'] as String?),
    comment: json['comment'] as String?,
    decidedAt: _time(json['decidedAt']),
    actedByName: json['actedByName'] as String?,
    signatureUrl: json['signatureUrl'] as String?,
  );
}

class ApprovalAttachment {
  final String? fileUrl;
  final String? fileName;
  final int? fileSize;
  final String? mimeType;
  const ApprovalAttachment({
    this.fileUrl,
    this.fileName,
    this.fileSize,
    this.mimeType,
  });

  factory ApprovalAttachment.fromJson(Map<String, dynamic> json) =>
      ApprovalAttachment(
        fileUrl: json['fileUrl'] as String?,
        fileName: json['fileName'] as String?,
        fileSize: (json['fileSize'] as num?)?.toInt(),
        mimeType: json['mimeType'] as String?,
      );
}

/// 결재 문서 하나.
class ApprovalDocument {
  final String id;
  final ApprovalKind kind;

  /// 문서 번호("휴가-2026-0012") — 이 기능 전 문서는 null.
  final String? docNumber;
  final String title;
  final String? body;

  /// 종류별 내용 — 휴가 { leaveType, startDate, endDate, halfDays }, 지출 { amount, category, spentOn }, 근태 수정
  /// { workDate, clockIn, clockOut }.
  final Map<String, dynamic> payload;
  final List<ApprovalAttachment> attachments;
  final ApprovalStatus status;
  final String? authorId;
  final String authorName;
  final DateTime? createdAt;
  final DateTime? decidedAt;
  final String? cancelReason;
  final String? canceledByName;
  final List<ApprovalStep> steps;

  /// 참조자(상세에서만).
  final List<({String id, String name})> cc;
  final bool myTurn;
  final bool canWithdraw;
  final bool canCancel;

  /// 구매 요청·출장 신청 — 이 결재를 정산하는 지출 결재(없으면 null)와 "정산하기"를 누를 수 있는지(올린 사람·승인됨·살아 있는 정산
  /// 없음 — 서버 settlementRules.js).
  final ApprovalSettlement? settlement;
  final bool canSettle;

  /// 대결로 내 차례면 누구 대신인지.
  final String? actingFor;

  /// 내 칸이 전결이면 승인하는 순간 결재가 끝난다.
  final bool finalForMe;

  const ApprovalDocument({
    required this.id,
    required this.kind,
    this.docNumber,
    this.actingFor,
    this.finalForMe = false,
    required this.title,
    this.body,
    this.payload = const {},
    this.attachments = const [],
    required this.status,
    this.authorId,
    required this.authorName,
    this.createdAt,
    this.decidedAt,
    this.cancelReason,
    this.canceledByName,
    this.steps = const [],
    this.cc = const [],
    this.myTurn = false,
    this.canWithdraw = false,
    this.canCancel = false,
    this.settlement,
    this.canSettle = false,
  });

  factory ApprovalDocument.fromJson(Map<String, dynamic> json) =>
      ApprovalDocument(
        id: json['id'] as String,
        kind: ApprovalKind.fromWire(json['kind'] as String?),
        docNumber: json['docNumber'] as String?,
        actingFor: json['actingFor'] as String?,
        finalForMe: json['finalForMe'] == true,
        title: json['title'] as String? ?? '',
        body: json['body'] as String?,
        payload: (json['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
        attachments: [
          for (final a in (json['attachments'] as List? ?? const []))
            ApprovalAttachment.fromJson((a as Map).cast<String, dynamic>()),
        ],
        status: ApprovalStatus.fromWire(json['status'] as String?),
        authorId: json['authorId'] as String?,
        authorName: json['authorName'] as String? ?? tr('(알 수 없음)'),
        createdAt: _time(json['createdAt']),
        decidedAt: _time(json['decidedAt']),
        cancelReason: json['cancelReason'] as String?,
        canceledByName: json['canceledByName'] as String?,
        steps: [
          for (final s in (json['steps'] as List? ?? const []))
            ApprovalStep.fromJson((s as Map).cast<String, dynamic>()),
        ],
        cc: [
          for (final c in (json['cc'] as List? ?? const []))
            if (c is Map)
              (id: c['id'] as String? ?? '', name: c['name'] as String? ?? ''),
        ],
        myTurn: json['myTurn'] as bool? ?? false,
        canWithdraw: json['canWithdraw'] as bool? ?? false,
        canCancel: json['canCancel'] as bool? ?? false,
        settlement: json['settlement'] is Map
            ? ApprovalSettlement.fromJson(
                (json['settlement'] as Map).cast<String, dynamic>(),
              )
            : null,
        canSettle: json['canSettle'] == true,
      );

  /// 지출 결재가 정산하는 원래 결재(구매·출장 — 없으면 null).
  ApprovalSettles? get settles => payload['settles'] is Map
      ? ApprovalSettles.fromJson(
          (payload['settles'] as Map).cast<String, dynamic>(),
        )
      : null;

  /// 지금 결재할 차례인 칸(진행 중일 때만).
  ApprovalStep? get currentStep {
    for (final s in steps) {
      if (s.status == ApprovalStepStatus.pending) return s;
    }
    return null;
  }

  /// 양식으로 올린 문서의 칸 정의(그때의 것 — 양식을 고쳐도 그대로).
  List<FormFieldDef> get formFields => [
    for (final f in payload['fields'] as List? ?? const [])
      if (f is Map) FormFieldDef.fromJson(f.cast<String, dynamic>()),
  ];

  /// 양식으로 올린 문서의 값(칸 key → 값).
  Map<String, dynamic> get formValues =>
      (payload['values'] as Map?)?.cast<String, dynamic>() ?? const {};

  /// 문서의 종류 이름 — 관리자가 만든 양식이면 그 양식 이름.
  String get kindLabel => kind == ApprovalKind.form
      ? (payload['templateName'] as String? ?? tr('결재'))
      : kind.label;

  /// 목록 한 줄의 요약 — 휴가 기간·양, 지출 금액, 근태 수정 날짜·시각, 양식은 종류별 요점.
  String summary(GroupwareContext? ctx) {
    switch (kind) {
      case ApprovalKind.draft:
        final budget = (payload['values'] as Map?)?['budget'] as num?;
        return budget == null
            ? tr('일반 기안서')
            : tr('일반 기안서 · 예산 {p0}', {'p0': wonText(budget.toInt())});
      case ApprovalKind.trip:
        final start = payload['startDate'] as String? ?? '';
        final end = payload['endDate'] as String? ?? start;
        final range = start == end
            ? shortDateText(start)
            : '${shortDateText(start)}~${shortDateText(end)}';
        return tr('{p0} · {range} · {p1}일', {
          'p0': payload['destination'] ?? '',
          'range': range,
          'p1': payload['days'] ?? 1,
        });
      case ApprovalKind.purchase:
        return tr('품목 {p0}건 · {p1}', {
          'p0': payload['itemCount'] ?? 0,
          'p1': wonText((payload['total'] as num?)?.toInt() ?? 0),
        });
      case ApprovalKind.overtime:
        final minutes = (payload['minutes'] as num?)?.toInt() ?? 0;
        return tr('{p0} · {p1} {p2}~{p3} · {p4}시간', {
          'p0': payload['overtimeType'] ?? '',
          'p1': shortDateText(payload['workDate'] as String? ?? ''),
          'p2': payload['startTime'] ?? '',
          'p3': payload['endTime'] ?? '',
          'p4': (minutes / 60).toStringAsFixed(minutes % 60 == 0 ? 0 : 1),
        });
      case ApprovalKind.form:
        return kindLabel;
      case ApprovalKind.leave:
        final label =
            payload['leaveLabel'] as String? ??
            ctx?.leaveType(payload['leaveType'] as String?)?.label ??
            tr('휴가');
        final start = payload['startDate'] as String? ?? '';
        final end = payload['endDate'] as String? ?? start;
        final range = start == end
            ? shortDateText(start)
            : '${shortDateText(start)}~${shortDateText(end)}';
        final half = (payload['halfDays'] as num?)?.toInt() ?? 0;
        return '$label · $range · ${halfDaysText(half)}';
      case ApprovalKind.expense:
        final amount = (payload['amount'] as num?)?.toInt() ?? 0;
        return '${payload['category'] ?? ''} · ${wonText(amount)}';
      case ApprovalKind.attendance:
        final out = payload['clockOut'] as String?;
        return tr('{p0} · 출근 {p1}{p2}', {
          'p0': shortDateText(payload['workDate'] as String? ?? ''),
          'p1': payload['clockIn'] ?? '',
          'p2': out == null ? '' : tr(' · 퇴근 {out}', {'out': out}),
        });
    }
  }
}

class LeaveAdjustment {
  final String id;
  final int halfDays;
  final String reason;
  final String createdByName;
  final DateTime? createdAt;
  const LeaveAdjustment({
    required this.id,
    required this.halfDays,
    required this.reason,
    required this.createdByName,
    this.createdAt,
  });

  factory LeaveAdjustment.fromJson(Map<String, dynamic> json) =>
      LeaveAdjustment(
        id: json['id'] as String,
        halfDays: (json['halfDays'] as num?)?.toInt() ?? 0,
        reason: json['reason'] as String? ?? '',
        createdByName: json['createdByName'] as String? ?? '',
        createdAt: _time(json['createdAt']),
      );
}

/// 연차 현황 — 입사일이 없으면 granted·remaining이 null(얼마나 남았는지 모름).
class LeaveBalance {
  final String? hireDate;
  final String? periodStart;
  final String? periodEnd;

  /// 근속 연수(0이면 입사 첫해).
  final int? serviceYears;
  final int? statutoryHalfDays;
  final int adjustmentHalfDays;
  final int? grantedHalfDays;
  final int usedHalfDays;
  final int pendingHalfDays;
  final int? remainingHalfDays;
  final List<LeaveAdjustment> adjustments;

  const LeaveBalance({
    this.hireDate,
    this.periodStart,
    this.periodEnd,
    this.serviceYears,
    this.statutoryHalfDays,
    this.adjustmentHalfDays = 0,
    this.grantedHalfDays,
    this.usedHalfDays = 0,
    this.pendingHalfDays = 0,
    this.remainingHalfDays,
    this.adjustments = const [],
  });

  factory LeaveBalance.fromJson(Map<String, dynamic> json) {
    final period = (json['period'] as Map?)?.cast<String, dynamic>();
    int? n(Object? v) => (v as num?)?.toInt();
    return LeaveBalance(
      hireDate: json['hireDate'] as String?,
      periodStart: period?['start'] as String?,
      periodEnd: period?['end'] as String?,
      serviceYears: n(period?['year']),
      statutoryHalfDays: n(json['statutoryHalfDays']),
      adjustmentHalfDays: n(json['adjustmentHalfDays']) ?? 0,
      grantedHalfDays: n(json['grantedHalfDays']),
      usedHalfDays: n(json['usedHalfDays']) ?? 0,
      pendingHalfDays: n(json['pendingHalfDays']) ?? 0,
      remainingHalfDays: n(json['remainingHalfDays']),
      adjustments: [
        for (final a in (json['adjustments'] as List? ?? const []))
          LeaveAdjustment.fromJson((a as Map).cast<String, dynamic>()),
      ],
    );
  }

  bool get known => grantedHalfDays != null;
}

/// 팀 휴가 목록의 한 줄(승인된 휴가).
class TeamLeave {
  final String documentId;
  final String? userId;
  final String name;
  final String leaveType;

  /// 신청할 때의 휴가 종류 이름(관리자가 이름을 바꿔도 그때 이름) — 예전 신청은 null.
  final String? leaveLabel;
  final String startDate;
  final String endDate;
  final int halfDays;
  const TeamLeave({
    this.leaveLabel,
    required this.documentId,
    this.userId,
    required this.name,
    required this.leaveType,
    required this.startDate,
    required this.endDate,
    required this.halfDays,
  });

  factory TeamLeave.fromJson(Map<String, dynamic> json) => TeamLeave(
    leaveLabel: json['leaveLabel'] as String?,
    documentId: json['documentId'] as String,
    userId: json['userId'] as String?,
    name: json['name'] as String? ?? '',
    leaveType: json['leaveType'] as String? ?? '',
    startDate: json['startDate'] as String? ?? '',
    endDate: json['endDate'] as String? ?? '',
    halfDays: (json['halfDays'] as num?)?.toInt() ?? 0,
  );
}

/// 출퇴근 기록 하나(지각·조퇴·일한 분은 서버가 계산해 준다).
class AttendanceRecord {
  final String id;
  final String workDate;
  final DateTime? clockInAt;
  final DateTime? clockOutAt;
  final bool? clockInLan;
  final bool? clockOutLan;
  final bool corrected;
  final DateTime? originalClockInAt;
  final DateTime? originalClockOutAt;
  final bool late;
  final bool earlyLeave;
  final int? workedMinutes;
  final bool missingClockOut;

  /// 출근 형태 — 'office' | 'field'(외근) | 'remote'(재택), 외근이면 [note]가 장소.
  final String clockInMode;
  final String? note;

  /// 휴게·실근로·연장·야간·휴일 근무.
  final WorkBreakdown breakdown;

  const AttendanceRecord({
    this.clockInMode = 'office',
    this.note,
    this.breakdown = const WorkBreakdown(),
    required this.id,
    required this.workDate,
    this.clockInAt,
    this.clockOutAt,
    this.clockInLan,
    this.clockOutLan,
    this.corrected = false,
    this.originalClockInAt,
    this.originalClockOutAt,
    this.late = false,
    this.earlyLeave = false,
    this.workedMinutes,
    this.missingClockOut = false,
  });

  factory AttendanceRecord.fromJson(Map<String, dynamic> json) =>
      AttendanceRecord(
        id: json['id'] as String,
        workDate: json['workDate'] as String? ?? '',
        clockInAt: _time(json['clockInAt']),
        clockOutAt: _time(json['clockOutAt']),
        clockInLan: json['clockInLan'] as bool?,
        clockOutLan: json['clockOutLan'] as bool?,
        corrected: json['corrected'] as bool? ?? false,
        originalClockInAt: _time(json['originalClockInAt']),
        originalClockOutAt: _time(json['originalClockOutAt']),
        late: json['late'] as bool? ?? false,
        earlyLeave: json['earlyLeave'] as bool? ?? false,
        workedMinutes: (json['workedMinutes'] as num?)?.toInt(),
        missingClockOut: json['missingClockOut'] as bool? ?? false,
        clockInMode: json['clockInMode'] as String? ?? 'office',
        note: json['note'] as String?,
        breakdown: WorkBreakdown.fromJson(json['breakdown']),
      );

  static AttendanceRecord? maybe(Object? json) => json is Map
      ? AttendanceRecord.fromJson(json.cast<String, dynamic>())
      : null;
}

/// 오늘 출퇴근 상태.
class AttendanceToday {
  final String today;
  final AttendanceRecord? record;

  /// 어제 출근하고 아직 안 닫힌 기록(야간 근무 — 퇴근을 누르면 이걸 닫는다).
  final AttendanceRecord? openRecord;
  final bool canClockIn;
  final bool canClockOut;
  final bool inLan;
  final int workStart;
  final int workEnd;

  /// 이번 주(월~일) 근로시간 — 주 52시간.
  final WeeklyHours? week;

  const AttendanceToday({
    this.week,
    required this.today,
    this.record,
    this.openRecord,
    required this.canClockIn,
    required this.canClockOut,
    required this.inLan,
    required this.workStart,
    required this.workEnd,
  });

  factory AttendanceToday.fromJson(Map<String, dynamic> json) =>
      AttendanceToday(
        today: json['today'] as String? ?? dateKeyOf(DateTime.now()),
        record: AttendanceRecord.maybe(json['record']),
        openRecord: AttendanceRecord.maybe(json['openRecord']),
        canClockIn: json['canClockIn'] as bool? ?? false,
        canClockOut: json['canClockOut'] as bool? ?? false,
        inLan: json['inLan'] as bool? ?? false,
        week: WeeklyHours.fromJson(json['week']),
        workStart: (json['workStart'] as num?)?.toInt() ?? 540,
        workEnd: (json['workEnd'] as num?)?.toInt() ?? 1080,
      );
}

/// 한 달 근태 요약 — 서버 attendanceRules.js summarizeMonth.
class AttendanceSummary {
  final int daysWorked;
  final int workedMinutes;
  final int late;
  final int earlyLeave;
  final int missingClockOut;
  final int absent;
  final int leaveHalfDays;

  /// 승인된 출장 날 수와 승인된 연장근무(분) — 출장·연장근무 신청(양식).
  final int tripDays;
  final int overtimeMinutes;

  /// 실제 기록으로 나눈 근로(분) — 실근로(휴게 뺌)·연장(하루 8시간 넘음)·야간(22~06시)·휴일.
  final int netMinutes;
  final int actualOvertimeMinutes;
  final int nightMinutes;
  final int holidayWorkMinutes;
  const AttendanceSummary({
    this.daysWorked = 0,
    this.workedMinutes = 0,
    this.late = 0,
    this.earlyLeave = 0,
    this.missingClockOut = 0,
    this.absent = 0,
    this.leaveHalfDays = 0,
    this.tripDays = 0,
    this.overtimeMinutes = 0,
    this.netMinutes = 0,
    this.actualOvertimeMinutes = 0,
    this.nightMinutes = 0,
    this.holidayWorkMinutes = 0,
  });

  factory AttendanceSummary.fromJson(Map<String, dynamic> json) {
    int n(String key) => (json[key] as num?)?.toInt() ?? 0;
    return AttendanceSummary(
      daysWorked: n('daysWorked'),
      workedMinutes: n('workedMinutes'),
      late: n('late'),
      earlyLeave: n('earlyLeave'),
      missingClockOut: n('missingClockOut'),
      absent: n('absent'),
      leaveHalfDays: n('leaveHalfDays'),
      tripDays: n('tripDays'),
      overtimeMinutes: n('overtimeMinutes'),
      netMinutes: n('netMinutes'),
      actualOvertimeMinutes: n('actualOvertimeMinutes'),
      nightMinutes: n('nightMinutes'),
      holidayWorkMinutes: n('holidayWorkMinutes'),
    );
  }

  /// 연장근무 "3시간" / "1.5시간".
  String get overtimeText {
    final hours = overtimeMinutes / 60;
    return tr('{p0}시간', {
      'p0': hours == hours.roundToDouble()
          ? hours.toInt()
          : hours.toStringAsFixed(1),
    });
  }

  /// "152.5시간".
  String get hoursText {
    final hours = workedMinutes / 60;
    return tr('{p0}시간', {
      'p0': hours == hours.roundToDouble()
          ? hours.toInt()
          : hours.toStringAsFixed(1),
    });
  }
}

/// 한 달 근태의 하루.
class AttendanceDay {
  final String date;
  final String? holiday;
  final String? leaveType;
  final int leaveHalfDays;

  /// 승인된 출장 날인지, 승인된 연장근무(분).
  final bool trip;
  final int overtimeMinutes;
  final AttendanceRecord? record;
  const AttendanceDay({
    required this.date,
    this.holiday,
    this.leaveType,
    this.leaveHalfDays = 0,
    this.trip = false,
    this.overtimeMinutes = 0,
    this.record,
  });

  factory AttendanceDay.fromJson(Map<String, dynamic> json) {
    final leave = (json['leave'] as Map?)?.cast<String, dynamic>();
    return AttendanceDay(
      date: json['date'] as String,
      holiday: json['holiday'] as String?,
      leaveType: leave?['type'] as String?,
      leaveHalfDays: (leave?['halfDays'] as num?)?.toInt() ?? 0,
      trip: json['trip'] == true,
      overtimeMinutes: (json['overtimeMinutes'] as num?)?.toInt() ?? 0,
      record: AttendanceRecord.maybe(json['record']),
    );
  }

  /// 주말인지(토·일).
  bool get weekend {
    final d = DateTime.parse(date);
    return d.weekday == DateTime.saturday || d.weekday == DateTime.sunday;
  }
}

class AttendanceMonth {
  final String month;
  final List<AttendanceDay> days;
  final AttendanceSummary summary;

  /// 이 달에 걸친 주들의 근로시간(주 52시간).
  final List<WeeklyHours> weeks;
  const AttendanceMonth({
    required this.month,
    required this.days,
    required this.summary,
    this.weeks = const [],
  });

  factory AttendanceMonth.fromJson(Map<String, dynamic> json) =>
      AttendanceMonth(
        month: json['month'] as String,
        days: [
          for (final d in (json['days'] as List? ?? const []))
            AttendanceDay.fromJson((d as Map).cast<String, dynamic>()),
        ],
        summary: AttendanceSummary.fromJson(
          (json['summary'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
        weeks: [
          for (final w in (json['weeks'] as List? ?? const []))
            ?WeeklyHours.fromJson(w),
        ],
      );
}

/// 관리자용 구성원별 한 달 근태 요약의 한 줄.
class AttendanceSummaryRow {
  final String userId;
  final String name;
  final AttendanceSummary summary;
  const AttendanceSummaryRow({
    required this.userId,
    required this.name,
    required this.summary,
  });

  factory AttendanceSummaryRow.fromJson(Map<String, dynamic> json) =>
      AttendanceSummaryRow(
        userId: json['userId'] as String,
        name: json['name'] as String? ?? '',
        summary: AttendanceSummary.fromJson(json),
      );
}

/// 관리자용 구성원 한 줄 — 입사일과 연차 현황.
class GroupwareMember {
  final String id;
  final String name;
  final String username;
  final String role;
  final bool suspended;
  final String? hireDate;
  final int? grantedHalfDays;
  final int usedHalfDays;
  final int pendingHalfDays;
  final int? remainingHalfDays;
  const GroupwareMember({
    required this.id,
    required this.name,
    required this.username,
    required this.role,
    this.suspended = false,
    this.hireDate,
    this.grantedHalfDays,
    this.usedHalfDays = 0,
    this.pendingHalfDays = 0,
    this.remainingHalfDays,
  });

  factory GroupwareMember.fromJson(Map<String, dynamic> json) {
    int? n(Object? v) => (v as num?)?.toInt();
    return GroupwareMember(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      username: json['username'] as String? ?? '',
      role: json['role'] as String? ?? 'guest',
      suspended: json['suspended'] as bool? ?? false,
      hireDate: json['hireDate'] as String?,
      grantedHalfDays: n(json['grantedHalfDays']),
      usedHalfDays: n(json['usedHalfDays']) ?? 0,
      pendingHalfDays: n(json['pendingHalfDays']) ?? 0,
      remainingHalfDays: n(json['remainingHalfDays']),
    );
  }
}

/// 결재 알림 종류 — 서버 approvalRules.js APPROVAL_NOTIFICATION_KINDS. 모르는 종류는 [other]로 읽고 그냥 보여 준다.
enum ApprovalNotificationKind {
  request('request'),
  approved('approved'),
  rejected('rejected'),
  withdrawn('withdrawn'),
  canceled('canceled'),
  other('other');

  final String wire;
  const ApprovalNotificationKind(this.wire);

  static ApprovalNotificationKind fromWire(String? value) =>
      values.firstWhere((k) => k.wire == value, orElse: () => other);
}

/// 결재 알림함의 한 건 — 알림 센터 "결재" 탭(서버 GET /groupware/notifications). 결재 요청(내 차례)·승인·반려·회수·취소.
class ApprovalNotification {
  final String id;
  final String documentId;

  /// 문서의 팀(팀 단위 범위) — 회사 전체 범위면 null.
  final String? teamId;
  final String? teamName;
  final ApprovalNotificationKind kind;
  final String title;
  final String body;
  final String? actorName;
  final ApprovalKind? docKind;
  final ApprovalStatus? docStatus;

  /// 지금 내가 결재할 차례인지 — 요청 알림을 받은 뒤 처리했거나 회수됐으면 false.
  final bool actionable;
  final DateTime createdAt;
  final bool read;

  const ApprovalNotification({
    required this.id,
    required this.documentId,
    this.teamId,
    this.teamName,
    required this.kind,
    required this.title,
    required this.body,
    this.actorName,
    this.docKind,
    this.docStatus,
    this.actionable = false,
    required this.createdAt,
    this.read = false,
  });

  factory ApprovalNotification.fromJson(Map<String, dynamic> j) =>
      ApprovalNotification(
        id: j['id'] as String,
        documentId: j['documentId'] as String,
        teamId: j['teamId'] as String?,
        teamName: j['teamName'] as String?,
        kind: ApprovalNotificationKind.fromWire(j['kind'] as String?),
        title: j['title'] as String? ?? '',
        body: j['body'] as String? ?? '',
        actorName: j['actorName'] as String?,
        docKind: j['docKind'] == null
            ? null
            : ApprovalKind.fromWire(j['docKind'] as String?),
        docStatus: j['docStatus'] == null
            ? null
            : ApprovalStatus.fromWire(j['docStatus'] as String?),
        actionable: j['actionable'] == true,
        createdAt: _time(j['createdAt']) ?? DateTime.now(),
        read: j['readAt'] != null,
      );

  ApprovalNotification asRead() => read
      ? this
      : ApprovalNotification(
          id: id,
          documentId: documentId,
          teamId: teamId,
          teamName: teamName,
          kind: kind,
          title: title,
          body: body,
          actorName: actorName,
          docKind: docKind,
          docStatus: docStatus,
          actionable: actionable,
          createdAt: createdAt,
          read: true,
        );
}

/// 결재선 규칙 — 결재 종류(와 금액)마다 조직도 상위자 사슬을 어디까지 채울지(서버 approvalLineRules.js). [kind]는 결재 종류
/// ('leave'·'expense'·'attendance'·'draft'·'trip'·'purchase'·'overtime'·'form') 또는 'any'(모든 종류), 관리자가 만든 양식은 'form'에
/// [templateId]로 한 양식만. [mode] 'levels'(상위자 [levels]명까지) | 'position'(직책이 [positionLabel] 이상인 상위자가 나올 때까지).
class ApprovalLineRule {
  final String id;
  final String kind;
  final String? templateId;
  final String? templateName;

  /// 이 금액(원) 이상일 때만 — null이면 금액과 상관없이.
  final int? minAmount;
  final String mode;
  final int? levels;
  final String? positionLabel;

  /// 사슬 뒤에 늘 붙일 결재자·늘 넣을 참조자.
  final List<String> extraApproverIds;
  final List<String> ccIds;

  const ApprovalLineRule({
    required this.id,
    required this.kind,
    this.templateId,
    this.templateName,
    this.minAmount,
    this.mode = 'levels',
    this.levels,
    this.positionLabel,
    this.extraApproverIds = const [],
    this.ccIds = const [],
  });

  factory ApprovalLineRule.fromJson(Map<String, dynamic> json) =>
      ApprovalLineRule(
        id: json['id'] as String? ?? '',
        kind: json['kind'] as String? ?? 'any',
        templateId: json['templateId'] as String?,
        templateName: json['templateName'] as String?,
        minAmount: (json['minAmount'] as num?)?.toInt(),
        mode: json['mode'] as String? ?? 'levels',
        levels: (json['levels'] as num?)?.toInt(),
        positionLabel: json['positionLabel'] as String?,
        extraApproverIds: (json['extraApproverIds'] as List? ?? const [])
            .whereType<String>()
            .toList(),
        ccIds: (json['ccIds'] as List? ?? const [])
            .whereType<String>()
            .toList(),
      );

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'templateId': templateId,
    'minAmount': minAmount,
    'mode': mode,
    'levels': levels,
    'positionLabel': positionLabel,
    'extraApproverIds': extraApproverIds,
    'ccIds': ccIds,
  };
}
