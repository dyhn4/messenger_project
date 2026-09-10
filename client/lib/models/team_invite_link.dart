import 'team.dart';

/// "팀 초대 링크" — 서버 src/teamInvites.js의 응답과 1:1로 대응한다.
///
/// 위 InviteLink(설치→가입)와 달리 이 링크로 가입하면 **가입과 동시에 특정 팀에 자동
/// 합류하고 계정 등급도 자동으로 부여**된다. 서버 운영자가 회원 등급을 일일이 올려주는
/// 수고를 줄이기 위한 기능이라, 만들 수 있는 사람은 서버 설정(팀 초대 링크 생성 권한)이
/// 정한 최소 등급을 만족해야 한다(session.canCreateTeamInviteLink).
class TeamInviteLink {
  final String id;
  final String token;
  final String teamId;
  final String teamName;
  final AccountRole assignedRole;
  final String? label;
  final String createdByName;
  final DateTime createdAt;
  final DateTime expiresAt;
  final bool revoked;
  final int usedCount;
  final DateTime? lastUsedAt;

  /// 지금 실제로 쓸 수 있는지(만료·폐기 안 됨) — 서버가 판정해서 내려준다.
  final bool valid;

  /// 상대방에게 그대로 보내면 되는 안내 페이지 주소(평문 HTTP, 자체 서명 인증서 경고 없음).
  final String? url;

  const TeamInviteLink({
    required this.id,
    required this.token,
    required this.teamId,
    required this.teamName,
    required this.assignedRole,
    this.label,
    required this.createdByName,
    required this.createdAt,
    required this.expiresAt,
    this.revoked = false,
    this.usedCount = 0,
    this.lastUsedAt,
    this.valid = true,
    this.url,
  });

  factory TeamInviteLink.fromJson(Map<String, dynamic> json) => TeamInviteLink(
    id: json['id'] as String,
    token: json['token'] as String,
    teamId: json['teamId'] as String,
    teamName: json['teamName'] as String,
    assignedRole: accountRoleFromWire(json['assignedRole'] as String?),
    label: json['label'] as String?,
    createdByName: json['createdByName'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num).toInt(),
    ),
    expiresAt: DateTime.fromMillisecondsSinceEpoch(
      (json['expiresAt'] as num).toInt(),
    ),
    revoked: json['revoked'] as bool? ?? false,
    usedCount: (json['usedCount'] as num?)?.toInt() ?? 0,
    lastUsedAt: json['lastUsedAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            (json['lastUsedAt'] as num).toInt(),
          ),
    valid: json['valid'] as bool? ?? true,
    url: json['url'] as String?,
  );

  /// "만료됨" / "취소됨" / "만료까지 3일" 처럼 상태를 한 줄로.
  String get statusLabel {
    if (revoked) return '취소됨';
    if (!valid) return '만료됨';
    final remaining = expiresAt.difference(DateTime.now());
    if (remaining.inHours < 1) return '곧 만료';
    if (remaining.inDays < 1) return '오늘 만료';
    return '만료까지 ${remaining.inDays}일';
  }
}
