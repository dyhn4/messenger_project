import '../models/groupware.dart';
import '../models/groupware_forms.dart';
import '../models/groupware_resources.dart';
import '../models/groupware_work.dart';
import 'api_client.dart';

/// 그룹웨어 API 묶음(server/src/groupware.js) — ApiClient의 인증·401 재시도·오류 처리를 그대로 쓴다(requestJson). 모든 호출에
/// 지금 보고 있는 팀([teamId])을 실어 보낸다 — 팀 범위면 그 팀 안에서, 회사 전체 범위면 서버가 팀과 상관없이 다룬다.
class GroupwareApi {
  final ApiClient _api;
  final String? teamId;
  GroupwareApi(this._api, {this.teamId});

  String _query([Map<String, String?> extra = const {}]) {
    final params = {'teamId': teamId, ...extra}
      ..removeWhere((_, v) => v == null || v.isEmpty);
    if (params.isEmpty) return '';
    return '?${params.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value!)}').join('&')}';
  }

  Map<String, dynamic> _body([Map<String, dynamic> extra = const {}]) => {
    'teamId': ?teamId,
    ...extra,
  };

  Future<Map<String, dynamic>> _getMap(String path) async =>
      (await _api.requestJson('GET', path) as Map).cast<String, dynamic>();

  Future<List<Map<String, dynamic>>> _getList(String path) async => [
    for (final e in (await _api.requestJson('GET', path) as List))
      (e as Map).cast<String, dynamic>(),
  ];

  Future<GroupwareContext> context() async => GroupwareContext.fromJson(
    await _getMap('/api/groupware/context${_query()}'),
  );

  /// 결재자·참조자 후보 — 나는 빼고, [includeSelf]면 나도(양식의 사람 칸·양식 기본 결재선).
  Future<List<ApprovalCandidate>> candidates({
    bool includeSelf = false,
  }) async => [
    for (final c in await _getList(
      '/api/groupware/candidates${_query({'includeSelf': includeSelf ? '1' : null})}',
    ))
      ApprovalCandidate.fromJson(c),
  ];

  /// 저장한 결재선과 미리 채울 결재선 — [kind]·[amount](원)·[templateId]를 주면 그 문서에 맞는 결재선 규칙대로(서버
  /// approvalLineRules.js). 금액을 바꾸면 다시 부른다.
  Future<ApprovalLines> approvalLines({
    String? kind,
    String? templateId,
    int? amount,
  }) async => ApprovalLines.fromJson(
    await _getMap(
      '/api/groupware/approval-lines${_query({'kind': kind, 'templateId': templateId, 'amount': amount?.toString()})}',
    ),
  );

  /// 이 범위의 결재선 규칙.
  Future<List<ApprovalLineRule>> lineRules() async => [
    for (final r in await _getList('/api/groupware/line-rules${_query()}'))
      ApprovalLineRule.fromJson(r),
  ];

  /// 규칙 만들기·바꾸기(그룹웨어 관리자) — [rule.id]가 비어 있으면 새로.
  Future<ApprovalLineRule> saveLineRule(ApprovalLineRule rule) async =>
      ApprovalLineRule.fromJson(
        (await _api.requestJson(
                  rule.id.isEmpty ? 'POST' : 'PUT',
                  rule.id.isEmpty
                      ? '/api/groupware/line-rules'
                      : '/api/groupware/line-rules/${rule.id}',
                  body: _body(rule.toJson()),
                )
                as Map)
            .cast<String, dynamic>(),
      );

  Future<void> deleteLineRule(String id) async {
    await _api.requestJson(
      'DELETE',
      '/api/groupware/line-rules/$id${_query()}',
    );
  }

  Future<ApprovalLine> saveApprovalLine({
    required String name,
    required List<String> approverIds,
    required List<String> ccIds,
    Map<String, LineRole> roles = const {},
  }) async => ApprovalLine.fromJson(
    (await _api.requestJson(
              'POST',
              '/api/groupware/approval-lines',
              body: _body({
                'name': name,
                'approverIds': approverIds,
                'ccIds': ccIds,
                if (rolesToJson(roles).isNotEmpty) 'roles': rolesToJson(roles),
              }),
            )
            as Map)
        .cast<String, dynamic>(),
  );

  // ── 결재 양식(서버 approvalForms.js) ──

  /// 이 범위의 결재 양식 — 관리자에게는 꺼진 것까지.
  Future<List<ApprovalForm>> forms() async => [
    for (final f in await _getList('/api/groupware/forms${_query()}'))
      ApprovalForm.fromJson(f),
  ];

  /// 양식 만들기(관리자) — [fields]의 key는 서버가 매긴다.
  Future<ApprovalForm> createForm({
    required String name,
    String? description,
    required List<FormFieldDef> fields,
    bool allowAttachments = false,
    List<FormDefaultLineEntry>? defaultLine,
    List<String>? defaultCcIds,
  }) async => ApprovalForm.fromJson(
    (await _api.requestJson(
              'POST',
              '/api/groupware/forms',
              body: _body({
                'name': name,
                'description': ?description,
                'fields': [for (final f in fields) f.toDefinitionJson()],
                'allowAttachments': allowAttachments,
                if (defaultLine != null)
                  'defaultLine': _defaultLineJson(defaultLine),
                'defaultCcIds': ?defaultCcIds,
              }),
            )
            as Map)
        .cast<String, dynamic>(),
  );

  List<Map<String, dynamic>> _defaultLineJson(
    List<FormDefaultLineEntry> line,
  ) => [
    for (final e in line) {'userId': e.userId, 'role': e.role.wire},
  ];

  /// 양식 바꾸기(관리자) — 기본 양식은 enabled와 기본 결재선·참조자만. [defaultLine]을 빈 목록으로 보내면 기본 결재선을 지운다.
  Future<ApprovalForm> updateForm(
    String id, {
    String? name,
    String? description,
    List<FormFieldDef>? fields,
    bool? allowAttachments,
    bool? enabled,
    List<FormDefaultLineEntry>? defaultLine,
    List<String>? defaultCcIds,
  }) async => ApprovalForm.fromJson(
    (await _api.requestJson(
              'PATCH',
              '/api/groupware/forms/$id',
              body: _body({
                'name': ?name,
                'description': ?description,
                if (fields != null)
                  'fields': [for (final f in fields) f.toDefinitionJson()],
                'allowAttachments': ?allowAttachments,
                'enabled': ?enabled,
                if (defaultLine != null)
                  'defaultLine': _defaultLineJson(defaultLine),
                'defaultCcIds': ?defaultCcIds,
              }),
            )
            as Map)
        .cast<String, dynamic>(),
  );

  Future<void> deleteForm(String id) =>
      _api.requestJson('DELETE', '/api/groupware/forms/$id${_query()}');

  /// 양식으로 결재 올리기 — [values]는 칸 key → 값(기간·시간대는 {start, end}, 품목 표는 [{name, qty, unitPrice}]).
  Future<ApprovalDocument> submitForm({
    required ApprovalForm form,
    required Map<String, dynamic> values,
    String? title,
    List<Map<String, dynamic>> attachments = const [],
    required List<String> approverIds,
    List<String> ccIds = const [],
    Map<String, LineRole> roles = const {},
  }) => submit(
    roles: roles,
    kind: form.kind,
    fields: {
      if (!form.builtin) 'formId': form.id,
      'values': values,
      if (attachments.isNotEmpty) 'attachments': attachments,
    },
    title: title,
    approverIds: approverIds,
    ccIds: ccIds,
  );

  // ── 대결·서명·통계 ──

  /// 대결 설정 — 내가 맡긴 것과 맡은 것([all]이면 관리자가 이 범위 전부).
  Future<List<ApprovalDelegation>> delegations({bool all = false}) async => [
    for (final d in await _getList(
      '/api/groupware/delegations${_query({'all': all ? '1' : null})}',
    ))
      ApprovalDelegation.fromJson(d),
  ];

  Future<ApprovalDelegation> createDelegation({
    required String delegateId,
    required String startDate,
    required String endDate,
    String? reason,
    String? userId,
  }) async => ApprovalDelegation.fromJson(
    (await _api.requestJson(
              'POST',
              '/api/groupware/delegations',
              body: _body({
                'delegateId': delegateId,
                'startDate': startDate,
                'endDate': endDate,
                'reason': ?reason,
                'userId': ?userId,
              }),
            )
            as Map)
        .cast<String, dynamic>(),
  );

  Future<void> deleteDelegation(String id) =>
      _api.requestJson('DELETE', '/api/groupware/delegations/$id');

  /// 내 서명·도장을 올린 그림으로 — 서명 링크를 돌려준다.
  Future<String?> setSignature(String fileUrl) async =>
      ((await _api.requestJson(
                'PUT',
                '/api/groupware/signature',
                body: {'fileUrl': fileUrl},
              ))
              as Map)['signatureUrl']
          as String?;

  Future<void> deleteSignature() =>
      _api.requestJson('DELETE', '/api/groupware/signature');

  /// 결재 통계(관리자) — [from]~[to] 'YYYY-MM-DD'.
  Future<ApprovalStats> stats({
    required String from,
    required String to,
  }) async => ApprovalStats.fromJson(
    await _getMap('/api/groupware/stats${_query({'from': from, 'to': to})}'),
  );

  /// 결재 통계 엑셀 내려받기 경로(Session.downloadAuthedFile에 넘긴다 — 요약·결재자별·문서 세 시트).
  String statsExportPath({required String from, required String to}) =>
      '/api/groupware/stats/export${_query({'from': from, 'to': to})}';

  /// 결재 문서의 전자서명 검증(문서를 볼 수 있는 사람).
  Future<ApprovalVerification> verifyDocument(String id) async =>
      ApprovalVerification.fromJson(
        await _getMap('/api/groupware/documents/$id/verify'),
      );

  /// 결재 전자서명의 서버 공개 키(PEM)와 지문.
  Future<({String fingerprint, String publicKey})> sealKey() async {
    final m = await _getMap('/api/groupware/seal-key');
    return (
      fingerprint: m['fingerprint'] as String? ?? '',
      publicKey: m['publicKey'] as String? ?? '',
    );
  }

  /// 이 범위의 전결 규정.
  Future<List<ApprovalFinalRule>> finalRules() async => [
    for (final r in await _getList('/api/groupware/final-rules${_query()}'))
      ApprovalFinalRule.fromJson(r),
  ];

  /// 전결 규정 만들기·바꾸기(그룹웨어 관리자) — [rule.id]가 비어 있으면 새로.
  Future<ApprovalFinalRule> saveFinalRule(ApprovalFinalRule rule) async =>
      ApprovalFinalRule.fromJson(
        (await _api.requestJson(
                  rule.id.isEmpty ? 'POST' : 'PUT',
                  rule.id.isEmpty
                      ? '/api/groupware/final-rules'
                      : '/api/groupware/final-rules/${rule.id}',
                  body: _body(rule.toJson()),
                )
                as Map)
            .cast<String, dynamic>(),
      );

  Future<void> deleteFinalRule(String id) async {
    await _api.requestJson(
      'DELETE',
      '/api/groupware/final-rules/$id${_query()}',
    );
  }

  Future<void> deleteApprovalLine(String id) =>
      _api.requestJson('DELETE', '/api/groupware/approval-lines/$id');

  Future<List<ApprovalDocument>> documents({
    required ApprovalBox box,
    ApprovalKind? kind,
    ApprovalStatus? status,
    DateTime? before,

    /// 정산 안 된 승인 구매·출장만(서버 ?unsettled=1).
    bool unsettled = false,

    /// 검색 — 제목·문서 번호·올린 사람에 들어간 글, 올린 날 [from]~[to]('YYYY-MM-DD').
    String? q,
    String? from,
    String? to,
  }) async => [
    for (final d in await _getList(
      '/api/groupware/documents${_query({'box': box.wire, 'kind': kind?.wire, 'status': status?.wire, 'before': before?.millisecondsSinceEpoch.toString(), 'unsettled': unsettled ? '1' : null, 'q': q, 'from': from, 'to': to})}',
    ))
      ApprovalDocument.fromJson(d),
  ];

  Future<ApprovalDocument> document(String id) async =>
      ApprovalDocument.fromJson(await _getMap('/api/groupware/documents/$id'));

  /// 결재 올리기 — [fields]는 종류별 내용(휴가 leaveType·startDate·endDate, 지출 amount·category·spentOn·attachments, 근태 수정
  /// workDate·clockIn·clockOut).
  Future<ApprovalDocument> submit({
    required ApprovalKind kind,
    required Map<String, dynamic> fields,
    String? title,
    String? body,
    required List<String> approverIds,
    List<String> ccIds = const [],
    Map<String, LineRole> roles = const {},
  }) async => ApprovalDocument.fromJson(
    (await _api.requestJson(
              'POST',
              '/api/groupware/documents',
              body: _body({
                'kind': kind.wire,
                ...fields,
                'title': ?title,
                'body': ?body,
                'approverIds': approverIds,
                'ccIds': ccIds,
                if (rolesToJson(roles).isNotEmpty) 'roles': rolesToJson(roles),
              }),
            )
            as Map)
        .cast<String, dynamic>(),
  );

  /// 승인·반려·회수·취소 — [action]: 'approve' | 'reject' | 'withdraw' | 'cancel'.
  Future<ApprovalDocument> decide(
    String id,
    String action, {
    String? comment,
  }) async => ApprovalDocument.fromJson(
    (await _api.requestJson(
              'POST',
              '/api/groupware/documents/$id/$action',
              body: {'comment': ?comment},
            )
            as Map)
        .cast<String, dynamic>(),
  );

  Future<LeaveBalance> leaveBalance({String? userId}) async =>
      LeaveBalance.fromJson(
        await _getMap(
          '/api/groupware/leave/balance${_query({'userId': userId})}',
        ),
      );

  Future<List<TeamLeave>> teamLeaves({
    required String from,
    required String to,
  }) async => [
    for (final l in await _getList(
      '/api/groupware/leave/calendar${_query({'from': from, 'to': to})}',
    ))
      TeamLeave.fromJson(l),
  ];

  Future<List<GroupwareMember>> members() async => [
    for (final m in await _getList('/api/groupware/members${_query()}'))
      GroupwareMember.fromJson(m),
  ];

  /// 입사일 정하기(null이면 지움) — 관리자.
  Future<LeaveBalance> setHireDate(String userId, String? hireDate) async =>
      LeaveBalance.fromJson(
        (await _api.requestJson(
                  'PATCH',
                  '/api/groupware/members/$userId',
                  body: _body({'hireDate': hireDate}),
                )
                as Map)
            .cast<String, dynamic>(),
      );

  /// 연차 조정(반일 단위, +는 더 줌 −는 뺌) — 관리자.
  Future<LeaveBalance> adjustLeave(
    String userId, {
    required int halfDays,
    required String reason,
  }) async => LeaveBalance.fromJson(
    (await _api.requestJson(
              'POST',
              '/api/groupware/members/$userId/leave-adjustments',
              body: _body({'halfDays': halfDays, 'reason': reason}),
            )
            as Map)
        .cast<String, dynamic>(),
  );

  /// 근무 시간(지각·조퇴 기준) — 관리자. 'HH:MM'.
  Future<void> setWorkHours({required String start, required String end}) =>
      _api.requestJson(
        'PATCH',
        '/api/groupware/settings',
        body: _body({'workStart': start, 'workEnd': end}),
      );

  Future<AttendanceToday> attendanceToday() async => AttendanceToday.fromJson(
    await _getMap('/api/groupware/attendance/today${_query()}'),
  );

  /// 출근 — [mode] 'office'(사무실) | 'field'(외근 — [note]에 장소, 꼭) | 'remote'(재택). [location]은 기기 위치(GPS — 보낼 수 있을 때,
  /// 범위가 외근 위치를 필수로 했으면 외근에 꼭). 주 52시간 지키기에 걸리면 409.
  Future<AttendanceRecord> clockIn({
    String mode = 'office',
    String? note,
    ({double lat, double lng, double? accuracy})? location,
  }) async => AttendanceRecord.fromJson(
    (await _api.requestJson(
              'POST',
              '/api/groupware/attendance/clock-in',
              body: _body({
                'mode': mode,
                'note': ?note,
                if (location != null) 'location': _locationJson(location),
              }),
            )
            as Map)
        .cast<String, dynamic>(),
  );

  // ── 범위 설정·유연근무·주 52시간·연차 촉진(서버 groupwareWork.js) ──

  Future<GroupwareOptions> options() async => GroupwareOptions.fromJson(
    await _getMap('/api/groupware/options${_query()}'),
  );

  /// 범위 설정 바꾸기(관리자) — 보낸 것만 바뀐다.
  Future<GroupwareOptions> updateOptions({
    List<LeaveTypeInfo>? leaveTypes,
    List<String>? expenseCategories,
    bool? clockInReminder,
    bool? clockOutReminder,
    int? reminderDelayMinutes,
    String? overtimeGuard,
    String? leaveBasis,
    int? fiscalStartMonth,
    int? carryOverMaxDays,
    PayRates? payRates,

    /// 사무실 위치 — [clearOfficeLocation]이면 지운다.
    ({double lat, double lng, int radius})? officeLocation,
    bool clearOfficeLocation = false,
    bool? requireFieldLocation,
  }) async => GroupwareOptions.fromJson(
    (await _api.requestJson(
              'PATCH',
              '/api/groupware/options',
              body: _body({
                if (leaveTypes != null)
                  'leaveTypes': [for (final t in leaveTypes) t.toJson()],
                'expenseCategories': ?expenseCategories,
                'clockInReminder': ?clockInReminder,
                'clockOutReminder': ?clockOutReminder,
                'reminderDelayMinutes': ?reminderDelayMinutes,
                'overtimeGuard': ?overtimeGuard,
                'leaveBasis': ?leaveBasis,
                'fiscalStartMonth': ?fiscalStartMonth,
                'carryOverMaxDays': ?carryOverMaxDays,
                if (payRates != null) 'payRates': payRates.toJson(),
                if (clearOfficeLocation)
                  'officeLocation': null
                else if (officeLocation != null)
                  'officeLocation': {
                    'lat': officeLocation.lat,
                    'lng': officeLocation.lng,
                    'radius': officeLocation.radius,
                  },
                'requireFieldLocation': ?requireFieldLocation,
              }),
            )
            as Map)
        .cast<String, dynamic>(),
  );

  Future<List<MemberSchedule>> schedules() async => [
    for (final m in await _getList('/api/groupware/schedules${_query()}'))
      MemberSchedule.fromJson(m),
  ];

  /// 근무 형태 정하기(관리자) — [mode] 'staggered'(start·end) | 'core'(coreStart·coreEnd) | 'free'. 시각은 'HH:MM'.
  Future<MemberSchedule> setSchedule(
    String userId, {
    required String mode,
    String? start,
    String? end,
    String? coreStart,
    String? coreEnd,

    /// 탄력적 근로시간제·선택근무 정산 기간 — 'flex2w' | 'flex3m' | 'select'(null이면 주 단위), 시작하는 날, 선택근무 개월(1 | 3).
    String? periodType,
    String? periodStart,
    int? periodMonths,
  }) async => MemberSchedule.fromJson(
    (await _api.requestJson(
              'PUT',
              '/api/groupware/schedules/$userId',
              body: _body({
                'mode': mode,
                'start': ?start,
                'end': ?end,
                'coreStart': ?coreStart,
                'coreEnd': ?coreEnd,
                'periodType': ?periodType,
                'periodStart': ?periodStart,
                'periodMonths': ?periodMonths,
              }),
            )
            as Map)
        .cast<String, dynamic>(),
  );

  Future<void> clearSchedule(String userId) =>
      _api.requestJson('DELETE', '/api/groupware/schedules/$userId${_query()}');

  /// 한 주(그 날이 든 월~일) 구성원별 근로시간(관리자).
  Future<({String weekStart, String weekEnd, List<WeeklyMember> members})>
  weekly(String day) async {
    final j = await _getMap(
      '/api/groupware/attendance/weekly${_query({'week': day})}',
    );
    return (
      weekStart: j['weekStart'] as String? ?? day,
      weekEnd: j['weekEnd'] as String? ?? day,
      members: [
        for (final m in j['members'] as List? ?? const [])
          WeeklyMember.fromJson((m as Map).cast<String, dynamic>()),
      ],
    );
  }

  /// 연차 촉진 현황(관리자).
  Future<List<PromotionMember>> promotions() async {
    final j = await _getMap('/api/groupware/leave/promotions${_query()}');
    return [
      for (final m in j['members'] as List? ?? const [])
        PromotionMember.fromJson((m as Map).cast<String, dynamic>()),
    ];
  }

  /// 1차 촉진 보내기(관리자) → 보낸 수와 건너뛴 이유들.
  Future<({int sent, List<String> skipped})> sendPromotion(
    List<String> userIds, {
    String? message,
  }) async {
    final j =
        (await _api.requestJson(
                  'POST',
                  '/api/groupware/leave/promotions',
                  body: _body({'userIds': userIds, 'message': ?message}),
                )
                as Map)
            .cast<String, dynamic>();
    return (
      sent: (j['sent'] as List? ?? const []).length,
      skipped: [
        for (final s in j['skipped'] as List? ?? const [])
          '${(s as Map)['reason']}',
      ],
    );
  }

  /// 2차 촉진(관리자) — 회사가 정한 날.
  Future<LeavePromotion> sendSecondPromotion(
    String userId,
    List<String> dates, {
    String? message,
  }) async => LeavePromotion.fromJson(
    (await _api.requestJson(
              'POST',
              '/api/groupware/leave/promotions/second',
              body: _body({
                'userId': userId,
                'dates': dates,
                'message': ?message,
              }),
            )
            as Map)
        .cast<String, dynamic>(),
  );

  Future<List<LeavePromotion>> myPromotions() async => [
    for (final p in await _getList(
      '/api/groupware/leave/promotions/mine${_query()}',
    ))
      LeavePromotion.fromJson(p),
  ];

  Future<LeavePromotion> readPromotion(String id) async =>
      LeavePromotion.fromJson(
        (await _api.requestJson(
                  'POST',
                  '/api/groupware/leave/promotions/$id/read',
                  body: const {},
                )
                as Map)
            .cast<String, dynamic>(),
      );

  Future<LeavePromotion> submitPromotionPlan(
    String id,
    List<String> dates,
  ) async => LeavePromotion.fromJson(
    (await _api.requestJson(
              'POST',
              '/api/groupware/leave/promotions/$id/plan',
              body: {'dates': dates},
            )
            as Map)
        .cast<String, dynamic>(),
  );

  Map<String, dynamic> _locationJson(
    ({double lat, double lng, double? accuracy}) l,
  ) => {'lat': l.lat, 'lng': l.lng, 'accuracy': ?l.accuracy};

  /// 퇴근 — [location]은 기기 위치(보낼 수 있을 때). 열린 휴게는 퇴근 시각으로 닫힌다.
  Future<AttendanceRecord> clockOut({
    ({double lat, double lng, double? accuracy})? location,
  }) async => AttendanceRecord.fromJson(
    (await _api.requestJson(
              'POST',
              '/api/groupware/attendance/clock-out',
              body: _body({
                if (location != null) 'location': _locationJson(location),
              }),
            )
            as Map)
        .cast<String, dynamic>(),
  );

  /// 휴게 시작([start] true)·끝 — 출근 뒤 퇴근 전.
  Future<AttendanceRecord> attendanceBreak({required bool start}) async =>
      AttendanceRecord.fromJson(
        (await _api.requestJson(
                  'POST',
                  '/api/groupware/attendance/break-${start ? 'start' : 'end'}',
                  body: _body(),
                )
                as Map)
            .cast<String, dynamic>(),
      );

  /// 통상시급 정하기(관리자 — null이면 지움). 가산 수당(참고용) 계산에만 쓴다.
  Future<void> setHourlyWage(String userId, int? hourlyWage) async {
    await _api.requestJson(
      'PUT',
      '/api/groupware/members/$userId/wage',
      body: _body({'hourlyWage': hourlyWage}),
    );
  }

  /// 연차 이월(관리자) — [dryRun]이면 넣지 않고 넣을 양만. [userIds]를 안 주면 입사일이 있는 모두.
  Future<CarryOverResult> carryOverLeave({
    bool dryRun = false,
    List<String>? userIds,
  }) async => CarryOverResult.fromJson(
    (await _api.requestJson(
              'POST',
              '/api/groupware/leave/carry-over',
              body: _body({'dryRun': dryRun, 'userIds': ?userIds}),
            )
            as Map)
        .cast<String, dynamic>(),
  );

  /// 한 달 근태 — [month]는 'YYYY-MM', [userId]는 관리자가 남의 것을 볼 때.
  Future<AttendanceMonth> attendanceMonth(
    String month, {
    String? userId,
  }) async => AttendanceMonth.fromJson(
    await _getMap(
      '/api/groupware/attendance/month${_query({'month': month, 'userId': userId})}',
    ),
  );

  Future<List<AttendanceSummaryRow>> attendanceSummary(String month) async {
    final map = await _getMap(
      '/api/groupware/attendance/summary${_query({'month': month})}',
    );
    return [
      for (final m in (map['members'] as List? ?? const []))
        AttendanceSummaryRow.fromJson((m as Map).cast<String, dynamic>()),
    ];
  }

  /// 한 달 근태 엑셀의 경로(인증 헤더를 붙여 받는다 — Session.downloadGroupwareFile).
  String attendanceExportPath(String month) =>
      '/api/groupware/attendance/export${_query({'month': month})}';

  /// 결재 알림함(알림 센터 "결재" 탭) — 범위와 상관없이 내 것 최근 50개와 안 읽은 수.
  Future<({List<ApprovalNotification> items, int unread})>
  notifications() async {
    final map = await _getMap('/api/groupware/notifications');
    return (
      items: [
        for (final n in (map['items'] as List? ?? const []))
          ApprovalNotification.fromJson((n as Map).cast<String, dynamic>()),
      ],
      unread: (map['unreadCount'] as num?)?.toInt() ?? 0,
    );
  }

  /// 결재 알림 읽음 — [ids] 또는 [documentId](그 문서의 내 알림 전부), 둘 다 없으면 전부. 남은 안 읽은 수.
  Future<int> markNotificationsRead({
    List<String>? ids,
    String? documentId,
  }) async {
    final map =
        (await _api.requestJson(
                  'POST',
                  '/api/groupware/notifications/read',
                  body: {'ids': ?ids, 'documentId': ?documentId},
                )
                as Map)
            .cast<String, dynamic>();
    return (map['unreadCount'] as num?)?.toInt() ?? 0;
  }

  // ── 회의실·자원 예약(서버 groupwareResources.js) ──

  /// 자원 목록(관리자는 끈 것도). [from]·[to](ms)를 주면 그 시간에 잡힌 예약을 `busy`로 — [eventId]의 예약은 빼고(일정 편집 중).
  Future<List<GroupwareResource>> resources({
    int? from,
    int? to,
    String? eventId,
  }) async => [
    for (final r in await _getList(
      '/api/groupware/resources${_query({'from': from?.toString(), 'to': to?.toString(), 'eventId': eventId})}',
    ))
      GroupwareResource.fromJson(r),
  ];

  /// 자원 만들기([id]가 null)·고치기(관리자) — [fields]는 `{ kind, name, location, capacity, description, enabled, sortOrder }` 중 보낼 것.
  Future<GroupwareResource> saveResource(
    String? id,
    Map<String, dynamic> fields,
  ) async => GroupwareResource.fromJson(
    (await _api.requestJson(
              id == null ? 'POST' : 'PATCH',
              id == null
                  ? '/api/groupware/resources'
                  : '/api/groupware/resources/$id',
              body: _body(fields),
            )
            as Map)
        .cast<String, dynamic>(),
  );

  Future<void> deleteResource(String id) =>
      _api.requestJson('DELETE', '/api/groupware/resources/$id${_query()}');

  /// [from]~[to](ms, 31일 안)에 걸친 범위의 모든 예약.
  Future<List<ResourceBooking>> bookings(int from, int to) async => [
    for (final b in await _getList(
      '/api/groupware/bookings${_query({'from': '$from', 'to': '$to'})}',
    ))
      ResourceBooking.fromJson(b),
  ];

  /// 내가 잡은 앞으로의 예약.
  Future<List<ResourceBooking>> myBookings() async => [
    for (final b in await _getList('/api/groupware/bookings/mine${_query()}'))
      ResourceBooking.fromJson(b),
  ];

  /// 예약하기 — 겹치면 409(ApiException 글에 누구 예약인지).
  Future<ResourceBooking> book({
    required String resourceId,
    required int start,
    required int end,
    String? title,
  }) async => ResourceBooking.fromJson(
    (await _api.requestJson(
              'POST',
              '/api/groupware/bookings',
              body: _body({
                'resourceId': resourceId,
                'start': start,
                'end': end,
                'title': ?title,
              }),
            )
            as Map)
        .cast<String, dynamic>(),
  );

  Future<void> cancelBooking(String id) =>
      _api.requestJson('DELETE', '/api/groupware/bookings/$id${_query()}');

  /// 한 달 휴가 달력 — [month] 'YYYY-MM'.
  Future<LeaveMonth> leaveMonth(String month) async => LeaveMonth.fromJson(
    await _getMap('/api/groupware/leave/month${_query({'month': month})}'),
  );

  // ── 설문(server/src/groupwareSurveys.js) ──

  /// 내가 볼 수 있는 설문(응답할 것이 앞)과 응답할 설문 수.
  Future<({List<SurveySummary> items, int pendingCount})> surveys() async {
    final j = await _getMap('/api/groupware/surveys${_query()}');
    return (
      items: [
        for (final s in (j['items'] as List? ?? const []))
          SurveySummary.fromJson((s as Map).cast<String, dynamic>()),
      ],
      pendingCount: (j['pendingCount'] as num?)?.toInt() ?? 0,
    );
  }

  /// 설문 만들기 — [targetIds]가 있으면 그 사람들에게만, 없으면 범위 모두.
  Future<SurveySummary> createSurvey({
    required String title,
    String? description,
    required List<SurveyQuestion> questions,
    bool anonymous = false,
    SurveyResultVisibility resultVisibility = SurveyResultVisibility.creator,
    List<String>? targetIds,
    DateTime? closesAt,
  }) async => SurveySummary.fromJson(
    (await _api.requestJson(
              'POST',
              '/api/groupware/surveys',
              body: _body({
                'title': title,
                if (description != null && description.trim().isNotEmpty)
                  'description': description,
                'questions': [for (final q in questions) q.toJson()],
                'anonymous': anonymous,
                'resultVisibility': resultVisibility.wire,
                'audience': targetIds == null ? 'all' : 'users',
                'targetIds': ?targetIds,
                'closesAt': ?closesAt?.millisecondsSinceEpoch,
              }),
            )
            as Map)
        .cast<String, dynamic>(),
  );

  Future<SurveyDetail> survey(String id) async => SurveyDetail.fromJson(
    await _getMap('/api/groupware/surveys/$id${_query()}'),
  );

  /// 응답하기·고치기 — 처음 낸 것이면 true.
  Future<bool> respondSurvey(String id, Map<String, dynamic> answers) async {
    final j =
        await _api.requestJson(
              'PUT',
              '/api/groupware/surveys/$id/response',
              body: _body({'answers': answers}),
            )
            as Map;
    return j['first'] == true;
  }

  Future<SurveyResults> surveyResults(String id) async =>
      SurveyResults.fromJson(
        await _getMap('/api/groupware/surveys/$id/results${_query()}'),
      );

  Future<void> closeSurvey(String id) => _api.requestJson(
    'POST',
    '/api/groupware/surveys/$id/close',
    body: _body(),
  );

  /// 안 한 사람에게 독촉 — 보낸 사람 수(1시간에 한 번 — 아니면 서버가 429).
  Future<int> remindSurvey(String id) async {
    final j =
        await _api.requestJson(
              'POST',
              '/api/groupware/surveys/$id/remind',
              body: _body(),
            )
            as Map;
    return (j['notified'] as num?)?.toInt() ?? 0;
  }

  Future<void> deleteSurvey(String id) =>
      _api.requestJson('DELETE', '/api/groupware/surveys/$id${_query()}');

  // ── 업무일지(server/src/groupwareReports.js) ──

  /// 내 업무일지 — [periodStart]를 비우면 오늘·이번 주.
  Future<MyWorkReportPage> myWorkReport(
    WorkReportKind kind, {
    String? periodStart,
  }) async => MyWorkReportPage.fromJson(
    await _getMap(
      '/api/groupware/work-reports${_query({'kind': kind.wire, 'periodStart': periodStart})}',
    ),
  );

  /// 내 일일 보고([from]~[to]) — 주간 보고에 그 주 일일 보고를 불러올 때.
  Future<List<WorkReport>> myDailyReports(String from, String to) async => [
    for (final r in await _getList(
      '/api/groupware/work-reports/mine${_query({'kind': 'daily', 'from': from, 'to': to})}',
    ))
      WorkReport.fromJson(r),
  ];

  Future<WorkReport> saveWorkReport({
    required WorkReportKind kind,
    required String periodStart,
    required String done,
    required String plan,
    required String issues,
  }) async => WorkReport.fromJson(
    (await _api.requestJson(
              'PUT',
              '/api/groupware/work-reports',
              body: _body({
                'kind': kind.wire,
                'periodStart': periodStart,
                'done': done,
                'plan': plan,
                'issues': issues,
              }),
            )
            as Map)
        .cast<String, dynamic>(),
  );

  Future<WorkReportTeam> teamWorkReports(
    WorkReportKind kind, {
    String? periodStart,
  }) async => WorkReportTeam.fromJson(
    await _getMap(
      '/api/groupware/work-reports/team${_query({'kind': kind.wire, 'periodStart': periodStart})}',
    ),
  );

  /// 보고 하나(댓글 포함) — 검토자가 열면 서버가 읽음을 남긴다.
  Future<WorkReport> workReport(String id) async => WorkReport.fromJson(
    await _getMap('/api/groupware/work-reports/$id${_query()}'),
  );

  Future<WorkReportComment> commentWorkReport(String id, String text) async =>
      WorkReportComment.fromJson(
        (await _api.requestJson(
                  'POST',
                  '/api/groupware/work-reports/$id/comments',
                  body: _body({'text': text}),
                )
                as Map)
            .cast<String, dynamic>(),
      );

  Future<void> deleteWorkReport(String id) =>
      _api.requestJson('DELETE', '/api/groupware/work-reports/$id${_query()}');
}
