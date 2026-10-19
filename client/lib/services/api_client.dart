import 'dart:async';
import 'dart:convert';

import 'package:cross_file/cross_file.dart';
import 'package:http/http.dart' as http;

import '../models/admin.dart';
import '../models/announcement.dart';
import '../models/call_recording.dart';
import '../models/drive.dart';
import '../models/wiki.dart';
import '../models/board_category.dart';
import '../models/app_user.dart';
import '../models/comment.dart';
import '../models/backup_settings.dart';
import '../models/ddns_settings.dart';
import '../models/inquiry.dart';
import '../models/bot_blocks.dart' show BotActionResult;
import '../models/integration.dart';
import '../models/invite_link.dart';
import '../models/invite_result.dart';
import '../models/mail_settings.dart';
import '../models/team_invite_link.dart';
import '../models/mention.dart';
import '../models/org_tree.dart';
import '../models/my_device.dart';
import '../models/login_security.dart';
import '../models/message.dart';
import '../models/message_reaction.dart';
import '../models/message_reminder.dart';
import '../models/todo.dart' show TodoPage;
import '../models/user_status.dart';
import '../models/poll.dart';
import '../models/project.dart';
import '../models/task_extras.dart';
import '../models/room.dart';
import '../models/scheduled_message.dart';
import '../models/shared_link.dart';
import '../models/sticker_pack.dart';
import '../models/team.dart';
import '../models/text_format.dart';
import '../models/topic_folder.dart';
import '../models/uploaded_attachment.dart';
import '../models/web_certificate_status.dart';
import 'chat_socket.dart' show SecretAcceptedEvent, SecretInviteEvent;
import 'device_kind.dart';
import 'invite_share.dart' show rememberWebAppUrl;
import '../l10n/tr.dart';

class ApiException implements Exception {
  final String message;

  /// 서버가 준 HTTP 상태 코드 — 알 때만(예전 서버에 없는 경로인지 404로 가려 예전 방식으로 되돌아갈 때 쓴다).
  final int? statusCode;
  const ApiException(this.message, {this.statusCode});
  @override
  String toString() => trServer(message);
}

/// 서버가 정한 시간 안에 답하지 않았다 — 연결 문제로 본다(보내기 대기열이 다시 한다 — connection_errors.dart).
class ApiTimeoutException extends ApiException {
  const ApiTimeoutException(super.message);
}

/// 메일로 확인 코드를 보냈다는 서버 답 — [email]은 일부만 보이는 받는 주소(모르면 null), 코드는 [expiresIn] 동안 쓸 수 있고
/// [resendIn]이 지나야 다시 받을 수 있다(server/src/emailCodes.js).
class EmailCodeSent {
  final String? email;
  final Duration expiresIn;
  final Duration resendIn;
  const EmailCodeSent({
    this.email,
    this.expiresIn = const Duration(minutes: 10),
    this.resendIn = const Duration(seconds: 60),
  });

  factory EmailCodeSent.fromJson(Map<String, dynamic> json) => EmailCodeSent(
    email: json['email'] as String?,
    expiresIn: Duration(
      seconds: (json['expiresInSeconds'] as num?)?.toInt() ?? 600,
    ),
    resendIn: Duration(
      seconds: (json['resendInSeconds'] as num?)?.toInt() ?? 60,
    ),
  );
}

/// 아이디 찾기 결과 — 화면에 보일 아이디([username]), 또는 메일로 보냈다는 표시([sentTo] — 일부만 보이는 주소).
/// 메일이 켜진 서버에서 이메일을 확인한 계정은 아이디를 화면에 보이지 않고 메일로 보낸다(server auth.js /find-id).
class FindIdResult {
  final String? username;
  final String? sentTo;
  const FindIdResult({this.username, this.sentTo});
  bool get sentByMail => username == null;
}

/// 비밀번호 찾기 첫 단계 결과 — 메일로 코드를 보냈으면 [emailCode], 아니면 보안 질문([question], 질문이 없는 옛 계정은
/// null)으로 찾는다(server auth.js /password-reset/start).
class PasswordResetStart {
  final EmailCodeSent? emailCode;
  final String? question;
  const PasswordResetStart({this.emailCode, this.question});
  bool get byEmail => emailCode != null;
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

/// 로그인 응답 → 토큰.
AuthResult authResultOf(Map<String, dynamic> body) => AuthResult(
  accessToken: body['accessToken'] as String,
  refreshToken: body['refreshToken'] as String,
  userId: body['userId'] as String,
  username: body['username'] as String,
);

/// 로그인 응답이 "2단계 인증이 남았다"(403 + otp_required/otp_setup_required)면 그 확인 표 — 아니면 null.
OtpChallenge? otpChallengeOf(int status, Map<String, dynamic> body) {
  if (status != 403) return null;
  final code = body['code'];
  final ticket = body['otpTicket'];
  if (ticket is! String ||
      (code != 'otp_required' && code != 'otp_setup_required')) {
    return null;
  }
  final methods = [
    for (final m in body['methods'] as List? ?? const ['totp'])
      if (m == 'totp' || m == 'webauthn') m as String,
  ];
  return OtpChallenge(
    ticket: ticket,
    setupRequired: code == 'otp_setup_required',
    username: body['username'] as String? ?? '',
    methods: methods.isEmpty ? const ['totp'] : methods,
  );
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

/// 기기 등록이 "다른 계정이 쓰는 기기 id"라서 거절됐을 때(409) — 공용 PC에서 계정을 바꿔 로그인한 경우다.
/// DeviceIdentity가 이걸 받으면 새 기기 id·키를 만들어 다시 등록한다(server/src/devices.js).
class DeviceOwnedByOtherException implements Exception {
  const DeviceOwnedByOtherException();
}

/// 서버가 비밀 대화 수락을 받지 않았다(4xx — 내 다른 기기가 먼저 수락했거나, 이미 끝났거나 거절된 요청 등). 수락을
/// 보내기 전에 적어 둔 이 기기의 키는 이 대화의 것이 아니므로 되돌린다(SecretSessionManager.acceptInvite). 응답이 없거나
/// 서버 오류(5xx)면 처리됐는지 몰라서 이 예외가 아니라 보통 ApiException이다.
class SecretChatRefusedException extends ApiException {
  const SecretChatRefusedException(super.message);
}

class UploadCancelledException implements Exception {
  @override
  String toString() => tr('업로드가 취소되었습니다.');
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

/// 팀 설정 "팀원 추가" 후보(GET /api/teams/:id/member-candidates) — 아직 이 팀에 없고 정지·탈퇴하지 않은 계정.
/// [complete]면(계정 등급 관리자·서버 운영자) 서버의 그런 회원 전부이고, 아니면(그 밖의 팀 소유자) 팀을 같이 쓰는
/// 사람뿐이라 나머지는 아이디로 한 명씩 찾는다([ApiClient.findTeamMemberCandidate]). 서버 userDirectory.js
/// memberCandidateScope — 팀만 만들면 누구나 소유자가 되므로 소유자에게 서버 전체 명단을 주지 않는다.
class TeamMemberCandidates {
  final List<AppUser> users;
  final bool complete;
  const TeamMemberCandidates({required this.users, required this.complete});

  factory TeamMemberCandidates.fromJson(Map<String, dynamic> json) =>
      TeamMemberCandidates(
        users: (json['users'] as List)
            .map((e) => AppUser.fromJson(e as Map<String, dynamic>))
            .toList(),
        complete: json['scope'] == 'all',
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

  /// 생일('MM-DD', 연도 없음). 안 정했으면 null.
  final String? birthday;

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

  /// 내 상태 메시지·방해 금지(server/src/statusRules.js) — 없으면 null.
  final UserStatus? status;
  final DndState? dnd;

  /// 이메일을 본인이 받는다고 메일 코드로 확인했는지 — 메일이 켜진 서버에서 확인하지 않았으면 앱이 확인을 권한다.
  final bool emailVerified;

  /// 로그인 방법 — 'local'(아이디·비밀번호) | 'ldap'(회사 Windows 도메인 계정) | 'sso'(회사 계정 Google·Microsoft로만). 내 프로필이
  /// 비밀번호 변경 칸을 보일지 정한다.
  final String authSource;

  /// 2단계 인증(OTP)을 켰는지.
  final bool otpEnabled;

  const MyProfile({
    required this.username,
    required this.name,
    this.email,
    this.emailVerified = false,
    this.authSource = 'local',
    this.otpEnabled = false,
    this.avatarType = 'initial',
    this.avatarEmoji,
    this.avatarColor,
    this.avatarUrl,
    this.birthday,
    this.role = 'guest',
    this.isServerAdmin = false,
    this.canCreateTeamInviteLink = false,
    this.canCreateProject = false,
    this.orgScope = 'team',
    this.department,
    this.position,
    this.teamPositions = const [],
    this.status,
    this.dnd,
  });

  factory MyProfile.fromJson(Map<String, dynamic> json) => MyProfile(
    status: UserStatus.fromJson(json['status']),
    dnd: DndState.fromJson(json['dnd']),
    username: json['username'] as String,
    name: (json['name'] as String?) ?? json['username'] as String,
    email: json['email'] as String?,
    emailVerified: json['emailVerified'] as bool? ?? false,
    authSource: json['authSource'] as String? ?? 'local',
    otpEnabled: json['otpEnabled'] == true,
    avatarType: json['avatarType'] as String? ?? 'initial',
    avatarEmoji: json['avatarEmoji'] as String?,
    avatarColor: json['avatarColor'] as String?,
    avatarUrl: json['avatarUrl'] as String?,
    birthday: json['birthday'] as String?,
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

/// GET /api/rooms/browse 결과 한 줄. 참여 여부가 함께 내려온다. 보기 방식~관리자 이름은
/// 예전 서버면 없어서 기본값(챗 뷰, 설정 꺼짐, 빈 목록)으로 읽는다.
class TopicBrowseEntry {
  final String id;
  final String name;
  final String? description;
  final bool isPublic;
  final int memberCount;
  final bool joined;
  final TopicViewMode viewMode;
  final bool readOnly;

  /// 보관된 공개 토픽도 목록에 남고 참여할 수 있다(배지로만 구분).
  final bool archived;
  final DateTime? createdAt;

  /// 토픽 관리자 이름들("멤버 N명 · 관리자 {names}").
  final List<String> adminNames;

  const TopicBrowseEntry({
    required this.id,
    required this.name,
    this.description,
    this.isPublic = true,
    required this.memberCount,
    required this.joined,
    this.viewMode = TopicViewMode.chat,
    this.readOnly = false,
    this.archived = false,
    this.createdAt,
    this.adminNames = const [],
  });

  bool get isBoard => viewMode == TopicViewMode.board;

  factory TopicBrowseEntry.fromJson(Map<String, dynamic> json) =>
      TopicBrowseEntry(
        id: json['id'] as String,
        name: json['name'] as String,
        description: json['description'] as String?,
        isPublic: json['isPublic'] as bool? ?? true,
        memberCount: (json['memberCount'] as num).toInt(),
        joined: json['joined'] as bool,
        viewMode: topicViewModeFromWire(json['viewMode'] as String?),
        readOnly: json['readOnly'] as bool? ?? false,
        archived: (json['archived'] as bool?) ?? (json['archivedAt'] != null),
        createdAt: (json['createdAt'] as num?) != null
            ? DateTime.fromMillisecondsSinceEpoch(
                (json['createdAt'] as num).toInt(),
              )
            : null,
        adminNames:
            (json['adminNames'] as List?)?.whereType<String>().toList() ??
            const [],
      );
}

/// 검색 한 번의 결과 — [items]는 한도(limit) 안에서 받은 것이고, [total]은 한도에 잘리기 전의 전체
/// 건수다("결과 N건"에 쓴다).
class SearchPage {
  final List<SearchResult> items;
  final int total;
  const SearchPage(this.items, this.total);
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

  /// 서버 메시지 타입 문자열('text'|'image'|'file'|'post' 등, 예전 서버면 null).
  final String? type;

  /// 보드 게시글이면 제목(서버가 실어줄 때만).
  final String? title;

  /// 방이 속한 팀 — "모든 팀"(scope=all)으로 찾았을 때만 서버가 실어준다.
  final String? teamId;
  final String? teamName;

  const SearchResult({
    required this.id,
    required this.roomId,
    this.roomName,
    this.senderId,
    required this.senderName,
    this.text,
    this.fileName,
    required this.createdAt,
    this.type,
    this.title,
    this.teamId,
    this.teamName,
  });

  bool get isPost => type == 'post';
  bool get isPoll => type == 'poll';

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
    type: json['type'] as String?,
    title: json['title'] as String?,
    teamId: json['teamId'] as String?,
    teamName: json['teamName'] as String?,
  );
}

/// 대화방 이름 검색([ApiClient.searchRoomsPage]) 결과 한 줄 — 내가 멤버인 방 하나.
class RoomSearchResult {
  final String roomId;
  final String teamId;
  final String teamName;

  /// 'topic' | 'group' | 'dm'.
  final String type;

  /// 화면에 보이는 이름(1:1은 상대 이름, 이름 없는 그룹은 멤버 이름들, 나와의 대화).
  final String name;
  final int memberCount;
  final bool archived;
  final bool isSelf;
  final DateTime lastActivityAt;

  const RoomSearchResult({
    required this.roomId,
    required this.teamId,
    required this.teamName,
    required this.type,
    required this.name,
    required this.memberCount,
    required this.archived,
    required this.isSelf,
    required this.lastActivityAt,
  });

  factory RoomSearchResult.fromJson(Map<String, dynamic> json) =>
      RoomSearchResult(
        roomId: json['roomId'] as String,
        teamId: json['teamId'] as String,
        teamName: json['teamName'] as String? ?? '',
        type: json['type'] as String? ?? 'group',
        name: json['name'] as String? ?? '',
        memberCount: (json['memberCount'] as num?)?.toInt() ?? 0,
        archived: json['archived'] as bool? ?? false,
        isSelf: json['isSelf'] as bool? ?? false,
        lastActivityAt: DateTime.fromMillisecondsSinceEpoch(
          (json['lastActivityAt'] as num?)?.toInt() ?? 0,
        ),
      );
}

/// 대화방 검색 한 번의 결과 — [total]은 한도에 잘리기 전의 건수.
class RoomSearchPage {
  final List<RoomSearchResult> items;
  final int total;
  const RoomSearchPage(this.items, this.total);
}

/// 즐겨찾기한 첨부 하나를 가리키는 키 — 메시지 id + 파일 이름(서명된 URL은 매번 바뀌어서 못 쓴다).
String favoriteFileKey(String messageId, String? fileName) =>
    '$messageId/${fileName ?? ''}';

/// Node.js 서버(REST 부분)와 통신하는 얇은 클라이언트.
class ApiClient {
  /// 예: https://192.168.0.62:3000 (끝에 슬래시 없음). 사내 주소 ↔ 외부(LTE/5G) 주소로 자동
  /// 전환될 때 Session이 이 필드를 직접 바꾼다 — 화면들이 들고 있는 이 인스턴스가 그대로 새
  /// 주소로 요청하게 하려는 것(server_endpoints.dart 참고).
  String baseUrl;
  String? token; // accessToken. 갱신되면 Session이 이 필드를 직접 덮어쓴다.

  /// 요청이 401을 받았을 때 한 번 호출된다. accessToken 갱신에 성공하면(=이 인스턴스의
  /// [token]을 새로 채워넣으면) true를 반환해서 원래 요청을 한 번 더 재시도하게 한다.
  Future<bool> Function()? onUnauthorized;

  /// 오프라인 보기로 저장할 응답을 받았을 때(offline_cache.dart) — [key]는 'teams' | 'rooms:<팀 id>' | 'messages:<방 id>'(방의 최근
  /// 페이지) | 'older:<방 id>'(더 오래된 페이지), [raw]는 서버가 준 JSON 그대로. Session이 비밀 대화를 걸러 저장한다.
  void Function(String key, List<Object?> raw)? onCacheable;

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
        onTimeout: () => throw ApiTimeoutException(
          tr('요청이 시간 초과되었습니다. 네트워크 연결을 확인하고 다시 시도하세요.'),
        ),
      );

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    var res = await _withTimeout(request());
    if (res.statusCode == 401 && onUnauthorized != null) {
      final refreshed = await onUnauthorized!();
      if (refreshed) res = await _withTimeout(request());
    }
    return res;
  }

  Future<bool> checkHealth({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    try {
      final res = await _client.get(_uri('/health')).timeout(timeout);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 서버에 설정된 외부(LTE/5G) 접속 주소(서버 .env의 EXTERNAL_ADDRESS — 없으면 null)와 서버 PC의
  /// 사내 주소들(GET /server-info). 물어보지 못했으면(오프라인·예전 서버 등) 예외 — "외부 주소
  /// 없음"과 구분해야 Session이 저장해둔 주소를 잘못 지우지 않는다. 같은 응답의 아이폰용 웹 앱 주소는
  /// [fetchServerInfoWithWebUrl] — Session이 이 반환 모양을 그대로 받아 쓰고 있어서 따로 뒀다(이걸 불러도
  /// 웹 앱 주소는 초대 링크 복사 글에 쓰이도록 기억된다).
  Future<({String? externalUrl, List<String> internalUrls})>
  fetchServerInfo() async {
    final info = await fetchServerInfoWithWebUrl();
    return (externalUrl: info.externalUrl, internalUrls: info.internalUrls);
  }

  /// [fetchServerInfo]에 아이폰용 웹 앱 주소(webUrl)까지 — 서버에 공인 인증서가 실제로 걸려 있을 때만
  /// `https://도메인[:포트]`이고, 기능이 꺼져 있거나 이 값을 모르는 예전 서버면 null. 받은 값은 초대 링크를 복사하는
  /// 글(invite_share.dart)이 쓰도록 기억해 두고, 물어보지 못했으면 지운다 — 다른 서버로 바꾼 직후 예전 서버의 주소를
  /// 안내하지 않게.
  Future<({String? externalUrl, List<String> internalUrls, String? webUrl})>
  fetchServerInfoWithWebUrl() async {
    try {
      // 로그인했으면 토큰을 붙인다 — 사내망 밖에서는 토큰이 있어야 서버가 사내 주소를 알려준다.
      final res = await _client
          .get(_uri('/server-info'), headers: _authHeaders)
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) {
        throw ApiException(
          tr('서버 정보를 가져오지 못했습니다({res.statusCode}).', {
            'res.statusCode': res.statusCode,
          }),
        );
      }
      final body =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final info = (
        externalUrl: body['externalUrl'] as String?,
        internalUrls: (body['internalUrls'] as List? ?? const [])
            .whereType<String>()
            .toList(),
        webUrl: _webAppUrlFrom(body['webUrl']),
      );
      rememberWebAppUrl(info.webUrl);
      return info;
    } catch (_) {
      rememberWebAppUrl(null);
      rethrow;
    }
  }

  /// /server-info의 webUrl을 쓸 모양으로 — 아이폰 사용자에게 그대로 안내할 주소라 https 주소만 받고 끝 슬래시는
  /// 뗀다. 없거나(예전 서버·기능 꺼짐) 모양이 이상하면 null.
  static String? _webAppUrlFrom(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    return trimmed;
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
  /// 웹 푸시(VAPID) 공개키 — 브라우저가 구독할 때 "이 서버가 보내는 푸시만 받겠다"고 넘기는 값이라 비밀이
  /// 아니다(server/src/webPush.js). 웹 푸시를 못 쓰는 서버(예전 버전)거나 못 닿으면 null.
  Future<String?> fetchWebPushPublicKey() async {
    try {
      final res = await _client
          .get(_uri('/web-push/public-key'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;
      final body =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      return body['publicKey'] as String?;
    } catch (_) {
      return null;
    }
  }

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
        // 아이폰 앱용(GoogleService-Info.plist) — 예전 서버는 주지 않는다(아이폰은 FCM을 켜지 않는다).
        'iosApiKey': body['iosApiKey'] as String?,
        'iosAppId': body['iosAppId'] as String?,
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

  /// 인증이 필요한 파일 내려받기(그룹웨어 근태 엑셀 등) — [path]는 쿼리까지 붙은 서버 경로. [exportRoomChat]처럼 스트림으로 받고,
  /// 401이어도 토큰을 갱신해 다시 시도하지 않는다(가끔 누르는 내려받기라 실패하면 다시 누르면 된다).
  Future<http.StreamedResponse> downloadAuthed(String path) {
    final req = http.Request('GET', _uri(path))..headers.addAll(_authHeaders);
    return _client.send(req);
  }

  /// 회원가입 폼의 "중복 확인" 버튼용. 사용 가능하면 null, 아니면(형식 오류/중복) 사유
  /// 문구를 돌려준다.
  /// [inviteToken]은 초대 링크로 열린 앱이 받은 코드 — 사내망 밖에서는 이게 있어야 서버가 실제로 확인해 준다
  /// (없으면 누구나 아이디 목록을 맞혀볼 수 있어서 서버가 늘 "사용 가능"으로만 답한다).
  Future<String?> checkUsernameAvailable(
    String username, {
    String? inviteToken,
  }) async {
    final res = await _client.get(
      _uri('/auth/username-available').replace(
        queryParameters: {'username': username, 'inviteToken': ?inviteToken},
      ),
    );
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      throw ApiException((body['error'] as String?) ?? tr('요청이 실패했습니다.'));
    }
    return (body['available'] as bool) ? null : body['error'] as String?;
  }

  /// 회원가입. 메일이 켜진 서버는 [emailCode](이 이메일로 받은 확인 코드 — [sendSignupEmailCode])가 있어야 되고, 그때는
  /// 보안 질문을 넣지 않아도 된다([securityQuestion]·[securityAnswer]가 null). 메일이 꺼진 서버는 보안 질문이 필요하다.
  Future<AuthResult> register(
    String username,
    String password,
    String email,
    String name, {
    String? securityQuestion,
    String? securityAnswer,
    String? emailCode,
    String? teamInviteToken,
  }) => _authRequest('/auth/register', {
    'username': username,
    'password': password,
    'email': email,
    'name': name,
    'securityQuestion': ?securityQuestion,
    'securityAnswer': ?securityAnswer,
    'emailCode': ?emailCode,
    'teamInviteToken': ?teamInviteToken,
  });

  /// 서버에 메일(SMTP) 기능이 켜져 있는지(GET /server-info의 mailEnabled) — 켜져 있으면 가입할 때 이메일 확인 코드를 받고,
  /// 아이디·비밀번호를 메일로 찾는다. 못 물어봤거나 이 값을 모르는 예전 서버면 false(지금처럼 보안 질문).
  Future<bool> fetchMailEnabled() async {
    try {
      final res = await _client
          .get(_uri('/server-info'), headers: _authHeaders)
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return false;
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      return body is Map && body['mailEnabled'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 로그인 없이 부르는 POST — 실패하면 서버 문구(없으면 기본 문구)와 상태 코드로 ApiException. JSON이 아닌 답(예전 서버의
  /// "Cannot POST" 페이지 등)은 빈 내용으로 본다.
  Future<Map<String, dynamic>> _publicPost(
    String path,
    Map<String, dynamic> payload,
  ) async {
    final res = await _client.post(
      _uri(path),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      decoded = null;
    }
    final body = decoded is Map<String, dynamic>
        ? decoded
        : const <String, dynamic>{};
    if (res.statusCode >= 400) {
      throw ApiException(
        (body['error'] as String?) ?? tr('요청이 실패했습니다.'),
        statusCode: res.statusCode,
      );
    }
    return body;
  }

  /// 가입 전 이메일 확인 코드를 [email]로 보낸다(메일이 켜진 서버에서만). 사내 와이파이 밖에서는 [teamInviteToken](초대
  /// 링크의 코드)이 있어야 서버가 보낸다.
  Future<EmailCodeSent> sendSignupEmailCode(
    String email, {
    String? teamInviteToken,
  }) async => EmailCodeSent.fromJson(
    await _publicPost('/auth/email-code/signup', {
      'email': email,
      'teamInviteToken': ?teamInviteToken,
    }),
  );

  /// 로그인 — 2단계 인증이 남았으면 토큰 대신 [OtpChallenge]를 던진다(화면이 코드를 묻는다).
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
    final challenge = otpChallengeOf(res.statusCode, body);
    if (challenge != null) throw challenge;
    if (res.statusCode >= 400) {
      throw ApiException(
        (body['error'] as String?) ?? tr('요청이 실패했습니다.'),
        statusCode: res.statusCode,
      );
    }
    return authResultOf(body);
  }

  // ───────────── 로그인 보안(2단계 인증·회사 계정 — server/src/loginSecurity.js·sso.js) ─────────────

  /// 로그인 화면에 보일 로그인 방법(GET /server-info의 loginMethods). 못 물어보면 아이디 로그인만.
  Future<LoginMethods> fetchLoginMethods() async {
    try {
      final res = await _client
          .get(_uri('/server-info'), headers: _authHeaders)
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return LoginMethods.none;
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      return body is Map
          ? LoginMethods.fromJson(body['loginMethods'])
          : LoginMethods.none;
    } catch (_) {
      return LoginMethods.none;
    }
  }

  /// 로그인 둘째 단계 — 확인 표와 6자리 코드(또는 복구 코드).
  Future<AuthResult> loginWithOtp(
    String ticket, {
    String? code,
    String? recoveryCode,
  }) => _authRequest('/auth/login/otp', {
    'ticket': ticket,
    'code': ?code,
    'recoveryCode': ?recoveryCode,
  });

  /// 로그인 중(확인 표 [ticket]) 또는 로그인한 뒤(토큰) 부르는 2단계 인증 경로.
  Future<Map<String, dynamic>> _otpPost(
    String path,
    Map<String, dynamic> payload, {
    String? ticket,
  }) async => ticket != null
      ? await _publicPost(path, {...payload, 'ticket': ticket})
      : (await _post(path, payload) as Map).cast<String, dynamic>();

  /// 2단계 인증 켜기 1단계 — 비밀 키와 QR 주소.
  Future<OtpSetupInfo> otpSetup({String? ticket}) async {
    final body = await _otpPost('/auth/otp/setup', const {}, ticket: ticket);
    return OtpSetupInfo(
      secret: body['secret'] as String,
      uri: body['uri'] as String,
    );
  }

  /// 2단계 인증 켜기 2단계 — 코드로 확인하면 복구 코드 10개. 로그인 중([ticket])이었으면 토큰도.
  Future<({List<String> recoveryCodes, AuthResult? auth})> otpEnable(
    String code, {
    String? ticket,
  }) async {
    final body = await _otpPost('/auth/otp/enable', {
      'code': code,
    }, ticket: ticket);
    return (
      recoveryCodes: [
        for (final c in (body['recoveryCodes'] as List? ?? const []))
          c as String,
      ],
      auth: body['accessToken'] is String ? authResultOf(body) : null,
    );
  }

  Future<OtpStatus> otpStatus() async => OtpStatus.fromJson(
    (await _get('/auth/otp/status') as Map).cast<String, dynamic>(),
  );

  /// 2단계 인증 끄기 — 코드(또는 복구 코드)와, 이 앱의 비밀번호를 쓰는 계정이면 비밀번호.
  Future<void> otpDisable({
    String? password,
    String? code,
    String? recoveryCode,
  }) async {
    await _post('/auth/otp/disable', {
      'password': ?password,
      'code': ?code,
      'recoveryCode': ?recoveryCode,
    });
  }

  /// 복구 코드 새로 받기(예전 것은 못 쓰게 된다).
  Future<List<String>> otpRegenerateRecoveryCodes(String code) async {
    final body = await _post('/auth/otp/recovery-codes', {'code': code}) as Map;
    return [
      for (final c in (body['recoveryCodes'] as List? ?? const [])) c as String,
    ];
  }

  /// 회사 계정 로그인 시작 — 브라우저로 열 주소. [link]면 로그인한 내 계정에 연결하기(토큰을 싣는다).
  Future<({String state, String authUrl})> ssoStart(
    String provider,
    String challenge, {
    bool link = false,
  }) async {
    final payload = {
      'provider': provider,
      'challenge': challenge,
      'mode': link ? 'link' : 'login',
    };
    final body = link
        ? (await _post('/auth/sso/start', payload) as Map)
              .cast<String, dynamic>()
        : await _publicPost('/auth/sso/start', payload);
    return (state: body['state'] as String, authUrl: body['authUrl'] as String);
  }

  /// 회사 계정 로그인 결과 묻기.
  Future<SsoPollResult> ssoPoll(String state, String verifier) async {
    try {
      return ssoPollResultFromJson(
        await _publicPost('/auth/sso/poll', {
          'state': state,
          'verifier': verifier,
        }),
      );
    } on ApiException catch (e) {
      // 400 — 시간이 지났거나 서버가 다시 켜져 진행 중인 로그인을 잃었다.
      if (e.statusCode == 400) return SsoFailed(e.message);
      rethrow;
    }
  }

  /// 같은 이메일의 계정에 연결하려고 그 이메일로 확인 코드를 보낸다.
  Future<EmailCodeSent> ssoLinkSend(String state, String verifier) async =>
      EmailCodeSent.fromJson(
        await _publicPost('/auth/sso/link/send', {
          'state': state,
          'verifier': verifier,
        }),
      );

  /// 확인 코드를 넣어 연결하고 로그인한다.
  Future<AuthResult> ssoLinkVerify(
    String state,
    String verifier,
    String code,
  ) async => authResultOf(
    await _publicPost('/auth/sso/link/verify', {
      'state': state,
      'verifier': verifier,
      'code': code,
    }),
  );

  // ── 보안 키·패스키(WebAuthn — 서버 webauthn.js) ──

  /// 등록 시작 — 내 프로필(토큰) 또는 로그인 중 "2단계 인증을 꼭 써야 함"(설정 확인 표 [ticket]).
  Future<({String state, String url})> passkeyRegisterStart(
    String challenge, {
    String? name,
    String? ticket,
  }) async {
    final payload = {'challenge': challenge, 'name': ?name};
    final body = ticket != null
        ? await _publicPost('/auth/passkeys/register/start', {
            ...payload,
            'ticket': ticket,
          })
        : (await _post('/auth/passkeys/register/start', payload) as Map)
              .cast<String, dynamic>();
    return (state: body['state'] as String, url: body['url'] as String);
  }

  /// 비밀번호 없이 로그인 시작(아이디를 묻지 않는다).
  Future<({String state, String url})> passkeyLoginStart(
    String challenge,
  ) async {
    final body = await _publicPost('/auth/passkeys/login/start', {
      'challenge': challenge,
    });
    return (state: body['state'] as String, url: body['url'] as String);
  }

  /// 로그인 둘째 단계 시작 — 비밀번호를 통과하고 받은 확인 표로.
  Future<({String state, String url})> passkeySecondStart(
    String ticket,
    String challenge,
  ) async {
    final body = await _publicPost('/auth/passkeys/second/start', {
      'ticket': ticket,
      'challenge': challenge,
    });
    return (state: body['state'] as String, url: body['url'] as String);
  }

  /// 보안 키 확인 결과 묻기.
  Future<PasskeyPollResult> passkeyPoll(String state, String verifier) async {
    try {
      return passkeyPollResultFromJson(
        await _publicPost('/auth/passkeys/poll', {
          'state': state,
          'verifier': verifier,
        }),
      );
    } on ApiException catch (e) {
      if (e.statusCode == 400) return PasskeyFailed(e.message);
      rethrow;
    }
  }

  Future<PasskeysInfo> fetchPasskeys() async => PasskeysInfo.fromJson(
    (await _get('/auth/passkeys') as Map).cast<String, dynamic>(),
  );

  Future<Passkey> renamePasskey(String id, String name) async =>
      Passkey.fromJson(
        (await _patch('/auth/passkeys/$id', {'name': name}) as Map)
            .cast<String, dynamic>(),
      );

  Future<void> deletePasskey(String id) async {
    await _delete('/auth/passkeys/$id');
  }

  /// 로그아웃 — 토큰을 지우기 전에. 회사 계정으로 들어온 로그인이면 그 세션을 끝내고, 관리자가 "회사 계정에서도 로그아웃"을 켰으면
  /// 브라우저로 열 그쪽 로그아웃 주소를 돌려준다(없으면 null).
  Future<String?> logoutOnServer({String? refreshToken}) async {
    final body = await _post('/auth/logout', {'refreshToken': ?refreshToken});
    return body is Map ? body['idpLogoutUrl'] as String? : null;
  }

  // 관리자 콘솔 — SAML 메타데이터·그룹 규칙
  Future<SamlMetadataFill> parseSamlMetadata(String xml) async =>
      SamlMetadataFill.fromJson(
        (await _post('/api/admin/login-security/saml-metadata', {'xml': xml})
                as Map)
            .cast<String, dynamic>(),
      );

  Future<List<GroupMapping>> fetchGroupMappings() async => [
    for (final j in await _get('/api/admin/group-mappings') as List)
      GroupMapping.fromJson((j as Map).cast<String, dynamic>()),
  ];

  Future<GroupMapping> createGroupMapping({
    required String source,
    required String group,
    String? teamId,
    String? accountRole,
  }) async => GroupMapping.fromJson(
    (await _post('/api/admin/group-mappings', {
              'source': source,
              'group': group,
              'teamId': teamId,
              'accountRole': accountRole,
            })
            as Map)
        .cast<String, dynamic>(),
  );

  Future<void> deleteGroupMapping(String id) async {
    await _delete('/api/admin/group-mappings/$id');
  }

  Future<IdentitiesInfo> fetchIdentities() async => IdentitiesInfo.fromJson(
    (await _get('/auth/identities') as Map).cast<String, dynamic>(),
  );

  Future<void> unlinkIdentity(String provider) async {
    await _delete('/auth/identities/${Uri.encodeComponent(provider)}');
  }

  // 관리자 콘솔 "로그인 보안"
  Future<LoginSecuritySettings> fetchLoginSecurity() async =>
      LoginSecuritySettings.fromJson(
        (await _get('/api/admin/login-security') as Map)
            .cast<String, dynamic>(),
      );

  Future<LoginSecuritySettings> updateLoginSecurity(
    Map<String, dynamic> patch,
  ) async => LoginSecuritySettings.fromJson(
    (await _patch('/api/admin/login-security', patch) as Map)
        .cast<String, dynamic>(),
  );

  Future<LdapTestResult> testLdap({String? username, String? password}) async {
    final body =
        (await _post('/api/admin/login-security/ldap-test', {
                  'username': ?username,
                  'password': ?password,
                })
                as Map)
            .cast<String, dynamic>();
    final profile = body['profile'];
    return LdapTestResult(
      ok: body['ok'] == true,
      message: body['message'] as String? ?? '',
      profile: profile is Map
          ? {
              for (final e in profile.entries)
                e.key as String: e.value as String?,
            }
          : null,
      view: LoginSecuritySettings.fromJson(
        (body['view'] as Map).cast<String, dynamic>(),
      ),
    );
  }

  Future<AdminUser> resetUserOtp(String userId) async => AdminUser.fromJson(
    await _post('/api/admin/users/$userId/otp-reset', {})
        as Map<String, dynamic>,
  );

  // ── 조직도(부서 트리·상위자 — 서버 orgTree.js) ──

  Future<OrgTree> fetchOrgTree({String? teamId}) async => OrgTree.fromJson(
    (await _get(
              teamId == null
                  ? '/api/org-tree'
                  : '/api/org-tree?teamId=${Uri.encodeQueryComponent(teamId)}',
            )
            as Map)
        .cast<String, dynamic>(),
  );

  Future<OrgDepartment> createDepartment({
    String? teamId,
    required String name,
    String? parentId,
  }) async => OrgDepartment.fromJson(
    (await _post('/api/org-tree/departments', {
              'teamId': ?teamId,
              'name': name,
              'parentId': parentId,
            })
            as Map)
        .cast<String, dynamic>(),
  );

  /// [patch]: name · parentId(null이면 맨 위로) · headId(null이면 부서장 없음).
  Future<void> updateDepartment(String id, Map<String, dynamic> patch) async {
    await _patch('/api/org-tree/departments/$id', patch);
  }

  Future<void> moveDepartment(String id, {required bool up}) async {
    await _post('/api/org-tree/departments/$id/move', {
      'direction': up ? 'up' : 'down',
    });
  }

  Future<void> deleteDepartment(String id) async {
    await _delete('/api/org-tree/departments/$id');
  }

  /// 사람의 부서·상위자 — [patch]: departmentId · managerId(null이면 비움 — 상위자는 부서장으로).
  Future<void> setMemberOrg(
    String userId, {
    String? teamId,
    required Map<String, dynamic> patch,
  }) async {
    await _put('/api/org-tree/members/$userId', {'teamId': ?teamId, ...patch});
  }

  /// 겸직 넣기 — 주 부서 말고 [departmentId] 부서에도([position]은 그 부서에서의 직책, 비우면 주 직책).
  Future<void> addConcurrentDepartment(
    String userId, {
    String? teamId,
    required String departmentId,
    String? position,
  }) async {
    await _post('/api/org-tree/members/$userId/concurrent', {
      'teamId': ?teamId,
      'departmentId': departmentId,
      'position': ?position,
    });
  }

  Future<void> removeConcurrentDepartment(
    String userId,
    String departmentId, {
    String? teamId,
  }) async {
    await _delete(
      '/api/org-tree/members/$userId/concurrent/$departmentId'
      '${teamId == null ? '' : '?teamId=${Uri.encodeQueryComponent(teamId)}'}',
    );
  }

  /// 끌어다 놓기 — [id] 부서를 [parentId](null이면 맨 위) 아래 [index]번째(0부터)로.
  Future<void> placeDepartment(
    String id, {
    required String? parentId,
    required int index,
  }) async {
    await _post('/api/org-tree/departments/$id/place', {
      'parentId': parentId,
      'index': index,
    });
  }

  /// 조직도 엑셀 내려받기 경로(Session.downloadAuthedFile에 넘긴다).
  String orgTreeExportPath({String? teamId}) => teamId == null
      ? '/api/org-tree/export'
      : '/api/org-tree/export?teamId=${Uri.encodeQueryComponent(teamId)}';

  /// 파일 바이트를 본문 그대로 보낸다(엑셀·CSV 가져오기 — 급여대장·법인카드 이용내역). [path]에는 쿼리까지 담는다. 응답 JSON을
  /// 돌려주고, 실패(4xx·5xx)면 ApiException — 단 [resultKey]를 담은 응답(줄마다의 오류가 든 미리 보기 결과)은 실패여도 그대로 돌려준다.
  Future<Map<String, dynamic>> postBytes(
    String path,
    List<int> bytes, {
    String contentType = 'application/octet-stream',
    String? resultKey,
  }) async {
    final res = await _send(
      () => _client.post(
        _uri(path),
        headers: {..._authHeaders, 'Content-Type': contentType},
        body: bytes,
      ),
    );
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode < 400 && decoded is Map) {
      return decoded.cast<String, dynamic>();
    }
    if (resultKey != null && decoded is Map && decoded.containsKey(resultKey)) {
      return decoded.cast<String, dynamic>();
    }
    throw ApiException(
      (decoded is Map ? decoded['error'] as String? : null) ??
          tr('요청이 실패했습니다.'),
      statusCode: res.statusCode,
    );
  }

  /// 조직도 엑셀 가져오기 — [dryRun]이면 바꾸지 않고 미리 보기만. 오류가 있어도(400) 결과로 돌려준다(줄마다의 오류).
  Future<OrgImportResult> importOrgTree(
    List<int> bytes, {
    String? teamId,
    bool dryRun = false,
  }) async {
    final params = <String, String>{
      'teamId': ?teamId,
      if (dryRun) 'dryRun': '1',
    };
    final res = await _send(
      () => _client.post(
        _uri(
          '/api/org-tree/import',
        ).replace(queryParameters: params.isEmpty ? null : params),
        headers: {
          ..._authHeaders,
          'Content-Type':
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        },
        body: bytes,
      ),
    );
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is Map && decoded['summary'] is Map) {
      return OrgImportResult.fromJson(decoded.cast<String, dynamic>());
    }
    throw ApiException(
      (decoded is Map ? decoded['error'] as String? : null) ??
          tr('요청이 실패했습니다.'),
      statusCode: res.statusCode,
    );
  }

  /// 관리자 콘솔 — 지금 사내 디렉터리와 조직도 맞추기(부서 OU·상위자 manager).
  Future<DirectoryOrgSyncResult> syncDirectoryOrg() async =>
      DirectoryOrgSyncResult.fromJson(
        (await _post('/api/admin/login-security/ldap-org-sync', {}) as Map)
            .cast<String, dynamic>(),
      );

  // ── 외부 연동(웹훅·슬래시 명령·개인 API 토큰 — 서버 integrations.js) ──

  Map<String, dynamic> _map(Object? json) =>
      (json as Map).cast<String, dynamic>();

  Future<List<Integration>> fetchRoomWebhooks(String roomId) async => [
    for (final j in await _get('/api/rooms/$roomId/webhooks') as List)
      Integration.fromJson(_map(j)),
  ];

  Future<WebhookSecret> createWebhook(
    String roomId, {
    required String name,
    String? emoji,
  }) async => WebhookSecret.fromJson(
    _map(
      await _post('/api/rooms/$roomId/webhooks', {
        'name': name,
        'emoji': ?emoji,
      }),
    ),
  );

  Future<Integration> updateIntegration(
    String id,
    Map<String, dynamic> patch,
  ) async =>
      Integration.fromJson(_map(await _patch('/api/integrations/$id', patch)));

  /// 웹훅이면 새 주소(WebhookSecret), 슬래시 명령이면 새 서명 비밀(String).
  Future<Object> regenerateIntegration(Integration integration) async {
    final body = _map(
      await _post('/api/integrations/${integration.id}/regenerate', {}),
    );
    return integration.isCommand
        ? body['secret'] as String
        : WebhookSecret.fromJson(body);
  }

  Future<void> deleteIntegration(String id) async {
    await _delete('/api/integrations/$id');
  }

  Future<List<Integration>> fetchTeamCommands(String teamId) async => [
    for (final j in await _get('/api/teams/$teamId/commands') as List)
      Integration.fromJson(_map(j)),
  ];

  /// 슬래시 명령 만들기(서버 운영자) → (명령, 서명 비밀 — 이번에만).
  Future<(Integration, String)> createTeamCommand(
    String teamId, {
    required String command,
    required String name,
    required String url,
    String? emoji,
    String? description,
  }) async {
    final body = _map(
      await _post('/api/teams/$teamId/commands', {
        'command': command,
        'name': name,
        'url': url,
        'emoji': ?emoji,
        'description': ?description,
      }),
    );
    return (Integration.fromJson(body), body['secret'] as String);
  }

  Future<CommandRunResult> runSlashCommand(
    String roomId, {
    required String command,
    required String text,
  }) async => CommandRunResult.fromJson(
    _map(
      await _post('/api/rooms/$roomId/commands/run', {
        'command': command,
        'text': text,
      }),
    ),
  );

  Future<List<ApiToken>> fetchApiTokens() async => [
    for (final j in await _get('/api/users/me/api-tokens') as List)
      ApiToken.fromJson(_map(j)),
  ];

  /// 개인 API 토큰 만들기 → (토큰, 토큰 글 — 이번에만).
  Future<(ApiToken, String)> createApiToken({
    required String name,
    required bool write,
    int? expiresInDays,
  }) async {
    final body = _map(
      await _post('/api/users/me/api-tokens', {
        'name': name,
        'scopes': write ? ['read', 'write'] : ['read'],
        'expiresInDays': ?expiresInDays,
      }),
    );
    return (ApiToken.fromJson(body), body['token'] as String);
  }

  Future<void> revokeApiToken(String id) async {
    await _delete('/api/users/me/api-tokens/$id');
  }

  // ── 나가는 웹훅·연동 앱·단추 누르기·연결된 앱(서버 integrations.js·oauth.js) ──

  Future<List<Integration>> fetchRoomOutgoingWebhooks(String roomId) async => [
    for (final j in await _get('/api/rooms/$roomId/outgoing-webhooks') as List)
      Integration.fromJson(_map(j)),
  ];

  /// 나가는 웹훅 만들기 → (웹훅, 서명 비밀 — 이번에만).
  Future<(Integration, String)> createOutgoingWebhook(
    String roomId, {
    required String name,
    required String url,
    required List<String> events,
    String? emoji,
  }) async {
    final body = _map(
      await _post('/api/rooms/$roomId/outgoing-webhooks', {
        'name': name,
        'url': url,
        'events': events,
        'emoji': ?emoji,
      }),
    );
    return (Integration.fromJson(body), body['secret'] as String);
  }

  /// 바꾸기 — 들어오는 웹훅에 응답 주소를 처음 정하면 서명 비밀이 함께 온다(이번에만).
  Future<(Integration, String?)> updateIntegrationWithSecret(
    String id,
    Map<String, dynamic> patch,
  ) async {
    final body = _map(await _patch('/api/integrations/$id', patch));
    return (Integration.fromJson(body), body['secret'] as String?);
  }

  /// 새 서명 비밀(나가는 웹훅, 들어오는 웹훅의 응답 — [which] 'signing') — 이번에만.
  Future<String> regenerateSigningSecret(String id) async {
    final body = _map(
      await _post('/api/integrations/$id/regenerate', {'which': 'signing'}),
    );
    return body['secret'] as String;
  }

  /// 연동 앱의 비밀 하나를 새로 — [which] 'bot'(봇 토큰) | 'client'(OAuth 앱 비밀) | 'signing'(서명 비밀).
  Future<AppSecrets> regenerateAppSecret(String id, String which) async =>
      AppSecrets.fromJson(
        _map(await _post('/api/integrations/$id/regenerate', {'which': which})),
      );

  Future<List<WebhookDelivery>> fetchIntegrationDeliveries(String id) async => [
    for (final j in await _get('/api/integrations/$id/deliveries') as List)
      WebhookDelivery.fromJson(_map(j)),
  ];

  /// 보내 보기 — ping을 바로 한 번 보내고 그 결과.
  Future<WebhookDelivery> testIntegration(String id) async =>
      WebhookDelivery.fromJson(
        _map(await _post('/api/integrations/$id/test', {})),
      );

  /// 팀의 연동 앱 — 서버 운영자는 주소까지(관리자 콘솔), 팀 멤버는 이름·아이콘·설명만.
  Future<List<Integration>> fetchTeamAppsAdmin(String teamId) async => [
    for (final j in await _get('/api/teams/$teamId/apps') as List)
      Integration.fromJson({'kind': 'app', 'teamId': teamId, ..._map(j)}),
  ];

  Future<List<TeamApp>> fetchTeamApps(String teamId) async => [
    for (final j in await _get('/api/teams/$teamId/apps') as List)
      TeamApp.fromJson(_map(j)),
  ];

  /// 연동 앱 만들기(서버 운영자) → 봇 토큰·OAuth 앱 비밀·서명 비밀(이번에만).
  Future<AppSecrets> createTeamApp(
    String teamId, {
    required String name,
    String? emoji,
    String? description,
    String? url,
    List<String> events = const [],
    String? interactionUrl,
    List<String> redirectUris = const [],
  }) async => AppSecrets.fromJson(
    _map(
      await _post('/api/teams/$teamId/apps', {
        'name': name,
        'emoji': ?emoji,
        'description': ?description,
        'url': ?url,
        'events': events,
        'interactionUrl': ?interactionUrl,
        'redirectUris': redirectUris,
      }),
    ),
  );

  Future<List<TeamApp>> fetchRoomApps(String roomId) async => [
    for (final j in await _get('/api/rooms/$roomId/apps') as List)
      TeamApp.fromJson(_map(j)),
  ];

  Future<void> addAppToRoom(String roomId, String appId) async {
    await _post('/api/rooms/$roomId/apps', {'appId': appId});
  }

  Future<void> removeAppFromRoom(String roomId, String appId) async {
    await _delete('/api/rooms/$roomId/apps/$appId');
  }

  /// 봇 메시지의 단추·선택지 누르기([value]는 선택지에서 고른 값).
  Future<BotActionResult> runMessageAction(
    String messageId, {
    required String actionId,
    String? value,
  }) async => BotActionResult.fromJson(
    _map(
      await _post('/api/messages/$messageId/actions', {
        'actionId': actionId,
        'value': ?value,
      }),
    ),
  );

  /// 승인 코드로 OAuth 승인 요청 찾기(브라우저의 승인 페이지에 보이는 코드).
  Future<OAuthRequestInfo> lookupOAuthRequest(String code) async =>
      OAuthRequestInfo.fromJson(
        _map(await _post('/api/oauth/requests/lookup', {'code': code})),
      );

  /// 승인([approve] true)·거절 — 같은 코드를 다시 보낸다.
  Future<void> answerOAuthRequest(
    String requestId, {
    required String code,
    required bool approve,
  }) async {
    await _post(
      '/api/oauth/requests/$requestId/${approve ? 'approve' : 'deny'}',
      {'code': code},
    );
  }

  Future<List<ConnectedApp>> fetchConnectedApps() async => [
    for (final j in await _get('/api/users/me/connected-apps') as List)
      ConnectedApp.fromJson(_map(j)),
  ];

  Future<void> disconnectApp(String grantId) async {
    await _delete('/api/users/me/connected-apps/$grantId');
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
      throw ApiException((body['error'] as String?) ?? tr('세션이 만료되었습니다.'));
    }
    return body['accessToken'] as String;
  }

  /// 아이디 찾기 — 화면에 보일 아이디, 또는 메일로 보냈다는 결과(메일이 켜진 서버에서 이메일을 확인한 계정).
  Future<FindIdResult> findId(String email) async {
    final body = await _publicPost('/auth/find-id', {'email': email});
    if (body['sent'] == true) {
      return FindIdResult(sentTo: body['email'] as String? ?? '');
    }
    return FindIdResult(username: body['username'] as String);
  }

  /// 비밀번호 찾기 첫 단계 — 메일로 찾는 계정이면 서버가 재설정 코드를 보내고, 아니면 보안 질문을 알려 준다. 다시 부르면 코드를
  /// 다시 보낸다(1분 간격). 이 단계가 없는 예전 서버면 보안 질문 조회(/auth/security-question)로 대신한다.
  Future<PasswordResetStart> startPasswordReset({
    required String username,
    required String email,
  }) async {
    try {
      final body = await _publicPost('/auth/password-reset/start', {
        'username': username,
        'email': email,
      });
      if (body['method'] == 'email') {
        return PasswordResetStart(emailCode: EmailCodeSent.fromJson(body));
      }
      return PasswordResetStart(question: body['question'] as String?);
    } on ApiException catch (e) {
      if (e.statusCode != 404 || e.message != '요청이 실패했습니다.') rethrow;
      // 예전 서버(경로 없음 — 서버 문구 없이 404).
      return PasswordResetStart(
        question: await fetchSecurityQuestion(username: username, email: email),
      );
    }
  }

  /// 메일로 받은 재설정 코드가 맞는지만 본다(비밀번호는 안 바꿈) — 맞을 때만 새 비밀번호 입력칸을 보여 주려고.
  Future<void> verifyPasswordResetCode({
    required String username,
    required String email,
    required String code,
  }) async {
    await _publicPost('/auth/password-reset/verify-code', {
      'username': username,
      'email': email,
      'code': code,
    });
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
      throw ApiException((body['error'] as String?) ?? tr('요청이 실패했습니다.'));
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
      throw ApiException((body['error'] as String?) ?? tr('요청이 실패했습니다.'));
    }
  }

  /// 비밀번호 재설정 — 메일로 찾는 계정은 [emailCode], 그 밖에는 [securityAnswer](질문이 없는 옛 계정은 null).
  Future<void> resetPassword({
    required String username,
    required String email,
    String? securityAnswer,
    String? emailCode,
    required String newPassword,
  }) async {
    final res = await _client.post(
      _uri('/auth/reset-password'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'email': email,
        'securityAnswer': ?securityAnswer,
        'emailCode': ?emailCode,
        'newPassword': newPassword,
      }),
    );
    if (res.statusCode >= 400) {
      final body =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      throw ApiException((body['error'] as String?) ?? tr('요청이 실패했습니다.'));
    }
  }

  Future<dynamic> _get(String path) async {
    final res = await _send(
      () => _client.get(_uri(path), headers: _authHeaders),
    );
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      throw ApiException(
        (body is Map ? body['error'] as String? : null) ?? tr('요청이 실패했습니다.'),
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
        (decoded is Map ? decoded['error'] as String? : null) ??
            tr('요청이 실패했습니다.'),
        statusCode: res.statusCode,
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
        (decoded is Map ? decoded['error'] as String? : null) ??
            tr('요청이 실패했습니다.'),
        statusCode: res.statusCode,
      );
    }
    return decoded;
  }

  Future<dynamic> _put(String path, Map<String, dynamic> body) async {
    final res = await _send(
      () => _client.put(
        _uri(path),
        headers: {..._authHeaders, 'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ),
    );
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      throw ApiException(
        (decoded is Map ? decoded['error'] as String? : null) ??
            tr('요청이 실패했습니다.'),
        statusCode: res.statusCode,
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
        (decoded is Map ? decoded['error'] as String? : null) ??
            tr('요청이 실패했습니다.'),
        statusCode: res.statusCode,
      );
    }
    return decoded;
  }

  /// 별도 파일의 API 묶음(calendar_api.dart 등)이 이 클라이언트의 인증·401 재시도·타임아웃·에러
  /// 처리를 그대로 쓰게 하는 범용 호출 — 엔드포인트가 많은 기능마다 이 파일을 늘리지 않으려는 것.
  /// [method]는 GET/POST/PUT/PATCH/DELETE. 4xx는 ApiException(서버의 `error` 문구)으로 던진다.
  Future<dynamic> requestJson(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) {
    switch (method) {
      case 'GET':
        return _get(path);
      case 'POST':
        return _post(path, body ?? const {});
      case 'PUT':
        return _put(path, body ?? const {});
      case 'PATCH':
        return _patch(path, body ?? const {});
      case 'DELETE':
        return _delete(path, body: body);
    }
    throw ArgumentError(tr('지원하지 않는 HTTP 메서드: {method}', {'method': method}));
  }

  /// 회원 목록 — 계정 등급 관리자·서버 운영자는 서버 전체(조직도), 그 밖에는 팀을 같이 쓰는 사람과 자기
  /// 자신만 온다(server users.js GET /users). 팀원 추가 후보는 [fetchTeamMemberCandidates].
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

  /// 내 상태 메시지 — [emoji]·[text]가 둘 다 없으면 지운다. [until]이 null이면 직접 지울 때까지.
  Future<MyProfile> updateMyStatus({
    String? emoji,
    String? text,
    DateTime? until,
  }) async => MyProfile.fromJson(
    await _put('/api/users/me/status', {
          'emoji': emoji,
          'text': text,
          'until': until?.millisecondsSinceEpoch,
        })
        as Map<String, dynamic>,
  );

  /// 내 방해 금지 — [setUntil]이면 "이 시각까지"를 [until]로(null이면 끔), [setSchedule]이면 매일 일정을 [schedule]로(null이면
  /// 지움). 넘긴 것만 바뀐다.
  Future<MyProfile> updateMyDnd({
    bool setUntil = false,
    DateTime? until,
    bool setSchedule = false,
    DndSchedule? schedule,
  }) async => MyProfile.fromJson(
    await _put('/api/users/me/dnd', {
          if (setUntil) 'until': until?.millisecondsSinceEpoch,
          if (setSchedule) 'schedule': schedule?.toJson(),
        })
        as Map<String, dynamic>,
  );

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

  /// 서버 운영자가 올린 "캐릭터" 세트(관리자 > 이모티콘 탭)에서 그림 하나를 내 프로필 사진으로
  /// 고른다 — 서버가 avatarType:'photo'로 바꿔서 돌려주므로(users.js), 그 뒤로는 "사진 올리기"로
  /// 고른 것과 똑같이 다뤄진다.
  Future<MyProfile> setAvatarToServerCharacter(String stickerId) async {
    final body = await _post('/api/users/me/avatar/character/$stickerId', {});
    return MyProfile.fromJson(body as Map<String, dynamic>);
  }

  /// 제공한 필드만 바꾼다(이름만, 이메일만, 또는 둘 다).
  /// [email]을 바꿀 때는 서버가 [currentPassword]로 본인 확인을 한다(비밀번호 변경과
  /// 같은 정책 — 이메일은 계정 복구 수단이라 이름/아바타보다 한 단계 더 확인한다).
  /// 메일이 켜진 서버에서 이메일을 바꿀 때는 새 주소로 받은 확인 코드([emailCode] — [sendEmailCode])도 함께 보낸다.
  Future<MyProfile> updateProfile({
    String? name,
    String? email,
    String? currentPassword,
    String? emailCode,
  }) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (email != null) {
      body['email'] = email;
      body['currentPassword'] = currentPassword;
      if (emailCode != null) body['emailCode'] = emailCode;
    }
    return MyProfile.fromJson(
      await _patch('/api/users/me', body) as Map<String, dynamic>,
    );
  }

  /// 이메일 확인 코드 보내기(메일이 켜진 서버에서만) — [email]이 없으면 지금 이메일을 확인하는 코드를 지금 주소로, 있으면 그
  /// 주소로 바꾸려는 코드를 새 주소로 보낸다(그때는 [currentPassword]가 필요하다).
  Future<EmailCodeSent> sendEmailCode({
    String? email,
    String? currentPassword,
  }) async => EmailCodeSent.fromJson(
    await _post('/api/users/me/email/send-code', {
          'email': ?email,
          'currentPassword': ?currentPassword,
        })
        as Map<String, dynamic>,
  );

  /// 지금 이메일로 받은 확인 코드를 넣어 이메일을 확인한다.
  Future<MyProfile> verifyEmail(String code) async => MyProfile.fromJson(
    await _post('/api/users/me/email/verify', {'code': code})
        as Map<String, dynamic>,
  );

  /// 생일만 바꾼다 — [birthday]는 'MM-DD'(연도 없음), null이면 삭제. null도 body에 그대로 실어야
  /// 서버가 "지우기"로 읽는다(빠지면 "바꾸지 않음").
  Future<MyProfile> updateMyBirthday(String? birthday) async {
    return MyProfile.fromJson(
      await _patch('/api/users/me', {'birthday': birthday})
          as Map<String, dynamic>,
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
    String? groupwareScope,
  }) async {
    await _patch('/api/admin/settings', {
      'teamCreation': ?teamCreation,
      'projectCreation': ?projectCreation,
      'teamInviteLinkCreation': ?teamInviteLinkCreation,
      'orgScope': ?orgScope,
      'groupwareScope': ?groupwareScope,
    });
  }

  /// 이 서버에서 화상회의를 쓸 수 있는지 + LiveKit 접속 주소(server/src/calls.js).
  /// LiveKit을 안 깐 서버면 enabled=false로 오고, 클라이언트는 통화 버튼 자체를 감춘다.
  /// [recording]·[minutes]·[summary]는 녹화(LiveKit Egress)·회의록 받아쓰기·요약을 이 서버가 하는지(예전 서버면 false).
  Future<
    ({bool enabled, String? url, bool recording, bool minutes, bool summary})
  >
  fetchCallsConfig() async {
    final body = await _get('/api/calls/config') as Map<String, dynamic>;
    return (
      enabled: body['enabled'] as bool? ?? false,
      url: body['url'] as String?,
      recording: body['recording'] == true,
      minutes: body['minutes'] == true,
      summary: body['summary'] == true,
    );
  }

  /// 통화 녹화 시작(진행자만 — 서버 callRecording.js). [audioOnly]면 음성만, [minutes]면 끝난 뒤 회의록을 만든다.
  Future<CallRecording> startCallRecording(
    String roomId, {
    bool audioOnly = false,
    bool minutes = false,
  }) async {
    final body =
        await _post('/api/rooms/$roomId/call/recording', {
              'audioOnly': audioOnly,
              'minutes': minutes,
            })
            as Map<String, dynamic>;
    return CallRecording.fromJson(body['recording'] as Map<String, dynamic>);
  }

  /// 통화 녹화 멈춤(진행자·시작한 사람) — 파일은 서버가 마무리해 대화방에 올린다.
  Future<void> stopCallRecording(String roomId) async {
    await _delete('/api/rooms/$roomId/call/recording');
  }

  /// 녹화 한 건과 회의록(받아쓰기·요약).
  Future<CallRecording> fetchCallRecording(String id) async {
    final body = await _get('/api/call-recordings/$id') as Map<String, dynamic>;
    return CallRecording.fromJson(body['recording'] as Map<String, dynamic>);
  }

  /// 못 만든 회의록을 다시 만든다(녹화를 시작한 사람·토픽 관리자).
  Future<CallRecording> retryCallMinutes(String id) async {
    final body =
        await _post('/api/call-recordings/$id/minutes/retry', const {})
            as Map<String, dynamic>;
    return CallRecording.fromJson(body['recording'] as Map<String, dynamic>);
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

  /// 관리자 콘솔 "DDNS" 탭의 웹 앱 주소(정식 인증서) 카드 — 아이폰용 웹 앱 포트의 Let's Encrypt 인증서 상태(GET
  /// /api/admin/web-certificate). 이 기능이 없는 예전 서버에는 이 경로가 없어 404(Express 기본 HTML 페이지라 JSON도
  /// 아니다)라 null — 화면이 카드를 숨긴다. 그 밖의 실패는 ApiException.
  Future<WebCertificateStatus?> fetchWebCertificateStatus() async {
    final res = await _send(
      () => _client.get(
        _uri('/api/admin/web-certificate'),
        headers: _authHeaders,
      ),
    );
    if (res.statusCode == 404) return null;
    final fallback = tr('웹 인증서 상태를 가져오지 못했습니다({res.statusCode}).', {
      'res.statusCode': res.statusCode,
    });
    final Object? body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      throw ApiException(fallback);
    }
    if (res.statusCode >= 400 || body is! Map<String, dynamic>) {
      final error = body is Map ? body['error'] : null;
      throw ApiException(error is String ? error : fallback);
    }
    return WebCertificateStatus.fromJson(body);
  }

  /// 관리자 콘솔 "DDNS" 탭 — DuckDNS 자동 갱신 설정과 상태(GET /api/admin/ddns). 이 기능이 없는 예전 서버는 404라
  /// null — 화면이 "서버를 업데이트하세요"로 안내한다.
  Future<DdnsSettings?> fetchDdnsSettings() async {
    final res = await _send(
      () => _client.get(_uri('/api/admin/ddns'), headers: _authHeaders),
    );
    if (res.statusCode == 404) return null;
    return DdnsSettings.fromJson(_decodeDdns(res));
  }

  /// DDNS 설정 변경 — 넘긴 항목만 바뀐다. [domains]는 "tangotalk, tangotalk-dev.duckdns.org"처럼, [token]에 빈
  /// 문자열을 넘기면 토큰을 지운다(그러면 꺼진다). 서버가 저장한 뒤 바로 한 번 갱신해 보고 그 결과를 돌려준다.
  Future<DdnsSettings> updateDdnsSettings({
    bool? enabled,
    String? domains,
    String? token,
  }) async => DdnsSettings.fromJson(
    await _patch('/api/admin/ddns', {
          'enabled': ?enabled,
          'domains': ?domains,
          'token': ?token,
        })
        as Map<String, dynamic>,
  );

  /// "지금 갱신" — 설정은 그대로 두고 바로 한 번 갱신한다.
  Future<DdnsSettings> runDdnsUpdate() async => DdnsSettings.fromJson(
    await _post('/api/admin/ddns/update', const {}) as Map<String, dynamic>,
  );

  /// 관리자 콘솔 "백업" 탭 — 서버 전체 백업 설정·상태·목록(GET /api/admin/backup). 이 기능이 없는 예전 서버는 404라
  /// null — 화면이 "서버를 업데이트하세요"로 안내한다.
  Future<BackupSettings?> fetchBackupSettings() async {
    final res = await _send(
      () => _client.get(_uri('/api/admin/backup'), headers: _authHeaders),
    );
    if (res.statusCode == 404) return null;
    return BackupSettings.fromJson(_decodeDdns(res, what: tr('백업 설정')));
  }

  /// 백업 설정 변경 — 넘긴 항목만 바뀐다. [destination]에 빈 문자열을 넘기면 외부 위치를 지운다. 백업 암호([password])나
  /// 외부 위치를 바꿀 때는 운영자 계정 비밀번호([accountPassword])를 같이 보내야 한다(서버가 다시 확인한다).
  Future<BackupSettings> updateBackupSettings({
    bool? enabled,
    int? hour,
    int? keep,
    String? destination,
    String? password,
    String? accountPassword,
  }) async => BackupSettings.fromJson(
    await _patch('/api/admin/backup', {
          'enabled': ?enabled,
          'hour': ?hour,
          'keep': ?keep,
          'destination': ?destination,
          'password': ?password,
          'accountPassword': ?accountPassword,
        })
        as Map<String, dynamic>,
  );

  /// "지금 백업" — 서버가 백업을 시작만 하고 바로 답한다(진행 상황은 [fetchBackupSettings]로 본다).
  Future<BackupSettings> runBackupNow() async => BackupSettings.fromJson(
    await _post('/api/admin/backup/run', const {}) as Map<String, dynamic>,
  );

  Map<String, dynamic> _decodeDdns(
    http.Response res, {
    String what = 'DDNS 설정',
  }) {
    final fallback = tr('{what}을 가져오지 못했습니다({res.statusCode}).', {
      'what': tr(what),
      'res.statusCode': res.statusCode,
    });
    final Object? body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      throw ApiException(fallback);
    }
    if (res.statusCode >= 400 || body is! Map<String, dynamic>) {
      final error = body is Map ? body['error'] : null;
      throw ApiException(error is String ? error : fallback);
    }
    return body;
  }

  /// 관리자 콘솔 "메일" 탭 — 메일(SMTP)·멘션 요약 메일 설정(GET /api/admin/mail). 이 기능이 없는 예전 서버는 404라 null —
  /// 화면이 "서버를 업데이트하세요"로 안내한다.
  Future<MailSettings?> fetchMailSettings() async {
    final res = await _send(
      () => _client.get(_uri('/api/admin/mail'), headers: _authHeaders),
    );
    if (res.statusCode == 404) return null;
    return MailSettings.fromJson(_decodeDdns(res, what: tr('메일 설정')));
  }

  /// 메일 설정 변경 — 넘긴 항목만 바뀐다. [password]에 빈 문자열을 넘기면 지우고, null이면 그대로 둔다. [port]를 지우려면
  /// [clearPort]. 연결 값을 바꾸면 서버가 시험 결과를 지우고 메일 기능을 끈다(다시 시험 메일을 보내 성공해야 켤 수 있다).
  Future<MailSettings> updateMailSettings({
    bool? enabled,
    String? host,
    int? port,
    bool clearPort = false,
    String? security,
    String? username,
    String? password,
    String? fromAddress,
    String? fromName,
    bool? digestEnabled,
    int? digestDays,
    bool? digestPreview,
  }) async => MailSettings.fromJson(
    await _patch('/api/admin/mail', {
          'enabled': ?enabled,
          'host': ?host,
          if (clearPort) 'port': null else 'port': ?port,
          'security': ?security,
          'username': ?username,
          'password': ?password,
          'fromAddress': ?fromAddress,
          'fromName': ?fromName,
          'digestEnabled': ?digestEnabled,
          'digestDays': ?digestDays,
          'digestPreview': ?digestPreview,
        })
        as Map<String, dynamic>,
  );

  /// 관리자 콘솔 "메일" 탭의 웹메일 칸 — 자체 메일 서버·OAuth 연결(GET /api/admin/webmail). 예전 서버는 404라 null(칸을 숨긴다).
  Future<WebmailAdminSettings?> fetchWebmailAdmin() async {
    final res = await _send(
      () => _client.get(_uri('/api/admin/webmail'), headers: _authHeaders),
    );
    if (res.statusCode == 404) return null;
    return WebmailAdminSettings.fromJson(_decodeDdns(res, what: tr('웹메일 설정')));
  }

  /// 웹메일 칸 바꾸기 — 넘긴 것만. 자체 메일 서버는 [localEnabled]·[localDomains]·[localPort]·[localMaxMessageMb]·[localQuotaMb],
  /// 스팸 거르기 [spamFilter], 보내는 메일 DKIM 서명 [dkimEnabled]·[dkimSelector], OAuth 연결은 [oauthGoogle]·[oauthMicrosoft]. 서버가
  /// 받는 포트를 바로 다시 연다.
  Future<WebmailAdminSettings> updateWebmailAdmin({
    bool? localEnabled,
    String? localDomains,
    int? localPort,
    int? localMaxMessageMb,
    int? localQuotaMb,
    bool? spamFilter,
    bool? dkimEnabled,
    String? dkimSelector,
    bool? oauthGoogle,
    bool? oauthMicrosoft,
  }) async {
    final local = {
      'enabled': ?localEnabled,
      'domains': ?localDomains,
      'port': ?localPort,
      'maxMessageMb': ?localMaxMessageMb,
      'quotaMb': ?localQuotaMb,
      'spamFilter': ?spamFilter,
      'dkimEnabled': ?dkimEnabled,
      'dkimSelector': ?dkimSelector,
    };
    final oauth = {'google': ?oauthGoogle, 'microsoft': ?oauthMicrosoft};
    return WebmailAdminSettings.fromJson(
      await _patch('/api/admin/webmail', {
            if (local.isNotEmpty) 'local': local,
            if (oauth.isNotEmpty) 'oauth': oauth,
          })
          as Map<String, dynamic>,
    );
  }

  /// DKIM 레코드가 DNS에 올라가 있는지 도메인마다(POST /api/admin/webmail/dkim-check) — [ok]가 아니면 [found]는 DNS에서 찾은 값의
  /// 앞부분(없으면 null).
  Future<List<({String domain, bool ok, String? found})>>
  checkDkimRecords() async {
    final m = await _post('/api/admin/webmail/dkim-check', {}) as Map;
    return [
      for (final r in m['results'] as List? ?? const [])
        if (r is Map)
          (
            domain: r['domain'] as String? ?? '',
            ok: r['ok'] == true,
            found: r['found'] as String?,
          ),
    ];
  }

  /// 시험 메일 — 지금 저장된 값으로 [to]에 한 통 보낸다. 성공하면 메일 기능을 켤 수 있게 된다. 실패하면 고칠 수 있는 이유로
  /// ApiException.
  Future<MailSettings> sendTestMail(String to) async => MailSettings.fromJson(
    await _post('/api/admin/mail/test', {'to': to}) as Map<String, dynamic>,
  );

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
    String? iosApiKey,
    String? iosAppId,
    String? serviceAccountJson,
  }) async {
    await _patch('/api/admin/fcm-settings', {
      'apiKey': ?apiKey,
      'appId': ?appId,
      'projectId': ?projectId,
      'messagingSenderId': ?messagingSenderId,
      'iosApiKey': ?iosApiKey,
      'iosAppId': ?iosAppId,
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
  // 만들 때마다 서버가 canCreateInviteLink를 다시 확인하므로, 권한이 없으면 403이 온다. 목록·취소는
  // 권한을 잃은 뒤에도 내가 만든 링크라면 된다.

  /// 내가 만든 초대 링크 목록(최신순).
  Future<List<InviteLink>> fetchInviteLinks() async {
    final list = await _get('/api/invite-links') as List;
    return list
        .map((e) => InviteLink.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 새 초대 링크 발급 — 유효기간은 서버에서 항상 7일로 고정된다. [maxUses]는 이 링크로 가입할
  /// 수 있는 사람 수(서버가 1~100명으로 맞추고, 안 보내면 1명).
  Future<InviteLink> createInviteLink({String? label, int? maxUses}) async =>
      InviteLink.fromJson(
        await _post('/api/invite-links', {'label': ?label, 'maxUses': ?maxUses})
            as Map<String, dynamic>,
      );

  /// 폐기 — 내가 만든 링크만 지울 수 있다(서버가 다시 확인).
  Future<InviteLink> revokeInviteLink(String id) async => InviteLink.fromJson(
    await _delete('/api/invite-links/$id') as Map<String, dynamic>,
  );

  /// 초대 링크를 메일로 보낸다(메일이 켜진 서버에서만) — 본문은 서버가 만든다. 결과는 보낸 수와 못 보낸 주소들.
  Future<InviteMailResult> sendInviteLinkEmails(
    String id,
    List<String> emails,
  ) async => InviteMailResult.fromJson(
    await _post('/api/invite-links/$id/email', {'emails': emails})
        as Map<String, dynamic>,
  );

  // ─────────────── 팀 초대 링크(가입 시 팀 자동 합류 + 등급 자동 부여) ───────────────
  // 만들 때마다 서버가 canCreateTeamInviteLink(서버 설정)를 다시 확인하므로, 권한이 없으면
  // 403이 온다(목록·취소는 권한을 잃은 뒤에도 내가 만든 링크라면 된다). 위 초대 링크와 달리 팀
  // 합류/등급 부여까지 자동으로 한다는 게 핵심 차이.

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
    int? maxUses,
  }) async => TeamInviteLink.fromJson(
    await _post('/api/team-invite-links', {
          'teamId': teamId,
          'assignedRole': assignedRole.wire,
          'assignedPosition': ?assignedPosition,
          'label': ?label,
          'maxUses': ?maxUses,
        })
        as Map<String, dynamic>,
  );

  /// 폐기 — 내가 만든 링크만 지울 수 있다(서버가 다시 확인).
  Future<TeamInviteLink> revokeTeamInviteLink(String id) async =>
      TeamInviteLink.fromJson(
        await _delete('/api/team-invite-links/$id') as Map<String, dynamic>,
      );

  /// 팀 초대 링크를 메일로 보낸다 — [sendInviteLinkEmails]와 같고 본문에 팀 이름이 들어간다.
  Future<InviteMailResult> sendTeamInviteLinkEmails(
    String id,
    List<String> emails,
  ) async => InviteMailResult.fromJson(
    await _post('/api/team-invite-links/$id/email', {'emails': emails})
        as Map<String, dynamic>,
  );

  /// 내가 속한 팀 목록(각 팀에서의 내 등급 포함) — 로그인/앱 시작 직후 팀 선택 화면이 쓴다.
  Future<List<Team>> fetchTeams() async {
    final list = await _get('/api/teams') as List;
    onCacheable?.call('teams', list);
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

  /// 팀 멤버 목록 — 조직도(멤버 패널)와 채팅 시작하기·새 그룹채팅 만들기의 멤버 고르기가 쓴다(서버
  /// 전체가 아니라 팀 단위).
  Future<List<AppUser>> fetchTeamMembers(String teamId) async {
    final list = await _get('/api/teams/$teamId/members') as List;
    return list
        .map((e) => AppUser.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 팀 설정 "팀원 추가" 후보 — 아직 이 팀에 없고 정지·탈퇴하지 않은 계정(그 팀을 관리할 수 있는 사람만,
  /// server teams.js GET /teams/:id/member-candidates). 회원 목록([fetchUsers])은 관리자 이상이 아니면 팀을 같이
  /// 쓰는 사람만 주므로, 아직 팀에 없는 사람(회원가입만 한 사람 등)은 여기서 받는다. 이름·아바타·아이디·등급만 온다.
  /// 계정 등급 관리자·서버 운영자가 아니면 팀을 같이 쓰는 사람만 온다([TeamMemberCandidates.complete]가 false).
  Future<TeamMemberCandidates> fetchTeamMemberCandidates(String teamId) async {
    final json =
        await _get('/api/teams/$teamId/member-candidates')
            as Map<String, dynamic>;
    return TeamMemberCandidates.fromJson(json);
  }

  /// 팀 밖 사람을 아이디로 한 명 찾는다(같은 엔드포인트의 ?username=) — 아이디가 정확히 같고(대소문자까지) 이
  /// 팀에 넣을 수 있는(아직 팀원이 아니고 정지·탈퇴하지 않은) 사람이면 그 사람, 아니면 null. 서버가 횟수를 제한한다
  /// (관리자 이상이 아니면 10분에 30번 — 넘으면 서버 안내 문구로 [ApiException]).
  Future<AppUser?> findTeamMemberCandidate(
    String teamId,
    String username,
  ) async {
    final json =
        await _get(
              '/api/teams/$teamId/member-candidates'
              '?username=${Uri.encodeQueryComponent(username)}',
            )
            as Map<String, dynamic>;
    final users = TeamMemberCandidates.fromJson(json).users;
    return users.isEmpty ? null : users.first;
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
    onCacheable?.call('rooms:$teamId', list);
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
    // 최근 페이지든 더 오래된 페이지든 이 기기 메시지 DB에 쌓는다(오프라인으로 위로 넘겨 보기·찾기 — offline_cache.dart).
    onCacheable?.call(
      before == null ? 'messages:$roomId' : 'older:$roomId',
      list,
    );
    return list
        .map((e) => Message.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 내 임시 저장(입력칸에 쓰다 만 글 — 서버 drafts.js) — `[{ roomId, text(지웠으면 null), format, mentions, updatedAt }]`.
  Future<List<Map<String, dynamic>>> fetchDrafts() async => [
    for (final e in await _get('/api/drafts') as List)
      (e as Map).cast<String, dynamic>(),
  ];

  /// 임시 저장 보내기 — [body]는 `{ text(비우면 지움), format?, mentions?, deviceId? }`. 서버가 받은 시각(ms).
  Future<int?> putDraft(String roomId, Map<String, dynamic> body) async {
    final res =
        await requestJson(
              'PUT',
              '/api/rooms/${Uri.encodeComponent(roomId)}/draft',
              body: body,
            )
            as Map;
    return (res['updatedAt'] as num?)?.toInt();
  }

  /// 메시지 한 건(GET /api/messages/:id) — 방 메시지 목록의 항목과 같은 모양(본문 원문·서명된 첨부·투표, 댓글은
  /// 없음). 접근 규칙도 목록과 같아서 그 방 멤버가 아니면, 지운 메시지·비밀 대화·1:1 "진짜 나가기" 이전 메시지면
  /// 던진다. 알림 센터의 "할 일로 등록"이 알림 미리보기(한 줄로 줄이고 잘린 스냅샷) 대신 지금의 원본을 받을 때 쓴다.
  Future<Message> fetchMessage(String messageId) async {
    return Message.fromJson(
      await _get('/api/messages/$messageId') as Map<String, dynamic>,
    );
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
  /// [textFormat]은 공지 쓰기 창의 서식 도구모음이 만든 서식 구간(AnnouncementDraft.format, 없으면 평문).
  Future<Announcement> createAnnouncement(
    String roomId,
    String text, {
    DateTime? autoUnpinAt,
    List<TextFormatRun>? textFormat,
  }) async {
    final format = textFormatToJson(textFormat);
    return Announcement.fromJson(
      await _post('/api/rooms/$roomId/announcements', {
            'text': text,
            'textFormat': ?format,
            if (autoUnpinAt != null)
              'autoUnpinAt': autoUnpinAt.millisecondsSinceEpoch,
          })
          as Map<String, dynamic>,
    );
  }

  /// 메시지 더보기의 "공지 등록" — 글을 직접 받지 않고 그 메시지에서 공지를 만든다(텍스트 메시지의 본문,
  /// 이미지 메시지의 첫 사진 + 설명글). 이미 고정 공지가 있으면 그 자리를 이 공지가 차지하고 이전 공지는
  /// 히스토리로 남는다. 텍스트·이미지가 아니거나 이미 이 메시지가 고정 공지이면 서버가 거절한다.
  Future<Announcement> createAnnouncementFromMessage(
    String roomId,
    String messageId,
  ) async {
    return Announcement.fromJson(
      await _post('/api/rooms/$roomId/announcements', {'messageId': messageId})
          as Map<String, dynamic>,
    );
  }

  /// 공지 수정 — 본인 작성 글만 가능(서버가 다시 확인). 글과 서식을 함께 바꾼다 — [textFormat]을 안 주면
  /// 서버가 서식을 지운다(글이 바뀌면 예전 서식 위치가 어긋나므로).
  Future<Announcement> updateAnnouncement(
    String roomId,
    String announcementId,
    String text, {
    List<TextFormatRun>? textFormat,
  }) async {
    final format = textFormatToJson(textFormat);
    return Announcement.fromJson(
      await _patch('/api/rooms/$roomId/announcements/$announcementId', {
            'text': text,
            'textFormat': ?format,
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

  /// 공지 읽음 확인 — 읽은 사람·안 읽은 사람(server/src/announcements.js readers).
  Future<AnnouncementReaders> fetchAnnouncementReaders(
    String roomId,
    String announcementId,
  ) async => AnnouncementReaders.fromJson(
    (await _get('/api/rooms/$roomId/announcements/$announcementId/readers')
            as Map)
        .cast<String, dynamic>(),
  );

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

  /// 공지 댓글 수정 — 작성자만(서버 moderation.js isSimpleComment).
  Future<AnnouncementComment> updateAnnouncementComment(
    String roomId,
    String announcementId,
    String commentId,
    String text,
  ) async {
    return AnnouncementComment.fromJson(
      await _patch(
            '/api/rooms/$roomId/announcements/$announcementId/comments/$commentId',
            {'text': text},
          )
          as Map<String, dynamic>,
    );
  }

  /// 공지 댓글 삭제 — 작성자와 관리자(팀 관리자·토픽 관리자).
  Future<void> deleteAnnouncementComment(
    String roomId,
    String announcementId,
    String commentId,
  ) async {
    await _delete(
      '/api/rooms/$roomId/announcements/$announcementId/comments/$commentId',
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

  /// [templateId]를 주면 기본 상태·유형·우선순위 대신 그 템플릿 구성으로 만든다.
  Future<Project> createProject({
    required String teamId,
    required String name,
    required String identifier,
    String? description,
    String? color,
    bool isPublic = false,
    List<String> memberIds = const [],
    String? templateId,
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
            'templateId': ?templateId,
          })
          as Map<String, dynamic>,
    );
  }

  /// 팀이 공유하는 프로젝트 템플릿들(만든 순).
  Future<List<ProjectTemplate>> fetchProjectTemplates(String teamId) async {
    final list = await _get('/api/projects/templates?teamId=$teamId') as List;
    return list
        .map((e) => ProjectTemplate.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 새 프로젝트 템플릿. [ProjectTemplate.sourceProjectId]가 있으면(프로젝트를 템플릿으로 저장)
  /// 서버가 그 프로젝트를 새 템플릿에 연결한다.
  Future<ProjectTemplate> createProjectTemplate(
    String teamId,
    ProjectTemplate template,
  ) async {
    return ProjectTemplate.fromJson(
      await _post('/api/projects/templates', {
            ...template.toJson(),
            'teamId': teamId,
            'sourceProjectId': ?template.sourceProjectId,
          })
          as Map<String, dynamic>,
    );
  }

  Future<ProjectTemplate> updateProjectTemplate(
    String id,
    ProjectTemplate template,
  ) async {
    return ProjectTemplate.fromJson(
      await _patch('/api/project-templates/$id', template.toJson())
          as Map<String, dynamic>,
    );
  }

  Future<void> deleteProjectTemplate(String id) async {
    await _delete('/api/project-templates/$id');
  }

  /// 내가 아직 참여하지 않은 이 팀의 공개 프로젝트들.
  /// (공개 프로젝트는 이제 자동으로 멤버가 되어 화면에서는 쓰지 않는다 — browse_projects_dialog.dart만 남아 있다.)
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
    // 노트 수정·삭제 권한 — 'all' | 'creator_admin'(설정 > 노트).
    String? noteEditPermission,
    String? noteDeletePermission,
  }) async {
    return Project.fromJson(
      await _patch('/api/projects/$projectId', {
            'name': ?name,
            'description': ?description,
            'color': ?color,
            'isPublic': ?isPublic,
            'archived': ?archived,
            'noteEditPermission': ?noteEditPermission,
            'noteDeletePermission': ?noteDeletePermission,
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

  /// 사이드바의 내 프로젝트 폴더들(개인 설정, 팀별) — 순서대로.
  Future<List<ProjectFolder>> fetchProjectFolders(String teamId) async {
    final list =
        await _get(
              '/api/projects/folders?teamId=${Uri.encodeQueryComponent(teamId)}',
            )
            as List;
    return list
        .map((e) => ProjectFolder.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ProjectFolder> createProjectFolder(String teamId, String name) async {
    return ProjectFolder.fromJson(
      await _post('/api/projects/folders', {'teamId': teamId, 'name': name})
          as Map<String, dynamic>,
    );
  }

  Future<ProjectFolder> updateProjectFolder(
    String folderId, {
    String? name,
    bool? collapsed,
    int? position,
  }) async {
    return ProjectFolder.fromJson(
      await _patch('/api/project-folders/$folderId', {
            'name': ?name,
            'collapsed': ?collapsed,
            'position': ?position,
          })
          as Map<String, dynamic>,
    );
  }

  /// 폴더만 지운다 — 안의 프로젝트는 사이드바 목록으로 돌아간다.
  Future<void> deleteProjectFolder(String folderId) async {
    await _delete('/api/project-folders/$folderId');
  }

  /// 프로젝트를 내 폴더 [folderId]에 넣는다. null이면 어느 폴더에서든 뺀다.
  Future<void> setProjectFolder(String projectId, String? folderId) async {
    await _put('/api/projects/$projectId/folder', {'folderId': folderId});
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

  /// 프로젝트 안의 업무 목록. [includeArchived]면 보관한 업무도 같이(리스트 탭이 흐리게 보여준다).
  Future<List<Task>> fetchProjectTasks(
    String projectId, {
    bool includeArchived = false,
  }) async {
    final list =
        await _get(
              '/api/projects/$projectId/tasks${includeArchived ? '?archived=all' : ''}',
            )
            as List;
    return list.map((e) => Task.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 내가 담당한 업무 전부(팀 기준) — "내 업무" 화면.
  /// 내가 참여 중인 모든 프로젝트의 업무(전체 캘린더/간트차트용).
  Future<List<Task>> fetchTeamTasks(String teamId) async {
    final list = await _get('/api/tasks/team?teamId=$teamId') as List;
    return list.map((e) => Task.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// [includeArchived]면 보관한 업무도 같이("내 업무" 표가 흐리게 보여준다).
  Future<List<Task>> fetchMyTasks(
    String teamId, {
    bool includeArchived = false,
  }) async {
    final list =
        await _get(
              '/api/tasks/mine?teamId=$teamId${includeArchived ? '&archived=all' : ''}',
            )
            as List;
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

  /// 노드 편집기로 만든 규칙 저장 — [ruleId]가 있으면 수정, 없으면 새로 만든다.
  Future<AutomationRule> saveAutomationGraph(
    String projectId, {
    String? ruleId,
    required String name,
    required bool enabled,
    required AutomationGraph graph,
  }) async {
    final body = {'name': name, 'enabled': enabled, 'graph': graph.toJson()};
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

  /// 칸반 한 열의 카드 순서 — 그 열의 업무 id를 위에서부터.
  Future<void> reorderTasks(String projectId, List<String> ids) async {
    await _post('/api/projects/$projectId/tasks/order', {'ids': ids});
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
    // 반복 규칙·예상 소요 시간(분) — clear…면 끄기·지우기.
    TaskRecurrence? recurrence,
    bool clearRecurrence = false,
    int? estimateMinutes,
    bool clearEstimate = false,
  }) async {
    return Task.fromJson(
      await _patch('/api/tasks/$taskId', {
            if (clearRecurrence)
              'recurrence': null
            else
              'recurrence': ?recurrence?.toJson(),
            if (clearEstimate)
              'estimateMinutes': null
            else
              'estimateMinutes': ?estimateMinutes,
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

  // ── 팀 공유 드라이브(서버 drive.js) ─────────────────────────────────

  String _driveQuery(String teamId, [Map<String, String?> extra = const {}]) {
    final params = {'teamId': teamId, ...extra}
      ..removeWhere((_, v) => v == null || v.isEmpty);
    return '?${params.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value!)}').join('&')}';
  }

  /// 폴더 내용([folderId]가 null이면 맨 위).
  Future<DriveListing> fetchDrive(String teamId, {String? folderId}) async =>
      DriveListing.fromJson(
        await _get('/api/drive${_driveQuery(teamId, {'folderId': folderId})}')
            as Map<String, dynamic>,
      );

  Future<({List<DriveFolder> folders, List<DriveFile> files})> searchDrive(
    String teamId,
    String query,
  ) async {
    final j =
        await _get('/api/drive/search${_driveQuery(teamId, {'q': query})}')
            as Map;
    return (
      folders: [
        for (final f in (j['folders'] as List? ?? const []))
          DriveFolder.fromJson((f as Map).cast<String, dynamic>()),
      ],
      files: [
        for (final f in (j['files'] as List? ?? const []))
          DriveFile.fromJson((f as Map).cast<String, dynamic>()),
      ],
    );
  }

  Future<DriveFolder> createDriveFolder(
    String teamId,
    String name, {
    String? parentId,
  }) async => DriveFolder.fromJson(
    await _post('/api/drive/folders', {
          'teamId': teamId,
          'name': name,
          'parentId': ?parentId,
        })
        as Map<String, dynamic>,
  );

  /// 폴더 이름 바꾸기·옮기기 — [move]면 [parentId](null = 맨 위)로 옮긴다.
  Future<DriveFolder> updateDriveFolder(
    String folderId, {
    String? name,
    bool move = false,
    String? parentId,
  }) async => DriveFolder.fromJson(
    await _patch('/api/drive/folders/$folderId', {
          'name': ?name,
          if (move) 'parentId': parentId,
        })
        as Map<String, dynamic>,
  );

  Future<void> deleteDriveFolder(String teamId, String folderId) =>
      _delete('/api/drive/folders/$folderId${_driveQuery(teamId)}');

  /// 올린 파일([upload])을 드라이브에 넣는다 — 같은 이름이 있으면 서버가 409(앱이 "새 판으로 올리기"를 묻는다).
  Future<DriveFile> addDriveFile(
    String teamId,
    UploadResult upload, {
    String? folderId,
    String? note,
  }) async => DriveFile.fromJson(
    await _post('/api/drive/files', {
          'teamId': teamId,
          'folderId': ?folderId,
          'file': upload.url,
          'fileName': upload.fileName,
          'mimeType': ?upload.mimeType,
          if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
        })
        as Map<String, dynamic>,
  );

  Future<DriveFile> addDriveFileVersion(
    String fileId,
    UploadResult upload, {
    String? note,
  }) async => DriveFile.fromJson(
    await _post('/api/drive/files/$fileId/versions', {
          'file': upload.url,
          'fileName': upload.fileName,
          'mimeType': ?upload.mimeType,
          if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
        })
        as Map<String, dynamic>,
  );

  Future<DriveFileDetail> fetchDriveFile(String teamId, String fileId) async =>
      DriveFileDetail.fromJson(
        await _get('/api/drive/files/$fileId${_driveQuery(teamId)}')
            as Map<String, dynamic>,
      );

  Future<DriveFile> restoreDriveFileVersion(String fileId, int version) async =>
      DriveFile.fromJson(
        await _post(
              '/api/drive/files/$fileId/versions/$version/restore',
              const {},
            )
            as Map<String, dynamic>,
      );

  /// 파일 이름 바꾸기·옮기기 — [move]면 [folderId](null = 맨 위)로 옮긴다.
  Future<DriveFile> updateDriveFile(
    String fileId, {
    String? name,
    bool move = false,
    String? folderId,
  }) async => DriveFile.fromJson(
    await _patch('/api/drive/files/$fileId', {
          'name': ?name,
          if (move) 'folderId': folderId,
        })
        as Map<String, dynamic>,
  );

  Future<void> deleteDriveFile(String teamId, String fileId) =>
      _delete('/api/drive/files/$fileId${_driveQuery(teamId)}');

  Future<DriveTrash> fetchDriveTrash(String teamId) async =>
      DriveTrash.fromJson(
        await _get('/api/drive/trash${_driveQuery(teamId)}')
            as Map<String, dynamic>,
      );

  Future<void> restoreDriveItem({
    required bool folder,
    required String id,
  }) async {
    await _post('/api/drive/trash/restore', {
      'kind': folder ? 'folder' : 'file',
      'id': id,
    });
  }

  Future<void> purgeDriveItem(
    String teamId, {
    required bool folder,
    required String id,
  }) => _delete(
    '/api/drive/trash/${folder ? 'folder' : 'file'}/$id${_driveQuery(teamId)}',
  );

  // ── 팀 위키(서버 wiki.js — 본문 동시 편집은 소켓, services/wiki_doc.dart) ──

  Future<WikiTree> fetchWikiTree(String teamId) async => WikiTree.fromJson(
    await _get('/api/wiki${_driveQuery(teamId)}') as Map<String, dynamic>,
  );

  Future<WikiPageRow> createWikiPage(
    String teamId,
    String title, {
    String? parentId,
    String? body,
  }) async => WikiPageRow.fromJson(
    await _post('/api/wiki', {
          'teamId': teamId,
          'title': title,
          'parentId': ?parentId,
          'body': ?body,
        })
        as Map<String, dynamic>,
  );

  Future<WikiPage> fetchWikiPage(String pageId) async => WikiPage.fromJson(
    await _get('/api/wiki/$pageId') as Map<String, dynamic>,
  );

  /// 제목 바꾸기·옮기기 — [move]면 [parentId](null = 맨 위)로.
  Future<WikiPageRow> updateWikiPage(
    String pageId, {
    String? title,
    bool move = false,
    String? parentId,
  }) async => WikiPageRow.fromJson(
    await _patch('/api/wiki/$pageId', {
          'title': ?title,
          if (move) 'parentId': parentId,
        })
        as Map<String, dynamic>,
  );

  Future<void> deleteWikiPage(String pageId) => _delete('/api/wiki/$pageId');

  Future<void> restoreWikiPage(String pageId) =>
      _post('/api/wiki/$pageId/restore', const {});

  Future<List<WikiPageRow>> fetchWikiTrash(String teamId) async => [
    for (final p
        in (await _get('/api/wiki/trash${_driveQuery(teamId)}') as List))
      WikiPageRow.fromJson((p as Map).cast<String, dynamic>()),
  ];

  Future<List<WikiSearchHit>> searchWiki(String teamId, String query) async => [
    for (final h
        in (await _get('/api/wiki/search${_driveQuery(teamId, {'q': query})}')
            as List))
      WikiSearchHit.fromJson((h as Map).cast<String, dynamic>()),
  ];

  Future<List<WikiVersion>> fetchWikiVersions(String pageId) async => [
    for (final v in (await _get('/api/wiki/$pageId/versions') as List))
      WikiVersion.fromJson((v as Map).cast<String, dynamic>()),
  ];

  Future<WikiVersion> fetchWikiVersion(String pageId, String versionId) async =>
      WikiVersion.fromJson(
        await _get('/api/wiki/$pageId/versions/$versionId')
            as Map<String, dynamic>,
      );

  Future<void> restoreWikiVersion(String pageId, String versionId) =>
      _post('/api/wiki/$pageId/versions/$versionId/restore', const {});

  // ── 업무 선후행·소요 시간(서버 taskExtras.js) ─────────────────────────

  /// [taskId]의 선행 업무로 [predecessorId]를 넣는다 — 같은 프로젝트, 순환이면 서버가 400. → (선행, 후행).
  Future<({List<TaskLink> predecessors, List<TaskLink> successors})>
  addTaskDependency(String taskId, String predecessorId) async {
    final j =
        await _post('/api/tasks/$taskId/dependencies', {
              'taskId': predecessorId,
            })
            as Map;
    return (
      predecessors: TaskLink.listFromJson(j['predecessors']),
      successors: TaskLink.listFromJson(j['successors']),
    );
  }

  Future<void> removeTaskDependency(String taskId, String predecessorId) async {
    await _delete('/api/tasks/$taskId/dependencies/$predecessorId');
  }

  /// 소요 시간 남기기 — [workDate]를 비우면 오늘(한국 날짜).
  Future<TaskTimeEntry> addTimeEntry(
    String taskId, {
    required int minutes,
    String? workDate,
    String? note,
  }) async {
    return TaskTimeEntry.fromJson(
      await _post('/api/tasks/$taskId/time-entries', {
            'minutes': minutes,
            'workDate': ?workDate,
            if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
          })
          as Map<String, dynamic>,
    );
  }

  Future<void> deleteTimeEntry(String taskId, String entryId) async {
    await _delete('/api/tasks/$taskId/time-entries/$entryId');
  }

  /// 내 타이머(없으면 null).
  Future<TaskTimer?> fetchTaskTimer() async =>
      TaskTimer.fromJson((await _get('/api/tasks/timer') as Map)['timer']);

  /// [taskId]에서 타이머를 켠다 — 다른 업무에서 돌던 것은 서버가 멈춰 기록한다.
  Future<TaskTimer?> startTaskTimer(String taskId) async => TaskTimer.fromJson(
    (await _post('/api/tasks/$taskId/timer/start', const {}) as Map)['timer'],
  );

  /// 타이머를 멈춘다 — 남긴 기록(1분이 안 되면 null).
  Future<TaskTimeEntry?> stopTaskTimer() async {
    final entry =
        (await _post('/api/tasks/timer/stop', const {}) as Map)['entry'];
    return entry is Map
        ? TaskTimeEntry.fromJson(Map<String, dynamic>.from(entry))
        : null;
  }

  /// 프로젝트 소요 시간 보고 — [from]·[to]는 'YYYY-MM-DD'(안 주면 이번 달).
  Future<ProjectTimeReport> fetchTimeReport(
    String projectId, {
    String? from,
    String? to,
  }) async {
    final query = [
      if (from != null) 'from=$from',
      if (to != null) 'to=$to',
    ].join('&');
    return ProjectTimeReport.fromJson(
      await _get(
            '/api/projects/$projectId/time-report${query.isEmpty ? '' : '?$query'}',
          )
          as Map<String, dynamic>,
    );
  }

  // ── 즐겨찾기한 파일 ──────────────────────────────────────────────────

  /// 내가 즐겨찾기한 첨부들의 메시지 id — 파일 모아보기가 별 표시와 정렬에 쓴다.
  /// (한 메시지에 사진이 여러 장이면 그중 하나만 담아도 그 메시지가 들어온다.)
  /// 즐겨찾기한 첨부들 — [favoriteFileKey] 형태로 돌려준다(한 메시지에 파일이 여러 개일 수
  /// 있어서 메시지 id만으로는 어느 파일인지 모른다).
  Future<Set<String>> fetchFavoriteFileKeys() async {
    final list = await _get('/api/favorite-files') as List;
    return {
      for (final e in list.cast<Map<String, dynamic>>())
        favoriteFileKey(e['messageId'] as String, e['fileName'] as String?),
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

  /// 만료된 첨부 링크(/files/<토큰>)를 새로 받는다 — 서버가 내가 들어 있는 방의 첨부일 때만
  /// 새 링크(/files/<토큰>)를 준다(server/src/fileResign.js).
  Future<String> resignFileUrl(String filePath) async {
    final res =
        await _post('/api/files/resign', {'url': filePath})
            as Map<String, dynamic>;
    return res['url'] as String;
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

  /// 새 토픽 — 만든 사람만 멤버(토픽 관리자)로 들어가고, [memberIds]를 주면 그 사람들도 같이
  /// 넣는다. [autoInvite]/[quietLeave]를 안 주면 서버 기본값(자동 초대 끔, 조용히 나가기는 보드
  /// 뷰만 켬)을 쓴다. [folderId]는 내 토픽 폴더 — 주면 새 토픽을 그 폴더에 바로 넣는다.
  Future<Room> createTopic({
    required String teamId,
    required String name,
    String? description,
    bool isPublic = true,
    TopicViewMode viewMode = TopicViewMode.chat,
    bool readOnly = false,
    bool? autoInvite,
    bool? quietLeave,
    String? folderId,
    List<String>? memberIds,
  }) async {
    return Room.fromJson(
      await _post('/api/rooms', {
            'teamId': teamId,
            'type': 'topic',
            'name': name,
            if (description != null && description.isNotEmpty)
              'description': description,
            'isPublic': isPublic,
            'viewMode': viewMode.wire,
            'readOnly': readOnly,
            'autoInvite': ?autoInvite,
            'quietLeave': ?quietLeave,
            'folderId': ?folderId,
            if (memberIds != null && memberIds.isNotEmpty)
              'memberIds': memberIds,
          })
          as Map<String, dynamic>,
    );
  }

  /// 토픽 정보 변경(토픽을 관리할 수 있는 사람만) — 준 값만 바꾼다. 설명을 지우려면 빈 문자열.
  /// 보기 방식은 바꿀 수 없다. 비공개로 바꾸면 서버가 자동 초대를 끈다.
  Future<Room> updateTopic(
    String roomId, {
    String? name,
    String? description,
    bool? isPublic,
    bool? readOnly,
    bool? autoInvite,
    bool? quietLeave,
  }) async {
    return Room.fromJson(
      await _patch('/api/rooms/$roomId', {
            'name': ?name,
            'description': ?description,
            'isPublic': ?isPublic,
            'readOnly': ?readOnly,
            'autoInvite': ?autoInvite,
            'quietLeave': ?quietLeave,
          })
          as Map<String, dynamic>,
    );
  }

  /// 토픽 보관/보관 해제(토픽을 관리할 수 있는 사람만).
  Future<Room> setTopicArchived(String roomId, bool archived) async {
    return Room.fromJson(
      await _post('/api/rooms/$roomId/archive', {'archived': archived})
          as Map<String, dynamic>,
    );
  }

  /// 토픽 삭제(토픽을 관리할 수 있는 사람만) — 메시지·파일까지 전부 지워져 되돌릴 수 없다.
  /// 멤버 전원에게 room:removed(reason 'deleted')가 간다.
  Future<void> deleteTopic(String roomId) async {
    await _delete('/api/rooms/$roomId');
  }

  /// 멤버 내보내기(토픽을 관리할 수 있는 사람만) — 내보낸 뒤의 토픽을 돌려준다. 내보내진
  /// 사람에게는 room:removed(reason 'kicked')가 간다.
  Future<Room> kickTopicMembers(String roomId, List<String> userIds) async {
    return Room.fromJson(
      await _post('/api/rooms/$roomId/kick', {'userIds': userIds})
          as Map<String, dynamic>,
    );
  }

  /// 토픽 관리자를 [userIds]로 통째로 바꾼다(한 명 이상, 정회원 이상 멤버만).
  Future<Room> setTopicAdmins(String roomId, List<String> userIds) async {
    return Room.fromJson(
      await _put('/api/rooms/$roomId/admins', {'userIds': userIds})
          as Map<String, dynamic>,
    );
  }

  /// 토픽 목록의 내 폴더들(개인 설정, 팀별) — 순서대로.
  Future<List<TopicFolder>> fetchTopicFolders(String teamId) async {
    final list =
        await _get(
              '/api/rooms/folders?teamId=${Uri.encodeQueryComponent(teamId)}',
            )
            as List;
    return list
        .map((e) => TopicFolder.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<TopicFolder> createTopicFolder(String teamId, String name) async {
    return TopicFolder.fromJson(
      await _post('/api/rooms/folders', {'teamId': teamId, 'name': name})
          as Map<String, dynamic>,
    );
  }

  Future<TopicFolder> updateTopicFolder(
    String folderId, {
    String? name,
    bool? collapsed,
  }) async {
    return TopicFolder.fromJson(
      await _patch('/api/topic-folders/$folderId', {
            'name': ?name,
            'collapsed': ?collapsed,
          })
          as Map<String, dynamic>,
    );
  }

  /// 폴더만 지운다 — 안의 토픽은 폴더 밖 목록으로 돌아간다.
  Future<void> deleteTopicFolder(String folderId) async {
    await _delete('/api/topic-folders/$folderId');
  }

  /// 내 폴더 순서를 [folderIds] 순서(그 팀의 내 폴더 전부)로 바꾼다.
  Future<void> reorderTopicFolders(
    String teamId,
    List<String> folderIds,
  ) async {
    await _put('/api/topic-folders/order', {
      'teamId': teamId,
      'folderIds': folderIds,
    });
  }

  /// 토픽을 내 폴더 [folderId]에 넣는다. null이면 어느 폴더에서든 뺀다.
  Future<void> moveTopicToFolder(String roomId, String? folderId) async {
    await _put('/api/rooms/$roomId/folder', {'folderId': folderId});
  }

  /// 새 그룹채팅 — [description](설명, 300자까지)은 비어 있으면 안 보낸다.
  Future<Room> createGroup({
    required String teamId,
    String? name,
    String? description,
    required List<String> memberIds,
    // 'members'(기본, 안 보내도 됨) | 'initial' | 'emoji' | 'photo' — 새 그룹채팅 만들기의
    // 아이콘 선택(group_icon_picker.dart). 'emoji'면 iconEmoji, 'photo'면 iconUrl(업로드 응답의
    // URL)이 필요하고, iconColor는 initial·emoji의 배경색(선택).
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
            if (description != null && description.isNotEmpty)
              'description': description,
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

  /// 그룹채팅 정보 변경(그 방 멤버인 정회원 이상) — 준 값만 보낸다. 이름·설명은 빈 문자열이면
  /// 지운다(이름을 지우면 멤버 이름으로 보인다). 아이콘을 바꿀 땐 [iconType]과 그 모양에 필요한 값을
  /// 같이 준다(createGroup과 같은 규칙, 'members'면 아이콘을 지운다). 바뀐 방은 room:created로도 퍼진다.
  Future<Room> updateGroupInfo(
    String roomId, {
    String? name,
    String? description,
    String? iconType,
    String? iconEmoji,
    String? iconColor,
    String? iconUrl,
  }) async {
    return Room.fromJson(
      await _patch('/api/rooms/$roomId', {
            'name': ?name,
            'description': ?description,
            'iconType': ?iconType,
            'iconEmoji': ?iconEmoji,
            'iconColor': ?iconColor,
            'iconUrl': ?iconUrl,
          })
          as Map<String, dynamic>,
    );
  }

  /// 그 팀의 나와의 대화 — 없으면 서버가 만들어서라도 돌려준다(멱등, POST /rooms/self).
  Future<Room> openSelfRoom(String teamId) async {
    return Room.fromJson(
      await _post('/api/rooms/self', {'teamId': teamId})
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

  // ---- 메시지 예약 발송(server/src/scheduledMessages.js) — 나만 보고 바꿀 수 있다 ----

  /// 그 팀에서 내가 예약한 메시지(발송 실패 먼저, 그다음 발송 시각 순). [roomId]를 주면 그 방만.
  Future<List<ScheduledMessage>> fetchScheduledMessages(
    String teamId, {
    String? roomId,
  }) async {
    final query = StringBuffer(
      '/api/scheduled-messages?teamId=${Uri.encodeQueryComponent(teamId)}',
    );
    if (roomId != null) {
      query.write('&roomId=${Uri.encodeQueryComponent(roomId)}');
    }
    final list = await _get(query.toString()) as List;
    return list
        .map((e) => ScheduledMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 예약 만들기 — [title]은 보드 뷰 토픽의 게시글 제목(그 밖엔 비워 둔다), [attachments]는 이미
  /// 올린 첨부(채팅 입력칸과 같은 모양), [sendAt]은 15분 단위의 앞으로 90일 안.
  Future<ScheduledMessage> createScheduledMessage({
    required String roomId,
    String? title,
    required String text,
    List<TextFormatRun>? textFormat,
    List<Mention>? mentions,
    List<UploadedAttachment> attachments = const [],
    required DateTime sendAt,
  }) async {
    return ScheduledMessage.fromJson(
      await _post('/api/scheduled-messages', {
            'roomId': roomId,
            if (title != null && title.isNotEmpty) 'title': title,
            'text': text,
            'textFormat': ?textFormatToJson(textFormat),
            'mentions': ?mentionsToJson(mentions),
            if (attachments.isNotEmpty)
              'attachments': [for (final a in attachments) a.toPayload()],
            'sendAt': sendAt.millisecondsSinceEpoch,
          })
          as Map<String, dynamic>,
    );
  }

  /// 예약 고치기 — 준 값만 바꾸고, 발송 실패였어도 다시 '예약됨'이 된다. [text]를 주면 [textFormat]도
  /// 늘 같이 보낸다(null이면 서식을 지운다 — 옛 서식이 새 글과 어긋나지 않게). 제목을 지우려면 빈
  /// 문자열, 첨부를 모두 빼려면 빈 목록.
  Future<ScheduledMessage> updateScheduledMessage(
    String id, {
    String? roomId,
    String? title,
    String? text,
    List<TextFormatRun>? textFormat,
    List<Mention>? mentions,
    List<UploadedAttachment>? attachments,
    DateTime? sendAt,
  }) async {
    return ScheduledMessage.fromJson(
      await _patch('/api/scheduled-messages/$id', {
            'roomId': ?roomId,
            'title': ?title,
            if (text != null) ...{
              'text': text,
              'textFormat': textFormatToJson(textFormat),
              // 글을 바꿀 때는 멘션도 늘 같이 보낸다(textFormat과 같은 이유 — 옛 구간이 새 글과 어긋나지 않게).
              'mentions': mentionsToJson(mentions) ?? [],
            },
            if (attachments != null)
              'attachments': [for (final a in attachments) a.toPayload()],
            if (sendAt != null) 'sendAt': sendAt.millisecondsSinceEpoch,
          })
          as Map<String, dynamic>,
    );
  }

  /// 예약 취소 — 행이 지워진다.
  Future<void> deleteScheduledMessage(String id) async {
    await _delete('/api/scheduled-messages/$id');
  }

  /// 지금 보내기 — 보내진 메시지 id들을 돌려준다. 보내지 못하면 서버가 그 예약을 '발송 실패'(사유와
  /// 함께)로 바꾸고, 그 사유로 [ApiException]이 난다.
  Future<List<String>> sendScheduledMessageNow(String id) async {
    final body = await _post('/api/scheduled-messages/$id/send-now', const {});
    final ids = body is Map ? body['messageIds'] : null;
    return ids is List ? ids.whereType<String>().toList() : const [];
  }

  /// 상대 기기의 서명 검증키(비밀 대화 핸드셰이크의 임시 공개키 서명을 확인하는 데 씀)와 그 기기의 주인. 서버의 말이라
  /// 그대로 믿지 않는다 — 호출하는 쪽(SecretSessionManager)이 주인이 대화 상대와 같은지 보고, 처음 본 기기일 때만
  /// 묻고 그 뒤로는 고정해 둔 키를 쓴다(secret_peer_store.dart). 모양이 틀린 응답은 ApiException.
  Future<({String userId, String signingPublicKey})>
  fetchDeviceSigningPublicKey(String deviceId) async {
    final body = await _get(
      '/api/devices/${Uri.encodeComponent(deviceId)}/public-key',
    );
    final userId = body is Map ? body['userId'] : null;
    final key = body is Map ? body['signingPublicKey'] : null;
    if (userId is! String || key is! String) {
      throw ApiException(tr('상대 기기 정보를 확인할 수 없습니다.'));
    }
    return (userId: userId, signingPublicKey: key);
  }

  /// 비밀 대화(E2EE)용 기기 신원 등록(멱등 — 같은 deviceId면 공개키만 갱신). 개인키는 절대 여기
  /// 담기지 않는다(device_identity.dart 참고). 서버가 이 기기에 묶은 새 토큰 쌍을 주면 돌려준다("내 기기"에서 이 기기만
  /// 로그아웃시킬 수 있게 — server/src/devices.js). 예전 서버면 null.
  Future<({String accessToken, String refreshToken})?> registerDevice({
    required String deviceId,
    String? name,
    required String identityPublicKey,
    required String signingPublicKey,
  }) async {
    final res = await _send(
      () => _client.post(
        _uri('/api/devices'),
        headers: {..._authHeaders, 'Content-Type': 'application/json'},
        body: jsonEncode({
          'deviceId': deviceId,
          'name': ?name,
          'identityPublicKey': identityPublicKey,
          'signingPublicKey': signingPublicKey,
          // 기기 종류 — PC 앱이 켜져 있으면 PC 브라우저로는 웹 푸시를 보내지 않는 데 쓴다(device_kind.dart).
          'kind': ?deviceKind(),
        }),
      ),
    );
    if (res.statusCode == 409) throw const DeviceOwnedByOtherException();
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      throw ApiException(
        (decoded is Map ? decoded['error'] as String? : null) ??
            tr('요청이 실패했습니다.'),
        statusCode: res.statusCode,
      );
    }
    final tokens = decoded is Map ? decoded['tokens'] : null;
    if (tokens is! Map) return null;
    final access = tokens['accessToken'];
    final refresh = tokens['refreshToken'];
    if (access is! String || refresh is! String) return null;
    return (accessToken: access, refreshToken: refresh);
  }

  /// 내 기기 목록("로그인한 기기") — 로그아웃시킨 기기도 `revoked`로 같이 온다. [currentDeviceId]는 이 앱의 기기 id.
  Future<List<MyDevice>> fetchMyDevices({String? currentDeviceId}) async {
    final list = await _get('/api/devices') as List;
    return [
      for (final d in list)
        MyDevice.fromJson(
          (d as Map).cast<String, dynamic>(),
          currentId: currentDeviceId,
        ),
    ];
  }

  /// 기기 하나를 로그아웃시킨다 — 그 기기의 토큰·소켓·푸시가 끊긴다.
  Future<void> logoutDevice(String deviceId) async {
    await _delete('/api/devices/${Uri.encodeComponent(deviceId)}');
  }

  /// 이 기기 말고 모든 기기에서 로그아웃 — 이 기기에 묶인 새 토큰 쌍과 로그아웃시킨 기기 수.
  Future<({String accessToken, String refreshToken, int revokedCount})>
  logoutOtherDevices({String? deviceId}) async {
    final body =
        await _post('/api/devices/logout-others', {'deviceId': ?deviceId})
            as Map;
    return (
      accessToken: body['accessToken'] as String,
      refreshToken: body['refreshToken'] as String,
      revokedCount: (body['revokedCount'] as num?)?.toInt() ?? 0,
    );
  }

  /// FCM 토큰을 등록/갱신한다(안드로이드 전용). null을 보내면(로그아웃 등) 서버가 토큰을
  /// 지워서 더 이상 이 기기로 푸시를 안 보낸다.
  Future<void> registerFcmToken(String deviceId, String? token) async {
    await _patch('/api/devices/$deviceId/fcm-token', {'token': token});
  }

  /// 웹 푸시 구독(endpoint·keys)을 등록/갱신한다(웹 전용 — FCM 토큰의 웹판). null이면(로그아웃 등)
  /// 서버가 지워서 더 이상 이 브라우저로 푸시를 안 보낸다.
  Future<void> registerWebPushSubscription(
    String deviceId,
    Map<String, dynamic>? subscription,
  ) async {
    await _patch('/api/devices/$deviceId/web-push', {
      'subscription': subscription,
    });
  }

  /// rooms.teamId는 서버에서 NOT NULL이라 비밀 대화 방도 어느 팀인가 하나를 걸어야 한다
  /// (그 팀 멤버인지는 나만 확인받는다 — 상대는 어느 팀 소속이든 상관없다, server/src/secretChats.js).
  /// [initiatorContextSignature]는 맥락 서명(v2 — secret_chat_crypto.dart). 서버는 이 상대와 이미 진행 중인 비밀
  /// 대화가 있으면 새로 만들지 않고 그 방을 돌려준다(200) — [created]가 false면 서버가 이번 임시키를 받지 않은
  /// 것이라, 이 임시키로 수락을 기다리면 안 된다(서버는 그 방의 원래 임시키로 상대에게 보냈다). [protocol]은 이 앱이 아는
  /// 비밀 대화 규약 번호(새 규약 v3 — 서버가 초대에 initiatorProtocol로 실어 상대에게 넘긴다, 예전 서버는 무시한다).
  Future<({Room room, bool created})> startSecretChat({
    required String targetUserId,
    required String deviceId,
    required String initiatorEphemeralPublicKey,
    required String initiatorEphemeralSignature,
    String? initiatorContextSignature,
    int? protocol,
    required String teamId,
  }) async {
    final res = await _send(
      () => _client.post(
        _uri('/api/secret-chats'),
        headers: {..._authHeaders, 'Content-Type': 'application/json'},
        body: jsonEncode({
          'targetUserId': targetUserId,
          'deviceId': deviceId,
          'initiatorEphemeralPublicKey': initiatorEphemeralPublicKey,
          'initiatorEphemeralSignature': initiatorEphemeralSignature,
          'initiatorContextSignature': ?initiatorContextSignature,
          'protocol': ?protocol,
          'teamId': teamId,
        }),
      ),
    );
    final decoded = _decodeSecretChatBody(res);
    if (res.statusCode >= 400) throw ApiException(_secretChatError(decoded));
    if (decoded is! Map<String, dynamic>) {
      throw ApiException(tr('요청이 실패했습니다.'));
    }
    return (room: Room.fromJson(decoded), created: res.statusCode == 201);
  }

  /// 수락 — 서버가 받지 않으면(4xx) [SecretChatRefusedException]. [responderContextSignature]는 맥락 서명(v2).
  Future<void> acceptSecretChat({
    required String roomId,
    required String deviceId,
    required String responderEphemeralPublicKey,
    required String responderEphemeralSignature,
    String? responderContextSignature,
  }) async {
    final res = await _send(
      () => _client.post(
        _uri('/api/secret-chats/$roomId/accept'),
        headers: {..._authHeaders, 'Content-Type': 'application/json'},
        body: jsonEncode({
          'deviceId': deviceId,
          'responderEphemeralPublicKey': responderEphemeralPublicKey,
          'responderEphemeralSignature': responderEphemeralSignature,
          'responderContextSignature': ?responderContextSignature,
        }),
      ),
    );
    if (res.statusCode < 400) return;
    final message = _secretChatError(_decodeSecretChatBody(res));
    if (res.statusCode < 500) throw SecretChatRefusedException(message);
    throw ApiException(message);
  }

  /// 비밀 대화 응답 본문(JSON이 아니면 null — 프록시 오류 화면 등).
  static Object? _decodeSecretChatBody(http.Response res) {
    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      return null;
    }
  }

  static String _secretChatError(Object? body) =>
      (body is Map ? body['error'] as String? : null) ?? tr('요청이 실패했습니다.');

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

  /// 내가 건 비밀 대화의 수락(secret:accepted)을 놓쳤을 때(초대해 두고 앱을 끈 사이 상대가 수락함) 그 수락 정보를 다시
  /// 받는다 — 소켓 이벤트와 같은 모양. 아직 수락되지 않았거나(404) 내가 건 대화가 아니면(403) 던진다.
  Future<SecretAcceptedEvent> fetchSecretAccepted(String roomId) async {
    return SecretAcceptedEvent.fromJson(
      await _get('/api/secret-chats/$roomId/accepted') as Map<String, dynamic>,
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

  /// 그룹채팅 → 토픽 전환(정회원 이상, 되돌릴 수 없다) — 비공개 토픽이 되고 전환한 사람이 토픽 관리자가 된다.
  /// 바뀐 방은 room:created로도 퍼진다.
  Future<Room> convertGroupToTopic(
    String roomId, {
    required String name,
    String? description,
  }) async {
    return Room.fromJson(
      await _post('/api/rooms/$roomId/convert-to-topic', {
            'name': name,
            'description': description ?? '',
          })
          as Map<String, dynamic>,
    );
  }

  /// 여러 토픽·그룹채팅에 한 번에 초대(정회원 이상) — 방별 결과(부분 성공 허용)를 요청한 방 순서대로 돌려준다.
  Future<List<RoomInviteResult>> inviteBulk(
    String teamId,
    List<String> userIds,
    List<String> roomIds,
  ) async {
    final json =
        await _post('/api/rooms/invite-bulk', {
              'teamId': teamId,
              'userIds': userIds,
              'roomIds': roomIds,
            })
            as Map<String, dynamic>;
    return [
      for (final r in (json['results'] as List? ?? const []))
        RoomInviteResult.fromJson(r as Map<String, dynamic>),
    ];
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

  /// 댓글 한 건(GET /api/comments/:id) — [fetchMessage]와 같은 용도·규칙(1:1 "진짜 나가기" 이전은 부모 메시지로
  /// 따진다). 파일 댓글이면 서명된 파일 칸까지 온다.
  Future<Comment> fetchComment(String commentId) async {
    return Comment.fromJson(
      await _get('/api/comments/$commentId') as Map<String, dynamic>,
    );
  }

  /// [text] 없이 첨부만(이미지/파일) 다는 댓글도 가능하다 — 그때는 [type]과 [fileUrl] 등을 채워서 호출.
  Future<Comment> addComment(
    String messageId, {
    String? text,
    List<TextFormatRun>? textFormat,
    List<Mention>? mentions,
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
            'mentions': ?mentionsToJson(mentions),
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
    List<Mention>? mentions,
  }) async {
    return Comment.fromJson(
      await _patch('/api/comments/$commentId', {
            'text': text,
            'textFormat': ?textFormatToJson(textFormat),
            // 수정할 때는 빈 목록도 보낸다 — 멘션을 모두 지웠다는 뜻(안 보내면 서버가 이전 것을 유지할 수 있다).
            if (mentions != null) 'mentions': mentionsToJson(mentions) ?? [],
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
    List<Mention>? mentions,
    // 사진·파일 메시지에서 지울 첨부 id들(서버가 내려준 attachments[].id). 글 메시지엔 안 보낸다.
    List<String>? removeAttachmentIds,
  }) async {
    return Message.fromJson(
      await _patch('/api/messages/$messageId', {
            'text': text,
            'textFormat': ?textFormatToJson(textFormat),
            if (mentions != null) 'mentions': mentionsToJson(mentions) ?? [],
            if (removeAttachmentIds != null && removeAttachmentIds.isNotEmpty)
              'removeAttachmentIds': removeAttachmentIds,
          })
          as Map<String, dynamic>,
    );
  }

  /// [editMessage]와 같지만 본문을 그대로 — 보내기 대기열이 저장해 둔 고치기(글·서식·멘션 JSON)를 보낼 때.
  Future<Message> editMessageBody(
    String messageId,
    Map<String, dynamic> body,
  ) async => Message.fromJson(
    await _patch('/api/messages/$messageId', body) as Map<String, dynamic>,
  );

  Future<void> deleteMessage(String messageId) async {
    await _delete('/api/messages/$messageId');
  }

  /// 파일 하나를 지운다(업로드한 본인 또는 팀 관리자) — 소프트 삭제라 메시지와 댓글은 그대로 남고, 지운 자리는
  /// "삭제된 파일입니다"로 바뀐다. [attachmentId]는 첨부 id(첨부 하나짜리 옛 메시지는 메시지 id).
  /// 방 멤버에게는 message:edited로 퍼진다.
  Future<void> deleteMessageFile(String messageId, String attachmentId) async {
    await _delete('/api/messages/$messageId/attachments/$attachmentId');
  }

  /// 보드 게시글 수정(작성자만 — 게시글은 팀의 수정 가능 시간 제한을 받지 않는다). 첨부는
  /// 바꿀 수 없다. 다른 멤버에게는 message:edited로 퍼진다.
  Future<Message> editPost(
    String messageId, {
    required String title,
    required String text,
    List<TextFormatRun>? textFormat,
    List<Mention>? mentions,
    // 말머리 — 바꿀 때만 [setCategory]를 켜고 [categoryId](null이면 빼기)를 보낸다.
    bool setCategory = false,
    String? categoryId,
  }) async {
    return Message.fromJson(
      await _patch('/api/messages/$messageId', {
            'title': title,
            'text': text,
            'textFormat': ?textFormatToJson(textFormat),
            if (mentions != null) 'mentions': mentionsToJson(mentions) ?? [],
            if (setCategory) 'categoryId': categoryId,
          })
          as Map<String, dynamic>,
    );
  }

  /// 보드 게시글 고정/해제(토픽을 관리할 수 있는 사람만) — 결과는 message:edited로도 퍼진다.
  Future<Message> setPostPinned(String messageId, bool pinned) async {
    return Message.fromJson(
      await _post('/api/messages/$messageId/pin', {'pinned': pinned})
          as Map<String, dynamic>,
    );
  }

  /// 보드 게시글 필독 지정/해제(토픽을 관리할 수 있는 사람만) — 지정하면 멤버에게 "[필독] 제목" 알림, 결과는 message:edited로도 퍼진다.
  Future<Message> setPostMustRead(String messageId, bool mustRead) async {
    return Message.fromJson(
      await _post('/api/messages/$messageId/must-read', {'mustRead': mustRead})
          as Map<String, dynamic>,
    );
  }

  /// 보드 게시글을 열었다 — 서버가 처음 연 시각만 남긴다(쓴 사람은 남기지 않음).
  Future<void> markPostRead(String messageId) async {
    await _post('/api/messages/$messageId/post-read', const {});
  }

  /// 보드 게시글 읽음 확인 — 공지 읽음 확인과 같은 모양(읽은 사람은 먼저 읽은 순, 쓴 사람은 늘 읽음).
  Future<AnnouncementReaders> fetchPostReaders(String messageId) async =>
      AnnouncementReaders.fromJson(
        (await _get('/api/messages/$messageId/readers') as Map)
            .cast<String, dynamic>(),
      );

  /// 이 보드에서 내가 아직 안 읽은 필독 게시글 — 최근 지정순(보드 위 "필독 안 읽음 N").
  Future<List<UnreadMustRead>> fetchUnreadMustRead(String roomId) async {
    final list = await _get('/api/rooms/$roomId/must-read') as List;
    return [
      for (final e in list)
        if (e is Map && e['id'] is String)
          (id: e['id'] as String, title: e['title'] as String? ?? ''),
    ];
  }

  /// 보드 뷰 토픽의 말머리 목록을 통째로 바꾼다(토픽을 관리할 수 있는 사람만) — 새 말머리는 id 없이 보낸다.
  Future<Room> updateBoardCategories(
    String roomId,
    List<BoardCategory> categories,
  ) async {
    return Room.fromJson(
      await _patch('/api/rooms/$roomId', {
            'boardCategories': [for (final c in categories) c.toJson()],
          })
          as Map<String, dynamic>,
    );
  }

  /// 보드의 고정된 게시글(삭제된 것 제외) — 게시글 작성 시각 최신순, 댓글 포함.
  Future<List<Message>> fetchPinnedPosts(String roomId) async {
    final list = await _get('/api/rooms/$roomId/pinned-posts') as List;
    return list
        .map((e) => Message.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ── 투표 ──────────────────────────────────────────────────────────────

  /// 투표를 만든다 — 응답은 방에 뿌려진 메시지(type 'poll'). 목록 반영은 message:new로 오지만,
  /// 응답도 그대로 돌려준다. [attachments]는 보드 뷰 토픽에서만 허용된다(서버가 다시 검사한다).
  Future<Message> createPoll(
    String roomId, {
    required String title,
    String? description,
    required List<String> options,
    bool anonymous = false,
    bool multiple = false,
    required DateTime closesAt,
    List<UploadedAttachment> attachments = const [],
  }) async {
    return Message.fromJson(
      await _post('/api/rooms/$roomId/polls', {
            'title': title,
            'description': ?description,
            'options': options,
            'anonymous': anonymous,
            'multiple': multiple,
            'closesAt': closesAt.millisecondsSinceEpoch,
            if (attachments.isNotEmpty)
              'attachments': [for (final u in attachments) u.toPayload()],
          })
          as Map<String, dynamic>,
    );
  }

  /// 투표하기·다시 투표하기 — 내 표를 [optionIds]로 통째로 바꾼다(빈 목록이면 내 표를 취소).
  /// 응답은 내 기준의 poll 객체다.
  Future<Poll> votePoll(String pollId, List<String> optionIds) async {
    return Poll.fromJson(
      await _put('/api/polls/$pollId/vote', {'optionIds': optionIds})
          as Map<String, dynamic>,
    );
  }

  /// 메시지 공감(이모지 반응) — 내 공감을 [emoji]로(이미 다른 것이면 바꿈), null이면 뺀다. 바뀐 뒤의 전체 공감 목록을 돌려준다.
  Future<List<MessageReaction>> setMessageReaction(
    String messageId,
    String? emoji,
  ) async {
    final body =
        await _put('/api/messages/$messageId/reaction', {'emoji': emoji})
            as Map<String, dynamic>;
    return parseReactions(body['reactions']);
  }

  /// 메시지 리마인더 걸기("나중에 알림") — [remindAt]에 "나와의 대화"로 알려 준다.
  Future<MessageReminder> createMessageReminder(
    String messageId,
    DateTime remindAt,
  ) async => MessageReminder.fromJson(
    await _post('/api/messages/$messageId/reminders', {
          'remindAt': remindAt.millisecondsSinceEpoch,
        })
        as Map<String, dynamic>,
  );

  /// 검색 패널의 "할 일" 탭 — [teamId] 팀에서 내가 참여한 대화방의 할 일 중 제목·설명에 [q]가 든 것(최근 만든 순, 완료 포함).
  /// [roomId]·[assigneeId](담당자)로 좁힐 수 있다. 한 번에 [limit]건까지(서버 한도 100).
  Future<TodoPage> searchTodos({
    required String teamId,
    required String q,
    String? roomId,
    String? assigneeId,
    int limit = 100,
  }) async {
    final query = <String, String>{
      'teamId': teamId,
      'scope': 'team',
      'includeDone': 'true',
      'sort': 'created',
      'limit': '$limit',
      'q': q,
      'roomId': ?roomId,
      'assigneeId': ?assigneeId,
    };
    final qs = query.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return TodoPage.fromJson(
      Map<String, dynamic>.from(
        await requestJson('GET', '/api/todos?$qs') as Map,
      ),
    );
  }

  /// 직접 만든 리마인더 걸기(메뉴의 "리마인더") — [remindAt]에 [teamId] 팀의 "나와의 대화"로 [text]를 알려 준다.
  Future<MessageReminder> createReminder({
    required String text,
    required DateTime remindAt,
    required String teamId,
  }) async => MessageReminder.fromJson(
    await _post('/api/reminders', {
          'text': text,
          'remindAt': remindAt.millisecondsSinceEpoch,
          'teamId': teamId,
        })
        as Map<String, dynamic>,
  );

  /// 아직 울리지 않은 내 리마인더 — 울릴 시각 순.
  Future<List<MessageReminder>> fetchReminders() async => [
    for (final e in await _get('/api/reminders') as List)
      MessageReminder.fromJson(e as Map<String, dynamic>),
  ];

  /// 리마인더 취소.
  Future<void> deleteReminder(String id) async {
    await _delete('/api/reminders/$id');
  }

  /// 투표 일찍 마감(만든 사람·관리자) — 응답은 내 기준의 poll 객체다.
  Future<Poll> closePoll(String pollId) async {
    return Poll.fromJson(
      await _post('/api/polls/$pollId/close', const {}) as Map<String, dynamic>,
    );
  }

  /// 투표 즐겨찾기 켜기/끄기 — 서버가 확정한 값을 돌려준다.
  Future<bool> setPollFavorite(String pollId, bool favorite) async {
    final body =
        await _put('/api/polls/$pollId/favorite', {'favorite': favorite})
            as Map<String, dynamic>;
    return body['favorite'] as bool? ?? favorite;
  }

  Future<List<SearchResult>> search(
    String query, {
    required String teamId,
    String? roomId,
    String? senderId,
    DateTime? since,
    DateTime? until,
  }) async {
    final page = await searchPage(
      query,
      teamId: teamId,
      roomId: roomId,
      senderId: senderId,
      since: since,
      until: until,
    );
    return page.items;
  }

  /// 검색 패널용 — [search]에 탭([type]: message|poll|file), 파일 형식([fileKind], 파일 탭일 때),
  /// 정렬([newestFirst])을 더하고, 한도(limit)에 잘리기 전의 전체 건수([SearchPage.total])도 받는다
  /// (server/src/search.js, withTotal=1). 예전 서버처럼 배열만 오면 받은 개수를 전체 건수로 본다.
  Future<SearchPage> searchPage(
    String query, {
    required String teamId,
    String? roomId,
    String? senderId,
    DateTime? since,
    DateTime? until,
    String? type,
    String? fileKind,
    bool newestFirst = true,
    int? limit,
    bool allTeams = false,
  }) async {
    // allTeams면 teamId 대신 scope=all — 서버가 내가 속한 모든 팀에서 찾고 결과에 teamId·teamName을 붙인다.
    final params = StringBuffer(
      '/api/search?q=${Uri.encodeQueryComponent(query)}'
      '${allTeams ? '&scope=all' : '&teamId=${Uri.encodeQueryComponent(teamId)}'}'
      '&withTotal=1',
    );
    if (roomId != null) {
      params.write('&roomId=${Uri.encodeQueryComponent(roomId)}');
    }
    if (senderId != null) {
      params.write('&senderId=${Uri.encodeQueryComponent(senderId)}');
    }
    if (since != null) params.write('&since=${since.millisecondsSinceEpoch}');
    if (until != null) params.write('&until=${until.millisecondsSinceEpoch}');
    if (type != null) params.write('&type=${Uri.encodeQueryComponent(type)}');
    if (fileKind != null) {
      params.write('&fileKind=${Uri.encodeQueryComponent(fileKind)}');
    }
    if (!newestFirst) params.write('&order=asc');
    if (limit != null) params.write('&limit=$limit');
    final body = await _get(params.toString());
    final rawItems = body is Map ? body['items'] as List : body as List;
    final items = rawItems
        .map((e) => SearchResult.fromJson(e as Map<String, dynamic>))
        .toList();
    final total = body is Map ? (body['total'] as num?)?.toInt() : null;
    return SearchPage(items, total ?? items.length);
  }

  /// 검색 패널 "대화방" 탭 — 내가 멤버인 토픽·그룹채팅·채팅·나와의 대화를 이름으로 찾는다
  /// (server/src/search.js, GET /api/search/rooms). [allTeams]면 현재 팀이 아니라 내가 속한 모든 팀.
  /// 정렬은 마지막 활동순([newestFirst] = 최근 활동이 먼저).
  Future<RoomSearchPage> searchRoomsPage(
    String query, {
    required String teamId,
    bool allTeams = false,
    bool newestFirst = true,
    int? limit,
  }) async {
    final params = StringBuffer(
      '/api/search/rooms?q=${Uri.encodeQueryComponent(query)}'
      '${allTeams ? '&scope=all' : '&teamId=${Uri.encodeQueryComponent(teamId)}'}',
    );
    if (!newestFirst) params.write('&order=asc');
    if (limit != null) params.write('&limit=$limit');
    final body = await _get(params.toString()) as Map<String, dynamic>;
    final items = (body['items'] as List)
        .map((e) => RoomSearchResult.fromJson(e as Map<String, dynamic>))
        .toList();
    return RoomSearchPage(
      items,
      (body['total'] as num?)?.toInt() ?? items.length,
    );
  }

  /// 방(들)에 첨부된 이미지/파일 목록(files_screen.dart). roomId를 안 주면 내가 속한 모든
  /// 방을 가로지른다. 서버가 toMessageDto와 동일한 모양으로 내려주므로 Message.fromJson을
  /// 그대로 재사용한다(새 모델을 따로 만들 필요 없음).
  Future<List<Message>> fetchAttachments({
    required String teamId,
    String? roomId,
    String? senderId,
    String? category,
    String? query,
    DateTime? since,
    DateTime? until,
    bool newestFirst = true,
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
    if (query != null && query.trim().isNotEmpty) {
      parts.add('q=${Uri.encodeQueryComponent(query.trim())}');
    }
    if (since != null) parts.add('since=${since.millisecondsSinceEpoch}');
    if (until != null) parts.add('until=${until.millisecondsSinceEpoch}');
    if (!newestFirst) parts.add('order=asc');
    params.write(parts.join('&'));
    final list = await _get(params.toString()) as List;
    return list
        .map((e) => Message.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// "링크" 모아보기 — 지금 팀에서 내가 속한 방(비밀 대화 제외)에서 주고받은 http(s) 링크, 최신순.
  /// [roomId]를 주면 그 방만(server/src/links.js).
  Future<List<SharedLink>> fetchLinks({
    required String teamId,
    String? roomId,
    String? senderId,
    String? query,
    DateTime? since,
    DateTime? until,
    bool newestFirst = true,
  }) async {
    final parts = <String>['teamId=${Uri.encodeQueryComponent(teamId)}'];
    if (roomId != null) parts.add('roomId=${Uri.encodeQueryComponent(roomId)}');
    if (senderId != null) {
      parts.add('senderId=${Uri.encodeQueryComponent(senderId)}');
    }
    if (query != null && query.trim().isNotEmpty) {
      parts.add('q=${Uri.encodeQueryComponent(query.trim())}');
    }
    if (since != null) parts.add('since=${since.millisecondsSinceEpoch}');
    if (until != null) parts.add('until=${until.millisecondsSinceEpoch}');
    if (!newestFirst) parts.add('order=asc');
    final list = await _get('/api/links?${parts.join('&')}') as List;
    return list
        .map((e) => SharedLink.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ── 그림 이모티콘(server/src/stickers.js) ──

  /// 세트 전부(숨긴 것 포함 — 예전 메시지를 그리려고). [kind]는 'sticker'(기본, 채팅 선택창) |
  /// 'character'(프로필 사진 세트) — 서버가 그 종류만 걸러서 돌려줘서 둘이 안 섞인다.
  Future<List<ServerStickerPack>> fetchStickerPacks({
    String kind = 'sticker',
  }) async {
    final list = await _get('/api/stickers?kind=$kind') as List;
    return list
        .map((e) => ServerStickerPack.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 새 세트(서버 운영자만).
  Future<ServerStickerPack> createStickerPack(
    String name, {
    String kind = 'sticker',
  }) async {
    final json = await _post('/api/stickers/packs', {
      'name': name,
      'kind': kind,
    });
    return ServerStickerPack.fromJson(json as Map<String, dynamic>);
  }

  /// 세트 이름 바꾸기·숨기기(서버 운영자만).
  Future<void> updateStickerPack(
    String packId, {
    String? name,
    bool? hidden,
  }) async {
    await _patch('/api/stickers/packs/$packId', {
      'name': ?name,
      'hidden': ?hidden,
    });
  }

  /// 세트 삭제(서버 운영자만) — 이미 보낸 메시지의 그림은 계속 보인다.
  Future<void> deleteStickerPack(String packId) async {
    await _delete('/api/stickers/packs/$packId');
  }

  /// 그림 여러 장을 세트 맨 뒤에 올린다(서버 운영자만) — 파일 이름 순서대로 붙는다.
  Future<void> uploadStickers(String packId, List<XFile> files) async {
    final res = await _send(() async {
      final req =
          http.MultipartRequest(
              'POST',
              _uri('/api/stickers/packs/$packId/stickers'),
            )
            ..headers.addAll(_authHeaders)
            ..files.addAll([
              for (final f in files) await _multipartFile('files', f),
            ]);
      return http.Response.fromStream(await _client.send(req));
    });
    if (res.statusCode >= 400) {
      String message = tr('이모티콘을 올리지 못했습니다.');
      try {
        message =
            (jsonDecode(utf8.decode(res.bodyBytes)) as Map)['error']
                as String? ??
            message;
      } catch (_) {}
      throw ApiException(message);
    }
  }

  /// 한 장 숨기기/다시 보이기(서버 운영자만).
  /// [packId] 세트의 그림 [stickerIds]를 지운다("개별 삭제") — 지운 수를 돌려준다. 서버는 행과 파일을 남기고
  /// 표시만 해서 이미 보낸 메시지의 그림은 계속 보인다.
  Future<int> deleteStickers(String packId, List<String> stickerIds) async {
    final res =
        await _post('/api/stickers/packs/$packId/stickers/delete', {
              'ids': stickerIds,
            })
            as Map<String, dynamic>;
    return (res['deleted'] as num?)?.toInt() ?? 0;
  }

  Future<void> setStickerHidden(
    String packId,
    String stickerId,
    bool hidden,
  ) async {
    await _patch('/api/stickers/packs/$packId/stickers/$stickerId', {
      'hidden': hidden,
    });
  }

  /// [onProgress]/[cancelToken]을 안 넘기면 지금까지와 완전히 동일하게(단순 MultipartRequest)
  /// 동작한다. 둘 중 하나라도 넘기면, http 패키지에 내장 진행률 콜백이 없어서 요청 바디를 직접
  /// 스트리밍하며 바이트 수를 센다 — MultipartRequest가 만든 바디(finalize())를 그대로 다시
  /// StreamedRequest로 감싸 보낼 뿐이라 인증서 핀닝(_client 자체)은 그대로 유지된다. 취소는
  /// 그 파이프를 도중에 끊어(구독 취소 + sink를 끝까지 안 채우고 닫음) 요청을 미완성 상태로
  /// 만드는 방식이라 서버에 별도로 알릴 필요가 없다.
  Future<UploadResult> uploadFile(
    XFile file, {
    void Function(int sent, int total)? onProgress,
    UploadCancelToken? cancelToken,
  }) async {
    try {
      return await _uploadFile(
        file,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
    } catch (_) {
      // 취소로 요청을 도중에 끊어서 난 실패면 [UploadCancelledException]으로 알린다 — 입력칸들이 이걸로
      // "취소는 조용히 넘기고, 진짜 실패만 알린다"를 가른다.
      if (cancelToken?.isCancelled == true) throw UploadCancelledException();
      rethrow;
    }
  }

  /// 업로드할 파일 하나 — 경로 대신 XFile에서 스트림으로 읽어서 웹(브라우저가 준 바이트)과
  /// 네이티브(디스크 파일, 큰 파일도 메모리에 다 올리지 않음)가 같은 코드로 올린다.
  Future<http.MultipartFile> _multipartFile(String field, XFile file) async =>
      http.MultipartFile(
        field,
        file.openRead(),
        await file.length(),
        filename: file.name,
      );

  Future<UploadResult> _uploadFile(
    XFile file, {
    void Function(int sent, int total)? onProgress,
    UploadCancelToken? cancelToken,
  }) async {
    final res = await _send(() async {
      final req = http.MultipartRequest('POST', _uri('/api/upload'))
        ..headers.addAll(_authHeaders)
        ..files.add(await _multipartFile('file', file));

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
      throw ApiException((body['error'] as String?) ?? tr('업로드에 실패했습니다.'));
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
