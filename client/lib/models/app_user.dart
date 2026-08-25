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

  const AppUser({
    required this.id,
    required this.username,
    required this.name,
    this.email,
    this.avatarType = 'initial',
    this.avatarEmoji,
    this.avatarColor,
    this.avatarUrl,
    this.online = false,
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
    );
  }
}
