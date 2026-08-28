import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/app_user.dart';
import '../models/comment.dart';
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
  const UploadResult({
    required this.url,
    required this.fileName,
    required this.size,
    this.mimeType,
  });
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

  factory TopicBrowseEntry.fromJson(Map<String, dynamic> json) =>
      TopicBrowseEntry(
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
  final String? senderId; // 시스템 메시지는 작성자가 없어서 null.
  final String senderName;
  final String? text;
  final String? fileName;
  final DateTime createdAt;
  const SearchResult({
    required this.id,
    required this.roomId,
    this.roomName,
    this.senderId,
    required this.senderName,
    this.text,
    this.fileName,
    required this.createdAt,
  });

  factory SearchResult.fromJson(Map<String, dynamic> json) => SearchResult(
    id: json['id'] as String,
    roomId: json['roomId'] as String,
    roomName: json['roomName'] as String?,
    senderId: json['senderId'] as String?,
    senderName: json['senderName'] as String,
    text: json['text'] as String?,
    fileName: json['fileName'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num).toInt(),
    ),
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

  ApiClient({
    required this.baseUrl,
    this.token,
    this.onUnauthorized,
    http.Client? httpClient,
  }) : _client = httpClient ?? http.Client();

  Map<String, String> get _authHeaders =>
      token == null ? {} : {'Authorization': 'Bearer $token'};

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
      final res = await _client
          .get(_uri('/health'))
          .timeout(const Duration(seconds: 5));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 서버에 배포된 최신 클라이언트 버전(version.js 참고). 아직 배포된 빌드가 없으면 null.
  /// 로그인 여부와 무관하게 호출 가능(인증 불필요 엔드포인트).
  Future<String?> fetchLatestVersion() async {
    try {
      final res = await _client
          .get(_uri('/version'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;
      final body =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      return body['version'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// 업데이트 설치 파일(windows/android)을 스트리밍으로 받는다. 인증 불필요 엔드포인트라
  /// fetchLatestVersion과 마찬가지로 로그인 여부와 무관하게 호출할 수 있다. 응답 본문을
  /// 통째로 메모리에 올리지 않고 스트림으로 넘겨서 호출부가 진행률을 계산하며 파일에 써넣게 한다.
  Future<http.StreamedResponse> downloadUpdate(String platformPath) {
    final req = http.Request('GET', _uri('/downloads/$platformPath'));
    return _client.send(req);
  }

  Future<AuthResult> register(
    String username,
    String password,
    String email,
    String name,
  ) => _authRequest('/auth/register', {
    'username': username,
    'password': password,
    'email': email,
    'name': name,
  });

  Future<AuthResult> login(String username, String password) =>
      _authRequest('/auth/login', {'username': username, 'password': password});

  Future<AuthResult> _authRequest(
    String path,
    Map<String, dynamic> payload,
  ) async {
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

  Future<void> resetPassword({
    required String username,
    required String email,
    required String newPassword,
  }) async {
    final res = await _client.post(
      _uri('/auth/reset-password'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'email': email,
        'newPassword': newPassword,
      }),
    );
    if (res.statusCode >= 400) {
      final body =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      throw ApiException((body['error'] as String?) ?? '요청이 실패했습니다.');
    }
  }

  Future<dynamic> _get(String path) async {
    final res = await _send(
      () => _client.get(_uri(path), headers: _authHeaders),
    );
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      throw ApiException(
        (body is Map ? body['error'] as String? : null) ?? '요청이 실패했습니다.',
      );
    }
    return body;
  }

  Future<dynamic> _post(String path, Map<String, dynamic> body) async {
    final res = await _send(
      () => _client.post(
        _uri(path),
        headers: {..._authHeaders, 'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ),
    );
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      throw ApiException(
        (decoded is Map ? decoded['error'] as String? : null) ?? '요청이 실패했습니다.',
      );
    }
    return decoded;
  }

  Future<dynamic> _patch(String path, Map<String, dynamic> body) async {
    final res = await _send(
      () => _client.patch(
        _uri(path),
        headers: {..._authHeaders, 'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ),
    );
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      throw ApiException(
        (decoded is Map ? decoded['error'] as String? : null) ?? '요청이 실패했습니다.',
      );
    }
    return decoded;
  }

  Future<dynamic> _delete(String path) async {
    final res = await _send(
      () => _client.delete(_uri(path), headers: _authHeaders),
    );
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      throw ApiException(
        (decoded is Map ? decoded['error'] as String? : null) ?? '요청이 실패했습니다.',
      );
    }
    return decoded;
  }

  Future<List<AppUser>> fetchUsers() async {
    final list = await _get('/api/users') as List;
    return list
        .map((e) => AppUser.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<MyProfile> fetchMe() async {
    return MyProfile.fromJson(
      await _get('/api/users/me') as Map<String, dynamic>,
    );
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
    return MyProfile.fromJson(
      await _patch('/api/users/me', body) as Map<String, dynamic>,
    );
  }

  /// 비밀번호 변경. 성공하면 서버가 새 토큰 쌍을 함께 내려준다(이 기기는 로그아웃되지 않고
  /// 그 토큰으로 이어서 쓸 수 있음 — 다른 기기는 이 시점에 강제로 끊긴다).
  Future<AuthResult> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final body =
        await _post('/api/users/me/change-password', {
              'currentPassword': currentPassword,
              'newPassword': newPassword,
            })
            as Map<String, dynamic>;
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
    return list
        .map((e) => TopicBrowseEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Room> fetchRoomDetail(String roomId) async {
    return Room.fromJson(
      await _get('/api/rooms/$roomId') as Map<String, dynamic>,
    );
  }

  /// [before]를 주면 그 시각보다 먼저 온 메시지 중 최근 [limit]개(과거로 페이지네이션 —
  /// "위로 스크롤해서 더 불러오기"/검색으로 오래된 메시지 찾기). 없으면 방에서 가장 최근 [limit]개.
  Future<List<Message>> fetchRoomMessages(
    String roomId, {
    int limit = 50,
    DateTime? before,
  }) async {
    final beforeParam = before != null
        ? '&before=${before.millisecondsSinceEpoch}'
        : '';
    final list =
        await _get('/api/rooms/$roomId/messages?limit=$limit$beforeParam')
            as List;
    return list
        .map((e) => Message.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Room> createTopic({
    required String name,
    String? description,
    bool isPublic = true,
  }) async {
    return Room.fromJson(
      await _post('/api/rooms', {
            'type': 'topic',
            'name': name,
            if (description != null && description.isNotEmpty)
              'description': description,
            'isPublic': isPublic,
          })
          as Map<String, dynamic>,
    );
  }

  Future<Room> createGroup({
    String? name,
    required List<String> memberIds,
  }) async {
    return Room.fromJson(
      await _post('/api/rooms', {
            'type': 'group',
            if (name != null && name.isNotEmpty) 'name': name,
            'memberIds': memberIds,
          })
          as Map<String, dynamic>,
    );
  }

  Future<Room> startDm(String targetUserId) async {
    return Room.fromJson(
      await _post('/api/rooms/dm', {'targetUserId': targetUserId})
          as Map<String, dynamic>,
    );
  }

  /// 비밀 대화(E2EE)용 기기 신원 등록(멱등 — 같은 deviceId면 공개키만 갱신). 개인키는 절대 여기
  /// 담기지 않는다(device_identity.dart 참고).
  /// 상대 기기의 서명 검증키(비밀 대화 핸드셰이크의 임시 공개키 서명을 확인하는 데 씀) 조회.
  Future<String> fetchDeviceSigningPublicKey(String deviceId) async {
    final body =
        await _get('/api/devices/$deviceId/public-key') as Map<String, dynamic>;
    return body['signingPublicKey'] as String;
  }

  Future<void> registerDevice({
    required String deviceId,
    String? name,
    required String identityPublicKey,
    required String signingPublicKey,
  }) async {
    await _post('/api/devices', {
      'deviceId': deviceId,
      'name': ?name,
      'identityPublicKey': identityPublicKey,
      'signingPublicKey': signingPublicKey,
    });
  }

  Future<Room> startSecretChat({
    required String targetUserId,
    required String deviceId,
    required String initiatorEphemeralPublicKey,
    required String initiatorEphemeralSignature,
  }) async {
    return Room.fromJson(
      await _post('/api/secret-chats', {
            'targetUserId': targetUserId,
            'deviceId': deviceId,
            'initiatorEphemeralPublicKey': initiatorEphemeralPublicKey,
            'initiatorEphemeralSignature': initiatorEphemeralSignature,
          })
          as Map<String, dynamic>,
    );
  }

  Future<void> acceptSecretChat({
    required String roomId,
    required String deviceId,
    required String responderEphemeralPublicKey,
    required String responderEphemeralSignature,
  }) async {
    await _post('/api/secret-chats/$roomId/accept', {
      'deviceId': deviceId,
      'responderEphemeralPublicKey': responderEphemeralPublicKey,
      'responderEphemeralSignature': responderEphemeralSignature,
    });
  }

  Future<void> rejectSecretChat(String roomId) async {
    await _post('/api/secret-chats/$roomId/reject', const {});
  }

  /// [seconds]가 null이면 자동 삭제를 끈다. 1초~1주(604800초) 범위여야 한다(서버가 재검증).
  Future<void> setSecretChatTimer(String roomId, int? seconds) async {
    await _patch('/api/secret-chats/$roomId/settings', {
      'selfDestructSeconds': seconds,
    });
  }

  Future<Room> joinRoom(String roomId) async {
    return Room.fromJson(
      await _post('/api/rooms/$roomId/join', const {}) as Map<String, dynamic>,
    );
  }

  /// [alsoRemoveOther]는 비밀 대화에서만 의미가 있다 — true면 상대방도 함께 나가지고 방
  /// 자체가 없어지며, false(기본)면 나만 나간다(평문 방은 이 값과 무관하게 항상 나만 나간다).
  Future<void> leaveRoom(String roomId, {bool alsoRemoveOther = false}) async {
    await _post('/api/rooms/$roomId/leave', {
      'alsoRemoveOther': alsoRemoveOther,
    });
  }

  Future<Room> inviteMembers(String roomId, List<String> userIds) async {
    return Room.fromJson(
      await _post('/api/rooms/$roomId/invite', {'userIds': userIds})
          as Map<String, dynamic>,
    );
  }

  Future<void> setFavorite(String roomId, bool favorite) async {
    await _post('/api/rooms/$roomId/favorite', {'favorite': favorite});
  }

  /// [text] 없이 첨부만(이미지/파일) 다는 댓글도 가능하다 — 그때는 [type]과 [fileUrl] 등을 채워서 호출.
  Future<Comment> addComment(
    String messageId, {
    String? text,
    String type = 'text',
    String? fileUrl,
    String? fileName,
    int? fileSize,
    String? mimeType,
    String? thumbnailUrl,
  }) async {
    return Comment.fromJson(
      await _post('/api/messages/$messageId/comments', {
            'text': ?text,
            'type': type,
            'fileUrl': ?fileUrl,
            'fileName': ?fileName,
            'fileSize': ?fileSize,
            'mimeType': ?mimeType,
            'thumbnailUrl': ?thumbnailUrl,
          })
          as Map<String, dynamic>,
    );
  }

  Future<Comment> editComment(String commentId, String text) async {
    return Comment.fromJson(
      await _patch('/api/comments/$commentId', {'text': text})
          as Map<String, dynamic>,
    );
  }

  Future<void> deleteComment(String commentId) async {
    await _delete('/api/comments/$commentId');
  }

  Future<Message> editMessage(String messageId, String text) async {
    return Message.fromJson(
      await _patch('/api/messages/$messageId', {'text': text})
          as Map<String, dynamic>,
    );
  }

  Future<void> deleteMessage(String messageId) async {
    await _delete('/api/messages/$messageId');
  }

  Future<List<SearchResult>> search(
    String query, {
    String? roomId,
    String? senderId,
    DateTime? since,
    DateTime? until,
  }) async {
    final params = StringBuffer(
      '/api/search?q=${Uri.encodeQueryComponent(query)}',
    );
    if (roomId != null)
      params.write('&roomId=${Uri.encodeQueryComponent(roomId)}');
    if (senderId != null)
      params.write('&senderId=${Uri.encodeQueryComponent(senderId)}');
    if (since != null) params.write('&since=${since.millisecondsSinceEpoch}');
    if (until != null) params.write('&until=${until.millisecondsSinceEpoch}');
    final list = await _get(params.toString()) as List;
    return list
        .map((e) => SearchResult.fromJson(e as Map<String, dynamic>))
        .toList();
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
  String resolve(String relativeUrl) =>
      relativeUrl.startsWith('http') ? relativeUrl : '$baseUrl$relativeUrl';
}
