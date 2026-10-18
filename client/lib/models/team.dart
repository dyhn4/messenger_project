import '../widgets/avatar_utils.dart' show initialsOf;
import '../l10n/tr.dart';

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
    AccountRole.admin => tr('관리자'),
    AccountRole.member => tr('정회원'),
    AccountRole.guest => tr('준회원'),
  };

  String get description => switch (this) {
    AccountRole.admin => tr('자기가 속한 팀의 설정·팀원·콘텐츠 관리 + 방·팀 만들기'),
    AccountRole.member => tr('방 만들기·참여·대화 등 일반 협업 기능 전부'),
    AccountRole.guest => tr('초대받은 방에서만 활동(방 생성·토픽 참여·대화 시작 불가)'),
  };

  String get wire => name;

  /// 아래 판정들은 전부 서버 server/src/permissions.js와 같은 규칙이다. 클라이언트는 버튼을
  /// 감추는 용도로만 쓰고, 실제 차단은 항상 서버가 다시 한다.

  /// 방(토픽/그룹/1:1)을 새로 만들거나 공개 토픽을 찾아 참여할 수 있는지 — 준회원은 불가.
  bool get canCreateRooms => this != AccountRole.guest;

  /// 등급 서열(숫자가 클수록 강함) — 서버 permissions.js의 ROLE_RANK와 같다. "팀 초대
  /// 링크"로 자기보다 높은 등급을 남에게 부여하지 못하게 막는 데 쓴다(team_invite_link_screen.dart).
  int get rank => switch (this) {
    AccountRole.admin => 2,
    AccountRole.member => 1,
    AccountRole.guest => 0,
  };
}

/// 새 토픽을 만들 수 있는 최소 등급(팀 설정) — 서버 teams.topicCreationPolicy와 같은 값.
/// 그룹채팅은 이 설정과 무관하게 항상 정회원 이상이면 만들 수 있다(AccountRole.canCreateRooms).
enum TopicCreationPolicy {
  member, // 정회원 이상(기본)
  admin, // 관리자 이상(소유자 포함)
  owner, // 소유자만
  designated, // 팀을 관리할 수 있는 사람이 콕 집어 고른 특정 정회원 이상만(Team.topicCreatorIds)
}

extension TopicCreationPolicyLabel on TopicCreationPolicy {
  String get label => switch (this) {
    TopicCreationPolicy.member => tr('정회원 이상'),
    TopicCreationPolicy.admin => tr('관리자 이상'),
    TopicCreationPolicy.owner => tr('소유자만'),
    TopicCreationPolicy.designated => tr('지정'),
  };

  String get wire => name;
}

TopicCreationPolicy topicCreationPolicyFromWire(String? s) => switch (s) {
  'admin' => TopicCreationPolicy.admin,
  'owner' => TopicCreationPolicy.owner,
  'designated' => TopicCreationPolicy.designated,
  _ => TopicCreationPolicy.member,
};

/// [메시지 설정]의 수정/삭제 가능 시간 선택지(초) — 서버 permissions.js의
/// EDIT_DELETE_WINDOW_OPTIONS와 같은 목록이어야 한다(서버가 이 목록 밖의 값을 거부한다).
const editDeleteWindowOptions = [300, 1800, 3600, 86400, 604800];

/// "5분"/"24시간"처럼 사람이 읽는 표기(서버 formatWindow와 같은 규칙).
String formatEditDeleteWindow(int seconds) {
  if (seconds % 86400 == 0) return tr('{p0}일', {'p0': seconds ~/ 86400});
  if (seconds % 3600 == 0) return tr('{p0}시간', {'p0': seconds ~/ 3600});
  return tr('{p0}분', {'p0': (seconds / 60).round()});
}

/// 사내 메신저의 팀(워크스페이스). 방/조직도/검색/파일이 전부 이 단위로 나뉘고,
/// 한 계정이 여러 팀에 속할 수 있다. 팀을 만든 사람이 그 팀의 소유자가 된다.
class Team {
  final String id;
  final String? createdBy;
  final DateTime createdAt;

  /// 이름/아이콘/토픽 생성 권한은 소유자·관리자가 설정에서 바꿀 수 있어서 그 자리에서
  /// 갱신된다 — non-final.
  String name;
  String? iconEmoji;
  String? iconColor;

  /// 팀 아이콘 사진(서명된 /files/ 링크) — 있으면 이모지·이니셜 대신 이걸 보여준다.
  String? iconUrl;

  /// 이 팀에서 새 토픽을 만들 수 있는 최소 등급.
  TopicCreationPolicy topicCreationPolicy;

  /// topicCreationPolicy가 [TopicCreationPolicy.designated]일 때만 의미가 있다 — 콕 집어
  /// 지정된 사람들의 id. 이름은 서버가 안 실어주므로(team_settings_dialog.dart) 팀원 목록과
  /// 대조해서 보여준다.
  List<String> topicCreatorIds;

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
    this.iconUrl,
    this.topicCreationPolicy = TopicCreationPolicy.member,
    this.topicCreatorIds = const [],
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
    iconUrl: json['iconUrl'] as String?,
    topicCreationPolicy: topicCreationPolicyFromWire(
      json['topicCreationPolicy'] as String?,
    ),
    topicCreatorIds:
        (json['topicCreatorIds'] as List?)?.cast<String>() ?? const [],
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

  /// 아이콘 이모지가 없으면 팀 이름 앞 2글자를 쓴다.
  String get initial => initialsOf(name);

  /// 이 팀을 관리할 수 있는지 — 그 팀의 소유자이거나 계정 등급이 관리자면 된다
  /// (서버 permissions.js의 canManageTeam과 같은 규칙).
  bool canManage(AccountRole role) => isOwner || role == AccountRole.admin;

  /// 이 팀에서 새 토픽을 만들 수 있는지 — 계정 등급·소유자 여부와 팀 설정
  /// (topicCreationPolicy)을 함께 본다(서버 permissions.js의 canCreateTopic과 같은 규칙).
  /// [userId]는 topicCreationPolicy가 designated일 때만 쓴다(그 외엔 안 넘겨도 된다).
  bool canCreateTopic(AccountRole role, [String? userId]) =>
      switch (topicCreationPolicy) {
        TopicCreationPolicy.owner => isOwner,
        TopicCreationPolicy.admin => canManage(role),
        TopicCreationPolicy.designated =>
          userId != null && topicCreatorIds.contains(userId),
        TopicCreationPolicy.member => role.canCreateRooms,
      };
}

/// 조직도 화면의 "팀" 탭용 — GET /api/org-chart/teams. 일반 [Team]과 달리 내가 속하지 않은
/// 팀도 포함하고(관리자 이상이 회사 전체 구조를 보는 용도), 각 팀의 멤버 id 목록을 담는다.
/// 이름/아바타 등 사람 정보는 회원 목록(fetchAllUsers — 조직도를 여는 관리자 이상에게는 서버 전체 회원이
/// 온다)과 id로 대조해서 보여준다 — 여기 실을 필요가 없다.
class OrgChartTeam {
  final String id;
  final String name;
  final String? iconEmoji;
  final String? iconColor;
  final String? iconUrl;
  final List<String> memberIds;

  /// 이 팀의 소유자 id — 조직도 "멤버" 탭이 등급 배지 옆에 "소유자" 표시를 붙일지 판단하는
  /// 데 쓴다(server/src/teams.js의 GET /org-chart/teams가 채워준다).
  final String? ownerId;

  const OrgChartTeam({
    required this.id,
    required this.name,
    this.iconEmoji,
    this.iconColor,
    this.iconUrl,
    required this.memberIds,
    this.ownerId,
  });

  factory OrgChartTeam.fromJson(Map<String, dynamic> json) => OrgChartTeam(
    id: json['id'] as String,
    name: json['name'] as String,
    iconEmoji: json['iconEmoji'] as String?,
    iconColor: json['iconColor'] as String?,
    iconUrl: json['iconUrl'] as String?,
    memberIds: (json['memberIds'] as List?)?.cast<String>() ?? const [],
    ownerId: json['ownerId'] as String?,
  );

  /// [TeamAvatar]는 [Team]을 받으므로, 아이콘만 그리는 용도의 자리표시자 팀을 만들어 준다.
  Team get asAvatarTeam => Team(
    id: id,
    name: name,
    iconEmoji: iconEmoji,
    iconColor: iconColor,
    iconUrl: iconUrl,
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
  );
}
