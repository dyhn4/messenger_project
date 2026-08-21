class AppUser {
  final String id;
  final String username;
  final String name;
  final String? email;
  final String avatarType; // 'initial' | 'character' | 'photo'
  final String? avatarEmoji;
  final String? avatarColor; // '#RRGGBB'
  final String? avatarUrl;

  const AppUser({
    required this.id,
    required this.username,
    required this.name,
    this.email,
    this.avatarType = 'initial',
    this.avatarEmoji,
    this.avatarColor,
    this.avatarUrl,
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
    );
  }
}
