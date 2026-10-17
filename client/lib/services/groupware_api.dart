import '../models/groupware.dart';
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
  }) async => ApprovalLine.fromJson(
    (await _api.requestJson(
              'POST',
              '/api/groupware/approval-lines',
              body: _body({
                'name': name,
                'approverIds': approverIds,
                'ccIds': ccIds,
              }),
            )
            as Map)
        .cast<String, dynamic>(),
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

  Future<AttendanceRecord> clockIn() async => AttendanceRecord.fromJson(
    (await _api.requestJson(
              'POST',
              '/api/groupware/attendance/clock-in',
              body: _body(),
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
