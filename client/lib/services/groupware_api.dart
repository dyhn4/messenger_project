import '../models/groupware.dart';
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

  Future<List<ApprovalCandidate>> candidates() async => [
    for (final c in await _getList('/api/groupware/candidates${_query()}'))
      ApprovalCandidate.fromJson(c),
  ];

  Future<ApprovalLines> approvalLines() async => ApprovalLines.fromJson(
    await _getMap('/api/groupware/approval-lines${_query()}'),
  );

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
  }) async => ApprovalForm.fromJson(
    (await _api.requestJson(
              'POST',
              '/api/groupware/forms',
              body: _body({
                'name': name,
                'description': ?description,
                'fields': [for (final f in fields) f.toDefinitionJson()],
                'allowAttachments': allowAttachments,
              }),
            )
            as Map)
        .cast<String, dynamic>(),
  );

  /// 양식 바꾸기(관리자) — 기본 양식은 enabled만.
  Future<ApprovalForm> updateForm(
    String id, {
    String? name,
    String? description,
    List<FormFieldDef>? fields,
    bool? allowAttachments,
    bool? enabled,
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

  Future<void> deleteApprovalLine(String id) =>
      _api.requestJson('DELETE', '/api/groupware/approval-lines/$id');

  Future<List<ApprovalDocument>> documents({
    required ApprovalBox box,
    ApprovalKind? kind,
    ApprovalStatus? status,
    DateTime? before,
  }) async => [
    for (final d in await _getList(
      '/api/groupware/documents${_query({'box': box.wire, 'kind': kind?.wire, 'status': status?.wire, 'before': before?.millisecondsSinceEpoch.toString()})}',
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

  /// 출근 — [mode] 'office'(사무실) | 'field'(외근 — [note]에 장소, 꼭) | 'remote'(재택).
  Future<AttendanceRecord> clockIn({
    String mode = 'office',
    String? note,
  }) async => AttendanceRecord.fromJson(
    (await _api.requestJson(
              'POST',
              '/api/groupware/attendance/clock-in',
              body: _body({'mode': mode, 'note': ?note}),
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

  Future<AttendanceRecord> clockOut() async => AttendanceRecord.fromJson(
    (await _api.requestJson(
              'POST',
              '/api/groupware/attendance/clock-out',
              body: _body(),
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
}
