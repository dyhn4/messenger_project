// 관리자 콘솔(서버 운영자 전용)에서만 쓰는 모델들. 서버 src/admin.js의 응답과 1:1로 대응한다.
//
// 일반 화면에서 쓰는 AppUser/Team과 굳이 합치지 않은 이유: 여기서 필요한 값(가입일, 정지
// 여부, 운영자 여부, 소속 팀 목록)은 운영 화면에서만 의미가 있고, 평소 화면에 흘러들어가면
// "누가 운영자인지"까지 모두에게 노출되기 때문이다.

import '../l10n/tr.dart';

/// 회원 관리 탭의 한 줄.
class AdminUser {
  final String id;
  final String username;
  final String name;
  final String avatarType;
  final String? avatarEmoji;
  final String? avatarColor;
  final bool online;

  /// 계정 등급('admin' | 'member' | 'guest') — 서버 운영자만 바꿀 수 있다.
  final String role;
  final String? department;
  final String? position;
  final bool isServerAdmin;
  final bool suspended;
  final DateTime? suspendedAt;
  final bool deleted;
  final DateTime createdAt;
  final List<AdminUserTeam> teams;

  /// 로그인 방법 — 'local' | 'ldap'(회사 디렉터리) | 'sso'(회사 계정).
  final String authSource;

  /// 2단계 인증을 켰는지 — 켜져 있으면 관리자가 해제할 수 있다(휴대폰 분실).
  final bool otpEnabled;

  const AdminUser({
    required this.id,
    required this.username,
    required this.name,
    this.avatarType = 'initial',
    this.avatarEmoji,
    this.avatarColor,
    this.online = false,
    this.role = 'guest',
    this.department,
    this.position,
    this.isServerAdmin = false,
    this.suspended = false,
    this.suspendedAt,
    this.deleted = false,
    required this.createdAt,
    this.teams = const [],
    this.authSource = 'local',
    this.otpEnabled = false,
  });

  factory AdminUser.fromJson(Map<String, dynamic> json) => AdminUser(
    authSource: json['authSource'] as String? ?? 'local',
    otpEnabled: json['otpEnabled'] == true,
    id: json['id'] as String,
    username: json['username'] as String,
    name: (json['name'] as String?) ?? json['username'] as String,
    avatarType: json['avatarType'] as String? ?? 'initial',
    avatarEmoji: json['avatarEmoji'] as String?,
    avatarColor: json['avatarColor'] as String?,
    online: json['online'] as bool? ?? false,
    role: json['role'] as String? ?? 'guest',
    department: json['department'] as String?,
    position: json['position'] as String?,
    isServerAdmin: json['isServerAdmin'] as bool? ?? false,
    suspended: json['suspended'] as bool? ?? false,
    suspendedAt: json['suspendedAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            (json['suspendedAt'] as num).toInt(),
          ),
    deleted: json['deleted'] as bool? ?? false,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num).toInt(),
    ),
    teams: ((json['teams'] as List?) ?? [])
        .map((e) => AdminUserTeam.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  /// 목록에서 상태를 한 줄로 — "정회원 · 정지됨 · 서버 운영자"처럼.
  String get statusLabel {
    if (deleted) return tr('탈퇴');
    final parts = [
      accountRoleLabel(role),
      if (suspended) tr('정지됨'),
      if (isServerAdmin) tr('서버 운영자'),
      if (authSource == 'ldap') tr('회사 디렉터리'),
      if (authSource == 'sso') tr('회사 계정'),
      if (otpEnabled) tr('2단계 인증'),
    ];
    return parts.join(' · ');
  }

  /// 부서·직책 한 줄(계정 단위로 관리할 때 관리자 콘솔에서 보여준다).
  String? get orgLine {
    final parts = [
      if (department != null && department!.isNotEmpty) department!,
      if (position != null && position!.isNotEmpty) position!,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

/// 그 사람이 속한 팀 하나(관리자 콘솔에서 소속을 보여줄 때만 쓴다).
class AdminUserTeam {
  final String id;
  final String name;
  final String role;
  const AdminUserTeam({
    required this.id,
    required this.name,
    required this.role,
  });

  factory AdminUserTeam.fromJson(Map<String, dynamic> json) => AdminUserTeam(
    id: json['id'] as String,
    name: json['name'] as String,
    role: json['role'] as String? ?? 'member',
  );
}

/// 팀 관리 탭의 한 줄 — 내가 속하지 않은 팀도 포함된 서버 전체 목록.
class AdminTeam {
  final String id;
  final String name;
  final String? iconEmoji;
  final String? iconColor;
  final String? iconUrl;
  final int memberCount;
  final String? createdBy;
  final DateTime createdAt;

  const AdminTeam({
    required this.id,
    required this.name,
    this.iconEmoji,
    this.iconColor,
    this.iconUrl,
    required this.memberCount,
    this.createdBy,
    required this.createdAt,
  });

  factory AdminTeam.fromJson(Map<String, dynamic> json) => AdminTeam(
    id: json['id'] as String,
    name: json['name'] as String,
    iconEmoji: json['iconEmoji'] as String?,
    iconColor: json['iconColor'] as String?,
    iconUrl: json['iconUrl'] as String?,
    memberCount: (json['memberCount'] as num?)?.toInt() ?? 0,
    createdBy: json['createdBy'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num).toInt(),
    ),
  );
}

/// 감사 로그 한 줄. 계정/팀이 지워져도 남아야 해서 이름은 그 시점의 스냅샷이다.
class AuditLog {
  final String id;
  final String? actorId;
  final String actorName;
  final String action;
  final String? teamId;
  final String? teamName;
  final String? targetType;
  final String? targetId;
  final String? targetLabel;
  final String? detail;
  final DateTime createdAt;

  const AuditLog({
    required this.id,
    this.actorId,
    required this.actorName,
    required this.action,
    this.teamId,
    this.teamName,
    this.targetType,
    this.targetId,
    this.targetLabel,
    this.detail,
    required this.createdAt,
  });

  factory AuditLog.fromJson(Map<String, dynamic> json) => AuditLog(
    id: json['id'] as String,
    actorId: json['actorId'] as String?,
    actorName: json['actorName'] as String,
    action: json['action'] as String,
    teamId: json['teamId'] as String?,
    teamName: json['teamName'] as String?,
    targetType: json['targetType'] as String?,
    targetId: json['targetId'] as String?,
    targetLabel: json['targetLabel'] as String?,
    detail: json['detail'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num).toInt(),
    ),
  );

  /// 서버 audit.js의 AUDIT 상수와 같은 목록이어야 한다.
  String get actionLabel => auditActionLabel(action);
}

/// 감사 로그 행위 코드 → 한국어 이름. 모르는 값이면 코드를 그대로 보여준다(서버가 새 행위를
/// 먼저 배포해도 화면이 깨지지 않도록).
String auditActionLabel(String action) => switch (action) {
  'message.delete' => tr('메시지 삭제'),
  'comment.delete' => tr('댓글 삭제'),
  'team.member.role' => tr('팀원 등급·직책 변경'),
  'team.member.add' => tr('팀원 추가'),
  'team.member.remove' => tr('팀원 제외'),
  'team.settings' => tr('팀 설정 변경'),
  'team.create' => tr('팀 생성'),
  'team.delete' => tr('팀 삭제'),
  'team.transferOwner' => tr('소유권 이양'),
  'topic.delete' => tr('토픽 삭제'),
  'room.convert' => tr('그룹채팅 토픽 전환'),
  'user.suspend' => tr('계정 정지'),
  'user.unsuspend' => tr('정지 해제'),
  'user.logoutAll' => tr('강제 로그아웃'),
  // 비밀번호 초기화 대행 기능은 없앴지만(운영자가 남의 평문 비밀번호를 정하는 건 계정을
  // 완전히 탈취할 수 있는 힘이라 위험하다고 판단), 예전에 남은 감사 로그 기록은 계속
  // 사람이 읽을 수 있는 이름으로 보여준다.
  'user.resetPassword' => tr('비밀번호 초기화(폐지된 기능)'),
  'user.role' => tr('계정 등급 변경'),
  'user.org' => tr('부서·직책 변경'),
  'user.serverAdmin' => tr('서버 운영자 지정·해제'),
  'server.settings' => tr('서버 설정 변경'),
  'server.backup' => tr('백업 설정·실행'),
  'invite.create' => tr('초대 링크 생성'),
  'invite.revoke' => tr('초대 링크 폐기'),
  'teamInvite.create' => tr('팀 초대 링크 생성'),
  'teamInvite.revoke' => tr('팀 초대 링크 폐기'),
  'invite.email' => tr('초대 메일 보냄'),
  'teamInvite.email' => tr('팀 초대 메일 보냄'),
  'groupware.hireDate' => tr('입사일 변경'),
  'groupware.leaveAdjust' => tr('연차 조정'),
  'groupware.settings' => tr('근무 시간 변경'),
  'groupware.cancel' => tr('승인된 결재 취소'),
  'groupware.form' => tr('결재 양식 변경'),
  'payroll.settings' => tr('급여 설정 변경'),
  'payroll.publish' => tr('급여명세서 보냄'),
  'payroll.unpublish' => tr('급여명세서 보내기 취소'),
  'payroll.delete' => tr('급여 대장 삭제'),
  'payroll.correct' => tr('급여명세서 정정'),
  'payroll.export' => tr('급여대장 내려받기'),
  'card.manage' => tr('법인카드 변경'),
  'card.import' => tr('법인카드 이용내역 가져오기'),
  'card.exclude' => tr('법인카드 사용 건 제외'),
  'card.feedKey' => tr('법인카드 연동 키 변경'),
  'org.tree' => tr('조직도 변경'),
  'auth.lockout' => tr('로그인 시도 차단'),
  'auth.loginSecurity' => tr('로그인 보안 설정 변경'),
  'user.otpReset' => tr('2단계 인증 해제'),
  'integration.create' => tr('외부 연동 만들기'),
  'integration.delete' => tr('외부 연동 지우기'),
  _ => action,
};

/// 감사 로그 필터 드롭다운에 쓸 목록(전체 + 자주 보는 행위들).
const auditActionFilters = [
  'message.delete',
  'comment.delete',
  'team.member.role',
  'team.member.add',
  'team.member.remove',
  'team.delete',
  'team.transferOwner',
  'topic.delete',
  'user.role',
  'user.org',
  'user.suspend',
  'user.serverAdmin',
  'invite.create',
  'teamInvite.create',
  'auth.lockout',
  'auth.loginSecurity',
  'integration.create',
  'server.backup',
];

/// 계정 등급 코드 → 한국어 이름(관리자 콘솔 목록용).
String accountRoleLabel(String role) => switch (role) {
  'admin' => tr('관리자'),
  'member' => tr('정회원'),
  _ => tr('준회원'),
};

/// 팀 생성 권한 설정값 → 한국어 이름. 서버 permissions.js의 TEAM_CREATION_LEVELS와 같은 목록.
const teamCreationLevels = ['member', 'admin', 'serverAdmin'];

String teamCreationLabel(String value) => switch (value) {
  'serverAdmin' => tr('서버 운영자'),
  'admin' => tr('관리자'),
  _ => tr('정회원'),
};

/// 운영 현황 대시보드 숫자들.
class ServerStats {
  final int users;
  final int teams;
  final int rooms;
  final int messages;
  final int messagesToday;
  final int uploadBytes;
  final DateTime serverStartedAt;

  /// 팀을 만들 수 있는 최소 등급 — 'member' | 'admin' | 'serverAdmin'.
  final String teamCreation;

  /// 팀 초대 링크(가입 시 팀 자동 합류 + 등급 자동 부여)를 만들 수 있는 최소 등급 —
  /// teamCreation과 같은 값 집합.
  final String teamInviteLinkCreation;

  /// 부서·직책을 어디에 두는지 — 'team'(팀마다 다르게) | 'account'(계정 하나로).
  final String orgScope;

  /// 프로젝트를 만들 수 있는 최소 등급 — teamCreation과 같은 값 집합.
  final String projectCreation;

  /// 그룹웨어(전자결재·연차·출퇴근) 범위 — 'org'(부서·직책 설정을 따름) | 'team'(팀마다) | 'server'(회사 전체).
  final String groupwareScope;

  const ServerStats({
    required this.users,
    required this.teams,
    required this.rooms,
    required this.messages,
    required this.messagesToday,
    required this.uploadBytes,
    required this.serverStartedAt,
    required this.teamCreation,
    required this.teamInviteLinkCreation,
    required this.orgScope,
    required this.projectCreation,
    this.groupwareScope = 'org',
  });

  factory ServerStats.fromJson(Map<String, dynamic> json) => ServerStats(
    users: (json['users'] as num?)?.toInt() ?? 0,
    teams: (json['teams'] as num?)?.toInt() ?? 0,
    rooms: (json['rooms'] as num?)?.toInt() ?? 0,
    messages: (json['messages'] as num?)?.toInt() ?? 0,
    messagesToday: (json['messagesToday'] as num?)?.toInt() ?? 0,
    uploadBytes: (json['uploadBytes'] as num?)?.toInt() ?? 0,
    serverStartedAt: DateTime.fromMillisecondsSinceEpoch(
      (json['serverStartedAt'] as num?)?.toInt() ?? 0,
    ),
    teamCreation: json['teamCreation'] as String? ?? 'member',
    teamInviteLinkCreation:
        json['teamInviteLinkCreation'] as String? ?? 'admin',
    orgScope: json['orgScope'] as String? ?? 'team',
    projectCreation: json['projectCreation'] as String? ?? 'member',
    groupwareScope: json['groupwareScope'] as String? ?? 'org',
  );
}

/// 관리자 콘솔의 "FCM 설정" 탭이 보여주는 현재 상태(GET /admin/fcm-settings). 서비스 계정의
/// private_key는 서버가 절대 다시 내려주지 않고, 설정 여부(serviceAccountConfigured)와
/// 어느 계정인지(serviceAccountEmail)만 알려준다.
class FcmSettings {
  final String apiKey;
  final String appId;
  final String projectId;
  final String messagingSenderId;

  /// 아이폰 앱(같은 Firebase 프로젝트에 등록한 iOS 앱 — GoogleService-Info.plist)의 API 키·앱 ID. 비면 아이폰은 앱이 꺼져 있을 때 알림이 없다.
  final String iosApiKey;
  final String iosAppId;
  final bool serviceAccountConfigured;
  final String? serviceAccountEmail;

  const FcmSettings({
    required this.apiKey,
    required this.appId,
    required this.projectId,
    required this.messagingSenderId,
    this.iosApiKey = '',
    this.iosAppId = '',
    required this.serviceAccountConfigured,
    this.serviceAccountEmail,
  });

  factory FcmSettings.fromJson(Map<String, dynamic> json) => FcmSettings(
    apiKey: json['apiKey'] as String? ?? '',
    appId: json['appId'] as String? ?? '',
    projectId: json['projectId'] as String? ?? '',
    messagingSenderId: json['messagingSenderId'] as String? ?? '',
    // 예전 서버는 이 둘을 모른다 — 빈 값(아이폰 설정 안 됨)으로 본다.
    iosApiKey: json['iosApiKey'] as String? ?? '',
    iosAppId: json['iosAppId'] as String? ?? '',
    serviceAccountConfigured:
        json['serviceAccountConfigured'] as bool? ?? false,
    serviceAccountEmail: json['serviceAccountEmail'] as String?,
  );
}
