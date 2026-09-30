import 'announcement.dart';
import 'app_user.dart';
import 'message.dart';

enum RoomType { topic, group, dm }

RoomType _typeFromString(String s) => switch (s) {
  'group' => RoomType.group,
  'dm' => RoomType.dm,
  _ => RoomType.topic,
};

/// 토픽의 보기 방식(서버 rooms.view_mode) — 만들 때 정하면 바꿀 수 없다. 그룹/DM은 항상 chat.
enum TopicViewMode {
  chat, // 챗 뷰 — 메시지를 주고받는 대화방(예전 토픽 전부)
  board, // 보드 뷰 — 제목이 있는 게시글(Message.isPost)을 올리는 게시판
}

/// 서버 문자열('chat'|'board')을 enum으로. 모르는 값·예전 서버(값 없음)면 챗 뷰.
TopicViewMode topicViewModeFromWire(String? s) =>
    s == 'board' ? TopicViewMode.board : TopicViewMode.chat;

extension TopicViewModeLabel on TopicViewMode {
  String get wire => name;

  String get label => switch (this) {
    TopicViewMode.chat => '챗 뷰',
    TopicViewMode.board => '보드 뷰',
  };

  String get description => switch (this) {
    TopicViewMode.chat => '메시지를 주고받는 대화방',
    TopicViewMode.board => '제목이 있는 게시글을 올리는 게시판',
  };
}

/// 토픽 이름(글자 수)·설명 최대 길이 — 서버 POST/PATCH /rooms가 같은 값으로 다시 검사한다.
const topicNameMaxLength = 60;
const topicDescriptionMaxLength = 300;

/// 그룹채팅 이름(글자 수)·설명 최대 길이 — 서버가 토픽과 같은 규칙으로 다시 검사한다.
const groupNameMaxLength = topicNameMaxLength;
const groupDescriptionMaxLength = topicDescriptionMaxLength;

/// 나와의 대화(나만 보는 메모 방)의 이름 — 방 목록·대화 헤더·알림이 같이 쓴다.
const selfRoomName = '나와의 대화';

/// 보관 시각 없이 archived만 온 경우(부분 응답)에도 보관 상태는 놓치지 않는다.
DateTime? _archivedAtFromJson(Map<String, dynamic> json) {
  final ms = json['archivedAt'] as num?;
  if (ms != null) return DateTime.fromMillisecondsSinceEpoch(ms.toInt());
  return json['archived'] == true
      ? DateTime.fromMillisecondsSinceEpoch(0)
      : null;
}

class Room {
  final String id;

  /// 이 방이 속한 팀. 방 목록/조직도/검색/파일이 전부 팀 단위로 갈리고, 다른 팀에서 온
  /// 메시지를 눌렀을 때 그 팀으로 전환하는 데도 쓴다(Session.requestOpenRoom 참고).
  final String teamId;
  final RoomType type;

  /// 이름·설명·공개 여부·멤버는 토픽 정보 변경/초대/내보내기로 바뀌어 room:created로 다시
  /// 오고, Session이 화면이 들고 있는 이 인스턴스에 그 자리에서 반영한다([mergeServerState])
  /// — 그래서 non-final.
  String? name; // dm/이름없는 group은 null (클라이언트가 대신 표시할 이름을 계산)
  String? description;
  bool isPublic; // 토픽에서만 의미 있음: 공개면 누구나 검색해서 참여 가능, 비공개면 초대로만.
  List<AppUser> members;
  final DateTime createdAt;
  Map<String, int> lastRead; // userId -> epoch millis, 마지막으로 이 방을 읽은 시각

  /// 내가 안 읽은 메시지 수. 서버가 REST 응답에서 계산해서 채워주고(로그인/방 목록 조회 시),
  /// 이후 실시간으로는 Session이 소켓 메시지를 받을 때마다 직접 증감시킨다 — 그래서 non-final.
  int unreadCount;

  /// 나만의 즐겨찾기 표시. 서버 브로드캐스트(room:created)에는 이 값이 안 실려올 수 있어서
  /// Session이 병합할 때 로컬 값을 유지한다 — 그래서 non-final.
  bool favorite;

  /// 나만의 알림 끄기 표시(즐겨찾기와 같은 방식 — non-final, Session이 병합 시 유지).
  /// 이 방을 뮤트하면 앱이 완전히 꺼져있을 때의 FCM 푸시가 안 온다(server/src/push.js).
  bool muted;

  /// 그룹채팅방 이름을 "나에게만" 다르게 부르는 개인 별칭(server/src/db/schema.js의
  /// room_members.custom_name). null이면 원래 이름. muted와 같은 방식으로 Session이 병합 시 유지한다.
  String? customName;

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

  /// 나와의 대화(나만 보는 메모 방)인지 — isSecret처럼 dm 위에 얹는 플래그이고 멤버는 나 하나뿐이다
  /// (서버 rooms.is_self, 팀마다 하나). 초대·나가기·숨기기·별칭은 서버가 막고, 이름은 늘 [selfRoomName].
  final bool isSelf;

  /// 초대로만 들어오는 비공개 토픽 — 방 목록·대화 헤더에서 이름 옆에 자물쇠를 붙인다.
  bool get isPrivateTopic => type == RoomType.topic && !isPublic;

  /// 비밀 대화 핸드셰이크 상태: 'pending'(초대 대기) | 'active'(성립) | 'rejected' | 'terminated'.
  /// 서버가 room:created/rooms 목록에 실어 보내고(rooms.js의 toRoomDto), 그 자리에서 바뀔 수
  /// 있어(secret:accepted 수신 시) non-final.
  String? secretStatus;

  /// 자동 삭제 타이머(초). null이면 꺼짐. RoomOptionsMenu 설정 변경 시 그 자리에서 바뀌므로 non-final.
  int? secretSelfDestructSeconds;

  /// 비밀 대화에서 "상대방도 나가기" 없이 상대방 혼자 나갔을 때, 그 사람의 이름(members에는
  /// 더 이상 없음). displayName()이 "(알 수 없음)" 대신 "OOO님 (나갔음)"을 보여주는 데 쓴다.
  /// 상대가 나가는 순간 room:created로 다시 오므로 non-final.
  String? secretDepartedMemberName;

  /// 비밀 대화를 먼저 건 쪽의 사용자 id. secretStatus가 'pending'일 때, 내가 이 값과 다르면
  /// (=상대가 나에게 건 것이면) 내가 응답(수락/거절)해야 하는 쪽 — Session이 이걸로 "내가
  /// 놓친 초대"를 판별해서 서버에서 다시 가져온다(ensurePendingSecretInvite 참고).
  final String? secretInitiatorUserId;

  /// 채팅방 상단 배너용 "지금 고정된 공지"(토픽방만, 없으면 null). 서버가 방 DTO에 얹어서
  /// 보내고(rooms.js), 실시간으로는 announcement:new 소켓 이벤트로 Session이 직접 갱신한다
  /// (message.dart의 lastMessagePreview와 같은 방식) — 그래서 non-final.
  Announcement? latestAnnouncement;

  /// 상단 배너의 X 버튼으로 이 공지를 닫았는지(카카오톡처럼) — 서버에는 없는 순수 로컬 상태라
  /// JSON에 없고 fromJson도 안 건드린다. latestAnnouncement.id와 같으면 배너를 숨기고, 새
  /// 공지가 올라와 id가 달라지면(chat_panel.dart의 _AnnouncementBanner) 자동으로 다시 뜬다.
  String? dismissedAnnouncementId;

  /// 알림 센터에 "안 읽은 공지"로 띄울지(rooms.js가 계산해서 내려줌 — 공지 목록/상세를 실제로
  /// 열어본 적 있는지 기준, X로 배너만 닫은 건 해당 안 됨). 실시간으로는 Session이 소켓
  /// 이벤트로 직접 갱신한다(latestAnnouncement와 같은 방식) — 그래서 non-final.
  bool hasUnreadAnnouncement;

  /// [hasUnreadAnnouncement]가 true일 때 안 읽은 공지가 몇 개인지(알림 센터 배지 숫자).
  int unreadAnnouncementCount;

  /// 이 방에서 내가 아직 읽지 않은 멘션 알림 수 — 방 목록이 안읽음 배지 옆에 "@"를 붙이는 데 쓴다.
  /// 서버가 방 목록에 실어 주고, 실시간으로는 notification:new가 올리고 그 방을 읽으면 0이 된다.
  int unreadMentionCount;

  /// 그룹채팅 아이콘 — 만들 때 고르고, 이후 "채팅 정보 변경"으로 바꿀 수 있다(바뀌면 room:created로
  /// 다시 와서 [mergeServerState]가 그 자리에서 반영한다 — 그래서 non-final).
  /// null 또는 'members'면 room_avatar.dart가 기존처럼 멤버 아바타 두 개를 겹쳐 보여준다.
  /// 'initial'이면 그룹 이름 앞 2글자, 'emoji'면 iconEmoji, 'photo'면 iconUrl(서명된
  /// /files/ 링크)을 보여준다. iconColor는 initial·emoji의 배경색. 토픽/DM은 항상 null.
  /// iconUrl은 때마다 새로 서명되는(만료되는) 링크라 방 갱신 때마다 새 값으로 바뀐다.
  String? iconType;
  String? iconEmoji;
  String? iconColor;
  String? iconUrl;

  /// 토픽의 보기 방식 — 챗 뷰/보드 뷰. 만든 뒤에는 바꿀 수 없어서(서버 PATCH가 거부) final.
  final TopicViewMode viewMode;

  /// 읽기 전용 — 토픽을 관리할 수 있는 사람만 글을 쓸 수 있다(서버 message:send가 막는다).
  /// 아래 토픽 설정들은 "토픽 정보 변경하기"로 바뀌어 room:created로 다시 오므로 non-final.
  bool readOnly;

  /// 정회원 자동 초대 — 새로 팀에 들어오는 정회원을 이 토픽에 자동으로 넣는다(공개 토픽만).
  bool autoInvite;

  /// 조용히 나가기 — 멤버가 나가거나 내보내져도 "OOO 님이 나갔습니다" 안내를 남기지 않는다.
  bool quietLeave;

  /// 토픽을 보관한 시각(null이면 보관 안 됨) — 보관된 토픽은 목록의 "보관된 토픽"으로
  /// 옮겨지고, 읽기 전용처럼 토픽을 관리할 수 있는 사람만 글을 쓸 수 있다.
  DateTime? archivedAt;

  /// 토픽 관리자(room_members.role = 'admin')의 id들 — 여러 명일 수 있다.
  List<String> adminIds;

  /// 토픽을 만든 사람 id(예전 방이거나 서버가 안 보내면 null).
  String? createdBy;

  Room({
    required this.id,
    required this.teamId,
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
    this.customName,
    this.hidden = false,
    this.lastMessagePreview,
    DateTime? lastActivityAt,
    this.isSecret = false,
    this.isSelf = false,
    this.secretStatus,
    this.secretSelfDestructSeconds,
    this.secretDepartedMemberName,
    this.secretInitiatorUserId,
    this.latestAnnouncement,
    this.hasUnreadAnnouncement = false,
    this.unreadAnnouncementCount = 0,
    this.unreadMentionCount = 0,
    this.iconType,
    this.iconEmoji,
    this.iconColor,
    this.iconUrl,
    this.viewMode = TopicViewMode.chat,
    this.readOnly = false,
    this.autoInvite = false,
    this.quietLeave = false,
    this.archivedAt,
    List<String>? adminIds,
    this.createdBy,
  }) : lastActivityAt = lastActivityAt ?? createdAt,
       adminIds = adminIds ?? [];

  /// 새 토픽 필드(viewMode~createdBy)가 없는 예전 서버 응답이면 전부 기본값(챗 뷰, 설정 꺼짐,
  /// 보관 안 됨, 토픽 관리자 없음)으로 읽는다. isSelf가 없으면 나와의 대화가 아니다.
  factory Room.fromJson(Map<String, dynamic> json) {
    return Room(
      id: json['id'] as String,
      teamId: json['teamId'] as String,
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
      customName: json['customName'] as String?,
      hidden: json['hidden'] as bool? ?? false,
      lastMessagePreview: json['lastMessagePreview'] as String?,
      lastActivityAt: (json['lastActivityAt'] as num?) != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (json['lastActivityAt'] as num).toInt(),
            )
          : null,
      isSecret: json['isSecret'] as bool? ?? false,
      isSelf: json['isSelf'] as bool? ?? false,
      secretStatus: json['secretStatus'] as String?,
      secretSelfDestructSeconds: (json['secretSelfDestructSeconds'] as num?)
          ?.toInt(),
      secretDepartedMemberName: json['secretDepartedMemberName'] as String?,
      secretInitiatorUserId: json['secretInitiatorUserId'] as String?,
      latestAnnouncement: json['latestAnnouncement'] == null
          ? null
          : Announcement.fromJson(
              json['latestAnnouncement'] as Map<String, dynamic>,
            ),
      hasUnreadAnnouncement: json['hasUnreadAnnouncement'] as bool? ?? false,
      unreadAnnouncementCount:
          (json['unreadAnnouncementCount'] as num?)?.toInt() ?? 0,
      unreadMentionCount: (json['unreadMentionCount'] as num?)?.toInt() ?? 0,
      iconType: json['iconType'] as String?,
      iconEmoji: json['iconEmoji'] as String?,
      iconColor: json['iconColor'] as String?,
      iconUrl: json['iconUrl'] as String?,
      viewMode: topicViewModeFromWire(json['viewMode'] as String?),
      readOnly: json['readOnly'] as bool? ?? false,
      autoInvite: json['autoInvite'] as bool? ?? false,
      quietLeave: json['quietLeave'] as bool? ?? false,
      archivedAt: _archivedAtFromJson(json),
      adminIds: (json['adminIds'] as List?)?.whereType<String>().toList(),
      createdBy: json['createdBy'] as String?,
    );
  }

  /// 보드 뷰 토픽 — 채팅 목록 대신 게시글 보드(board_view.dart)를 보여준다.
  bool get isBoard => type == RoomType.topic && viewMode == TopicViewMode.board;

  /// 보관된 토픽인지 — 목록에서는 "보관된 토픽"에만 보인다.
  bool get isArchived => archivedAt != null;

  /// [userId]가 이 토픽의 토픽 관리자인지(팀 관리자 여부와는 별개 — 둘을 합친 "토픽을 관리할 수
  /// 있는 사람"은 room_permissions.dart의 canManage).
  bool isTopicAdmin(String? userId) =>
      userId != null && adminIds.contains(userId);

  /// 같은 방의 새 서버 값([incoming] — room:created 브로드캐스트나 REST 응답)을 이 인스턴스에
  /// 그 자리에서 반영한다. 방 하나에 인스턴스를 하나만 두려는 것 — 화면·컨트롤러가 붙잡고 있는
  /// 객체도 다시 열지 않고 최신 이름·멤버·권한(읽기 전용/보관/토픽 관리자)을 보게 된다.
  /// 이 사람만의 값(안읽음·즐겨찾기·알림 끄기·별칭·숨김·최근 활동·미리보기·안 읽은 공지)은
  /// 브로드캐스트엔 없거나 낡았을 수 있어서, [includePersonal]일 때(재연결 후 내 기준으로 다시
  /// 받은 목록)만 덮어쓴다. 배너 닫기(dismissedAnnouncementId)는 순수 로컬 값이라 늘 그대로 둔다.
  void mergeServerState(Room incoming, {bool includePersonal = false}) {
    if (identical(incoming, this)) return;
    name = incoming.name;
    description = incoming.description;
    isPublic = incoming.isPublic;
    members = incoming.members;
    // 읽음 시각은 늘기만 한다 — 조금 전에 만들어진 브로드캐스트가 방금 받은 room:read보다
    // 늦게 도착해도 되돌아가지 않게 더 큰 값을 남긴다.
    final mergedRead = Map<String, int>.of(lastRead);
    incoming.lastRead.forEach((userId, at) {
      if (at > (mergedRead[userId] ?? 0)) mergedRead[userId] = at;
    });
    lastRead = mergedRead;
    secretStatus = incoming.secretStatus;
    secretSelfDestructSeconds = incoming.secretSelfDestructSeconds;
    secretDepartedMemberName = incoming.secretDepartedMemberName;
    latestAnnouncement = incoming.latestAnnouncement;
    iconType = incoming.iconType;
    iconEmoji = incoming.iconEmoji;
    iconColor = incoming.iconColor;
    iconUrl = incoming.iconUrl;
    readOnly = incoming.readOnly;
    autoInvite = incoming.autoInvite;
    quietLeave = incoming.quietLeave;
    archivedAt = incoming.archivedAt;
    adminIds = incoming.adminIds;
    createdBy = incoming.createdBy;
    if (!includePersonal) return;
    unreadCount = incoming.unreadCount;
    favorite = incoming.favorite;
    muted = incoming.muted;
    customName = incoming.customName;
    hidden = incoming.hidden;
    lastActivityAt = incoming.lastActivityAt;
    lastMessagePreview = incoming.lastMessagePreview;
    hasUnreadAnnouncement = incoming.hasUnreadAnnouncement;
    unreadAnnouncementCount = incoming.unreadAnnouncementCount;
    unreadMentionCount = incoming.unreadMentionCount;
  }

  /// 화면에 보여줄 이름. DM은 상대방 이름, 이름 없는 그룹은 멤버 이름을 이름순 정렬해 보여준다.
  /// 나와의 대화는 늘 [selfRoomName]이다.
  String displayName(String myUserId) {
    if (isSelf) return selfRoomName;
    final custom = customName;
    if (custom != null && custom.isNotEmpty) return custom;
    return originalDisplayName(myUserId);
  }

  /// 나만의 별칭([customName])을 무시한 원래 이름 — 이름 변경 메뉴가 "이름 변경(원래 이름)"으로
  /// 보여주고, 별칭을 지웠을 때 돌아갈 이름을 안내하는 데 쓴다.
  String originalDisplayName(String myUserId) {
    if (isSelf) return selfRoomName;
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
    return memberNames(myUserId);
  }

  /// 이름 없는 그룹채팅이 대신 보여주는 이름 — 나를 뺀 멤버 이름(이름순)을 쉼표로 잇는다. 이름이
  /// 있는 그룹에서도 "비워 두면 이렇게 보여요" 안내(채팅 정보 변경)에 쓴다.
  String memberNames(String myUserId) {
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
