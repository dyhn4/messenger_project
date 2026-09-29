class AppUser {
  final String id;
  final String username;
  final String name;
  final String? email;
  final String avatarType; // 'initial' | 'character' | 'photo'
  final String? avatarEmoji;
  final String? avatarColor; // '#RRGGBB'
  final String? avatarUrl;
  final bool online; // 조회 시점 스냅샷일 뿐 — 실시간 갱신은 Session.onlineUserIds를 봐야 함.

  /// 계정 등급('admin' | 'member' | 'guest'). 서버가 publicUser에 항상 실어주므로 조직도·
  /// 팀원 추가 화면 어디서든 볼 수 있다. 바꾸는 것은 서버 운영자만 가능하다.
  final String? role;

  /// "그 팀의 소유자인지" — 팀 멤버 목록(GET /teams/:id/members)과 방 멤버 목록(Room.members,
  /// 방이 속한 팀 기준)에서 채워진다. 그 밖의 사용자 목록에서는 항상 false.
  final bool isOwner;

  /// 부서/직책도 팀 멤버 목록에서만 채워진다(계정이 아니라 팀 안에서의 정보 — 서버
  /// team_members 테이블). 안 정했으면 null. 관리자 콘솔에서 바뀌면 서버가 org:updated로
  /// 알려주고, session.dart가 이 값을 직접 덮어써서 로그아웃 없이 반영한다 — 그래서 final이
  /// 아니다(editedAt/linkPreview 같은 다른 "실시간 갱신되는" 필드와 동일한 패턴).
  String? department;
  String? position;

  AppUser({
    required this.id,
    required this.username,
    required this.name,
    this.email,
    this.avatarType = 'initial',
    this.avatarEmoji,
    this.avatarColor,
    this.avatarUrl,
    this.online = false,
    this.role,
    this.isOwner = false,
    this.department,
    this.position,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) {
    final username = json['username'] as String;
    return AppUser(
      id: json['id'] as String,
      username: username,
      name: (json['name'] as String?) ?? username,
      email: json['email'] as String?,
      avatarType: json['avatarType'] as String? ?? 'initial',
      avatarEmoji: json['avatarEmoji'] as String?,
      avatarColor: json['avatarColor'] as String?,
      avatarUrl: json['avatarUrl'] as String?,
      online: json['online'] as bool? ?? false,
      role: json['role'] as String?,
      isOwner: json['isOwner'] as bool? ?? false,
      department: json['department'] as String?,
      position: json['position'] as String?,
    );
  }

  /// 프로필 카드/조직도에 한 줄로 보여줄 "개발팀 · 팀장". 둘 다 비어 있으면 null.
  String? get orgLine {
    final parts = [
      if (department != null && department!.isNotEmpty) department!,
      if (position != null && position!.isNotEmpty) position!,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}
