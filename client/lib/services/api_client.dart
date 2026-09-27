import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/admin.dart';
import '../models/announcement.dart';
import '../models/app_user.dart';
import '../models/comment.dart';
import '../models/inquiry.dart';
import '../models/invite_link.dart';
import '../models/team_invite_link.dart';
import '../models/message.dart';
import '../models/project.dart';
import '../models/room.dart';
import '../models/team.dart';
import '../models/text_format.dart';
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

  /// 올린 사람이 저장 전에 바로 미리보기를 그릴 수 있는 서명된 /files/ 링크(팀·그룹 아이콘
  /// 사진). [url](미서명 /uploads/ 경로)은 그 자체로는 내려받을 수 없다.
  final String? signedUrl;
  final String fileName;
  final int size;
  final String? mimeType;
  const UploadResult({
    required this.url,
    this.signedUrl,
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

/// GET /api/users/me의 `teamPositions` 항목 — 부서·직책 관리 범위가 '팀 단위'일 때, 내가
/// 속한 팀마다 다를 수 있는 부서/직책 한 행(프로필 카드의 "팀" 항목이 팀별로 짝지어 보여준다).
class TeamPosition {
  final String teamId;
  final String teamName;
  final String? department;
  final String? position;
  const TeamPosition({
    required this.teamId,
    required this.teamName,
    this.department,
    this.position,
  });

  factory TeamPosition.fromJson(Map<String, dynamic> json) => TeamPosition(
    teamId: json['teamId'] as String,
    teamName: json['teamName'] as String,
    department: json['department'] as String?,
    position: json['position'] as String?,
  );
}

/// 서버 운영자가 관리하는 "직책 목록"(GET /admin/position-options) 한 항목 — 부서·직책 관리
/// 범위가 '계정 단위'일 때, 회원 탭의 직책 수정을 자유 입력 대신 이 중에서 고르게 한다.
class PositionOption {
  final String id;
  final String label;

  /// 최대 1개만 true — 회원가입 시 이 직책이 자동으로 부여된다(server/src/auth.js).
  final bool isDefault;

  const PositionOption({
    required this.id,
    required this.label,
    this.isDefault = false,
  });

  factory PositionOption.fromJson(Map<String, dynamic> json) => PositionOption(
    id: json['id'] as String,
    label: json['label'] as String,
    isDefault: json['isDefault'] as bool? ?? false,
  );
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

  /// "팀 초대 링크 생성" 메뉴를 보여줄지 — 서버 설정(팀 초대 링크 생성 권한)에 달려 있어서
  /// 클라이언트가 로컬 상태만으로 판단할 수 없어 서버가 최종 판정해서 내려준다.
  final bool canCreateTeamInviteLink;

  /// "프로젝트" 창의 "+새 프로젝트" 버튼을 보여줄지 — 서버 설정(프로젝트 생성 권한)에 달려
  /// 있어서 마찬가지로 서버가 최종 판정해서 내려준다.
  final bool canCreateProject;

  /// 부서·직책을 팀 단위로 관리하는지('team') 계정 단위로 관리하는지('account') — 내 프로필
  /// 카드의 "직책" 표시 형태를 결정한다. 'account'면 [position] 하나만, 'team'이면
  /// [teamPositions]를 본다.
  final String orgScope;
  final String? department;
  final String? position;
  final List<TeamPosition> teamPositions;

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
    this.canCreateTeamInviteLink = false,
    this.canCreateProject = false,
    this.orgScope = 'team',
    this.department,
    this.position,
    this.teamPositions = const [],
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
    canCreateTeamInviteLink: json['canCreateTeamInviteLink'] as bool? ?? false,
    canCreateProject: json['canCreateProject'] as bool? ?? false,
    orgScope: json['orgScope'] as String? ?? 'team',
    department: json['department'] as String?,
    position: json['position'] as String?,
    teamPositions:
        (json['teamPositions'] as List?)
            ?.map((e) => TeamPosition.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [],
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
  /// 일반 API 호출(_get/_post/_patch/_delete가 전부 이걸 거친다)의 공통 타임아웃 — 서버가
  /// 잠깐 죽어 있거나(재시작 중 등) 네트워크가 끊긴 상태에서 요청을 보내면, 타임아웃이 없는
  /// http 요청은 응답이 올 때까지 영원히 기다린다. 그러면 화면은 "불러오는 중" 스피너가
  /// 끝없이 도는 것으로 보이고(실패로도, 성공으로도 안 끝남) 사용자는 재시도할 방법이
  /// 없다 — 실제로 이런 신고가 있었다. 20초 후에는 명확한 에러로 실패시켜서, 각 화면의
  /// catch가 에러 문구를 보여주고 다시 시도할 수 있게 한다.
  static const _requestTimeout = Duration(seconds: 20);

  Future<http.Response> _withTimeout(Future<http.Response> future) =>
      future.timeout(
        _requestTimeout,
        onTimeout: () =>
            throw const ApiException('요청이 시간 초과되었습니다. 네트워크 연결을 확인하고 다시 시도하세요.'),
      );

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    var res = await _withTimeout(request());
    if (res.statusCode == 401 && onUnauthorized != null) {
      final refreshed = await onUnauthorized!();
      if (refreshed) res = await _withTimeout(request());
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

  /// 클라이언트가 Firebase.initializeApp()에 쓸 4개 값(GET /firebase-client-config) —
  /// fetchLatestVersion과 같은 성격의 인증 불필요 엔드포인트. 관리자가 아직 FCM을 설정
  /// 안 했으면 필드가 전부 null로 온다(session.dart가 이 경우 FCM을 조용히 비활성화한다).
  Future<Map<String, String?>?> fetchFirebaseClientConfig() async {
    try {
      final res = await _client
          .get(_uri('/firebase-client-config'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;
      final body =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      return {
        'apiKey': body['apiKey'] as String?,
        'appId': body['appId'] as String?,
        'projectId': body['projectId'] as String?,
        'messagingSenderId': body['messagingSenderId'] as String?,
      };
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

  /// 방의 대화 내용을 엑셀(.xlsx)로 받는다(GET /rooms/:id/export). [since]/[until]을 안 주면
  /// 전체 기간. 인증이 필요한 엔드포인트라 downloadUpdate와 달리 Authorization 헤더를
  /// 붙인다 — 다만 이 스트림 요청은 401이어도 토큰을 갱신해 재시도하지 않는다(다른 화면을
  /// 오래 보다가 실행하는 흔치 않은 경로라, 실패하면 사용자가 다시 누르는 것으로 충분하다).
  Future<http.StreamedResponse> exportRoomChat(
    String roomId, {
    DateTime? since,
    DateTime? until,
  }) {
    final params = <String, String>{
      if (since != null) 'since': since.millisecondsSinceEpoch.toString(),
      if (until != null) 'until': until.millisecondsSinceEpoch.toString(),
    };
    final uri = _uri(
      '/api/rooms/$roomId/export',
    ).replace(queryParameters: params.isEmpty ? null : params);
    final req = http.Request('GET', uri)..headers.addAll(_authHeaders);
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
    String? teamInviteToken,
  }) => _authRequest('/auth/register', {
    'username': username,
    'password': password,
    'email': email,
    'name': name,
    'securityQuestion': securityQuestion,
    'securityAnswer': securityAnswer,
    'teamInviteToken': ?teamInviteToken,
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

  /// 현재 비밀번호가 맞는지만 확인한다(다른 부수효과 없음) — "이메일 변경" 1단계(비밀번호
  /// 확인) 다이얼로그가 쓴다. 틀리면 서버가 401로 응답하고 _send()가 ApiException을 던진다.
  Future<void> verifyPassword(String password) async {
    await _post('/api/users/me/verify-password', {'password': password});
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

  /// 서버 설정 변경 — 팀 생성 권한, 팀 초대 링크 생성 권한(둘 다 'member'|'admin'|'serverAdmin')과
  /// 부서·직책 관리 범위('team'|'account').
  Future<void> updateServerSettings({
    String? teamCreation,
    String? projectCreation,
    String? teamInviteLinkCreation,
    String? orgScope,
  }) async {
    await _patch('/api/admin/settings', {
      'teamCreation': ?teamCreation,
      'projectCreation': ?projectCreation,
      'teamInviteLinkCreation': ?teamInviteLinkCreation,
      'orgScope': ?orgScope,
    });
  }

  /// 이 서버에서 화상회의를 쓸 수 있는지 + LiveKit 접속 주소(server/src/calls.js).
  /// LiveKit을 안 깐 서버면 enabled=false로 오고, 클라이언트는 통화 버튼 자체를 감춘다.
  Future<({bool enabled, String? url})> fetchCallsConfig() async {
    final body = await _get('/api/calls/config') as Map<String, dynamic>;
    return (
      enabled: body['enabled'] as bool? ?? false,
      url: body['url'] as String?,
    );
  }

  /// 이 방의 화상회의 참가 토큰. 방 멤버가 아니거나(403) 비밀 대화면(400) 서버가 거부한다.
  Future<({String url, String roomName, String token})> fetchCallToken(
    String roomId,
  ) async {
    final body =
        await _post('/api/rooms/$roomId/call/token', const {})
            as Map<String, dynamic>;
    return (
      url: body['url'] as String,
      roomName: body['roomName'] as String,
      token: body['token'] as String,
    );
  }

  /// 관리자 콘솔의 "FCM 설정" — 지금 저장된 값(서비스 계정의 private_key는 빼고).
  Future<FcmSettings> fetchFcmSettings() async => FcmSettings.fromJson(
    await _get('/api/admin/fcm-settings') as Map<String, dynamic>,
  );

  /// FCM 설정 변경 — 넘긴 항목만 바뀐다. serviceAccountJson에 빈 문자열을 넘기면 설정을
  /// 해제한다(서버가 그렇게 해석 — admin.js 참고).
  Future<void> updateFcmSettings({
    String? apiKey,
    String? appId,
    String? projectId,
    String? messagingSenderId,
    String? serviceAccountJson,
  }) async {
    await _patch('/api/admin/fcm-settings', {
      'apiKey': ?apiKey,
      'appId': ?appId,
      'projectId': ?projectId,
      'messagingSenderId': ?messagingSenderId,
      'serviceAccountJson': ?serviceAccountJson,
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

  /// 직책 목록(GET /admin/position-options) — 부서·직책 관리 범위가 '계정 단위'일 때, 회원
  /// 탭의 직책 수정이 자유 입력 대신 이 중에서 고르게 한다.
  Future<List<PositionOption>> fetchPositionOptions() async {
    final list = await _get('/api/admin/position-options') as List;
    return list
        .map((e) => PositionOption.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 직책 목록(GET /position-options, 서열순) — 위 [fetchPositionOptions]와 달리 서버
  /// 운영자가 아니어도 누구나 부를 수 있다. "팀 초대 링크 만들기"의 "부여할 직책"이 쓴다.
  Future<List<PositionOption>> fetchPublicPositionOptions() async {
    final list = await _get('/api/position-options') as List;
    return list
        .map((e) => PositionOption.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<PositionOption> createPositionOption(String label) async =>
      PositionOption.fromJson(
        await _post('/api/admin/position-options', {'label': label})
            as Map<String, dynamic>,
      );

  Future<void> deletePositionOption(String id) async {
    await _delete('/api/admin/position-options/$id');
  }

  /// 직책 서열 변경 — [ids]는 전체 직책 id를 원하는 순서대로. 항상 최신 전체 목록을
  /// 돌려주므로 그대로 다시 그리면 된다.
  Future<List<PositionOption>> reorderPositionOptions(List<String> ids) async {
    final list =
        await _post('/api/admin/position-options/order', {'ids': ids}) as List;
    return list
        .map((e) => PositionOption.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 직책 "기본값" 지정/해제(토글) — 이미 기본값이면 해제, 아니면 기존 기본값을 내리고
  /// 이 항목을 새 기본값으로 올린다.
  Future<List<PositionOption>> toggleDefaultPositionOption(String id) async {
    final list =
        await _post('/api/admin/position-options/$id/default', {}) as List;
    return list
        .map((e) => PositionOption.fromJson(e as Map<String, dynamic>))
        .toList();
  }

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

  // ─────────────── 초대 링크(설치→가입, 서버 운영자·팀 소유자·관리자) ───────────────
  // 서버가 매 요청마다 canCreateInviteLink를 다시 확인하므로, 권한이 없으면 403이 온다.

  /// 내가 만든 초대 링크 목록(최신순).
  Future<List<InviteLink>> fetchInviteLinks() async {
    final list = await _get('/api/invite-links') as List;
    return list
        .map((e) => InviteLink.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 새 초대 링크 발급 — 유효기간은 서버에서 항상 7일로 고정된다.
  Future<InviteLink> createInviteLink({String? label}) async =>
      InviteLink.fromJson(
        await _post('/api/invite-links', {'label': ?label})
            as Map<String, dynamic>,
      );

  /// 폐기 — 내가 만든 링크만 지울 수 있다(서버가 다시 확인).
  Future<InviteLink> revokeInviteLink(String id) async => InviteLink.fromJson(
    await _delete('/api/invite-links/$id') as Map<String, dynamic>,
  );

  // ─────────────── 팀 초대 링크(가입 시 팀 자동 합류 + 등급 자동 부여) ───────────────
  // 서버가 매 요청마다 canCreateTeamInviteLink(서버 설정)를 다시 확인하므로, 권한이 없으면
  // 403이 온다. 위 초대 링크와 달리 팀 합류/등급 부여까지 자동으로 한다는 게 핵심 차이.

  /// 내가 만든 팀 초대 링크 목록(최신순).
  Future<List<TeamInviteLink>> fetchTeamInviteLinks() async {
    final list = await _get('/api/team-invite-links') as List;
    return list
        .map((e) => TeamInviteLink.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 새 팀 초대 링크 발급 — 유효기간은 서버에서 항상 7일로 고정된다. teamId는 내가 속한
  /// 팀이어야 한다(서버가 다시 확인).
  Future<TeamInviteLink> createTeamInviteLink({
    required String teamId,
    required AccountRole assignedRole,
    String? assignedPosition,
    String? label,
  }) async => TeamInviteLink.fromJson(
    await _post('/api/team-invite-links', {
          'teamId': teamId,
          'assignedRole': assignedRole.wire,
          'assignedPosition': ?assignedPosition,
          'label': ?label,
        })
        as Map<String, dynamic>,
  );

  /// 폐기 — 내가 만든 링크만 지울 수 있다(서버가 다시 확인).
  Future<TeamInviteLink> revokeTeamInviteLink(String id) async =>
      TeamInviteLink.fromJson(
        await _delete('/api/team-invite-links/$id') as Map<String, dynamic>,
      );

  /// 내가 속한 팀 목록(각 팀에서의 내 등급 포함) — 로그인/앱 시작 직후 팀 선택 화면이 쓴다.
  Future<List<Team>> fetchTeams() async {
    final list = await _get('/api/teams') as List;
    return list.map((e) => Team.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 조직도 — 서버 전체 팀과 각 팀의 멤버 id 목록. 관리자 이상만 호출할 수 있다(서버가
  /// 403으로 막는다).
  Future<List<OrgChartTeam>> fetchOrgChartTeams() async {
    final list = await _get('/api/org-chart/teams') as List;
    return list
        .map((e) => OrgChartTeam.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 다른 사람의 프로필 카드 "팀" 항목용 — 그 사람이 속한 팀 목록. 서버가 노출 범위를
  /// 정한다(대상이 계정 등급 관리자면 나와 겹치는 팀만, 정회원·준회원이면 전체).
  Future<List<Team>> fetchUserTeams(String userId) async {
    final list = await _get('/api/users/$userId/teams') as List;
    return list.map((e) => Team.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 팀 생성 — 만든 사람이 그 팀의 소유자가 된다(서버 teams.js 참고).
  /// 팀 생성 — 팀 설정과 같은 항목(아이콘·토픽 생성 권한·메시지 설정)을 함께 정할 수 있다
  /// ('designated' 토픽 생성 권한은 멤버가 생긴 뒤 팀 설정에서만).
  Future<Team> createTeam({
    required String name,
    String? iconEmoji,
    String? iconColor,
    String? iconUrl,
    String? topicCreationPolicy,
    bool? messageEditDeleteEnabled,
    int? messageEditDeleteWindowSeconds,
  }) async {
    return Team.fromJson(
      await _post('/api/teams', {
            'name': name,
            'iconEmoji': ?iconEmoji,
            'iconColor': ?iconColor,
            'iconUrl': ?iconUrl,
            'topicCreationPolicy': ?topicCreationPolicy,
            'messageEditDeleteEnabled': ?messageEditDeleteEnabled,
            'messageEditDeleteWindowSeconds': ?messageEditDeleteWindowSeconds,
          })
          as Map<String, dynamic>,
    );
  }

  /// 팀 이름/아이콘/토픽 생성 권한/메시지 설정 변경 — 소유자·관리자만(서버가 다시 검사한다).
  Future<Team> updateTeam(
    String teamId, {
    String? name,
    String? iconEmoji,
    String? iconColor,
    String? iconUrl,
    String? topicCreationPolicy,
    List<String>? topicCreatorIds,
    bool? messageEditDeleteEnabled,
    int? messageEditDeleteWindowSeconds,
  }) async {
    return Team.fromJson(
      await _patch('/api/teams/$teamId', {
            'name': ?name,
            'iconEmoji': ?iconEmoji,
            'iconColor': ?iconColor,
            'iconUrl': ?iconUrl,
            'topicCreationPolicy': ?topicCreationPolicy,
            'topicCreatorIds': ?topicCreatorIds,
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

  /// 토픽방 공지 히스토리(최신순) — server/src/announcements.js 참고.
  Future<List<Announcement>> fetchAnnouncements(String roomId) async {
    final list = await _get('/api/rooms/$roomId/announcements') as List;
    return list
        .map((e) => Announcement.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 공지 작성 — 새로 쓴 것이 자동으로 그 방의 "지금 고정된 공지"가 된다. 토픽을 만들 수
  /// 있는 사람만 가능(서버가 다시 확인 — canCreateTopic과 같은 권한). [autoUnpinAt]을 주면
  /// 그 시각에 서버가 자동으로 "공지 내리기"를 한다(공지 작성 다이얼로그의 빠른 선택 버튼).
  Future<Announcement> createAnnouncement(
    String roomId,
    String text, {
    DateTime? autoUnpinAt,
  }) async {
    return Announcement.fromJson(
      await _post('/api/rooms/$roomId/announcements', {
            'text': text,
            if (autoUnpinAt != null)
              'autoUnpinAt': autoUnpinAt.millisecondsSinceEpoch,
          })
          as Map<String, dynamic>,
    );
  }

  /// 공지 수정 — 본인 작성 글만 가능(서버가 다시 확인).
  Future<Announcement> updateAnnouncement(
    String roomId,
    String announcementId,
    String text,
  ) async {
    return Announcement.fromJson(
      await _patch('/api/rooms/$roomId/announcements/$announcementId', {
            'text': text,
          })
          as Map<String, dynamic>,
    );
  }

  /// 공지 삭제 — 본인 작성 글만 가능. 히스토리에서도 완전히 사라진다.
  Future<void> deleteAnnouncement(String roomId, String announcementId) async {
    await _delete('/api/rooms/$roomId/announcements/$announcementId');
  }

  /// "공지 내리기" — 삭제하지 않고 채팅방 상단 배너에서만 내린다.
  Future<void> unpinAnnouncement(String roomId, String announcementId) async {
    await _post(
      '/api/rooms/$roomId/announcements/$announcementId/unpin',
      const {},
    );
  }

  /// 공지에 달린 댓글 목록(오래된 순).
  Future<List<AnnouncementComment>> fetchAnnouncementComments(
    String roomId,
    String announcementId,
  ) async {
    final list =
        await _get('/api/rooms/$roomId/announcements/$announcementId/comments')
            as List;
    return list
        .map((e) => AnnouncementComment.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 공지에 댓글 작성 — 그 방의 멤버라면 누구나 가능.
  Future<AnnouncementComment> postAnnouncementComment(
    String roomId,
    String announcementId,
    String text,
  ) async {
    return AnnouncementComment.fromJson(
      await _post('/api/rooms/$roomId/announcements/$announcementId/comments', {
            'text': text,
          })
          as Map<String, dynamic>,
    );
  }

  /// "팀장에게 문의하기" — 그 방(1:1)의 상대가 팀장일 때만 서버가 허용한다
  /// (session.canSendInquiryIn과 같은 조건을 서버가 다시 확인).
  Future<Inquiry> createInquiry(
    String roomId, {
    required String category,
    required String title,
    required String content,
    String? fileUrl,
    String? fileName,
    int? fileSize,
    String? mimeType,
    String? thumbnailUrl,
  }) async {
    return Inquiry.fromJson(
      await _post('/api/rooms/$roomId/inquiries', {
            'category': category,
            'title': title,
            'content': content,
            'fileUrl': ?fileUrl,
            'fileName': ?fileName,
            'fileSize': ?fileSize,
            'mimeType': ?mimeType,
            'thumbnailUrl': ?thumbnailUrl,
          })
          as Map<String, dynamic>,
    );
  }

  /// 내가 받은 문의(팀장 시점) — [status]를 주면 그 상태만 걸러서 받는다.
  Future<List<Inquiry>> fetchReceivedInquiries({InquiryStatus? status}) async {
    final path = status == null
        ? '/api/inquiries/received'
        : '/api/inquiries/received?status=${inquiryStatusToWire(status)}';
    final list = await _get(path) as List;
    return list
        .map((e) => Inquiry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 내가 보낸 문의 — 처리 현황을 직접 확인하는 용도.
  Future<List<Inquiry>> fetchSentInquiries() async {
    final list = await _get('/api/inquiries/sent') as List;
    return list
        .map((e) => Inquiry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 문의 상태 변경 — 받는 사람(팀장) 본인만 가능(서버가 다시 확인).
  Future<Inquiry> updateInquiryStatus(String id, InquiryStatus status) async {
    return Inquiry.fromJson(
      await _patch('/api/inquiries/$id', {
            'status': inquiryStatusToWire(status),
          })
          as Map<String, dynamic>,
    );
  }

  // ───────────────────────────── 프로젝트 ─────────────────────────────

  /// 프로젝트 홈(대시보드)에 필요한 값 한 번에 — 통계/내 프로젝트/내 업무/최근 댓글.
  Future<ProjectHome> fetchProjectHome(String teamId) async {
    return ProjectHome.fromJson(
      await _get('/api/projects/home?teamId=$teamId') as Map<String, dynamic>,
    );
  }

  /// 내가 참여 중인 프로젝트 목록(사이드바).
  /// [archived]가 true면 종료(보관)된 프로젝트만, 아니면 진행 중인 프로젝트만.
  Future<List<Project>> fetchProjects(
    String teamId, {
    bool archived = false,
  }) async {
    final list =
        await _get(
              '/api/projects?teamId=$teamId${archived ? '&archived=1' : ''}',
            )
            as List;
    return list
        .map((e) => Project.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 프로젝트 상세(구성원 포함).
  Future<Project> fetchProject(String projectId) async {
    return Project.fromJson(
      await _get('/api/projects/$projectId') as Map<String, dynamic>,
    );
  }

  Future<Project> createProject({
    required String teamId,
    required String name,
    required String identifier,
    String? description,
    String? color,
    bool isPublic = false,
    List<String> memberIds = const [],
  }) async {
    return Project.fromJson(
      await _post('/api/projects', {
            'teamId': teamId,
            'name': name,
            'identifier': identifier,
            'description': ?description,
            'color': ?color,
            'isPublic': isPublic,
            'memberIds': memberIds,
          })
          as Map<String, dynamic>,
    );
  }

  /// 내가 아직 참여하지 않은 이 팀의 공개 프로젝트들.
  Future<List<Project>> browsePublicProjects(String teamId) async {
    final list = await _get('/api/projects/browse?teamId=$teamId') as List;
    return list
        .map((e) => Project.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 공개 프로젝트에 초대 없이 참여한다.
  Future<Project> joinProject(String projectId) async {
    return Project.fromJson(
      await _post('/api/projects/$projectId/join', {}) as Map<String, dynamic>,
    );
  }

  Future<Project> updateProject(
    String projectId, {
    String? name,
    String? description,
    String? color,
    bool? isPublic,
    bool? archived,
  }) async {
    return Project.fromJson(
      await _patch('/api/projects/$projectId', {
            'name': ?name,
            'description': ?description,
            'color': ?color,
            'isPublic': ?isPublic,
            'archived': ?archived,
          })
          as Map<String, dynamic>,
    );
  }

  Future<void> deleteProject(String projectId) async {
    await _delete('/api/projects/$projectId');
  }

  /// 사이드바 즐겨찾기(개인 설정).
  Future<void> setProjectFavorite(String projectId, bool favorite) async {
    await _patch('/api/projects/$projectId/favorite', {'favorite': favorite});
  }

  Future<List<AppUser>> addProjectMembers(
    String projectId,
    List<String> userIds,
  ) async {
    final list =
        await _post('/api/projects/$projectId/members', {'userIds': userIds})
            as List;
    return list
        .map((e) => AppUser.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 구성원의 프로젝트 역할을 바꾼다('owner' = 담당자 | 'member').
  Future<void> setProjectMemberRole(
    String projectId,
    String userId,
    String role,
  ) async {
    await _patch('/api/projects/$projectId/members/$userId', {'role': role});
  }

  Future<List<AppUser>> removeProjectMember(
    String projectId,
    String userId,
  ) async {
    final list =
        await _delete('/api/projects/$projectId/members/$userId') as List;
    return list
        .map((e) => AppUser.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 프로젝트 안의 업무 목록.
  Future<List<Task>> fetchProjectTasks(String projectId) async {
    final list = await _get('/api/projects/$projectId/tasks') as List;
    return list.map((e) => Task.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 내가 담당한 업무 전부(팀 기준) — "내 업무" 화면.
  /// 내가 참여 중인 모든 프로젝트의 업무(전체 캘린더/간트차트용).
  Future<List<Task>> fetchTeamTasks(String teamId) async {
    final list = await _get('/api/tasks/team?teamId=$teamId') as List;
    return list.map((e) => Task.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<Task>> fetchMyTasks(String teamId) async {
    final list = await _get('/api/tasks/mine?teamId=$teamId') as List;
    return list.map((e) => Task.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 업무 상세(댓글 포함).
  Future<Task> fetchTask(String taskId) async {
    return Task.fromJson(
      await _get('/api/tasks/$taskId') as Map<String, dynamic>,
    );
  }

  Future<List<TaskType>> fetchTaskTypes(String projectId) async {
    final list = await _get('/api/projects/$projectId/task-types') as List;
    return list
        .map((e) => TaskType.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<TaskType> createTaskType(
    String projectId, {
    required String name,
    required String color,
  }) async {
    return TaskType.fromJson(
      await _post('/api/projects/$projectId/task-types', {
            'name': name,
            'color': color,
          })
          as Map<String, dynamic>,
    );
  }

  Future<TaskType> updateTaskType(
    String typeId, {
    String? name,
    String? color,
  }) async {
    return TaskType.fromJson(
      await _patch('/api/task-types/$typeId', {'name': ?name, 'color': ?color})
          as Map<String, dynamic>,
    );
  }

  Future<void> deleteTaskType(String typeId) async {
    await _delete('/api/task-types/$typeId');
  }

  /// 유형 순서 저장 — [ids]는 그 프로젝트의 전체 유형 id를 원하는 순서대로.
  Future<void> reorderTaskTypes(String projectId, List<String> ids) async {
    await _post('/api/projects/$projectId/task-types/order', {'ids': ids});
  }

  /// 노트 목록(본문 제외) — [projectId] 하나 또는 [teamId](내가 참여한 모든 프로젝트).
  Future<List<ProjectNote>> fetchNotes({
    String? projectId,
    String? teamId,
  }) async {
    final query = projectId != null ? 'projectId=$projectId' : 'teamId=$teamId';
    final list = await _get('/api/notes?$query') as List;
    return list
        .map((e) => ProjectNote.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ProjectNote> fetchNote(String noteId) async {
    return ProjectNote.fromJson(
      await _get('/api/notes/$noteId') as Map<String, dynamic>,
    );
  }

  Future<ProjectNote> createNote(
    String projectId, {
    required String title,
    required String body,
  }) async {
    return ProjectNote.fromJson(
      await _post('/api/projects/$projectId/notes', {
            'title': title,
            'body': body,
          })
          as Map<String, dynamic>,
    );
  }

  /// [baseUpdatedAt]은 편집을 시작할 때의 수정 시각 — 그 사이 다른 사람이 고쳤으면 서버가 409로 막는다.
  Future<ProjectNote> updateNote(
    String noteId, {
    String? title,
    String? body,
    DateTime? baseUpdatedAt,
  }) async {
    return ProjectNote.fromJson(
      await _patch('/api/notes/$noteId', {
            'title': ?title,
            'body': ?body,
            'baseUpdatedAt': ?baseUpdatedAt?.millisecondsSinceEpoch,
          })
          as Map<String, dynamic>,
    );
  }

  Future<void> deleteNote(String noteId) async {
    await _delete('/api/notes/$noteId');
  }

  /// 내 프로젝트 알림함(최근 50개)과 안 읽은 개수.
  Future<(List<ProjectNotification>, int)> fetchProjectNotifications() async {
    final json =
        await _get('/api/project-notifications') as Map<String, dynamic>;
    final items = (json['items'] as List)
        .map((e) => ProjectNotification.fromJson(e as Map<String, dynamic>))
        .toList();
    return (items, (json['unreadCount'] as num?)?.toInt() ?? 0);
  }

  /// [ids]가 없으면 전부 읽음. 남은 안 읽은 개수를 돌려준다.
  Future<int> markProjectNotificationsRead({List<String>? ids}) async {
    final json =
        await _post('/api/project-notifications/read', {'ids': ?ids})
            as Map<String, dynamic>;
    return (json['unreadCount'] as num?)?.toInt() ?? 0;
  }

  Future<ProjectNotificationSettings> fetchProjectNotificationSettings(
    String projectId,
  ) async {
    return ProjectNotificationSettings.fromJson(
      await _get('/api/projects/$projectId/notification-settings')
          as Map<String, dynamic>,
    );
  }

  /// 내 개인 설정 — 이 프로젝트 알림을 나만 전부 끄거나 켠다.
  Future<ProjectNotificationSettings> setProjectNotificationMuted(
    String projectId,
    bool muted,
  ) async {
    return ProjectNotificationSettings.fromJson(
      await _patch('/api/projects/$projectId/notification-settings', {
            'muted': muted,
          })
          as Map<String, dynamic>,
    );
  }

  Future<ProjectNotificationPolicy> fetchProjectNotificationPolicy(
    String projectId,
  ) async {
    return ProjectNotificationPolicy.fromJson(
      await _get('/api/projects/$projectId/notification-policy')
          as Map<String, dynamic>,
    );
  }

  /// 프로젝트 알림 정책을 바꾼다(담당자·팀 소유자/관리자만) — [key]는 서버와 같은 이름.
  Future<ProjectNotificationPolicy> setProjectNotificationPolicy(
    String projectId,
    String key,
    bool value,
  ) async {
    return ProjectNotificationPolicy.fromJson(
      await _patch('/api/projects/$projectId/notification-policy', {key: value})
          as Map<String, dynamic>,
    );
  }

  Future<List<TaskTemplate>> fetchTaskTemplates(String projectId) async {
    final list = await _get('/api/projects/$projectId/task-templates') as List;
    return list
        .map((e) => TaskTemplate.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 템플릿 저장 — [templateId]가 있으면 수정, 없으면 새로 만든다. 담당자/유형/마감일수는
  /// 비우는 것도 뜻이 있어서 항상 값(또는 null)을 그대로 보낸다.
  Future<TaskTemplate> saveTaskTemplate(
    String projectId, {
    String? templateId,
    required String name,
    required String title,
    required String description,
    required TaskPriority priority,
    String? typeId,
    String? assigneeId,
    int? dueOffsetDays,
  }) async {
    final body = {
      'name': name,
      'title': title,
      'description': description,
      'priority': taskPriorityToWire(priority),
      'typeId': typeId,
      'assigneeId': assigneeId,
      'dueOffsetDays': dueOffsetDays,
    };
    final json = templateId == null
        ? await _post('/api/projects/$projectId/task-templates', body)
        : await _patch('/api/task-templates/$templateId', body);
    return TaskTemplate.fromJson(json as Map<String, dynamic>);
  }

  Future<void> deleteTaskTemplate(String templateId) async {
    await _delete('/api/task-templates/$templateId');
  }

  Future<List<AutomationRule>> fetchAutomations(String projectId) async {
    final list = await _get('/api/projects/$projectId/automations') as List;
    return list
        .map((e) => AutomationRule.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 규칙 저장 — [ruleId]가 있으면 수정, 없으면 새로 만든다.
  Future<AutomationRule> saveAutomation(
    String projectId, {
    String? ruleId,
    required String name,
    required String trigger,
    String? triggerStatusId,
    String? conditionPriority,
    String? conditionTypeId,
    required List<AutomationAction> actions,
  }) async {
    final body = {
      'name': name,
      'trigger': trigger,
      'triggerStatusId': triggerStatusId,
      'condition': {'priority': ?conditionPriority, 'typeId': ?conditionTypeId},
      'actions': [for (final a in actions) a.toJson()],
    };
    final json = ruleId == null
        ? await _post('/api/projects/$projectId/automations', body)
        : await _patch('/api/automations/$ruleId', body);
    return AutomationRule.fromJson(json as Map<String, dynamic>);
  }

  Future<void> setAutomationEnabled(String ruleId, bool enabled) async {
    await _patch('/api/automations/$ruleId', {'enabled': enabled});
  }

  Future<void> deleteAutomation(String ruleId) async {
    await _delete('/api/automations/$ruleId');
  }

  Future<List<NoteComment>> fetchNoteComments(String noteId) async {
    final list = await _get('/api/notes/$noteId/comments') as List;
    return list
        .map((e) => NoteComment.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// [parentCommentId]를 주면 그 댓글의 답글로 단다.
  Future<NoteComment> addNoteComment(
    String noteId,
    String text, {
    List<TextFormatRun>? textFormat,
    String? parentCommentId,
  }) async {
    return NoteComment.fromJson(
      await _post('/api/notes/$noteId/comments', {
            'text': text,
            'textFormat': ?textFormatToJson(textFormat),
            'parentCommentId': ?parentCommentId,
          })
          as Map<String, dynamic>,
    );
  }

  Future<NoteComment> updateNoteComment(
    String commentId,
    String text, {
    List<TextFormatRun>? textFormat,
  }) async {
    return NoteComment.fromJson(
      await _patch('/api/note-comments/$commentId', {
            'text': text,
            'textFormat': ?textFormatToJson(textFormat),
          })
          as Map<String, dynamic>,
    );
  }

  Future<void> deleteNoteComment(String commentId) async {
    await _delete('/api/note-comments/$commentId');
  }

  Future<List<NoteVersion>> fetchNoteVersions(String noteId) async {
    final list = await _get('/api/notes/$noteId/versions') as List;
    return list
        .map((e) => NoteVersion.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<NoteVersion> fetchNoteVersion(String versionId) async {
    return NoteVersion.fromJson(
      await _get('/api/note-versions/$versionId') as Map<String, dynamic>,
    );
  }

  /// 노트를 이 이력 버전의 내용으로 되돌린다(되돌리기 직전 내용도 이력에 남는다).
  Future<ProjectNote> restoreNoteVersion(
    String noteId,
    String versionId,
  ) async {
    return ProjectNote.fromJson(
      await _post('/api/notes/$noteId/restore', {'versionId': versionId})
          as Map<String, dynamic>,
    );
  }

  Future<List<AutomationRunLog>> fetchAutomationRuns(String projectId) async {
    final list = await _get('/api/projects/$projectId/automation-runs') as List;
    return list
        .map((e) => AutomationRunLog.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<TaskStatusDef>> fetchTaskStatuses(String projectId) async {
    final list = await _get('/api/projects/$projectId/task-statuses') as List;
    return list
        .map((e) => TaskStatusDef.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<TaskStatusDef> createTaskStatus(
    String projectId, {
    required String name,
    required String color,
    required TaskStatus category,
  }) async {
    return TaskStatusDef.fromJson(
      await _post('/api/projects/$projectId/task-statuses', {
            'name': name,
            'color': color,
            'category': taskStatusToWire(category),
          })
          as Map<String, dynamic>,
    );
  }

  Future<TaskStatusDef> updateTaskStatus(
    String statusId, {
    String? name,
    String? color,
  }) async {
    return TaskStatusDef.fromJson(
      await _patch('/api/task-statuses/$statusId', {
            'name': ?name,
            'color': ?color,
          })
          as Map<String, dynamic>,
    );
  }

  Future<void> deleteTaskStatus(String statusId) async {
    await _delete('/api/task-statuses/$statusId');
  }

  Future<void> reorderTaskStatuses(String projectId, List<String> ids) async {
    await _post('/api/projects/$projectId/task-statuses/order', {'ids': ids});
  }

  Future<List<TaskPriorityDef>> fetchTaskPriorities(String projectId) async {
    final list = await _get('/api/projects/$projectId/task-priorities') as List;
    return list
        .map((e) => TaskPriorityDef.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<TaskPriorityDef> createTaskPriority(
    String projectId, {
    required String name,
    required String color,
    required TaskPriority level,
  }) async {
    return TaskPriorityDef.fromJson(
      await _post('/api/projects/$projectId/task-priorities', {
            'name': name,
            'color': color,
            'level': taskPriorityToWire(level),
          })
          as Map<String, dynamic>,
    );
  }

  Future<TaskPriorityDef> updateTaskPriority(
    String priorityId, {
    String? name,
    String? color,
  }) async {
    return TaskPriorityDef.fromJson(
      await _patch('/api/task-priorities/$priorityId', {
            'name': ?name,
            'color': ?color,
          })
          as Map<String, dynamic>,
    );
  }

  Future<void> deleteTaskPriority(String priorityId) async {
    await _delete('/api/task-priorities/$priorityId');
  }

  Future<void> reorderTaskPriorities(String projectId, List<String> ids) async {
    await _post('/api/projects/$projectId/task-priorities/order', {'ids': ids});
  }

  Future<List<TaskFieldDef>> fetchTaskFields(String projectId) async {
    final list = await _get('/api/projects/$projectId/task-fields') as List;
    return list
        .map((e) => TaskFieldDef.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<TaskFieldDef> createTaskField(
    String projectId, {
    required String name,
    required String kind,
    List<String> options = const [],
  }) async {
    return TaskFieldDef.fromJson(
      await _post('/api/projects/$projectId/task-fields', {
            'name': name,
            'kind': kind,
            'options': options,
          })
          as Map<String, dynamic>,
    );
  }

  Future<TaskFieldDef> updateTaskField(
    String fieldId, {
    String? name,
    List<String>? options,
  }) async {
    return TaskFieldDef.fromJson(
      await _patch('/api/task-fields/$fieldId', {
            'name': ?name,
            'options': ?options,
          })
          as Map<String, dynamic>,
    );
  }

  Future<void> deleteTaskField(String fieldId) async {
    await _delete('/api/task-fields/$fieldId');
  }

  Future<Task> createTask({
    required String projectId,
    String? parentTaskId,
    required String title,
    String? description,
    String? assigneeId,
    TaskStatus status = TaskStatus.todo,
    String? statusId,
    Map<String, dynamic>? customValues,
    TaskPriority priority = TaskPriority.normal,
    String? priorityId,
    String? typeId,
    List<String> referenceIds = const [],
    DateTime? startDate,
    DateTime? dueDate,
  }) async {
    return Task.fromJson(
      await _post('/api/projects/$projectId/tasks', {
            'parentTaskId': ?parentTaskId,
            'title': title,
            'description': ?description,
            'assigneeId': ?assigneeId,
            'status': taskStatusToWire(status),
            'statusId': ?statusId,
            'customValues': ?customValues,
            'priority': taskPriorityToWire(priority),
            'priorityId': ?priorityId,
            'typeId': ?typeId,
            'referenceIds': referenceIds,
            'startDate': ?startDate?.millisecondsSinceEpoch,
            'dueDate': ?dueDate?.millisecondsSinceEpoch,
          })
          as Map<String, dynamic>,
    );
  }

  /// 업무 수정 — 넘긴 항목만 바뀐다. 담당자/마감일은 "지우기"도 되어야 해서
  /// [clearAssignee]/[clearDueDate]로 명시적으로 null을 보낸다(값을 안 넘기는 것과 구분).
  Future<Task> updateTask(
    String taskId, {
    String? title,
    String? description,
    String? assigneeId,
    bool clearAssignee = false,
    TaskStatus? status,
    String? statusId,
    Map<String, dynamic>? customValues,
    TaskPriority? priority,
    String? priorityId,
    String? typeId,
    bool clearType = false,
    String? parentTaskId,
    bool clearParent = false,
    List<String>? referenceIds,
    DateTime? startDate,
    bool clearStartDate = false,
    DateTime? dueDate,
    bool clearDueDate = false,
  }) async {
    return Task.fromJson(
      await _patch('/api/tasks/$taskId', {
            'title': ?title,
            'description': ?description,
            if (clearAssignee)
              'assigneeId': null
            else
              'assigneeId': ?assigneeId,
            'status': ?(status == null ? null : taskStatusToWire(status)),
            'statusId': ?statusId,
            'customValues': ?customValues,
            'priority': ?(priority == null
                ? null
                : taskPriorityToWire(priority)),
            'priorityId': ?priorityId,
            if (clearType) 'typeId': null else 'typeId': ?typeId,
            if (clearParent)
              'parentTaskId': null
            else
              'parentTaskId': ?parentTaskId,
            'referenceIds': ?referenceIds,
            if (clearStartDate)
              'startDate': null
            else
              'startDate': ?startDate?.millisecondsSinceEpoch,
            if (clearDueDate)
              'dueDate': null
            else
              'dueDate': ?dueDate?.millisecondsSinceEpoch,
          })
          as Map<String, dynamic>,
    );
  }

  // ── 즐겨찾기한 파일 ──────────────────────────────────────────────────

  /// 내가 즐겨찾기한 첨부들의 메시지 id — 파일 모아보기가 별 표시와 정렬에 쓴다.
  /// (한 메시지에 사진이 여러 장이면 그중 하나만 담아도 그 메시지가 들어온다.)
  Future<Set<String>> fetchFavoriteFileMessageIds() async {
    final list = await _get('/api/favorite-files') as List;
    return {
      for (final e in list) (e as Map<String, dynamic>)['messageId'] as String,
    };
  }

  /// 첨부 하나를 즐겨찾기에 넣거나 뺀다(토글) — 넣었으면 true.
  Future<bool> toggleFavoriteFile(
    String messageId, {
    required String fileUrl,
    String? fileName,
  }) async {
    final res =
        await _post('/api/messages/$messageId/favorite-file', {
              'fileUrl': fileUrl,
              'fileName': ?fileName,
            })
            as Map<String, dynamic>;
    return res['favorited'] as bool? ?? false;
  }

  Future<void> deleteTask(String taskId) async {
    await _delete('/api/tasks/$taskId');
  }

  // ── 체크리스트 ────────────────────────────────────────────────────────

  Future<TaskChecklistItem> addChecklistItem(String taskId, String text) async {
    return TaskChecklistItem.fromJson(
      await _post('/api/tasks/$taskId/checklist', {'text': text})
          as Map<String, dynamic>,
    );
  }

  Future<TaskChecklistItem> updateChecklistItem(
    String itemId, {
    bool? done,
    String? text,
  }) async {
    return TaskChecklistItem.fromJson(
      await _patch('/api/checklist-items/$itemId', {
            'done': ?done,
            'text': ?text,
          })
          as Map<String, dynamic>,
    );
  }

  Future<void> deleteChecklistItem(String itemId) async {
    await _delete('/api/checklist-items/$itemId');
  }

  // ── 보관 · 복사 · 이동 ────────────────────────────────────────────────

  Future<Task> setTaskArchived(String taskId, bool archived) async {
    return Task.fromJson(
      await _post('/api/tasks/$taskId/archive', {'archived': archived})
          as Map<String, dynamic>,
    );
  }

  Future<Task> copyTask(String taskId) async {
    return Task.fromJson(
      await _post('/api/tasks/$taskId/copy', {}) as Map<String, dynamic>,
    );
  }

  Future<Task> moveTask(String taskId, String projectId) async {
    return Task.fromJson(
      await _post('/api/tasks/$taskId/move', {'projectId': projectId})
          as Map<String, dynamic>,
    );
  }

  /// [parentCommentId]를 주면 그 댓글의 답글로 단다.
  Future<TaskComment> addTaskComment(
    String taskId,
    String text, {
    List<TextFormatRun>? textFormat,
    String? parentCommentId,
  }) async {
    return TaskComment.fromJson(
      await _post('/api/tasks/$taskId/comments', {
            'text': text,
            'textFormat': ?textFormatToJson(textFormat),
            'parentCommentId': ?parentCommentId,
          })
          as Map<String, dynamic>,
    );
  }

  Future<TaskComment> updateTaskComment(
    String commentId,
    String text, {
    List<TextFormatRun>? textFormat,
  }) async {
    return TaskComment.fromJson(
      await _patch('/api/task-comments/$commentId', {
            'text': text,
            'textFormat': ?textFormatToJson(textFormat),
          })
          as Map<String, dynamic>,
    );
  }

  /// 댓글 삭제 — 달린 답글도 같이 지워진다.
  Future<void> deleteTaskComment(String commentId) async {
    await _delete('/api/task-comments/$commentId');
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
    // 'members'(기본, 안 보내도 됨) | 'initial' | 'emoji' | 'photo' — new_chat_screen.dart의
    // 아이콘 선택. 'emoji'면 iconEmoji, 'photo'면 iconUrl(업로드 응답의 URL)이 필요하고,
    // iconColor는 initial·emoji의 배경색(선택).
    String? iconType,
    String? iconEmoji,
    String? iconColor,
    String? iconUrl,
  }) async {
    return Room.fromJson(
      await _post('/api/rooms', {
            'teamId': teamId,
            'type': 'group',
            if (name != null && name.isNotEmpty) 'name': name,
            'memberIds': memberIds,
            'iconType': ?(iconType != null && iconType != 'members'
                ? iconType
                : null),
            'iconEmoji': ?iconEmoji,
            'iconColor': ?iconColor,
            'iconUrl': ?iconUrl,
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

  /// rooms.teamId는 서버에서 NOT NULL이라 비밀 대화 방도 어느 팀인가 하나를 걸어야 한다
  /// (그 팀 멤버인지는 나만 확인받는다 — 상대는 어느 팀 소속이든 상관없다, server/src/secretChats.js).
  Future<Room> startSecretChat({
    required String targetUserId,
    required String deviceId,
    required String initiatorEphemeralPublicKey,
    required String initiatorEphemeralSignature,
    required String teamId,
  }) async {
    return Room.fromJson(
      await _post('/api/secret-chats', {
            'targetUserId': targetUserId,
            'deviceId': deviceId,
            'initiatorEphemeralPublicKey': initiatorEphemeralPublicKey,
            'initiatorEphemeralSignature': initiatorEphemeralSignature,
            'teamId': teamId,
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

  /// 그룹채팅방 이름을 나에게만 바꾼다. 빈 문자열이면 별칭을 지운다.
  Future<void> setRoomNickname(String roomId, String name) async {
    await _post('/api/rooms/$roomId/nickname', {'name': name});
  }

  /// [text] 없이 첨부만(이미지/파일) 다는 댓글도 가능하다 — 그때는 [type]과 [fileUrl] 등을 채워서 호출.
  Future<Comment> addComment(
    String messageId, {
    String? text,
    List<TextFormatRun>? textFormat,
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
            'textFormat': ?textFormatToJson(textFormat),
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

  Future<Comment> editComment(
    String commentId,
    String text, {
    List<TextFormatRun>? textFormat,
  }) async {
    return Comment.fromJson(
      await _patch('/api/comments/$commentId', {
            'text': text,
            'textFormat': ?textFormatToJson(textFormat),
          })
          as Map<String, dynamic>,
    );
  }

  Future<void> deleteComment(String commentId) async {
    await _delete('/api/comments/$commentId');
  }

  Future<Message> editMessage(
    String messageId,
    String text, {
    List<TextFormatRun>? textFormat,
  }) async {
    return Message.fromJson(
      await _patch('/api/messages/$messageId', {
            'text': text,
            'textFormat': ?textFormatToJson(textFormat),
          })
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
    if (roomId != null) {
      params.write('&roomId=${Uri.encodeQueryComponent(roomId)}');
    }
    if (senderId != null) {
      params.write('&senderId=${Uri.encodeQueryComponent(senderId)}');
    }
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
      signedUrl: body['signedUrl'] as String?,
      fileName: body['fileName'] as String,
      size: (body['size'] as num).toInt(),
      mimeType: body['mimeType'] as String?,
    );
  }

  /// 서버가 내려준 상대 경로(/uploads/xxx)를 절대 주소로 바꿉니다.
  String resolve(String relativeUrl) =>
      relativeUrl.startsWith('http') ? relativeUrl : '$baseUrl$relativeUrl';
}
