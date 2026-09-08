import 'app_user.dart';
import 'message.dart';

enum RoomType { topic, group, dm }

RoomType _typeFromString(String s) => switch (s) {
  'group' => RoomType.group,
  'dm' => RoomType.dm,
  _ => RoomType.topic,
};

class Room {
  final String id;
  final RoomType type;
  final String? name; // dm/이름없는 group은 null (클라이언트가 대신 표시할 이름을 계산)
  final String? description;
  final bool isPublic; // 토픽에서만 의미 있음: 공개면 누구나 검색해서 참여 가능, 비공개면 초대로만.
  final List<AppUser> members;
  final DateTime createdAt;
  final Map<String, int> lastRead; // userId -> epoch millis, 마지막으로 이 방을 읽은 시각

  /// 내가 안 읽은 메시지 수. 서버가 REST 응답에서 계산해서 채워주고(로그인/방 목록 조회 시),
  /// 이후 실시간으로는 Session이 소켓 메시지를 받을 때마다 직접 증감시킨다 — 그래서 non-final.
  int unreadCount;

  /// 나만의 즐겨찾기 표시. 서버 브로드캐스트(room:created)에는 이 값이 안 실려올 수 있어서
  /// Session이 병합할 때 로컬 값을 유지한다 — 그래서 non-final.
  bool favorite;

  /// 나만의 알림 끄기 표시(즐겨찾기와 같은 방식 — non-final, Session이 병합 시 유지).
  /// 이 방을 뮤트하면 앱이 완전히 꺼져있을 때의 FCM 푸시가 안 온다(server/src/push.js).
  bool muted;

  /// 평문 DM의 "채팅방 숨기기"/"채팅방 나가기" — 즐겨찾기/뮤트와 같은 방식으로 나만의
  /// 개인 설정이다(멤버십 자체는 안 바뀐다, room_options_menu.dart 참고). true면 방 목록
  /// 화면들이 이 방을 안 보여준다. 상대가 새 메시지를 보내면 서버가 자동으로 false로
  /// 되돌려서(room_options_menu.dart의 숨기기 설명대로) 다시 보이게 한다 — 그래서 non-final.
  bool hidden;

  /// 그룹채팅/채팅 목록 이름 아래 한 줄 미리보기(room_list_screen.dart). 로그인 시점엔
  /// 서버가 계산해서 내려주고(rooms.js의 toRoomDto), 이후 실시간으로는 Session이 소켓으로
  /// 받은 메시지/댓글의 실제(복호화된) 내용으로 직접 갱신한다 — 그래서 non-final.
  String? lastMessagePreview;

  /// 이 방에서 마지막으로 활동(메시지/댓글)이 있었던 시각 — 방 목록에서 카테고리 안 정렬
  /// 기준으로 쓴다. 서버가 로그인 시점 기준(오프라인 동안 쌓인 활동 포함)으로 계산해서
  /// 내려주고(rooms.js의 toRoomDto), 이후 이번 세션 동안은 실시간으로 메시지/댓글을
  /// 보내거나 받을 때마다 Session._bumpRoomActivity가 갱신한다 — 그래서 non-final.
  DateTime lastActivityAt;

  /// 비밀 대화(E2EE) 방인지 — dm 위에 얹는 플래그(새 RoomType을 만들지 않음, isPublic과 같은 방식).
  /// true면 text는 클라이언트가 만든 암호문 JSON이라 Session이 송수신 경계에서 암복호화한다.
  final bool isSecret;

  /// 비밀 대화 핸드셰이크 상태: 'pending'(초대 대기) | 'active'(성립) | 'rejected' | 'terminated'.
  /// 서버가 room:created/rooms 목록에 실어 보내고(rooms.js의 toRoomDto), 그 자리에서 바뀔 수
  /// 있어(secret:accepted 수신 시) non-final.
  String? secretStatus;

  /// 자동 삭제 타이머(초). null이면 꺼짐. RoomOptionsMenu 설정 변경 시 그 자리에서 바뀌므로 non-final.
  int? secretSelfDestructSeconds;

  /// 비밀 대화에서 "상대방도 나가기" 없이 상대방 혼자 나갔을 때, 그 사람의 이름(members에는
  /// 더 이상 없음). displayName()이 "(알 수 없음)" 대신 "OOO님 (나갔음)"을 보여주는 데 쓴다.
  final String? secretDepartedMemberName;

  /// 비밀 대화를 먼저 건 쪽의 사용자 id. secretStatus가 'pending'일 때, 내가 이 값과 다르면
  /// (=상대가 나에게 건 것이면) 내가 응답(수락/거절)해야 하는 쪽 — Session이 이걸로 "내가
  /// 놓친 초대"를 판별해서 서버에서 다시 가져온다(ensurePendingSecretInvite 참고).
  final String? secretInitiatorUserId;

  Room({
    required this.id,
    required this.type,
    required this.name,
    this.description,
    this.isPublic = true,
    required this.members,
    required this.createdAt,
    required this.lastRead,
    this.unreadCount = 0,
    this.favorite = false,
    this.muted = false,
    this.hidden = false,
    this.lastMessagePreview,
    DateTime? lastActivityAt,
    this.isSecret = false,
    this.secretStatus,
    this.secretSelfDestructSeconds,
    this.secretDepartedMemberName,
    this.secretInitiatorUserId,
  }) : lastActivityAt = lastActivityAt ?? createdAt;

  factory Room.fromJson(Map<String, dynamic> json) {
    return Room(
      id: json['id'] as String,
      type: _typeFromString(json['type'] as String),
      name: json['name'] as String?,
      description: json['description'] as String?,
      isPublic: json['isPublic'] as bool? ?? true,
      members: (json['members'] as List)
          .map((e) => AppUser.fromJson(e as Map<String, dynamic>))
          .toList(),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAt'] as num).toInt(),
      ),
      lastRead: ((json['lastRead'] as Map?) ?? const {}).map(
        (k, v) => MapEntry(k as String, (v as num).toInt()),
      ),
      unreadCount: (json['unreadCount'] as num?)?.toInt() ?? 0,
      favorite: json['favorite'] as bool? ?? false,
      muted: json['muted'] as bool? ?? false,
      hidden: json['hidden'] as bool? ?? false,
      lastMessagePreview: json['lastMessagePreview'] as String?,
      lastActivityAt: (json['lastActivityAt'] as num?) != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (json['lastActivityAt'] as num).toInt(),
            )
          : null,
      isSecret: json['isSecret'] as bool? ?? false,
      secretStatus: json['secretStatus'] as String?,
      secretSelfDestructSeconds: (json['secretSelfDestructSeconds'] as num?)
          ?.toInt(),
      secretDepartedMemberName: json['secretDepartedMemberName'] as String?,
      secretInitiatorUserId: json['secretInitiatorUserId'] as String?,
    );
  }

  /// 화면에 보여줄 이름. DM은 상대방 이름, 이름 없는 그룹은 멤버 이름을 이름순 정렬해 보여준다.
  String displayName(String myUserId) {
    if (name != null) return name!;
    if (type == RoomType.dm) {
      for (final m in members) {
        if (m.id != myUserId) return m.name;
      }
      if (secretDepartedMemberName != null) {
        return '$secretDepartedMemberName (나갔음)';
      }
      return '(알 수 없음)';
    }
    final names =
        members.where((m) => m.id != myUserId).map((m) => m.name).toList()
          ..sort();
    if (names.isEmpty) return '(알 수 없음)';
    return names.join(', ');
  }

  /// 이 메시지를 아직 안 읽은(보낸 사람 제외) 멤버 수.
  int unreadCountFor(Message message) {
    final sentAt = message.createdAt.millisecondsSinceEpoch;
    var count = 0;
    for (final m in members) {
      if (m.id == message.senderId) continue;
      if ((lastRead[m.id] ?? 0) < sentAt) count++;
    }
    return count;
  }
}
