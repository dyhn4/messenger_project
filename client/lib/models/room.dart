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
  final List<AppUser> members;
  final DateTime createdAt;
  final Map<String, int> lastRead; // userId -> epoch millis, 마지막으로 이 방을 읽은 시각

  /// 내가 안 읽은 메시지 수. 서버가 REST 응답에서 계산해서 채워주고(로그인/방 목록 조회 시),
  /// 이후 실시간으로는 Session이 소켓 메시지를 받을 때마다 직접 증감시킨다 — 그래서 non-final.
  int unreadCount;

  Room({
    required this.id,
    required this.type,
    required this.name,
    this.description,
    required this.members,
    required this.createdAt,
    required this.lastRead,
    this.unreadCount = 0,
  });

  factory Room.fromJson(Map<String, dynamic> json) {
    return Room(
      id: json['id'] as String,
      type: _typeFromString(json['type'] as String),
      name: json['name'] as String?,
      description: json['description'] as String?,
      members: (json['members'] as List).map((e) => AppUser.fromJson(e as Map<String, dynamic>)).toList(),
      createdAt: DateTime.fromMillisecondsSinceEpoch((json['createdAt'] as num).toInt()),
      lastRead: ((json['lastRead'] as Map?) ?? const {})
          .map((k, v) => MapEntry(k as String, (v as num).toInt())),
      unreadCount: (json['unreadCount'] as num?)?.toInt() ?? 0,
    );
  }

  /// 화면에 보여줄 이름. DM은 상대방 이름, 이름 없는 그룹은 멤버 이름을 이름순 정렬해 보여준다.
  String displayName(String myUserId) {
    if (name != null) return name!;
    if (type == RoomType.dm) {
      for (final m in members) {
        if (m.id != myUserId) return m.username;
      }
      return '(알 수 없음)';
    }
    final names = members.map((m) => m.username).toList()..sort();
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
