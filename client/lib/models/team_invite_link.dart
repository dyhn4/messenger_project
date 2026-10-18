import 'team.dart';
import '../l10n/tr.dart';

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

  /// 이 링크로 가입하면 같이 부여되는 직책(선택 사항) — 직책 목록(position_options)의 label.
  final String? assignedPosition;
  final String? label;
  final String createdByName;
  final DateTime createdAt;
  final DateTime expiresAt;
  final bool revoked;
  final int usedCount;

  /// 이 링크로 가입할 수 있는 사람 수 — 다 차면 더 못 쓴다. null은 이 제한이 생기기 전에 만든 링크(제한 없음).
  final int? maxUses;
  final DateTime? lastUsedAt;

  /// 이 링크로 지금 새로 가입시킬 수 있는지(만료·폐기 안 됐고 인원이 남음) — 서버가 판정해서 내려준다.
  /// 인원이 다 차도 [isOpen]인 동안은 이미 가입한 사람이 이 링크로 다른 기기를 연결·설치할 수 있다
  /// (server/src/pairing.js).
  final bool valid;

  /// 상대방에게 그대로 보내면 되는 안내 페이지 주소(평문 HTTP, 자체 서명 인증서 경고 없음).
  final String? url;

  /// 사내망 밖(LTE/5G)에서 열 안내 페이지 주소 — 서버에 외부 주소가 설정돼 있을 때만 온다.
  final String? externalUrl;

  const TeamInviteLink({
    required this.id,
    required this.token,
    required this.teamId,
    required this.teamName,
    required this.assignedRole,
    this.assignedPosition,
    this.label,
    required this.createdByName,
    required this.createdAt,
    required this.expiresAt,
    this.revoked = false,
    this.usedCount = 0,
    this.maxUses,
    this.lastUsedAt,
    this.valid = true,
    this.url,
    this.externalUrl,
  });

  factory TeamInviteLink.fromJson(Map<String, dynamic> json) => TeamInviteLink(
    id: json['id'] as String,
    token: json['token'] as String,
    teamId: json['teamId'] as String,
    teamName: json['teamName'] as String,
    assignedRole: accountRoleFromWire(json['assignedRole'] as String?),
    assignedPosition: json['assignedPosition'] as String?,
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
    maxUses: (json['maxUses'] as num?)?.toInt(),
    lastUsedAt: json['lastUsedAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            (json['lastUsedAt'] as num).toInt(),
          ),
    valid: json['valid'] as bool? ?? true,
    url: json['url'] as String?,
    externalUrl: json['externalUrl'] as String?,
  );

  /// 아직 취소·만료되지 않았는지 — 인원이 다 찬 링크도 이 동안은 연결·설치에 쓰이므로 취소할 수
  /// 있어야 한다.
  bool get isOpen => !revoked && expiresAt.isAfter(DateTime.now());

  /// 정한 가입 인원이 다 찼는지(인원 제한이 없는 예전 링크는 늘 false).
  bool get isFull => maxUses != null && usedCount >= maxUses!;

  /// "만료됨" / "취소됨" / "인원 마감" / "만료까지 3일" 처럼 상태를 한 줄로. 인원이 다 찬 링크도
  /// 만료되면 "만료됨"이다 — 그때부터는 연결·설치에도 못 쓴다.
  String get statusLabel {
    if (revoked) return tr('취소됨');
    if (!isOpen) return tr('만료됨');
    if (isFull) return tr('인원 마감');
    if (!valid) return tr('만료됨');
    final remaining = expiresAt.difference(DateTime.now());
    if (remaining.inHours < 1) return tr('곧 만료');
    if (remaining.inDays < 1) return tr('오늘 만료');
    return tr('만료까지 {remaining.inDays}일', {
      'remaining.inDays': remaining.inDays,
    });
  }

  /// "가입 2/5명"처럼 — 인원 제한이 없는 예전 링크는 "가입 2명".
  String get usageLabel => maxUses == null
      ? tr('가입 {usedCount}명', {'usedCount': usedCount})
      : tr('가입 {usedCount}/{maxUses}명', {
          'usedCount': usedCount,
          'maxUses': maxUses,
        });
}
