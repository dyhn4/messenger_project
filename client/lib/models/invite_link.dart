/// 초대 링크(설치 초대·팀 초대) 하나로 가입할 수 있는 사람 수 고르기 — 서버는 1~100명만
/// 받는다(server/src/invites.js의 inviteMaxUses, 팀 초대는 teamInvites.js).
const inviteMaxUsesOptions = [1, 5, 10, 30, 100];

/// "설치→가입" 초대 링크. 서버 src/invites.js의 응답과 1:1로 대응한다.
///
/// 팀 합류는 여기 포함되지 않는다 — 이 링크가 하는 일은 낯선 기기가 이 서버(자체 서명
/// 인증서)를 신뢰하게 만들고 안내 페이지에서 설치 파일을 받게 해주는 것뿐이다. 회원가입은
/// 사내 와이파이에서는 누구나 열려 있지만 밖(LTE/5G)에서는 초대 링크가 있어야 해서, 링크마다
/// 정한 인원([maxUses])만 가입할 수 있다. 팀 합류는 항상 소유자·관리자가 팀 설정 → 팀원
/// 추가에서 한다.
class InviteLink {
  final String id;
  final String token;
  final String? label;
  final String createdByName;
  final DateTime createdAt;
  final DateTime expiresAt;
  final bool revoked;

  /// 이 링크로 가입한 사람 수(연결·설치만 한 사람은 세지 않는다).
  final int usedCount;

  /// 이 링크로 가입할 수 있는 사람 수 — 다 차면 사내 와이파이 밖에서는 이 링크로 가입할 수
  /// 없다. null은 이 제한이 생기기 전에 만든 링크(제한 없음).
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

  const InviteLink({
    required this.id,
    required this.token,
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
    if (revoked) return '취소됨';
    if (!isOpen) return '만료됨';
    if (isFull) return '인원 마감';
    if (!valid) return '만료됨';
    final remaining = expiresAt.difference(DateTime.now());
    if (remaining.inHours < 1) return '곧 만료';
    if (remaining.inDays < 1) return '오늘 만료';
    return '만료까지 ${remaining.inDays}일';
  }

  /// "가입 2/5명"처럼 — 인원 제한이 없는 예전 링크는 "가입 2명".
  String get usageLabel =>
      maxUses == null ? '가입 $usedCount명' : '가입 $usedCount/$maxUses명';
}
