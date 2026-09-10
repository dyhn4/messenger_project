/// "설치→가입" 초대 링크. 서버 src/invites.js의 응답과 1:1로 대응한다.
///
/// 팀 합류는 여기 포함되지 않는다 — 이 링크가 하는 일은 낯선 기기가 이 서버(자체 서명
/// 인증서)를 신뢰하게 만들고 안내 페이지에서 설치 파일을 받게 해주는 것뿐이다. 회원가입은
/// 원래 누구나 열려 있고, 팀 합류는 항상 소유자·관리자가 팀 설정 → 팀원 추가에서 한다.
class InviteLink {
  final String id;
  final String token;
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

  const InviteLink({
    required this.id,
    required this.token,
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

  factory InviteLink.fromJson(Map<String, dynamic> json) => InviteLink(
    id: json['id'] as String,
    token: json['token'] as String,
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
