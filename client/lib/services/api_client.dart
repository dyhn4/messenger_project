import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/app_user.dart';
import '../models/message.dart';
import '../models/room.dart';

class ApiException implements Exception {
  final String message;
  const ApiException(this.message);
  @override
  String toString() => message;
}

class AuthResult {
  final String accessToken;
  final String refreshToken;
  final String userId;
  final String username;
  const AuthResult({
    required this.accessToken,
    required this.refreshToken,
    required this.userId,
    required this.username,
  });
}

class UploadResult {
  final String url;
  final String fileName;
  final int size;
  final String? mimeType;
  const UploadResult({required this.url, required this.fileName, required this.size, this.mimeType});
}

/// GET/PATCH /api/users/me 결과: 내 프로필과 아바타 상태.
class MyProfile {
  final String username;
  final String name;
  final String? email;
  final String avatarType; // 'initial' | 'character' | 'photo'
  final String? avatarEmoji;
  final String? avatarColor; // '#RRGGBB'
  final String? avatarUrl;
  const MyProfile({
    required this.username,
    required this.name,
    this.email,
    this.avatarType = 'initial',
    this.avatarEmoji,
    this.avatarColor,
    this.avatarUrl,
  });

  factory MyProfile.fromJson(Map<String, dynamic> json) => MyProfile(
        username: json['username'] as String,
        name: (json['name'] as String?) ?? json['username'] as String,
        email: json['email'] as String?,
        avatarType: json['avatarType'] as String? ?? 'initial',
        avatarEmoji: json['avatarEmoji'] as String?,
        avatarColor: json['avatarColor'] as String?,
        avatarUrl: json['avatarUrl'] as String?,
      );
}

/// GET /api/rooms/browse 결과 한 줄. 참여 여부가 함께 내려온다.
class TopicBrowseEntry {
  final String id;
  final String name;
  final String? description;
  final bool isPublic;
  final int memberCount;
  final bool joined;
  const TopicBrowseEntry({
    required this.id,
    required this.name,
    this.description,
    this.isPublic = true,
    required this.memberCount,
    required this.joined,
  });

  factory TopicBrowseEntry.fromJson(Map<String, dynamic> json) => TopicBrowseEntry(
        id: json['id'] as String,
        name: json['name'] as String,
        description: json['description'] as String?,
        isPublic: json['isPublic'] as bool? ?? true,
        memberCount: (json['memberCount'] as num).toInt(),
        joined: json['joined'] as bool,
      );
}

/// GET /api/search 결과 한 줄.
class SearchResult {
  final String id;
  final String roomId;
  final String? roomName;
  final String senderId;
  final String senderName;
  final String? text;
  final String? fileName;
  final DateTime createdAt;
  const SearchResult({
    required this.id,
    required this.roomId,
    this.roomName,
    required this.senderId,
    required this.senderName,
    this.text,
    this.fileName,
    required this.createdAt,
  });

  factory SearchResult.fromJson(Map<String, dynamic> json) => SearchResult(
        id: json['id'] as String,
        roomId: json['roomId'] as String,
        roomName: json['roomName'] as String?,
        senderId: json['senderId'] as String,
        senderName: json['senderName'] as String,
        text: json['text'] as String?,
        fileName: json['fileName'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch((json['createdAt'] as num).toInt()),
      );
}

/// Node.js 서버(REST 부분)와 통신하는 얇은 클라이언트.
class ApiClient {
  final String baseUrl; // 예: https://192.168.0.62:3000 (끝에 슬래시 없음)
  String? token; // accessToken. 갱신되면 Session이 이 필드를 직접 덮어쓴다.

  /// 요청이 401을 받았을 때 한 번 호출된다. accessToken 갱신에 성공하면(=이 인스턴스의
  /// [token]을 새로 채워넣으면) true를 반환해서 원래 요청을 한 번 더 재시도하게 한다.
  Future<bool> Function()? onUnauthorized;

  /// 서버가 자체 서명 인증서(HTTPS)를 쓰므로, PinnedTls.httpClient()로 만든(그 인증서만
  /// 신뢰하는) 클라이언트를 주입받는다. 안 주면 플랫폼 기본 클라이언트를 쓴다(테스트 등).
  final http.Client _client;

  ApiClient({required this.baseUrl, this.token, this.onUnauthorized, http.Client? httpClient})
      : _client = httpClient ?? http.Client();

  Map<String, String> get _authHeaders => token == null ? {} : {'Authorization': 'Bearer $token'};

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  /// [request]를 보내고, 401이면 [onUnauthorized]로 한 번 갱신을 시도한 뒤 한 번만 재시도한다.
  /// [request]는 매번 새로 헤더/바디를 구성해야 한다(재시도 시 갱신된 token을 반영하도록).
  Future<http.Response> _send(Future<http.Response> Function() request) async {
    var res = await request();
    if (res.statusCode == 401 && onUnauthorized != null) {
      final refreshed = await onUnauthorized!();
      if (refreshed) res = await request();
    }
    return res;
  }

  Future<bool> checkHealth() async {
    try {
      final res = await _client.get(_uri('/health')).timeout(const Duration(seconds: 5));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<AuthResult> register(String username, String password, String email, String name) => _authRequest(
        '/auth/register',
        {'username': username, 'password': password, 'email': email, 'name': name},
      );

  Future<AuthResult> login(String username, String password) =>
      _authRequest('/auth/login', {'username': username, 'password': password});

  Future<AuthResult> _authRequest(String path, Map<String, dynamic> payload) async {
    final res = await _client.post(
      _uri(path),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      throw ApiException((body['error'] as String?) ?? '요청이 실패했습니다.');
    }
    return AuthResult(
      accessToken: body['accessToken'] as String,
      refreshToken: body['refreshToken'] as String,
      userId: body['userId'] as String,
      username: body['username'] as String,
    );
  }

  /// refreshToken으로 새 accessToken을 받아온다. 실패하면(만료/비밀번호 변경 등) 던진다.
  Future<String> refreshAccessToken(String refreshToken) async {
    final res = await _client.post(
      _uri('/auth/refresh'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'refreshToken': refreshToken}),
    );
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      throw ApiException((body['error'] as String?) ?? '세션이 만료되었습니다.');
    }
    return body['accessToken'] as String;
  }

  Future<String> findId(String email) async {
    final res = await _client.post(
      _uri('/auth/find-id'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email}),
    );
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      throw ApiException((body['error'] as String?) ?? '요청이 실패했습니다.');
    }
    return body['username'] as String;
  }

  Future<void> resetPassword({required String username, required String email, required String newPassword}) async {
    final res = await _client.post(
      _uri('/auth/reset-password'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'email': email, 'newPassword': newPassword}),
    );
    if (res.statusCode >= 400) {
      final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      throw ApiException((body['error'] as String?) ?? '요청이 실패했습니다.');
    }
  }

  Future<dynamic> _get(String path) async {
    final res = await _send(() => _client.get(_uri(path), headers: _authHeaders));
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      throw ApiException((body is Map ? body['error'] as String? : null) ?? '요청이 실패했습니다.');
    }
    return body;
  }

  Future<dynamic> _post(String path, Map<String, dynamic> body) async {
    final res = await _send(() => _client.post(
          _uri(path),
          headers: {..._authHeaders, 'Content-Type': 'application/json'},
          body: jsonEncode(body),
        ));
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      throw ApiException((decoded is Map ? decoded['error'] as String? : null) ?? '요청이 실패했습니다.');
    }
    return decoded;
  }

  Future<dynamic> _patch(String path, Map<String, dynamic> body) async {
    final res = await _send(() => _client.patch(
          _uri(path),
          headers: {..._authHeaders, 'Content-Type': 'application/json'},
          body: jsonEncode(body),
        ));
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      throw ApiException((decoded is Map ? decoded['error'] as String? : null) ?? '요청이 실패했습니다.');
    }
    return decoded;
  }

  Future<List<AppUser>> fetchUsers() async {
    final list = await _get('/api/users') as List;
    return list.map((e) => AppUser.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<MyProfile> fetchMe() async {
    return MyProfile.fromJson(await _get('/api/users/me') as Map<String, dynamic>);
  }

  /// 매번 아바타 상태 전체를 통째로 바꾼다("초기화"는 전부 null, "캐릭터"는
  /// emoji+color, "사진"은 url만 채워서 호출).
  Future<MyProfile> updateMyAvatar({
    required String avatarType,
    String? avatarEmoji,
    String? avatarColor,
    String? avatarUrl,
  }) async {
    final body = await _patch('/api/users/me', {
      'avatarType': avatarType,
      'avatarEmoji': avatarEmoji,
      'avatarColor': avatarColor,
      'avatarUrl': avatarUrl,
    });
    return MyProfile.fromJson(body as Map<String, dynamic>);
  }

  /// 제공한 필드만 바꾼다(이름만, 이메일만, 또는 둘 다).
  Future<MyProfile> updateProfile({String? name, String? email}) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (email != null) body['email'] = email;
    return MyProfile.fromJson(await _patch('/api/users/me', body) as Map<String, dynamic>);
  }

  /// 비밀번호 변경. 성공하면 서버가 새 토큰 쌍을 함께 내려준다(이 기기는 로그아웃되지 않고
  /// 그 토큰으로 이어서 쓸 수 있음 — 다른 기기는 이 시점에 강제로 끊긴다).
  Future<AuthResult> changePassword({required String currentPassword, required String newPassword}) async {
    final body = await _post('/api/users/me/change-password', {
      'currentPassword': currentPassword,
      'newPassword': newPassword,
    }) as Map<String, dynamic>;
    return AuthResult(
      accessToken: body['accessToken'] as String,
      refreshToken: body['refreshToken'] as String,
      userId: body['userId'] as String,
      username: body['username'] as String,
    );
  }

  /// 회원 탈퇴. 비밀번호 확인이 틀리면 서버가 401로 거부한다.
  Future<void> withdraw(String password) async {
    await _post('/api/users/me/withdraw', {'password': password});
  }

  Future<List<Room>> fetchRooms() async {
    final list = await _get('/api/rooms') as List;
    return list.map((e) => Room.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<TopicBrowseEntry>> browseTopics() async {
    final list = await _get('/api/rooms/browse') as List;
    return list.map((e) => TopicBrowseEntry.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Room> fetchRoomDetail(String roomId) async {
    return Room.fromJson(await _get('/api/rooms/$roomId') as Map<String, dynamic>);
  }

  Future<List<Message>> fetchRoomMessages(String roomId, {int limit = 50}) async {
    final list = await _get('/api/rooms/$roomId/messages?limit=$limit') as List;
    return list.map((e) => Message.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Room> createTopic({required String name, String? description, bool isPublic = true}) async {
    return Room.fromJson(await _post('/api/rooms', {
      'type': 'topic',
      'name': name,
      if (description != null && description.isNotEmpty) 'description': description,
      'isPublic': isPublic,
    }) as Map<String, dynamic>);
  }

  Future<Room> createGroup({String? name, required List<String> memberIds}) async {
    return Room.fromJson(await _post('/api/rooms', {
      'type': 'group',
      if (name != null && name.isNotEmpty) 'name': name,
      'memberIds': memberIds,
    }) as Map<String, dynamic>);
  }

  Future<Room> startDm(String targetUserId) async {
    return Room.fromJson(await _post('/api/rooms/dm', {'targetUserId': targetUserId}) as Map<String, dynamic>);
  }

  Future<Room> joinRoom(String roomId) async {
    return Room.fromJson(await _post('/api/rooms/$roomId/join', const {}) as Map<String, dynamic>);
  }

  Future<void> leaveRoom(String roomId) async {
    await _post('/api/rooms/$roomId/leave', const {});
  }

  Future<Room> inviteMembers(String roomId, List<String> userIds) async {
    return Room.fromJson(await _post('/api/rooms/$roomId/invite', {'userIds': userIds}) as Map<String, dynamic>);
  }

  Future<List<SearchResult>> search(
    String query, {
    String? roomId,
    String? senderId,
    DateTime? since,
    DateTime? until,
  }) async {
    final params = StringBuffer('/api/search?q=${Uri.encodeQueryComponent(query)}');
    if (roomId != null) params.write('&roomId=${Uri.encodeQueryComponent(roomId)}');
    if (senderId != null) params.write('&senderId=${Uri.encodeQueryComponent(senderId)}');
    if (since != null) params.write('&since=${since.millisecondsSinceEpoch}');
    if (until != null) params.write('&until=${until.millisecondsSinceEpoch}');
    final list = await _get(params.toString()) as List;
    return list.map((e) => SearchResult.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<UploadResult> uploadFile(File file) async {
    final res = await _send(() async {
      final req = http.MultipartRequest('POST', _uri('/api/upload'))
        ..headers.addAll(_authHeaders)
        ..files.add(await http.MultipartFile.fromPath('file', file.path));
      final streamed = await _client.send(req);
      return http.Response.fromStream(streamed);
    });
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      throw ApiException((body['error'] as String?) ?? '업로드에 실패했습니다.');
    }
    return UploadResult(
      url: body['url'] as String,
      fileName: body['fileName'] as String,
      size: (body['size'] as num).toInt(),
      mimeType: body['mimeType'] as String?,
    );
  }

  /// 서버가 내려준 상대 경로(/uploads/xxx)를 절대 주소로 바꿉니다.
  String resolve(String relativeUrl) => relativeUrl.startsWith('http') ? relativeUrl : '$baseUrl$relativeUrl';
}
