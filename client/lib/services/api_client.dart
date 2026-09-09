import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/admin.dart';
import '../models/app_user.dart';
import '../models/comment.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../models/team.dart';
import 'chat_socket.dart' show SecretInviteEvent;

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

/// uploadFile()에 넘겨서 업로드 중간에 취소할 수 있게 하는 토큰. RoomChatController가 만들어서
/// Message/Comment의 uploadCancelToken 필드(Object? — 모델이 서비스 계층을 몰라도 되도록)에
/// 보관해두고, 취소 버튼을 누르면 이 객체의 cancel()을 호출한다.
class UploadCancelToken {
  bool _cancelled = false;
  void cancel() => _cancelled = true;
  bool get isCancelled => _cancelled;
}

class UploadCancelledException implements Exception {
  @override
  String toString() => '업로드가 취소되었습니다.';
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

  /// 내 계정 등급(준회원/정회원/관리자). 서버 운영자만 바꿀 수 있고, 화면은 이 값으로
  /// 버튼을 감춘다(실제 차단은 항상 서버가 다시 한다).
  final String role;

  /// 서버 전체 운영자인지 — 관리자 콘솔 진입 메뉴를 보여줄지 판단하는 데만 쓴다.
  final bool isServerAdmin;
  const MyProfile({
    required this.username,
    required this.name,
    this.email,
    this.avatarType = 'initial',
    this.avatarEmoji,
    this.avatarColor,
    this.avatarUrl,
    this.role = 'guest',
    this.isServerAdmin = false,
  });

  factory MyProfile.fromJson(Map<String, dynamic> json) => MyProfile(
    username: json['username'] as String,
    name: (json['name'] as String?) ?? json['username'] as String,
    email: json['email'] as String?,
    avatarType: json['avatarType'] as String? ?? 'initial',
    avatarEmoji: json['avatarEmoji'] as String?,
    avatarColor: json['avatarColor'] as String?,
    avatarUrl: json['avatarUrl'] as String?,
    role: json['role'] as String? ?? 'guest',
    isServerAdmin: json['isServerAdmin'] as bool? ?? false,
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

  /// 회원가입 폼의 "중복 확인" 버튼용. 사용 가능하면 null, 아니면(형식 오류/중복) 사유
  /// 문구를 돌려준다.
  Future<String?> checkUsernameAvailable(String username) async {
    final res = await _client.get(
      _uri(
        '/auth/username-available?username=${Uri.encodeQueryComponent(username)}',
      ),
    );
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      throw ApiException((body['error'] as String?) ?? '요청이 실패했습니다.');
    }
    return (body['available'] as bool) ? null : body['error'] as String?;
  }

  Future<AuthResult> register(
    String username,
    String password,
    String email,
    String name, {
    required String securityQuestion,
    required String securityAnswer,
  }) => _authRequest('/auth/register', {
    'username': username,
    'password': password,
    'email': email,
    'name': name,
    'securityQuestion': securityQuestion,
    'securityAnswer': securityAnswer,
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

  /// 아이디+이메일이 일치하는 계정의 보안 질문을 가져온다. 그 컬럼이 생기기 전에 가입한
  /// 계정은 question이 null로 온다 — 그 경우 답변 확인 없이 바로 재설정할 수 있다.
  Future<String?> fetchSecurityQuestion({
    required String username,
    required String email,
  }) async {
    final res = await _client.post(
      _uri('/auth/security-question'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'email': email}),
    );
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      throw ApiException((body['error'] as String?) ?? '요청이 실패했습니다.');
    }
    return body['question'] as String?;
  }

  /// 보안 질문 답변만 검증한다(비밀번호는 안 바꿈) — 답변이 맞을 때만 새 비밀번호 입력칸을
  /// 보여주기 위해 재설정 화면에서 쓴다. 계정에 보안 질문이 없으면 서버가 항상 통과시킨다.
  Future<void> verifySecurityAnswer({
    required String username,
    required String email,
    String? securityAnswer,
  }) async {
    final res = await _client.post(
      _uri('/auth/verify-security-answer'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'email': email,
        'securityAnswer': ?securityAnswer,
      }),
    );
    if (res.statusCode >= 400) {
      final body =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      throw ApiException((body['error'] as String?) ?? '요청이 실패했습니다.');
    }
  }

  Future<void> resetPassword({
    required String username,
    required String email,
    String? securityAnswer,
    required String newPassword,
  }) async {
    final res = await _client.post(
      _uri('/auth/reset-password'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'email': email,
        'securityAnswer': ?securityAnswer,
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

  /// [body]는 팀 삭제처럼 DELETE에도 확인값을 실어 보내야 할 때만 쓴다(없으면 안 보낸다).
  Future<dynamic> _delete(String path, {Map<String, dynamic>? body}) async {
    final res = await _send(
      () => _client.delete(
        _uri(path),
        headers: body == null
            ? _authHeaders
            : {..._authHeaders, 'Content-Type': 'application/json'},
        body: body == null ? null : jsonEncode(body),
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
  /// [email]을 바꿀 때는 서버가 [currentPassword]로 본인 확인을 한다(비밀번호 변경과
  /// 같은 정책 — 이메일은 계정 복구 수단이라 이름/아바타보다 한 단계 더 확인한다).
  Future<MyProfile> updateProfile({
    String? name,
    String? email,
    String? currentPassword,
  }) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (email != null) {
      body['email'] = email;
      body['currentPassword'] = currentPassword;
    }
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

  // ─────────────── 관리자 콘솔(서버 운영자 전용, 서버 admin.js) ───────────────
  // 전부 서버가 매 요청마다 isServerAdmin을 다시 확인하므로, 운영자가 아니면 403이 온다.

  Future<ServerStats> fetchServerStats() async => ServerStats.fromJson(
    await _get('/api/admin/stats') as Map<String, dynamic>,
  );

  /// 서버 설정 변경 — 팀 생성 권한('member'|'admin'|'serverAdmin')과 부서·직책 관리
  /// 범위('team'|'account').
  Future<void> updateServerSettings({
    String? teamCreation,
    String? orgScope,
  }) async {
    await _patch('/api/admin/settings', {
      'teamCreation': ?teamCreation,
      'orgScope': ?orgScope,
    });
  }

  /// 계정 등급 변경 — 서버 운영자만.
  Future<AdminUser> setUserRole(String userId, String role) async =>
      AdminUser.fromJson(
        await _post('/api/admin/users/$userId/role', {'role': role})
            as Map<String, dynamic>,
      );

  /// 부서·직책을 계정 단위로 관리하는 설정일 때 관리자 콘솔에서 쓴다.
  Future<AdminUser> updateUserOrg(
    String userId, {
    String? department,
    String? position,
  }) async => AdminUser.fromJson(
    await _patch('/api/admin/users/$userId/org', {
          'department': ?department,
          'position': ?position,
        })
        as Map<String, dynamic>,
  );

  Future<List<AdminUser>> fetchAdminUsers() async {
    final list = await _get('/api/admin/users') as List;
    return list
        .map((e) => AdminUser.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<AdminUser> setUserSuspended(String userId, bool suspended) async =>
      AdminUser.fromJson(
        await _post('/api/admin/users/$userId/suspend', {
              'suspended': suspended,
            })
            as Map<String, dynamic>,
      );

  Future<AdminUser> logoutUserEverywhere(String userId) async =>
      AdminUser.fromJson(
        await _post('/api/admin/users/$userId/logout-all', {})
            as Map<String, dynamic>,
      );

  /// 운영자가 정한 임시 비밀번호로 초기화한다(그 계정의 기존 로그인은 전부 끊긴다).
  Future<void> resetUserPassword(String userId, String password) async {
    await _post('/api/admin/users/$userId/reset-password', {
      'password': password,
    });
  }

  Future<AdminUser> setUserServerAdmin(
    String userId,
    bool isServerAdmin,
  ) async => AdminUser.fromJson(
    await _post('/api/admin/users/$userId/server-admin', {
          'isServerAdmin': isServerAdmin,
        })
        as Map<String, dynamic>,
  );

  Future<List<AdminTeam>> fetchAdminTeams() async {
    final list = await _get('/api/admin/teams') as List;
    return list
        .map((e) => AdminTeam.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 감사 로그 조회. 총 건수도 같이 와서 화면이 "몇 건 중 몇 건"을 보여줄 수 있다.
  Future<({int total, List<AuditLog> logs})> fetchAuditLogs({
    String? action,
    int limit = 50,
    int offset = 0,
  }) async {
    final query = <String>['limit=$limit', 'offset=$offset'];
    if (action != null && action.isNotEmpty) {
      query.add('action=${Uri.encodeQueryComponent(action)}');
    }
    final body =
        await _get('/api/admin/audit-logs?${query.join('&')}')
            as Map<String, dynamic>;
    return (
      total: (body['total'] as num?)?.toInt() ?? 0,
      logs: ((body['logs'] as List?) ?? [])
          .map((e) => AuditLog.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// 내가 속한 팀 목록(각 팀에서의 내 등급 포함) — 로그인/앱 시작 직후 팀 선택 화면이 쓴다.
  Future<List<Team>> fetchTeams() async {
    final list = await _get('/api/teams') as List;
    return list.map((e) => Team.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 팀 생성 — 만든 사람이 그 팀의 소유자가 된다(서버 teams.js 참고).
  Future<Team> createTeam({
    required String name,
    String? iconEmoji,
    String? iconColor,
  }) async {
    return Team.fromJson(
      await _post('/api/teams', {
            'name': name,
            'iconEmoji': ?iconEmoji,
            'iconColor': ?iconColor,
          })
          as Map<String, dynamic>,
    );
  }

  /// 팀 이름/도메인/아이콘/초대 권한/메시지 설정 변경 — 소유자·관리자만(서버가 다시 검사한다).
  Future<Team> updateTeam(
    String teamId, {
    String? name,
    String? iconEmoji,
    String? iconColor,
    String? domain,
    String? invitePolicy,
    bool? messageEditDeleteEnabled,
    int? messageEditDeleteWindowSeconds,
  }) async {
    return Team.fromJson(
      await _patch('/api/teams/$teamId', {
            'name': ?name,
            'iconEmoji': ?iconEmoji,
            'iconColor': ?iconColor,
            'domain': ?domain,
            'invitePolicy': ?invitePolicy,
            'messageEditDeleteEnabled': ?messageEditDeleteEnabled,
            'messageEditDeleteWindowSeconds': ?messageEditDeleteWindowSeconds,
          })
          as Map<String, dynamic>,
    );
  }

  /// 팀 삭제 — 소유자만. 실수 방지를 위해 팀 이름을 그대로 다시 보내야 한다.
  Future<void> deleteTeam(String teamId, String confirmName) async {
    await _delete('/api/teams/$teamId', body: {'name': confirmName});
  }

  /// 소유권 이양 — 소유자만. 넘겨받는 사람이 소유자가 되고 넘긴 사람은 관리자가 된다.
  Future<List<AppUser>> transferTeamOwnership(
    String teamId,
    String userId,
  ) async {
    final list =
        await _post('/api/teams/$teamId/transfer-owner', {'userId': userId})
            as List;
    return list
        .map((e) => AppUser.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 팀원의 부서/직책 변경 — 그 팀을 관리할 수 있는 사람만. 등급은 여기서 못 바꾼다
  /// (계정 등급은 서버 운영자가 관리자 콘솔에서만 정한다).
  Future<List<AppUser>> updateTeamMember(
    String teamId,
    String userId, {
    String? department,
    String? position,
  }) async {
    final list =
        await _patch('/api/teams/$teamId/members/$userId', {
              'department': ?department,
              'position': ?position,
            })
            as List;
    return list
        .map((e) => AppUser.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 팀 멤버 목록 — 조직도(멤버 패널)와 "새 대화" 상대 선택이 쓴다(서버 전체가 아니라 팀 단위).
  Future<List<AppUser>> fetchTeamMembers(String teamId) async {
    final list = await _get('/api/teams/$teamId/members') as List;
    return list
        .map((e) => AppUser.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 팀에 멤버 추가 — 소유자·관리자만. 가입만 한 사람은 어느 팀에도 없으므로 이걸로 넣어준다.
  Future<List<AppUser>> addTeamMembers(
    String teamId,
    List<String> userIds,
  ) async {
    final list =
        await _post('/api/teams/$teamId/members', {'userIds': userIds}) as List;
    return list
        .map((e) => AppUser.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<AppUser>> removeTeamMember(String teamId, String userId) async {
    final list = await _delete('/api/teams/$teamId/members/$userId') as List;
    return list
        .map((e) => AppUser.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Room>> fetchRooms(String teamId) async {
    final list =
        await _get('/api/rooms?teamId=${Uri.encodeQueryComponent(teamId)}')
            as List;
    return list.map((e) => Room.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<TopicBrowseEntry>> browseTopics(String teamId) async {
    final list =
        await _get(
              '/api/rooms/browse?teamId=${Uri.encodeQueryComponent(teamId)}',
            )
            as List;
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
    required String teamId,
    required String name,
    String? description,
    bool isPublic = true,
  }) async {
    return Room.fromJson(
      await _post('/api/rooms', {
            'teamId': teamId,
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
    required String teamId,
    String? name,
    required List<String> memberIds,
  }) async {
    return Room.fromJson(
      await _post('/api/rooms', {
            'teamId': teamId,
            'type': 'group',
            if (name != null && name.isNotEmpty) 'name': name,
            'memberIds': memberIds,
          })
          as Map<String, dynamic>,
    );
  }

  Future<Room> startDm(String teamId, String targetUserId) async {
    return Room.fromJson(
      await _post('/api/rooms/dm', {
            'teamId': teamId,
            'targetUserId': targetUserId,
          })
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

  /// FCM 토큰을 등록/갱신한다(안드로이드 전용). null을 보내면(로그아웃 등) 서버가 토큰을
  /// 지워서 더 이상 이 기기로 푸시를 안 보낸다.
  Future<void> registerFcmToken(String deviceId, String? token) async {
    await _patch('/api/devices/$deviceId/fcm-token', {'token': token});
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

  /// 앱이 꺼져있어서(FCM만 받음) secret:invite 소켓 이벤트를 놓쳤을 때, 수락/거절에 필요한
  /// 정보를 서버에서 다시 가져온다. 이미 수락/거절됐으면(404) 서버가 에러를 주는데, 그건
  /// Session.ensurePendingSecretInvite가 조용히 무시한다.
  Future<SecretInviteEvent> fetchSecretInvite(String roomId) async {
    return SecretInviteEvent.fromJson(
      await _get('/api/secret-chats/$roomId/invite') as Map<String, dynamic>,
    );
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
  ///
  /// [realLeave]는 평문 DM에서만 의미가 있다 — true면 서버가 이 시각을 기록 시작선으로
  /// 남겨서(dm_history_floors) 나중에 상대가 다시 말을 걸어 방이 복원돼도 그 이전 메시지/
  /// 파일/검색 결과가 이 사람에게는 안 보인다("진짜 나가기"). false(기본)면 지금처럼 그냥
  /// 나가기만 해서(=숨기기), 다시 대화하면 예전 내용이 그대로 복원된다.
  Future<void> leaveRoom(
    String roomId, {
    bool alsoRemoveOther = false,
    bool realLeave = false,
  }) async {
    await _post('/api/rooms/$roomId/leave', {
      'alsoRemoveOther': alsoRemoveOther,
      'realLeave': realLeave,
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

  Future<void> setMuted(String roomId, bool muted) async {
    await _post('/api/rooms/$roomId/muted', {'muted': muted});
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
    required String teamId,
    String? roomId,
    String? senderId,
    DateTime? since,
    DateTime? until,
  }) async {
    final params = StringBuffer(
      '/api/search?q=${Uri.encodeQueryComponent(query)}'
      '&teamId=${Uri.encodeQueryComponent(teamId)}',
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

  /// 방(들)에 첨부된 이미지/파일 목록(files_screen.dart). roomId를 안 주면 내가 속한 모든
  /// 방을 가로지른다. 서버가 toMessageDto와 동일한 모양으로 내려주므로 Message.fromJson을
  /// 그대로 재사용한다(새 모델을 따로 만들 필요 없음).
  Future<List<Message>> fetchAttachments({
    required String teamId,
    String? roomId,
    String? senderId,
    String? category,
  }) async {
    final params = StringBuffer('/api/attachments?');
    final parts = <String>['teamId=${Uri.encodeQueryComponent(teamId)}'];
    if (roomId != null) parts.add('roomId=${Uri.encodeQueryComponent(roomId)}');
    if (senderId != null) {
      parts.add('senderId=${Uri.encodeQueryComponent(senderId)}');
    }
    if (category != null) {
      parts.add('category=${Uri.encodeQueryComponent(category)}');
    }
    params.write(parts.join('&'));
    final list = await _get(params.toString()) as List;
    return list
        .map((e) => Message.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// [onProgress]/[cancelToken]을 안 넘기면 지금까지와 완전히 동일하게(단순 MultipartRequest)
  /// 동작한다. 둘 중 하나라도 넘기면, http 패키지에 내장 진행률 콜백이 없어서 요청 바디를 직접
  /// 스트리밍하며 바이트 수를 센다 — MultipartRequest가 만든 바디(finalize())를 그대로 다시
  /// StreamedRequest로 감싸 보낼 뿐이라 인증서 핀닝(_client 자체)은 그대로 유지된다. 취소는
  /// 그 파이프를 도중에 끊어(구독 취소 + sink를 끝까지 안 채우고 닫음) 요청을 미완성 상태로
  /// 만드는 방식이라 서버에 별도로 알릴 필요가 없다.
  Future<UploadResult> uploadFile(
    File file, {
    void Function(int sent, int total)? onProgress,
    UploadCancelToken? cancelToken,
  }) async {
    final res = await _send(() async {
      final req = http.MultipartRequest('POST', _uri('/api/upload'))
        ..headers.addAll(_authHeaders)
        ..files.add(await http.MultipartFile.fromPath('file', file.path));

      if (onProgress == null && cancelToken == null) {
        final streamed = await _client.send(req);
        return http.Response.fromStream(streamed);
      }

      final total = req.contentLength;
      var sentBytes = 0;
      final bodyStream = req.finalize();
      final streamedRequest = http.StreamedRequest(req.method, req.url)
        ..headers.addAll(req.headers)
        ..contentLength = total;
      late final StreamSubscription<List<int>> subscription;
      subscription = bodyStream.listen(
        (chunk) {
          if (cancelToken?.isCancelled == true) {
            subscription.cancel();
            streamedRequest.sink.close();
            return;
          }
          sentBytes += chunk.length;
          onProgress?.call(sentBytes, total);
          streamedRequest.sink.add(chunk);
        },
        onDone: () => streamedRequest.sink.close(),
        onError: (Object e, StackTrace st) =>
            streamedRequest.sink.addError(e, st),
        cancelOnError: true,
      );
      final streamed = await _client.send(streamedRequest);
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
