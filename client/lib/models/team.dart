/// 계정 등급. **서버 운영자만** 바꿀 수 있고(관리자 콘솔), 팀이 아니라 계정에 붙는다 —
/// 어느 팀에 있든 같은 등급이다. 자세한 설명은 README.md의 "권한 등급" 참고.
/// 서버 users.role 문자열과 1:1로 대응한다.
enum AccountRole {
  admin, // 관리자 — 자기가 속한 팀의 설정·팀원·콘텐츠 관리 + 방/팀 생성.
  member, // 정회원 — 기본 협업 기능(방 만들기, 대화, 초대).
  guest, // 준회원 — 초대받은 방에서만 활동(방 생성·토픽 참여·대화 시작 불가).
}

/// 서버가 주는 등급 문자열('admin'|'member'|'guest')을 enum으로. 모르는 값이면 가장 약한
/// 준회원으로 떨어뜨린다(서버가 새 등급을 먼저 배포해도 앱이 과한 권한을 주지 않도록).
AccountRole accountRoleFromWire(String? s) => switch (s) {
  'admin' => AccountRole.admin,
  'member' => AccountRole.member,
  _ => AccountRole.guest,
};

extension AccountRoleLabel on AccountRole {
  String get label => switch (this) {
    AccountRole.admin => '관리자',
    AccountRole.member => '정회원',
    AccountRole.guest => '준회원',
  };

  String get description => switch (this) {
    AccountRole.admin => '자기가 속한 팀의 설정·팀원·콘텐츠 관리 + 방·팀 만들기',
    AccountRole.member => '방 만들기·참여·대화 등 일반 협업 기능 전부',
    AccountRole.guest => '초대받은 방에서만 활동(방 생성·토픽 참여·대화 시작 불가)',
  };

  String get wire => name;

  /// 아래 판정들은 전부 서버 server/src/permissions.js와 같은 규칙이다. 클라이언트는 버튼을
  /// 감추는 용도로만 쓰고, 실제 차단은 항상 서버가 다시 한다.

  /// 방(토픽/그룹/1:1)을 새로 만들거나 공개 토픽을 찾아 참여할 수 있는지 — 준회원은 불가.
  bool get canCreateRooms => this != AccountRole.guest;
}

/// 방에 멤버를 초대할 수 있는 최소 등급(팀 설정) — 서버 teams.invitePolicy와 같은 값.
enum InvitePolicy {
  member, // 정회원 이상(기본)
  admin, // 소유자·관리자만
}

extension InvitePolicyLabel on InvitePolicy {
  String get label => switch (this) {
    InvitePolicy.member => '정회원 이상',
    InvitePolicy.admin => '팀을 관리할 수 있는 사람만',
  };

  String get wire => this == InvitePolicy.admin ? 'admin' : 'member';
}

/// [메시지 설정]의 수정/삭제 가능 시간 선택지(초) — 서버 permissions.js의
/// EDIT_DELETE_WINDOW_OPTIONS와 같은 목록이어야 한다(서버가 이 목록 밖의 값을 거부한다).
const editDeleteWindowOptions = [300, 1800, 3600, 86400, 604800];

/// "5분"/"24시간"처럼 사람이 읽는 표기(서버 formatWindow와 같은 규칙).
String formatEditDeleteWindow(int seconds) {
  if (seconds % 86400 == 0) return '${seconds ~/ 86400}일';
  if (seconds % 3600 == 0) return '${seconds ~/ 3600}시간';
  return '${(seconds / 60).round()}분';
}

/// 사내 메신저의 팀(워크스페이스). 방/조직도/검색/파일이 전부 이 단위로 나뉘고,
/// 한 계정이 여러 팀에 속할 수 있다. 팀을 만든 사람이 그 팀의 소유자가 된다.
class Team {
  final String id;
  final String? createdBy;
  final DateTime createdAt;

  /// 이름/아이콘/도메인/초대 권한은 소유자·관리자가 설정에서 바꿀 수 있어서 그 자리에서
  /// 갱신된다 — non-final.
  String name;
  String? iconEmoji;
  String? iconColor;

  /// 팀을 가리키는 짧은 식별자(영문 소문자/숫자/하이픈). 안 정했으면 null.
  String? domain;

  /// 이 팀에서 방에 멤버를 초대할 수 있는 최소 등급.
  InvitePolicy invitePolicy;

  /// [메시지 설정] 메시지 수정/삭제를 쓰는지. false면 그 팀에서는 아무도(소유자·관리자 포함)
  /// 메시지/댓글을 고치거나 지울 수 없다.
  bool messageEditDeleteEnabled;

  /// 작성 후 이 시간(초) 안에서만 수정/삭제할 수 있다. 고를 수 있는 값은
  /// [editDeleteWindowOptions].
  int messageEditDeleteWindowSeconds;

  /// 내가 이 팀의 소유자인지. 서버가 요청자 기준으로 채워준다.
  /// 등급(준회원/정회원/관리자)은 계정 단위라 팀마다 다르지 않다 — Session.accountRole 참고.
  bool isOwner;

  /// 팀 멤버 수(팀 목록 카드 표시용). 서버가 없으면 null.
  int? memberCount;

  Team({
    required this.id,
    required this.name,
    this.iconEmoji,
    this.iconColor,
    this.domain,
    this.invitePolicy = InvitePolicy.member,
    this.messageEditDeleteEnabled = true,
    this.messageEditDeleteWindowSeconds = 300,
    this.createdBy,
    required this.createdAt,
    this.isOwner = false,
    this.memberCount,
  });

  factory Team.fromJson(Map<String, dynamic> json) => Team(
    id: json['id'] as String,
    name: json['name'] as String,
    iconEmoji: json['iconEmoji'] as String?,
    iconColor: json['iconColor'] as String?,
    domain: json['domain'] as String?,
    invitePolicy: json['invitePolicy'] == 'admin'
        ? InvitePolicy.admin
        : InvitePolicy.member,
    messageEditDeleteEnabled: json['messageEditDeleteEnabled'] as bool? ?? true,
    messageEditDeleteWindowSeconds:
        (json['messageEditDeleteWindowSeconds'] as num?)?.toInt() ?? 300,
    createdBy: json['createdBy'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num).toInt(),
    ),
    isOwner: json['isOwner'] as bool? ?? false,
    memberCount: (json['memberCount'] as num?)?.toInt(),
  );

  /// 아이콘 이모지가 없으면 팀 이름 첫 글자를 쓴다(사용자 아바타의 initial 방식과 동일).
  String get initial => name.isEmpty ? '?' : name.substring(0, 1);

  /// 이 팀을 관리할 수 있는지 — 그 팀의 소유자이거나 계정 등급이 관리자면 된다
  /// (서버 permissions.js의 canManageTeam과 같은 규칙).
  bool canManage(AccountRole role) => isOwner || role == AccountRole.admin;

  /// 이 팀에서 방에 멤버를 초대할 수 있는지 — 계정 등급과 팀 설정(invitePolicy)을 함께 본다.
  bool canInvite(AccountRole role) => invitePolicy == InvitePolicy.admin
      ? canManage(role)
      : role.canCreateRooms;
}
