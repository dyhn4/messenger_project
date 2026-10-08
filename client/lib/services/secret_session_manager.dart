import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../models/message.dart';
import '../models/room.dart';
import 'api_client.dart';
import 'chat_socket.dart';
import 'device_identity.dart';
import 'secret_chat_crypto.dart' as crypto;
import 'secret_key_store.dart';
import 'secret_peer_store.dart';
import 'secret_ratchet.dart';
import 'secret_room_lock.dart';

/// 보안 확인에 실패해 멈춘 비밀 대화로 보내려 할 때 — 화면에 그대로 보여 줄 문구를 담는다.
class SecretChatBlockedException extends ApiException {
  const SecretChatBlockedException()
    : super(
        '보안 확인에 실패해 멈춘 비밀 대화입니다. 이 비밀 대화를 끝내고 상대와 보안 코드를 비교한 뒤 새로 시작해 주세요.',
      );
}

/// 새 규약을 알리지 않은 초대(예전 앱이 걸었거나, 서버가 새 앱의 초대에서 새 규약 표시를 뺌)를 수락하려 할 때 — 이 기기는
/// 그런 초대를 받지 않는다([SecretSessionManager.offersCurrentProtocol]).
class SecretInviteOutdatedException extends ApiException {
  const SecretInviteOutdatedException()
    : super(
        '상대가 예전 버전의 앱으로 보낸 비밀 대화 요청이라 수락할 수 없습니다. 상대에게 앱을 업데이트한 뒤 다시 요청해 달라고 해 주세요.',
      );
}

/// 이 기기에 저장한 비밀 대화의 키 상태를 읽을 수 없을 때(저장소가 깨짐) 보내려 하면 — 더 이어 갈 수 없다.
class SecretChatBrokenException extends ApiException {
  const SecretChatBrokenException()
    : super('이 기기에 저장된 비밀 대화 키를 읽을 수 없어 보낼 수 없습니다. 이 비밀 대화를 끝내고 새로 시작해 주세요.');
}

/// 비밀 대화 글 하나가 놓이는 자리(보내는 쪽) — 새 규약(v3)은 이것을 암호문 안에 함께 넣어, 서버가 글을 다른 자리로
/// 옮겨 붙이면(메시지를 댓글로, 댓글을 다른 글 아래로, 다른 글의 수정으로) 받는 쪽이 알아채고 풀지 않는다
/// ([SecretTextSlot.accepts]). 예전 규약(v1)은 예전 앱이 읽어야 해서 넣지 않는다.
class SecretTextPlace {
  /// 메시지 — 새 글이면 [editOf]가 없고, 수정이면 고치는 메시지 id.
  const SecretTextPlace.message({this.editOf}) : kind = 'm', parentId = null;

  /// [parentId] 메시지의 댓글 — 수정이면 [editOf]가 고치는 댓글 id(그때는 원본 메시지를 몰라 [parentId]가 없어도 된다).
  const SecretTextPlace.comment({this.parentId, this.editOf}) : kind = 'c';

  /// 'm'(메시지)·'c'(댓글).
  final String kind;
  final String? parentId;
  final String? editOf;
}

/// 받은 비밀 대화 글이 서버가 보여 주는 자리 — 메시지 [id], 댓글이면 그 댓글 [id]와 원본 메시지 [parentId].
class SecretTextSlot {
  const SecretTextSlot.message(this.id) : kind = 'm', parentId = null;
  const SecretTextSlot.comment(this.id, this.parentId) : kind = 'c';

  final String kind;
  final String id;
  final String? parentId;

  /// 보낸 쪽이 적은 자리 [place]가 이 자리와 맞는지 — 종류가 같고, 수정이면 고치는 글이 이 글이며(원본 메시지를 적었으면
  /// 그것도 같아야 한다), 새 댓글이면 원본 메시지가 같아야 한다. 새 메시지의 id는 보낼 때 아직 없어서 묶지 못한다.
  bool accepts(SecretTextPlace place) {
    if (place.kind != kind) return false;
    final editOf = place.editOf;
    if (editOf != null) {
      return editOf == id &&
          (place.parentId == null || place.parentId == parentId);
    }
    return kind != 'c' || place.parentId == parentId;
  }
}

/// 새 규약(v3) 암호문 안의 글 — {t: 글, k: 종류, p: 원본 메시지, e: 고치는 글}.
String _wrapPlacedText(String text, SecretTextPlace? place) => jsonEncode({
  't': text,
  'k': place?.kind ?? 'm',
  'p': ?place?.parentId,
  'e': ?place?.editOf,
});

/// [_wrapPlacedText]의 반대 — 모양이 틀리면 null.
({String text, SecretTextPlace place})? _unwrapPlacedText(String raw) {
  try {
    final json = jsonDecode(raw);
    if (json is! Map) return null;
    final text = json['t'];
    final kind = json['k'];
    final parentId = json['p'];
    final editOf = json['e'];
    if (text is! String ||
        (parentId != null && parentId is! String) ||
        (editOf != null && editOf is! String)) {
      return null;
    }
    final SecretTextPlace place;
    if (kind == 'm') {
      if (parentId != null) return null;
      place = SecretTextPlace.message(editOf: editOf as String?);
    } else if (kind == 'c') {
      place = SecretTextPlace.comment(
        parentId: parentId as String?,
        editOf: editOf as String?,
      );
    } else {
      return null;
    }
    return (text: text, place: place);
  } on FormatException {
    return null;
  }
}

/// 핸드셰이크(초대 수락·수락 확인) 하나를 처리한 결과 — Session이 안내(토스트)를 고르는 데 쓴다.
enum SecretHandshakeOutcome {
  /// 확인을 마치고 세션 키를 만들었다.
  established,

  /// [established]인데, 상대가 이 기기가 예전에 보안 코드를 확인한 기기가 아닌 다른 기기로 맺었다 — 보안 코드를
  /// 다시 비교하라고 알린다.
  establishedOnChangedDevice,

  /// 이 기기와 상관없거나(내 다른 기기·이미 처리됨) 아직 처리할 수 없어 아무것도 하지 않았다.
  ignored,

  /// 보안 확인에 실패해 이 대화를 멈췄다 — 체인키는 만들지 않았다.
  blocked,
}

/// 상대 기기의 서명 검증키를 찾은 결과.
///  - 고정해 둔 키: [signingPublicKey]와 [pin]이 있다.
///  - 서버에 처음 물어 주인까지 확인한 키: [signingPublicKey]만 있다(서명을 확인한 뒤 고정한다).
///  - 확인 실패: [failure]가 있다. 고정해 둔 기록 때문에 실패했으면(다툼 중·깨짐) [pinInvolved] — 그 고정이 [pin].
class _PeerKey {
  _PeerKey.pinned(SecretDevicePin pinned)
    : signingPublicKey = pinned.signingPublicKey,
      pin = pinned,
      failure = null,
      pinInvolved = true;
  const _PeerKey.firstSeen(String this.signingPublicKey)
    : pin = null,
      failure = null,
      pinInvolved = false;
  const _PeerKey.failed(
    SecretBlockReason this.failure, {
    this.pin,
    this.pinInvolved = false,
  }) : signingPublicKey = null;

  final String? signingPublicKey;
  final SecretDevicePin? pin;
  final SecretBlockReason? failure;

  /// 이 기기에 그 기기의 고정 기록이 있었다(읽을 수 없었어도) — 멈출 때 "상대 기기 키 다시 받기" 대상으로 적는다.
  final bool pinInvolved;

  bool get pinned => pin != null && failure == null;
}

/// 비밀 대화(E2EE) 방 하나의 핸드셰이크·암복호화 상태 머신. 공유비밀/체인키 계산은 전부 여기서
/// 로컬로만 이뤄지고, 서버로는 공개키/서명만 나간다. Session이 메시지 송수신 경계에서 이
/// 매니저의 encryptForRoom/decryptForRoom을 호출하는 얇은 통합만 한다.
///
/// 규약(secret_chat_crypto.dart 머리말): 초대할 때 새 규약(v3 — 더블 래칫, secret_ratchet.dart)을 안다고 알리고,
/// 받는 쪽은 v3 맥락 서명으로 수락해 두 기기가 v3로 대화한다. 새 규약을 알리지 않은 초대는 받지 않는다 — 예전 앱의
/// 초대와 서버가 새 규약 표시를 뺀 초대를 가릴 수 없어서, 받으면 서버가 새 앱끼리의 대화도 예전 규약으로 낮출 수 있다
/// ([offersCurrentProtocol]). 그래서 새 앱끼리는 늘 v3다. 새 앱이 예전 앱에 건 대화(예전 앱이 예전 방식으로 수락)와 이
/// 업데이트 전에 맺은 대화는 예전 규약(v1 — 체인 하나를 함께 씀)을 그대로 쓰되, 대화가 깨지지 않게 이렇게만 고쳤다:
///  - 재키잉을 하지 않는다 — 제안하지도, 상대의 제안·수락에 응하지도 않는다. 예전 재키잉은 두 기기의 체인 위치가
///    조금만 어긋나도(제안이 메시지보다 먼저 도착 등) 양쪽 체인이 갈라져 대화가 영영 풀리지 않았다. 재키잉 없이도
///    메시지마다 체인키를 바꾸는 순방향 비밀성은 그대로다.
///  - 내가 막 보낸 메시지가 되돌아온 것은 봉투의 nonce로 알아본다(예전엔 번호로 알아봐서, 거의 동시에 같은 번호로 온
///    상대 메시지를 내 글로 보여 줬다). 같은 번호로 상대가 보낸 메시지는 내가 그 번호로 보낼 때 쓴 키로 푼다.
///  - 건너뛴 번호의 키를 남겨 두어 늦게 온 메시지(최신 페이지를 먼저 푼 히스토리 등)도 푼다. 풀지 못하면 체인을
///    밀지 않는다.
///
/// 서버를 믿지 않는다(S5): 상대 기기의 서명 검증키는 처음 본 기기일 때만 서버에 묻고(그 기기의 주인이 이 대화의
/// 상대인지 함께 확인), 그 뒤로는 이 기기에 고정해 둔 키만 쓴다(secret_peer_store.dart). 방마다 묶인 상대
/// 기기도 저장해 둔다(보안 코드·신뢰 안내에 쓴다). 핸드셰이크에서 서명이 고정한 키로 맞지 않거나, 이벤트가 방에 묶인
/// 상대가 아닌 사람·기기를 가리키면 세션 키를 만들지 않고 그 방을 멈춘다(되돌리는 방법은 없다 — 끝내고 새로 시작한
/// 뒤 보안 코드를 비교해야 한다).
class SecretSessionManager {
  final ApiClient _api;
  final DeviceIdentity _identity;
  final SecretKeyStore _keyStore;

  /// 로그인한 내 사용자 id — 맥락 서명(누가 누구에게)을 만들고 확인하는 데 쓴다.
  final String? _myUserId;

  /// 방 id로 지금 아는 방 정보(멤버·핸드셰이크 양쪽 기기)를 찾는다 — Session의 방 목록. 초대·수락을 보낸 사람이
  /// 그 방의 상대가 맞는지 보고, 이 업데이트 전에 성립한 대화를 상대 기기에 묶는 데 쓴다.
  final Room? Function(String roomId)? _lookupRoom;

  /// 방의 신뢰 상태([trustOf])가 바뀌었을 때 — Session이 화면(방 안내·더보기 메뉴)을 다시 그리게 한다.
  void Function(String roomId)? onTrustChanged;

  /// 처리하던 방이 아닌 다른 방들을 함께 멈췄을 때(서버가 같은 상대 기기를 다른 키로 알려 와 그 기기와의 대화를 모두
  /// 멈춤) — 처리하던 방은 결과([SecretHandshakeOutcome.blocked])로 알리고, 함께 멈춘 방은 이걸로 알린다(Session이
  /// 토스트로 알린다 — 그 방을 보고 있지 않아도 알게).
  void Function(List<String> roomIds)? onRoomsBlocked;

  /// 저장소에서 읽은 방 상태(묶인 상대·보안 상태·규약·키 상태)를 메모리에 들고 있어도 되는지 — 이 기기의 저장소를 이
  /// 매니저만 쓸 때(PC·모바일 앱)만. 웹 앱은 같은 브라우저의 탭들이 저장소를 함께 써서, 들고 있으면 다른 탭이 바꾼 것을
  /// 모른 채 옛 상태로 보내고 덮어쓴다 — 웹에서는 매번 저장소에서 읽고, 방 줄도 탭 사이에서 지킨다([_inRoom]).
  static const _keepStateInMemory = !secretStorageSharedAcrossInstances;

  // 방 id → 묶인 상대 기기·보안 상태(저장소의 값을 한 번 읽어 들고 있는다 — 메시지마다 저장소를 읽지 않게).
  final Map<String, SecretRoomBinding> _bindings = {};
  final Map<String, SecretRoomSecurity> _securities = {};
  final Map<String, SecretRoomTrust> _trust = {};

  // 묶인 상대 기기가 없다고 읽은 방(예전 대화를 아직 묶지 못함 등) — 메시지마다 저장소를 다시 읽지 않게. 묶으면
  // ([_saveBinding]) 뺀다.
  final Set<String> _unboundRooms = {};

  // 방 정보로 상대 기기를 찾아 묶는 중인 방 — 같은 방을 동시에 두 번 묻지 않게.
  final Map<String, Future<SecretRoomBinding?>> _bootstraps = {};

  // 방마다 핸드셰이크·암복호화를 한 줄로 세운다 — 한 메시지가 체인 상태를 바꾸는 동안 다른 메시지가 옛 상태를 읽고
  // 덮어쓰면 같은 키를 두 번 쓰거나 체인이 어긋난다. 줄 안에서 다시 같은 방 줄을 서면 멈추므로, 줄 안의 도우미는 줄을
  // 서지 않는다(다른 방 줄을 기다리지도 않는다 — 웹 앱은 탭끼리 잠그는데, 서로의 방을 기다리면 둘 다 멈춘다).
  final Map<String, Future<void>> _roomQueues = {};

  // 방 id → 그 방 세션의 규약(새 규약 3, 예전 규약 1) — 세션이 있는 방만 적어 둔다(메시지마다 저장소를 읽지 않게).
  final Map<String, int> _protocols = {};

  // 방 id → 저장해 둔 래칫 상태(새 규약)·체인 상태와 남겨 둔 키(예전 규약). 이 기기에서 이 상태를 쓰는 것은 이 매니저뿐이라
  // 한 번 읽은 뒤로는 메시지마다 저장소를 다시 읽지 않는다(Windows 저장소는 읽을 때마다 파일 전체를 푼다 — 웹 앱은
  // 들고 있지 않는다, [_keepStateInMemory]). 저장에 성공한 값만 넣고, 저장하다 실패하면 빼서 다음에 저장소에서 다시 읽는다.
  final Map<String, SecretRatchetState> _ratchetStates = {};
  final Map<String, SecretChainState> _chainStates = {};
  final Map<String, List<SecretSkippedKey>> _v1Skipped = {};

  // "roomId|nonce" → 내가 보낸 평문·그 봉투(JSON 그대로)·시각(오래된 것부터). encryptForRoom은 전송 즉시 보내는 체인을
  // 한 칸 전진시켜 저장하는데(다음 메시지를 위해), 서버가 그 메시지를 내 소켓에도 그대로 되돌려주면(다른 멤버들과 동일하게
  // echo됨) 한 방향 래칫으로는 "뒤로" 못 감는다(의도된 동작 — 순방향 비밀성의 핵심). 그래서 내가 보낸 메시지만 여기 잠깐
  // 들고 있다가 돌아오면 이걸 돌려준다. 봉투마다 새로 뽑는 nonce(12바이트)로 찾고 봉투 전체가 같아야 준다 — 번호로 찾으면
  // 같은 번호로 온 상대 메시지를 내 글로 보여 주고, nonce만 보면 서버가 그 nonce에 다른 암호문을 붙여 새 메시지로 보내도
  // 내 글이 된다. 되돌아온 메시지를 평문 캐시에 메시지 id로 적으면 여기서는 뺀다(그 뒤로는 캐시가 준다). 끊긴 사이 늦게
  // 되돌아오는 경우를 위해 [_recentlySentLifetime] 동안은 들고 있고, [_maxRecentlySent]개를 넘으면 오래된 것부터 버린다.
  final Map<
    String,
    ({String text, String envelope, SecretTextPlace? place, DateTime at})
  >
  _recentlySentPlaintext = {};
  static const _maxRecentlySent = 256;
  static const _recentlySentLifetime = Duration(hours: 24);

  // 예전 규약(v1) — "roomId|epoch|n" → 내가 그 번호로 보낼 때 쓴 메시지 키·그 봉투의 nonce·시각. 예전 규약은 체인
  // 하나를 함께 써서, 상대가 거의 같은 때 같은 번호로 보낸 메시지도 같은 키다. 그 메시지가 오면 이걸로 푼다 — 내 봉투(같은
  // nonce)는 이 키로 풀지 않는다(서버가 내 메시지를 상대가 보낸 것처럼 되돌려 보내면 내 글이 상대 글로 보이게 된다).
  // 동시에 보낸 메시지는 곧 오므로 [_v1SentKeyLifetime] 동안 메모리에만 둔다(오래 남기면 기기가 털렸을 때 내가 보낸
  // 메시지를 풀 수 있다).
  final Map<String, ({List<int> key, String nonce, DateTime at})> _v1SentKeys =
      {};
  static const _v1SentKeyLifetime = Duration(minutes: 10);
  static const _maxV1SentKeys = 128;

  // 이번 실행에서 "새 규약으로 말함"을 이미 적은(또는 적혀 있던) 상대 기기 — 메시지마다 고정을 다시 읽지 않게.
  final Set<String> _v3ConfirmedDevices = {};

  bool _disposed = false;

  String _sentCacheKey(String roomId, String nonce) => '$roomId|$nonce';

  /// 로그아웃 등으로 버린 뒤에는 저장하지 않는다 — 새로 만든 매니저가 같은 방의 상태를 저장소에서 읽어 쓰는데, 버린
  /// 매니저가 하던 일이 뒤늦게 저장하면 그 상태를 되돌려 같은 키를 다시 쓰거나 대화가 어긋난다(방 줄은 매니저마다 따로라
  /// 서로를 기다리지 않는다). 버리기 전에 저장을 줄 세운 일은 저장소 줄(앱 전체에 하나)이 먼저 끝낸다.
  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('로그아웃해 버린 비밀 대화 매니저입니다.');
    }
  }

  /// [keyStore]는 테스트가 저장소를 바꿔 끼울 때만 준다. [userId]는 로그인한 내 id, [roomLookup]은 Session의 방
  /// 목록 — 핸드셰이크에 꼭 필요하다(평문 캐시만 다루는 곳에서는 없어도 된다). [acceptLegacyInvites]는 테스트가 이
  /// 업데이트 전에 맺은 예전 규약 대화를 두 매니저로 흉내 낼 때만 켠다(앱은 새 규약을 알리지 않은 초대를 받지 않는다).
  SecretSessionManager(
    this._api,
    this._identity, {
    SecretKeyStore? keyStore,
    String? userId,
    Room? Function(String roomId)? roomLookup,
    @visibleForTesting this._acceptLegacyInvites = false,
  }) : _keyStore = keyStore ?? SecretKeyStore(),
       _myUserId = userId,
       _lookupRoom = roomLookup;

  final bool _acceptLegacyInvites;

  /// [invite]가 새 규약(v3)을 알렸는지 — 초대한 앱의 맥락 서명(v2)과 규약 번호 3 이상이 함께 있어야 한다. 아니면 예전 앱이
  /// 건 초대거나 서버가 새 규약 표시를 뺀 초대다. 둘을 가릴 수 없어(규약 번호는 서명되지 않는다 — 예전 앱이 확인하는 초대
  /// 서명에 그 칸이 없다) 받지 않는다. 그래서 서버가 표시를 빼도 대화를 못 맺을 뿐 예전 규약으로 낮추지는 못하고, 새 앱은
  /// 예전 규약으로 수락하지 않으니 서버가 새 앱의 예전 방식 수락을 꾸며 초대한 쪽을 낮출 수도 없다.
  static bool offersCurrentProtocol(SecretInviteEvent invite) =>
      invite.initiatorContextSignature != null &&
      (invite.initiatorProtocol ?? 0) >= crypto.secretProtocolV3;

  String get _me {
    final me = _myUserId;
    if (me == null) {
      throw StateError('비밀 대화 핸드셰이크에는 로그인한 사용자 id가 필요합니다.');
    }
    return me;
  }

  /// 이 기기 id — 아직 불러오지 않았으면 null(평문 캐시만 다루는 테스트 등).
  String? get _myDeviceIdOrNull {
    try {
      return _identity.deviceId;
    } on StateError {
      return null;
    }
  }

  Future<T> _inRoom<T>(String roomId, Future<T> Function() op) {
    final previous = _roomQueues[roomId] ?? Future<void>.value();
    // 웹 앱은 같은 저장소를 쓰는 다른 탭과도 차례를 지킨다(secret_room_lock.dart — 앱은 그대로 돌린다).
    final result = previous.then(
      (_) => runWithSecretRoomLock('tangotalk-secret-room/$roomId', op),
    );
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _roomQueues[roomId] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_roomQueues[roomId], tail)) _roomQueues.remove(roomId);
      }),
    );
    return result;
  }

  // ---- 방에 묶인 상대 기기·보안 상태 ----

  Future<SecretRoomBinding?> _bindingOf(String roomId) async {
    if (_keepStateInMemory) {
      final cached = _bindings[roomId];
      if (cached != null) return cached;
      if (_unboundRooms.contains(roomId)) return null;
    }
    final stored = await _keyStore.readRoomBinding(roomId);
    if (stored != null) {
      _bindings[roomId] = stored;
      _unboundRooms.remove(roomId);
    } else {
      _bindings.remove(roomId);
      _unboundRooms.add(roomId);
    }
    return stored;
  }

  Future<void> _saveBinding(String roomId, SecretRoomBinding binding) async {
    _ensureNotDisposed();
    // 적다가 실패하면 무엇이 남았는지 모른다 — 다음에 저장소에서 다시 읽게 먼저 뺀다.
    _forgetBinding(roomId);
    await _keyStore.saveRoomBinding(roomId, binding);
    _bindings[roomId] = binding;
  }

  /// 들고 있는 묶음(없다고 읽은 것 포함)을 버린다 — 다음에 저장소에서 다시 읽는다.
  void _forgetBinding(String roomId) {
    _bindings.remove(roomId);
    _unboundRooms.remove(roomId);
  }

  Future<SecretRoomSecurity> _securityOf(String roomId) async {
    if (_keepStateInMemory) {
      final cached = _securities[roomId];
      if (cached != null) return cached;
    }
    final stored = await _keyStore.readRoomSecurity(roomId);
    return _securities[roomId] = stored;
  }

  /// 보안 상태를 적는다 — 저장소가 이미 적힌 멈춤은 지키며 적고(다른 방의 일로 그 사이 멈췄을 수 있다) 실제로 적힌
  /// 값을 돌려주므로, 들고 있는 값도 그것으로 맞춘다.
  Future<void> _saveSecurity(String roomId, SecretRoomSecurity security) async {
    if (await _securityOf(roomId) == security) return;
    _securities[roomId] = await _keyStore.saveRoomSecurity(roomId, security);
  }

  /// 보안 확인에 실패한 방을 멈춘다 — 처음 멈춘 이유를 남기고, 더 쓸 일이 없는 대기 중인 임시 개인키와 세션 키는 지운다
  /// (멈춘 대화는 되살릴 수 없어 그 키를 쓸 일이 없다 — 기기가 털려도 그 대화를 풀 키가 남지 않게). 세션 키는 그 방의
  /// 다른 일(풀던 메시지 등)이 끝난 뒤에 지우도록 방 줄에 세운다(이 방 줄 안에서 불렸어도 기다리지 않아 멈추지 않는다 —
  /// 그동안은 멈춤 표시가 먼저 막는다). 이 기기에 고정해 둔 키 때문에 멈췄으면 그 상대 기기 [deviceId]와 그 고정 [pin]을
  /// 함께 적어 둔다("상대 기기 키 다시 받기"가 그 고정에만 쓰이게 — 깨진 고정이었으면 [pin]은 null).
  Future<SecretHandshakeOutcome> _block(
    String roomId,
    SecretBlockReason reason, {
    String? deviceId,
    SecretDevicePin? pin,
  }) async {
    final current = await _securityOf(roomId);
    if (!current.blocked) {
      await _saveSecurity(
        roomId,
        current.blockedWith(
          reason,
          DateTime.now(),
          deviceId: reason.allowsKeyReset ? deviceId : null,
          pinSeenAt: pin?.firstSeenAt,
        ),
      );
    }
    await _keyStore.clearPendingEphemeralSeed(roomId);
    unawaited(
      _inRoom(roomId, () => _dropKeyMaterial(roomId)).then(
        (_) {},
        onError: (Object e) =>
            debugPrint('[secret] 멈춘 대화의 키를 지우지 못함: room=$roomId $e'),
      ),
    );
    await _refreshTrust(roomId);
    return SecretHandshakeOutcome.blocked;
  }

  /// 방 [roomId]의 세션 키(두 규약 모두)를 저장소와 메모리에서 지운다 — 방 줄 안에서만 부른다.
  Future<void> _dropKeyMaterial(String roomId) async {
    _forgetKeyState(roomId);
    await _keyStore.deleteSessionKeyMaterial(roomId);
    await _refreshTrust(roomId);
  }

  /// 메모리에 들고 있는 방 [roomId]의 세션 키 상태(규약·래칫·체인·남겨 둔 키·막 보낸 키)를 버린다.
  void _forgetKeyState(String roomId) {
    _ratchetStates.remove(roomId);
    _chainStates.remove(roomId);
    _v1Skipped.remove(roomId);
    _protocols.remove(roomId);
    _v1SentKeys.removeWhere((key, _) => key.startsWith('$roomId|'));
  }

  /// [key] 확인에 실패해 방을 멈춘다 — 고정 기록 때문이면 그 기기를 "다시 받기" 대상으로 적는다.
  Future<SecretHandshakeOutcome> _blockForKey(
    String roomId,
    String deviceId,
    _PeerKey key,
    SecretBlockReason reason,
  ) => _block(
    roomId,
    reason,
    deviceId: key.pinInvolved ? deviceId : null,
    pin: key.pin,
  );

  /// 상대 기기 [deviceId]에 묶인 방(이 기기에 저장된 묶음 전부와 지금 들고 있는 묶음)을 [reason]으로 멈추고, 새로
  /// 멈춘 방 id를 돌려준다 — [except] 방은 부른 쪽이 따로 다룬다. [notify]면 [onRoomsBlocked]로도 알린다.
  Future<List<String>> _blockRoomsBoundTo(
    String deviceId,
    SecretBlockReason reason, {
    SecretDevicePin? pin,
    String? except,
    bool notify = true,
  }) async {
    final roomIds = <String>{
      ...await _keyStore.roomIdsBoundToDevice(deviceId),
      for (final entry in _bindings.entries)
        if (entry.value.peerDeviceId == deviceId) entry.key,
    }..remove(except);
    final newlyBlocked = <String>[];
    for (final roomId in roomIds) {
      if ((await _securityOf(roomId)).blocked) {
        // 이미 멈춘 방도 그 기기의 고정이 바뀌었으니(다툼·지움) 화면에 보일 상태를 다시 맞춘다.
        await _refreshTrust(roomId);
        continue;
      }
      await _block(roomId, reason, deviceId: deviceId, pin: pin);
      newlyBlocked.add(roomId);
    }
    if (notify && newlyBlocked.isNotEmpty && !_disposed) {
      onRoomsBlocked?.call(newlyBlocked);
    }
    return newlyBlocked;
  }

  /// 보안 확인에 실패해 멈춘 방인지.
  Future<bool> isBlocked(String roomId) async =>
      (await _securityOf(roomId)).blocked;

  /// 방 [roomId] 세션의 규약(새 규약 3, 예전 규약 1) — 세션이 없으면 null.
  Future<int?> _protocolOf(String roomId) async {
    if (_keepStateInMemory) {
      final known = _protocols[roomId];
      if (known != null) return known;
    }
    final stored = await _keyStore.sessionProtocol(roomId);
    if (stored != null) {
      _protocols[roomId] = stored;
    } else {
      _protocols.remove(roomId);
    }
    return stored;
  }

  /// 방 [roomId]의 상대 기기 — 저장된 것이 없으면, 이 업데이트 전에 성립한 대화일 수 있어 방 정보로 찾아 묶는다
  /// ([_bootstrapBinding]). 찾지 못하면(서버가 기기 정보를 안 주는 예전 서버, 이 기기의 대화가 아님, 오프라인) null.
  Future<SecretRoomBinding?> _bindingFor(String roomId) async {
    final known = await _bindingOf(roomId);
    if (known != null) return known;
    final running = _bootstraps[roomId];
    if (running != null) return running;
    final bootstrap = _bootstrapBinding(roomId);
    _bootstraps[roomId] = bootstrap;
    try {
      return await bootstrap;
    } finally {
      if (identical(_bootstraps[roomId], bootstrap)) _bootstraps.remove(roomId);
    }
  }

  /// 이 업데이트 전에 성립한 비밀 대화를 상대 기기에 묶는다 — 그때는 상대 기기를 메모리에만 들고 있어서 저장된 것이
  /// 없다. 서버가 방 정보로 알려 주는 양쪽 사용자·기기 중 이 기기 쪽이 맞을 때만, 상대 기기의 키를(처음 보는 기기면
  /// 서버에 물어 주인이 그 상대인지 확인하고) 고정한다. 서명으로 확인할 것이 없어 처음 믿는 키다 — 그래서 보안 코드
  /// 비교가 필요하다. 주인이 다르면 그 방을 멈춘다.
  Future<SecretRoomBinding?> _bootstrapBinding(String roomId) async {
    final room = _lookupRoom?.call(roomId);
    final me = _myUserId;
    final myDeviceId = _myDeviceIdOrNull;
    if (room == null ||
        !room.isSecret ||
        room.secretStatus != 'active' ||
        me == null ||
        myDeviceId == null) {
      return null;
    }
    // 이 기기에 그 대화의 세션이 없으면 묶을 것도 없다(핸드셰이크가 새로 묶는다).
    if (!await _keyStore.hasSession(roomId)) return null;
    if ((await _securityOf(roomId)).blocked) return null;
    String? peerUserId;
    String? peerDeviceId;
    if (room.secretInitiatorUserId == me &&
        room.secretInitiatorDeviceId == myDeviceId) {
      peerUserId = room.secretResponderUserId;
      peerDeviceId = room.secretResponderDeviceId;
    } else if (room.secretResponderUserId == me &&
        room.secretResponderDeviceId == myDeviceId) {
      peerUserId = room.secretInitiatorUserId;
      peerDeviceId = room.secretInitiatorDeviceId;
    }
    if (peerUserId == null || peerDeviceId == null || peerUserId == me) {
      return null;
    }
    // 상대가 이미 나간 방(멤버에 없음)은 묶을 상대가 없다.
    if (!room.members.any((m) => m.id == peerUserId)) return null;
    final _PeerKey key;
    try {
      key = await _peerKeyFor(peerDeviceId, peerUserId);
    } catch (_) {
      return null; // 오프라인 등 — 다음에 다시 묶어 본다.
    }
    final failure = key.failure;
    if (failure != null) {
      await _blockForKey(roomId, peerDeviceId, key, failure);
      return null;
    }
    // 묻는 사이 핸드셰이크가 먼저 묶었으면 그것을 쓴다.
    final raced = await _bindingOf(roomId);
    if (raced != null) return raced;
    // 먼저 묶고 그다음 고정한다(acceptInvite와 같은 까닭 — 다른 방에서 드러난 키 다툼이 이 방을 빠뜨리지 않게).
    final binding = SecretRoomBinding(
      peerUserId: peerUserId,
      peerDeviceId: peerDeviceId,
      myDeviceId: myDeviceId,
    );
    await _saveBinding(roomId, binding);
    // 서버가 이 답을 붙잡아 두는 사이 다른 방의 핸드셰이크가 같은 기기를 다른 키로 먼저 고정했으면 — 덮어쓰지
    // 않고(그러면 그 방의 보안 코드가 진짜처럼 바뀐다) 이 방과 그 기기와의 대화를 모두 멈춘다.
    final ({
      SecretBlockReason? failure,
      SecretDevicePin? pin,
      bool deviceChanged,
    })
    pinned;
    try {
      pinned = await _pinPeerDevice(
        roomId,
        peerDeviceId,
        peerUserId,
        key,
        checkDeviceChange: false,
      );
    } catch (_) {
      // 고정을 적지 못했으면(저장소 오류) 묶음도 거둔다 — 고정 없는 묶음으로 남으면 다음에 다시 묶지 않는다.
      _forgetBinding(roomId);
      try {
        await _keyStore.deleteRoomBinding(roomId);
      } catch (_) {}
      return null;
    }
    final pinFailure = pinned.failure;
    if (pinFailure != null) {
      await _block(roomId, pinFailure, deviceId: peerDeviceId, pin: pinned.pin);
      return null;
    }
    await _refreshTrust(roomId);
    return binding;
  }

  /// 앱을 켤 때 — 내 다른 기기가 수락한 대화에 이 기기의 키가 남아 있으면 치우고([_dropStaleResponderKeys]), 내가 건
  /// 대화의 수락을 놓쳤으면 다시 받아 처리하고([recoverMissedAcceptance]), 이 업데이트 전에 성립한 대화들을 상대 기기에
  /// 미리 묶어 둔다(보안 코드·신뢰 안내에 쓴다). 세션을 만든 뒤 지우지 못한 초대 임시키(그 사이 꺼짐 — 그 키로 첫 루트키를
  /// 다시 만들 수 있다)와, 처음 한 번은 예전 앱이 재키잉을 제안하고 남겨 둔 임시 개인키도 지운다(이제 재키잉을 하지
  /// 않는다). 실패해도 다음에 필요할 때(보안 코드 화면 등) 다시 해 본다. 이번에 멈춘 방 id를 돌려준다(Session이 알린다).
  Future<List<String>> bootstrapBindings(Iterable<String> roomIds) async {
    final blocked = <String>[];
    final me = _myUserId;
    var cleanRekeySeeds = false;
    if (me != null) {
      try {
        cleanRekeySeeds = !await _keyStore.staleRekeyCleanupDone(me);
      } catch (_) {}
    }
    var cleanupFailed = false;
    for (final roomId in roomIds.toList()) {
      if (_disposed) break;
      try {
        await _dropStaleResponderKeys(roomId);
        await _inRoom(roomId, () async {
          if (cleanRekeySeeds) await _keyStore.clearStaleRekeySeed(roomId);
          if (await _keyStore.readPendingEphemeralSeed(roomId) != null &&
              await _keyStore.hasSession(roomId)) {
            await _keyStore.clearPendingEphemeralSeed(roomId);
          }
          if ((await _securityOf(roomId)).blocked) {
            // 이 업데이트 전에 멈춘 방에 남은 세션 키 — 이제는 멈출 때 지운다.
            if (await _keyStore.hasSession(roomId)) {
              await _dropKeyMaterial(roomId);
            }
          } else {
            await _pruneExpiredSkippedKeys(roomId);
          }
        });
        final wasBlocked = await isBlocked(roomId);
        await recoverMissedAcceptance(roomId);
        await _bindingFor(roomId);
        if (!wasBlocked && await isBlocked(roomId)) blocked.add(roomId);
      } catch (_) {
        cleanupFailed = true;
      }
    }
    if (cleanRekeySeeds && !cleanupFailed && !_disposed && me != null) {
      try {
        await _keyStore.markStaleRekeyCleanupDone(me);
      } catch (_) {}
    }
    return blocked;
  }

  /// 방 [roomId]에 묶인 상대 기기가 새 규약(v3)으로 말하는 것을 확인했다 — 그 기기의 고정에 적는다(SecretDevicePin
  /// .speaksV3, 한 번만). 수락한 쪽은 초대에 실린 v3 표시가 서명되지 않아 그것만으로는 믿지 않고, 상대가 v3로 보낸 글이
  /// 풀릴 때(그 대화의 키는 상대가 서명한 핸드셰이크로 맺었다) 적는다. 방 줄 안에서만 부른다. 적지 못해도 넘어간다.
  Future<void> _notePeerSpeaksV3(String roomId) async {
    final binding = await _bindingOf(roomId);
    if (binding == null) return;
    await _markSpeaksV3(binding.peerDeviceId, binding.peerUserId);
  }

  Future<void> _markSpeaksV3(String deviceId, String userId) async {
    if (_keepStateInMemory && _v3ConfirmedDevices.contains(deviceId)) return;
    try {
      final pin = await _keyStore.readDevicePin(deviceId);
      if (pin == null || pin.userId != userId || pin.disputed) return;
      if (!pin.speaksV3) await _keyStore.markDevicePinSpeaksV3(deviceId, pin);
      _v3ConfirmedDevices.add(deviceId);
    } catch (e) {
      debugPrint('[secret] 상대 기기가 새 규약을 쓴다고 적지 못함: $e');
    }
  }

  /// 수명([secretSkippedKeyLifetime])이 다한 남겨 둔 키를 버린다 — 메시지가 오지 않는 방에서도 오래 남지 않게(앱을 켤
  /// 때). 방 줄 안에서만 부른다.
  Future<void> _pruneExpiredSkippedKeys(String roomId) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    switch (await _protocolOf(roomId)) {
      case crypto.secretProtocolV3:
        final state = await _ratchetStateOf(roomId);
        if (state == null) return;
        final live = pruneExpiredSkippedKeys(state.skipped, nowMs);
        if (identical(live, state.skipped)) return;
        await _saveRatchetState(
          roomId,
          state.withSkipped(live),
          skippedChanged: true,
        );
      case 1:
        final skipped = await _v1SkippedOf(roomId);
        final live = pruneExpiredSkippedKeys(skipped, nowMs);
        if (!identical(live, skipped)) await _saveV1Skipped(roomId, live);
    }
  }

  /// 내가 이 기기로 건 대화가 수락됐는데(방 정보가 active) 이 기기는 그 수락(secret:accepted — 그 순간 연결된 기기에만
  /// 간다)을 놓쳐 세션이 없으면 — 초대해 두고 앱을 끈 사이 상대가 수락한 경우 — 서버에 다시 물어 처리한다. 서버가 준
  /// 값은 소켓으로 받은 것과 똑같이 [handleAccepted]가 확인한다(서명·고정한 키·상대). 할 일이 없거나 물어보지 못하면 null.
  Future<SecretHandshakeOutcome?> recoverMissedAcceptance(String roomId) async {
    final room = _lookupRoom?.call(roomId);
    final me = _myUserId;
    if (_disposed ||
        room == null ||
        me == null ||
        !room.isSecret ||
        room.secretStatus != 'active' ||
        room.secretInitiatorUserId != me) {
      return null;
    }
    if (await _protocolOf(roomId) != null ||
        await _keyStore.readPendingEphemeralSeed(roomId) == null ||
        (await _securityOf(roomId)).blocked) {
      return null;
    }
    final SecretAcceptedEvent event;
    try {
      event = await _api.fetchSecretAccepted(roomId);
    } catch (_) {
      return null; // 아직 수락되지 않았거나(서버 기준) 오프라인 — 다음에 다시 본다.
    }
    // 묻는 사이 로그아웃해 버린 매니저 — 새 매니저가 다시 본다.
    if (_disposed || event.roomId != roomId) return null;
    return handleAccepted(event);
  }

  /// 이 기기가 수락을 보냈다가 응답을 못 받아(시간 초과) 키를 남겨 둔 사이, 실제로는 내 다른 기기가 수락했고 그 알림
  /// (secret:accepted)도 꺼져 있어 놓쳤으면 — 방 정보의 "수락한 기기"가 이 기기가 아니다. 그 키는 이 대화의 것이
  /// 아니라 쓸 일이 없고, 남겨 두면 이 기기가 대화를 맺은 것처럼 보인다(보낸 메시지를 상대가 풀지 못한다).
  /// 서버가 꾸민 값이면 이 기기의 대화만 끊길 뿐(서버는 원래 메시지를 안 전해 줄 수도 있다) 내용은 새지 않는다. 멈춘
  /// 방은 건드리지 않는다 — 서버가 준 값으로 멈춤을 풀 수 있으면 안 된다.
  Future<void> _dropStaleResponderKeys(String roomId) =>
      _inRoom(roomId, () async {
        final room = _lookupRoom?.call(roomId);
        final me = _myUserId;
        final myDeviceId = _myDeviceIdOrNull;
        if (room == null || me == null || myDeviceId == null) return;
        if ((await _securityOf(roomId)).blocked) return;
        final responderDeviceId = room.secretResponderDeviceId;
        if (room.secretStatus != 'active' ||
            room.secretResponderUserId != me ||
            responderDeviceId == null ||
            responderDeviceId == myDeviceId) {
          return;
        }
        // 이 기기가 지금의 id로 수락해 둔 대화일 때만(공용 PC에서 id가 바뀐 예전 대화 등은 건드리지 않는다).
        if ((await _bindingOf(roomId))?.myDeviceId != myDeviceId) return;
        if (!await _keyStore.hasSession(roomId)) return;
        await _clearSessionKeys(roomId);
        await _refreshTrust(roomId);
      });

  // ---- 상대 기기 키 ----

  /// 기기 [deviceId]의 서명 검증키. 이미 고정한 기기면 고정한 키만 쓰고 서버에 다시 묻지 않는다(서버가 그 기기의
  /// 키를 바꿔 답해도 듣지 않는다). 그 고정이 다툼 중이거나 읽을 수 없으면 확인 실패다(어느 키를 믿을지 모른다).
  /// 처음 보는 기기면 서버에 물어 그 기기의 주인이 [expectedUserId]인지 확인한다. 고정은 서명을 확인한 뒤에
  /// 한다([_pinFirstSeen] — 맞지 않는 키를 고정해 두면 그 기기와는 대화할 수 없다). 네트워크 오류는 던진다.
  Future<_PeerKey> _peerKeyFor(String deviceId, String expectedUserId) async {
    final entry = await _keyStore.readDevicePinEntry(deviceId);
    if (entry.present) {
      final pin = entry.pin;
      if (pin == null || pin.disputed) {
        return _PeerKey.failed(
          SecretBlockReason.keyMismatch,
          pin: pin,
          pinInvolved: true,
        );
      }
      return pin.userId == expectedUserId
          ? _PeerKey.pinned(pin)
          : const _PeerKey.failed(SecretBlockReason.userMismatch);
    }
    final info = await _api.fetchDeviceSigningPublicKey(deviceId);
    if (info.userId != expectedUserId) {
      return const _PeerKey.failed(SecretBlockReason.userMismatch);
    }
    return _PeerKey.firstSeen(info.signingPublicKey);
  }

  /// 서명을 확인한 처음 보는 기기를 고정한다 — 없을 때만 적는다(SecretKeyStore.pinDeviceIfAbsent). 서버에 묻는 사이
  /// 다른 곳(다른 방의 핸드셰이크·예전 대화 묶기)이 같은 기기를 다른 키·주인으로 먼저 고정했으면, 서버가 같은 기기를
  /// 두 가지로 알려 온 것이다 — 어느 쪽이 진짜인지 모르니 그 고정에 다툼이 적히고, 그 기기에 묶인 다른 방도 모두
  /// 멈춘다(먼저 고정된 쪽이 서버의 키였다면 그 방은 서버와 맺어진 것이다). [ok]가 false면 부른 쪽이 [roomId]를
  /// 멈춘다. [pin]은 지금 고정된 값(깨진 고정이면 null).
  Future<({bool ok, SecretDevicePin? pin})> _pinFirstSeen(
    String roomId,
    String deviceId,
    String userId,
    String signingPublicKey,
  ) async {
    final candidate = SecretDevicePin.firstSeen(
      userId: userId,
      signingPublicKey: signingPublicKey,
    );
    final stored = await _keyStore.pinDeviceIfAbsent(deviceId, candidate);
    if (stored != null && !stored.disputed && stored.sameKeyAs(candidate)) {
      return (ok: true, pin: stored);
    }
    await _blockRoomsBoundTo(
      deviceId,
      SecretBlockReason.keyMismatch,
      pin: stored,
      except: roomId,
    );
    return (ok: false, pin: stored);
  }

  /// 방 [roomId]를 상대 기기에 묶은 뒤 부른다 — 서명을 확인한 그 기기를 고정하고(처음 본 기기면 [_pinFirstSeen]),
  /// 이미 고정한 기기면 그 고정이 아직 그대로인지 다시 본다. 고정한 키를 읽은 뒤 서명을 확인하는 사이 사용자가 그 키를
  /// 지웠거나("상대 기기 키 다시 받기") 다른 방에서 다툼이 드러났으면, 그 일이 이 방을 찾기 전이었을 수 있어서다(묶은
  /// 뒤라 그 뒤의 일은 이 방을 찾아 멈춘다). 실패하면 [failure]. [checkDeviceChange]면 이 사람의 다른 기기를 이 기기에서
  /// 보안 코드로 확인한 적이 있는데 이 기기는 확인하지 않았을 때 [deviceChanged](상대 기기가 바뀌었다고 알린다).
  Future<
    ({SecretBlockReason? failure, SecretDevicePin? pin, bool deviceChanged})
  >
  _pinPeerDevice(
    String roomId,
    String deviceId,
    String userId,
    _PeerKey key, {
    bool checkDeviceChange = true,
  }) async {
    SecretDevicePin? pin;
    if (key.pinned) {
      final entry = await _keyStore.readDevicePinEntry(deviceId);
      final current = entry.pin;
      if (!entry.present) {
        return (
          failure: SecretBlockReason.keyReset,
          pin: null,
          deviceChanged: false,
        );
      }
      if (current == null ||
          current.disputed ||
          !current.isSamePinAs(key.pin!)) {
        return (
          failure: SecretBlockReason.keyMismatch,
          pin: current,
          deviceChanged: false,
        );
      }
      pin = current;
    } else {
      final pinned = await _pinFirstSeen(
        roomId,
        deviceId,
        userId,
        key.signingPublicKey!,
      );
      if (!pinned.ok) {
        return (
          failure: SecretBlockReason.keyMismatch,
          pin: pinned.pin,
          deviceChanged: false,
        );
      }
      pin = pinned.pin;
    }
    if (!checkDeviceChange) {
      return (failure: null, pin: pin, deviceChanged: false);
    }
    final myDeviceId = _identity.deviceId;
    final changed =
        pin?.verifiedAtFor(myDeviceId) == null &&
        await _otherDeviceVerified(userId, deviceId, myDeviceId);
    return (failure: null, pin: pin, deviceChanged: changed);
  }

  Future<bool> _otherDeviceVerified(
    String userId,
    String deviceId,
    String myDeviceId,
  ) async {
    final pins = await _keyStore.devicePinsOfUser(userId);
    return pins.any(
      (e) => e.$1 != deviceId && e.$2.verifiedAtFor(myDeviceId) != null,
    );
  }

  /// [userId]의 기기 [deviceId]가 이 기기가 보안 코드를 확인하지 않은 기기인데, 같은 사람의 다른 기기는 확인한 적이
  /// 있는지 — 초대 대화상자가 "상대가 새 기기에서 요청했다"고 미리 알리는 데 쓴다(서버가 알려 준 기기 id라 참고용).
  Future<bool> isUnverifiedDeviceOfVerifiedPeer(
    String userId,
    String deviceId,
  ) async {
    final myDeviceId = _myDeviceIdOrNull;
    if (myDeviceId == null) return false;
    try {
      final pin = await _keyStore.readDevicePin(deviceId);
      if (pin != null &&
          pin.userId == userId &&
          pin.verifiedAtFor(myDeviceId) != null) {
        return false;
      }
      return await _otherDeviceVerified(userId, deviceId, myDeviceId);
    } catch (_) {
      return false;
    }
  }

  /// 상대가 보낸 서명을 확인한다 — 맥락 서명(v2)을 보냈으면 그것만 본다(키만 서명한 v1은 다른 세션에 다시 끼워
  /// 넣어도 맞으므로 v2가 있으면 보지 않는다). 맥락은 서버가 준 값이 아니라 이 기기가 아는 값으로 만든 [context]다.
  /// v2가 없으면(예전 앱) v1을 고정한 키로 확인하고 [legacy]로 알린다.
  Future<({bool ok, bool legacy})> _verifyPeer({
    required String signingPublicKey,
    required String? contextSignature,
    required String Function() context,
    required String ephemeralPublicKey,
    required String ephemeralSignature,
  }) async {
    if (contextSignature != null) {
      final String text;
      try {
        text = context();
      } on ArgumentError {
        return (ok: false, legacy: false);
      }
      final ok = await crypto.verifyContext(
        signingPublicKeyBase64: signingPublicKey,
        context: text,
        signatureBase64: contextSignature,
      );
      return (ok: ok, legacy: false);
    }
    final ok = await crypto.verifyEphemeralKey(
      signingPublicKeyBase64: signingPublicKey,
      ephemeralPublicKeyBytes: base64Decode(ephemeralPublicKey),
      signatureBase64: ephemeralSignature,
    );
    return (ok: ok, legacy: true);
  }

  /// X25519 공개키(base64, 32바이트) — 모양이 틀리면 null(서버가 꾸민 값 — 서명 확인 실패와 같이 다룬다).
  static List<int>? _x25519Bytes(String base64Key) {
    try {
      final bytes = base64Decode(base64Key);
      return bytes.length == 32 ? bytes : null;
    } on FormatException {
      return null;
    }
  }

  /// 방 [roomId]가 알려진 방이면 [userId]가 그 방 멤버인지(모르는 방이면 확인하지 않는다).
  bool _isMemberOfKnownRoom(String roomId, String userId) {
    final room = _lookupRoom?.call(roomId);
    if (room == null || room.members.isEmpty) return true;
    return room.members.any((m) => m.id == userId);
  }

  /// 알려진 방이면 나를 뺀 멤버 한 명(비밀 대화의 상대).
  String? _otherMemberOf(String roomId) {
    final room = _lookupRoom?.call(roomId);
    if (room == null) return null;
    final others = [
      for (final m in room.members)
        if (m.id != _myUserId) m.id,
    ];
    return others.length == 1 ? others.single : null;
  }

  // ---- 핸드셰이크 ----

  /// 내가 상대에게 비밀 대화를 걸 때. 방이 만들어진 뒤 서버가 돌려준 roomId로 임시키를 저장한다.
  /// [teamId]는 내가 지금 속해 있어야 하는 팀(서버 NOT NULL 제약을 만족시키기 위한 부가
  /// 정보일 뿐 — 상대는 그 팀 소속이 아니어도 된다, server/src/secretChats.js). 새 규약(v3)을 안다고 함께 알린다 —
  /// 상대도 새 앱이면 v3로 수락한다([handleAccepted]).
  Future<Room> startSecretChat(String targetUserId, String teamId) async {
    final me = _me;
    final myDeviceId = _identity.deviceId;
    final ephemeral = await X25519().newKeyPair();
    final ephemeralPublicKey = await publicKeyBase64(ephemeral);
    final signature = await crypto.signEphemeralKey(
      _identity.signingKeyPair,
      base64Decode(ephemeralPublicKey),
    );
    final contextSignature = await crypto.signContext(
      _identity.signingKeyPair,
      crypto.secretInitContext(
        initiatorUserId: me,
        initiatorDeviceId: myDeviceId,
        responderUserId: targetUserId,
        initiatorEphemeralPublicKey: ephemeralPublicKey,
      ),
    );

    final result = await _api.startSecretChat(
      targetUserId: targetUserId,
      deviceId: myDeviceId,
      initiatorEphemeralPublicKey: ephemeralPublicKey,
      initiatorEphemeralSignature: signature,
      initiatorContextSignature: contextSignature,
      protocol: crypto.secretProtocolV3,
      teamId: teamId,
    );
    // 이미 진행 중인 대화가 있어 서버가 그 방을 돌려줬으면(created가 false) 서버는 이번 임시키를 받지 않았다 — 상대는
    // 그 방의 원래 임시키로 수락하므로, 여기서 새 키를 대기시키면 수락이 와도 체인이 어긋난다.
    if (result.created) {
      await _keyStore.savePendingEphemeralSeed(
        result.room.id,
        await ephemeral.extractPrivateKeyBytes(),
        targetUserId: targetUserId,
        myDeviceId: myDeviceId,
        offeredProtocol: crypto.secretProtocolV3,
      );
    }
    return result.room;
  }

  /// 상대의 초대(secret:invite)를 수락한다 — 서명을 먼저 검증하고, 통과해야만 진행한다.
  /// 서버가 수락을 받지 않으면(내 다른 기기가 먼저 수락함 등) 이 기기에 적은 키를 되돌리고
  /// [SecretChatRefusedException]을 던진다. 이미 맺어 서버도 받았다고 답한 대화에 같은 초대가 다시 오면(초대 창이 다시
  /// 뜸·서버가 다시 보냄) 아무것도 하지 않는다 — 다시 수락하면 지금 세션을 덮어쓰고, 서버는 이미 받은 수락이라 거절해(409)
  /// 세션까지 지워진다. 응답을 못 받은 수락(그 사이 끊김·꺼짐)은 다시 할 수 있다.
  Future<SecretHandshakeOutcome> acceptInvite(SecretInviteEvent invite) =>
      _inRoom(invite.roomId, () async {
        // 새 규약을 알리지 않은 초대는 받지 않는다([offersCurrentProtocol]) — 아무것도 적지 않고 묻지도 않는다.
        if (!_acceptLegacyInvites && !offersCurrentProtocol(invite)) {
          throw const SecretInviteOutdatedException();
        }
        final roomId = invite.roomId;
        final me = _me;
        final myDeviceId = _identity.deviceId;
        if ((await _securityOf(roomId)).blocked) {
          return SecretHandshakeOutcome.blocked;
        }
        final peerUserId = invite.initiatorUserId;
        final peerDeviceId = invite.initiatorDeviceId;
        // 초대를 보낸 사람이 이 방의 상대가 맞는지 — 나 자신이거나 방에 없는 사람이면 서버가 꾸민 초대다.
        if (peerUserId == me || !_isMemberOfKnownRoom(roomId, peerUserId)) {
          return _block(roomId, SecretBlockReason.peerMismatch);
        }
        final existing = await _bindingOf(roomId);
        if (existing != null &&
            (existing.peerUserId != peerUserId ||
                existing.peerDeviceId != peerDeviceId)) {
          return _block(roomId, SecretBlockReason.deviceMismatch);
        }
        final theirEphemeralBytes = _x25519Bytes(
          invite.initiatorEphemeralPublicKey,
        );
        if (theirEphemeralBytes == null) {
          return _block(roomId, SecretBlockReason.badSignature);
        }
        final key = await _peerKeyFor(peerDeviceId, peerUserId);
        // 서버에 묻는 사이 로그아웃해 버린 매니저면 여기서 그만둔다(새 매니저가 같은 방에 적은 것을 덮어쓰지 않게).
        _ensureNotDisposed();
        final keyFailure = key.failure;
        if (keyFailure != null) {
          return _blockForKey(roomId, peerDeviceId, key, keyFailure);
        }
        final check = await _verifyPeer(
          signingPublicKey: key.signingPublicKey!,
          contextSignature: invite.initiatorContextSignature,
          context: () => crypto.secretInitContext(
            initiatorUserId: peerUserId,
            initiatorDeviceId: peerDeviceId,
            responderUserId: me,
            initiatorEphemeralPublicKey: invite.initiatorEphemeralPublicKey,
          ),
          ephemeralPublicKey: invite.initiatorEphemeralPublicKey,
          ephemeralSignature: invite.initiatorEphemeralSignature,
        );
        // 서버가 키를 바꿔치기했거나 변조됨 — 절대 진행하지 않는다.
        if (!check.ok) {
          return _blockForKey(
            roomId,
            peerDeviceId,
            key,
            SecretBlockReason.badSignature,
          );
        }
        final hadSession = await _keyStore.hasSession(roomId);
        if (hadSession && !await _keyStore.hasAcceptPending(roomId)) {
          return SecretHandshakeOutcome.ignored;
        }
        // 상대 기기에 먼저 묶고 그다음 고정한다 — 다른 방에서 이 기기의 키 다툼이 드러나면 그 기기에 묶인 방을 모두
        // 멈추는데, 고정과 묶음 사이에 그 일이 끼어도 이 방이 빠지지 않게. 고정은 체인키를 적기 전에 — 같은 기기를
        // 다른 키로 먼저 고정한 곳이 있으면 여기서 멈춘다(묶음은 멈춘 방에 남아도 쓰이지 않는다).
        await _saveBinding(
          roomId,
          SecretRoomBinding(
            peerUserId: peerUserId,
            peerDeviceId: peerDeviceId,
            myDeviceId: myDeviceId,
          ),
        );
        final pinned = await _pinPeerDevice(
          roomId,
          peerDeviceId,
          peerUserId,
          key,
        );
        final pinFailure = pinned.failure;
        if (pinFailure != null) {
          return _block(
            roomId,
            pinFailure,
            deviceId: peerDeviceId,
            pin: pinned.pin,
          );
        }
        final deviceChanged = pinned.deviceChanged;
        // 초대한 앱이 새 규약을 안다고 했으면 v3로 수락한다. 맥락 서명(v2)이 없는 초대는 예전 앱의 것이라(새 앱은
        // 늘 보낸다) 서버가 규약 번호를 붙였더라도 예전 규약으로 받는다.
        final useV3 =
            !check.legacy &&
            (invite.initiatorProtocol ?? 0) >= crypto.secretProtocolV3;
        // 새 규약으로 말하는 것을 확인한 기기인데 이번 초대는 예전 규약이다 — 서버가 초대에서 새 규약 표시나 맥락 서명을
        // 뺀 것이다(새 앱은 늘 둘 다 보낸다). 예전 방식으로 맺지 않고 멈춘다.
        if (!useV3 && pinned.pin?.speaksV3 == true) {
          return _block(
            roomId,
            SecretBlockReason.downgrade,
            deviceId: peerDeviceId,
            pin: pinned.pin,
          );
        }

        final myEphemeral = await X25519().newKeyPair();
        final myEphemeralPublicKey = await publicKeyBase64(myEphemeral);
        final acceptContext = useV3
            ? crypto.secretAcceptContextV3
            : crypto.secretAcceptContext;
        final myContextSignature = await crypto.signContext(
          _identity.signingKeyPair,
          acceptContext(
            roomId: roomId,
            initiatorUserId: peerUserId,
            initiatorDeviceId: peerDeviceId,
            initiatorEphemeralPublicKey: invite.initiatorEphemeralPublicKey,
            responderUserId: me,
            responderDeviceId: myDeviceId,
            responderEphemeralPublicKey: myEphemeralPublicKey,
          ),
        );
        // 키만 서명하는 예전 서명(v1)은 예전 앱이 읽는다. v3로 수락할 때는 그 칸에도 v3 맥락 서명을 넣는다 — v3를 알린
        // 초대는 새 앱이 건 것이라 그 칸을 읽지 않고, 서버가 맥락 서명을 빼고 넘기면 초대한 쪽이 예전 서명으로 확인하다
        // 실패해 멈춘다(빼지 않았다면 받는 쪽만 v3라 아무 메시지도 풀리지 않는 채로 맺어진다).
        final mySignature = useV3
            ? myContextSignature
            : await crypto.signEphemeralKey(
                _identity.signingKeyPair,
                base64Decode(myEphemeralPublicKey),
              );

        final SecretRatchetState? ratchet;
        final List<int>? chainKey;
        if (useV3) {
          final rootKey = await crypto.deriveRootKeyV3(
            myEphemeralKeyPair: myEphemeral,
            theirEphemeralPublicKey: theirEphemeralBytes,
            roomId: roomId,
            transcript: crypto.secretRootTranscriptV3(
              roomId: roomId,
              initiatorUserId: peerUserId,
              initiatorDeviceId: peerDeviceId,
              initiatorEphemeralPublicKey: invite.initiatorEphemeralPublicKey,
              responderUserId: me,
              responderDeviceId: myDeviceId,
              responderEphemeralPublicKey: myEphemeralPublicKey,
            ),
          );
          // 서명은 맞는데 공유비밀이 0뿐인 임시키 — 상대 기기가 일부러 만든 값이 아니면 생길 수 없다.
          if (rootKey == null) {
            return _block(roomId, SecretBlockReason.badSignature);
          }
          ratchet = await SecretRatchetState.forResponder(
            rootKey: rootKey,
            myEphemeralKeyPair: myEphemeral,
          );
          chainKey = null;
        } else {
          ratchet = null;
          chainKey = await crypto.deriveInitialChainKey(
            myEphemeralKeyPair: myEphemeral,
            theirEphemeralPublicKey: SimplePublicKey(
              theirEphemeralBytes,
              type: KeyPairType.x25519,
            ),
            roomId: roomId,
          );
        }
        // 묶음(위)은 세션 키보다 먼저 적혀 있다 — 세션 키가 있는데 묶인 기기가 없으면 예전 대화로 보고 방 정보로
        // 묶으려 하기 때문이다.
        _ensureNotDisposed();
        await _saveSecurity(
          roomId,
          (await _securityOf(roomId)).copyWith(
            legacyPeer: check.legacy,
            peerDeviceChanged: deviceChanged,
          ),
        );
        // 서버가 받았다고 답하기 전에는 "응답 대기" 표시를 남긴다(세션보다 먼저) — 그 사이 끊기거나 꺼지면 같은 초대를 다시
        // 수락할 수 있게. 응답을 못 받은 지난 수락의 키는(다른 규약의 칸까지) 비우고 새로 적는다.
        await _keyStore.markAcceptPending(roomId);
        if (hadSession) {
          _forgetKeyState(roomId);
          await _keyStore.deleteSessionKeyMaterial(roomId);
        }
        if (ratchet != null) {
          await _keyStore.saveRatchetState(roomId, ratchet);
          _ratchetStates[roomId] = ratchet;
          _protocols[roomId] = crypto.secretProtocolV3;
        } else {
          final state = SecretChainState(epoch: 0, n: 0, chainKey: chainKey!);
          await _keyStore.saveChainState(roomId, state, skipped: const []);
          _chainStates[roomId] = state;
          _v1Skipped[roomId] = const [];
          _protocols[roomId] = 1;
        }

        try {
          await _api.acceptSecretChat(
            roomId: roomId,
            deviceId: myDeviceId,
            responderEphemeralPublicKey: myEphemeralPublicKey,
            responderEphemeralSignature: mySignature,
            responderContextSignature: myContextSignature,
          );
          try {
            await _keyStore.clearAcceptPending(roomId);
          } catch (_) {
            // 표시를 지우지 못했다 — 수락은 됐다. 이 기기가 수락했다는 secret:accepted가 오면 그때 지운다.
          }
        } on SecretChatRefusedException {
          // 서버가 이 기기의 수락을 받지 않았다 — 이 기기는 이 대화의 기기가 아니다. 키를 남겨 두면 이 기기가 대화를
          // 맺은 것처럼 보이지만 상대는 다른 기기와 맺었다(이 기기가 보낸 것을 상대가 풀지 못한다). 응답이 없었던
          // 경우(시간 초과)는 처리됐을 수 있어 그대로 둔다.
          await _clearSessionKeys(roomId);
          rethrow;
        } finally {
          await _refreshTrust(roomId);
        }
        return deviceChanged
            ? SecretHandshakeOutcome.establishedOnChangedDevice
            : SecretHandshakeOutcome.established;
      });

  Future<void> rejectInvite(String roomId) async {
    await _api.rejectSecretChat(roomId);
    await _inRoom(roomId, () => _clearRoom(roomId));
  }

  /// 상대가 내 초대를 수락했다는 브로드캐스트(secret:accepted)를 받았을 때 — 이제 나도 체인키를
  /// 계산할 수 있다(내가 처음 만들었던 임시 개인키 + 상대의 임시 공개키).
  Future<SecretHandshakeOutcome> handleAccepted(
    SecretAcceptedEvent event,
  ) => _inRoom(event.roomId, () async {
    final roomId = event.roomId;
    final me = _me;
    final myDeviceId = _identity.deviceId;
    if (event.responderUserId == me) {
      // 이 기기의 수락을 서버가 받았다 — 응답을 못 받은 수락 표시를 지운다(같은 초대가 다시 와도 다시 수락하지 않게).
      if (event.responderDeviceId == myDeviceId) {
        try {
          await _keyStore.clearAcceptPending(roomId);
        } catch (_) {}
      }
      if (event.responderDeviceId != myDeviceId &&
          await _keyStore.readPendingEphemeralSeed(roomId) == null &&
          !(await _securityOf(roomId)).blocked) {
        // 내 다른 기기가 이 초대를 수락했다 — 이 기기가 수락을 보냈다가 응답을 못 받아 남은 키가 있다면 이 대화의
        // 것이 아니다(남겨 두면 이 기기가 대화를 맺은 것처럼 보인다). 멈춘 방은 건드리지 않는다 — 이 알림은 서버가
        // 보내는 값이라, 이것으로 키를 치우다 멈춤까지 풀리면 가로채려다 들킨 서버가 멈춤을 풀 수 있다.
        if (await _keyStore.hasSession(roomId) &&
            (await _bindingOf(roomId))?.myDeviceId == myDeviceId) {
          await _clearSessionKeys(roomId);
          await _refreshTrust(roomId);
        }
      }
      return SecretHandshakeOutcome.ignored; // 내가(이 기기 또는 다른 기기) 수락한 것이 되돌아온 것.
    }
    final myPendingSeed = await _keyStore.readPendingEphemeralSeed(roomId);
    if (myPendingSeed == null) {
      return SecretHandshakeOutcome.ignored; // 이미 처리됐거나 이 기기가 초대자가 아님.
    }
    // 이미 성립한 대화에 늦게 온(또는 꾸민) 수락 — 세션 키를 새로 만들면 지금 대화가 깨진다. 세션을 만든 뒤 지우지
    // 못한(그 사이 꺼짐) 초대 임시키는 여기서 치운다(그 키로 첫 루트키를 다시 만들 수 있다).
    if (await _keyStore.hasSession(roomId)) {
      await _keyStore.clearPendingEphemeralSeed(roomId);
      return SecretHandshakeOutcome.ignored;
    }
    // 이미 멈춘 방 — 아무것도 하지 않는다(멈췄다는 안내는 처음 멈출 때 한 번만).
    if ((await _securityOf(roomId)).blocked) {
      return SecretHandshakeOutcome.ignored;
    }
    final pendingInit = await _keyStore.readPendingInit(roomId);
    // 수락한 사람은 내가 초대한 사람이어야 한다 — 서버가 알려 주는 수락자를 그대로 믿지 않는다. 업데이트 전에 건
    // 초대(초대한 상대를 적어 두지 않음)면 방의 상대 멤버로 본다.
    final expected = pendingInit.targetUserId ?? _otherMemberOf(roomId);
    final peerUserId = event.responderUserId ?? expected;
    if (peerUserId == null) {
      return SecretHandshakeOutcome.ignored; // 누구와의 대화인지 모르면 확인할 수 없다.
    }
    if ((expected != null && peerUserId != expected) ||
        !_isMemberOfKnownRoom(roomId, peerUserId)) {
      return _block(roomId, SecretBlockReason.peerMismatch);
    }
    final peerDeviceId = event.responderDeviceId;
    final existing = await _bindingOf(roomId);
    if (existing != null &&
        (existing.peerUserId != peerUserId ||
            existing.peerDeviceId != peerDeviceId)) {
      return _block(roomId, SecretBlockReason.deviceMismatch);
    }
    final theirEphemeralBytes = _x25519Bytes(event.responderEphemeralPublicKey);
    if (theirEphemeralBytes == null) {
      return _block(roomId, SecretBlockReason.badSignature);
    }
    final key = await _peerKeyFor(peerDeviceId, peerUserId);
    // 서버에 묻는 사이 로그아웃해 버린 매니저면 여기서 그만둔다(새 매니저가 같은 방에 적은 것을 덮어쓰지 않게).
    _ensureNotDisposed();
    final keyFailure = key.failure;
    if (keyFailure != null) {
      return _blockForKey(roomId, peerDeviceId, key, keyFailure);
    }

    final myEphemeral = await X25519().newKeyPairFromSeed(myPendingSeed);
    final myEphemeralPublicKey = await publicKeyBase64(myEphemeral);
    // 초대할 때 쓴 이 기기 id — 그 뒤 이 기기의 id가 바뀌었어도 상대는 초대에 실린 id로 서명했다.
    final initiatorDeviceId = pendingInit.myDeviceId ?? myDeviceId;
    String acceptContext(
      String Function({
        required String roomId,
        required String initiatorUserId,
        required String initiatorDeviceId,
        required String initiatorEphemeralPublicKey,
        required String responderUserId,
        required String responderDeviceId,
        required String responderEphemeralPublicKey,
      })
      build,
    ) => build(
      roomId: roomId,
      initiatorUserId: me,
      initiatorDeviceId: initiatorDeviceId,
      initiatorEphemeralPublicKey: myEphemeralPublicKey,
      responderUserId: peerUserId,
      responderDeviceId: peerDeviceId,
      responderEphemeralPublicKey: event.responderEphemeralPublicKey,
    );
    // 새 규약을 안다고 알린 초대에 상대가 v3 맥락으로 서명했으면 v3로 대화한다. 아니면(상대가 예전 앱이거나, 서버가
    // 초대에서 규약 표시를 빼 상대가 예전 규약으로 수락함) 예전처럼 v2·v1 서명을 본다. v3·v2 맥락은 머리가 달라 한쪽
    // 서명이 다른 쪽으로 맞지 않고, v3로 수락한 새 앱은 예전 서명 칸에도 v3 서명을 넣어(acceptInvite) 서버가 맥락 서명을
    // 빼면 여기서 멈춘다 — 두 기기가 다른 규약으로 맺어지지 않는다.
    var useV3 = false;
    var check = (ok: false, legacy: false);
    final contextSignature = event.responderContextSignature;
    if ((pendingInit.offeredProtocol ?? 0) >= crypto.secretProtocolV3 &&
        contextSignature != null) {
      try {
        useV3 = await crypto.verifyContext(
          signingPublicKeyBase64: key.signingPublicKey!,
          context: acceptContext(crypto.secretAcceptContextV3),
          signatureBase64: contextSignature,
        );
      } on ArgumentError {
        useV3 = false;
      }
      if (useV3) check = (ok: true, legacy: false);
    }
    if (!useV3) {
      check = await _verifyPeer(
        signingPublicKey: key.signingPublicKey!,
        contextSignature: contextSignature,
        context: () => acceptContext(crypto.secretAcceptContext),
        ephemeralPublicKey: event.responderEphemeralPublicKey,
        ephemeralSignature: event.responderEphemeralSignature,
      );
    }
    if (!check.ok) {
      return _blockForKey(
        roomId,
        peerDeviceId,
        key,
        SecretBlockReason.badSignature,
      );
    }
    // 상대 기기에 먼저 묶고 그다음 고정한다(acceptInvite와 같은 까닭 — 다른 방에서 드러난 키 다툼이 이 방을 빠뜨리지
    // 않게). 고정은 세션 키를 적기 전에 — 같은 기기를 다른 키로 먼저 고정한 곳이 있으면 여기서 멈춘다.
    await _saveBinding(
      roomId,
      SecretRoomBinding(
        peerUserId: peerUserId,
        peerDeviceId: peerDeviceId,
        myDeviceId: initiatorDeviceId,
      ),
    );
    final pinned = await _pinPeerDevice(roomId, peerDeviceId, peerUserId, key);
    final pinFailure = pinned.failure;
    if (pinFailure != null) {
      return _block(
        roomId,
        pinFailure,
        deviceId: peerDeviceId,
        pin: pinned.pin,
      );
    }
    final deviceChanged = pinned.deviceChanged;
    // 새 규약을 알린 초대인데 새 규약으로 말하는 것을 확인한 기기가 예전 규약으로 수락했다고 온다 — 서버가 초대에서 새 규약
    // 표시를 빼 상대가 예전 방식으로 수락하게 한 것이다. 예전 방식으로 맺지 않고 멈춘다(이 업데이트 전에 건 초대는 새
    // 규약을 알리지 않았으니 그대로 맺는다).
    if (!useV3 &&
        (pendingInit.offeredProtocol ?? 0) >= crypto.secretProtocolV3 &&
        pinned.pin?.speaksV3 == true) {
      return _block(
        roomId,
        SecretBlockReason.downgrade,
        deviceId: peerDeviceId,
        pin: pinned.pin,
      );
    }

    SecretRatchetState? ratchet;
    List<int>? chainKey;
    if (useV3) {
      final rootKey = await crypto.deriveRootKeyV3(
        myEphemeralKeyPair: myEphemeral,
        theirEphemeralPublicKey: theirEphemeralBytes,
        roomId: roomId,
        // 수락 맥락과 같은 칸(양쪽 사용자·기기·임시키) — 수락한 기기가 만든 것과 같은 값이 된다.
        transcript: acceptContext(crypto.secretRootTranscriptV3),
      );
      ratchet = rootKey == null
          ? null
          : await SecretRatchetState.forInitiator(
              rootKey: rootKey,
              responderEphemeralPublicKey: event.responderEphemeralPublicKey,
            );
      // 서명은 맞는데 공유비밀이 0뿐인 임시키 — 상대 기기가 일부러 만든 값이 아니면 생길 수 없다.
      if (ratchet == null) {
        return _block(roomId, SecretBlockReason.badSignature);
      }
    } else {
      chainKey = await crypto.deriveInitialChainKey(
        myEphemeralKeyPair: myEphemeral,
        theirEphemeralPublicKey: SimplePublicKey(
          theirEphemeralBytes,
          type: KeyPairType.x25519,
        ),
        roomId: roomId,
      );
    }
    _ensureNotDisposed();
    await _saveSecurity(
      roomId,
      (await _securityOf(
        roomId,
      )).copyWith(legacyPeer: check.legacy, peerDeviceChanged: deviceChanged),
    );
    if (ratchet != null) {
      await _keyStore.saveRatchetState(roomId, ratchet);
      _ratchetStates[roomId] = ratchet;
      _protocols[roomId] = crypto.secretProtocolV3;
      // 상대 기기가 v3 맥락으로 서명했다 — 그 기기가 새 규약으로 말한다(서버가 꾸밀 수 없는 증거).
      await _markSpeaksV3(peerDeviceId, peerUserId);
    } else {
      final state = SecretChainState(epoch: 0, n: 0, chainKey: chainKey!);
      await _keyStore.saveChainState(roomId, state, skipped: const []);
      _chainStates[roomId] = state;
      _v1Skipped[roomId] = const [];
      _protocols[roomId] = 1;
    }
    await _keyStore.clearPendingEphemeralSeed(roomId);
    await _refreshTrust(roomId);
    return deviceChanged
        ? SecretHandshakeOutcome.establishedOnChangedDevice
        : SecretHandshakeOutcome.established;
  });

  Future<bool> hasActiveSession(String roomId) => _keyStore.hasSession(roomId);

  /// 이 기기가 이 방의 세션을 맺었고 서버도 그 수락을 받았다고 답했는지(응답을 기다리는 수락이 아님) — 같은 초대를 다시
  /// 띄우지 않을 때 쓴다(다시 수락하면 맺은 세션이 깨진다).
  Future<bool> hasEstablishedSession(String roomId) async =>
      await _keyStore.hasSession(roomId) &&
      !await _keyStore.hasAcceptPending(roomId);

  // ---- 평문 캐시(secret_key_store.dart) ----

  /// 이미 한 번 복호화에 성공한 메시지/댓글의 평문을 재사용한다(한 방향 래칫이라 두 번째부터는
  /// 암호문을 다시 복호화할 수 없기 때문 — secret_key_store.dart 참고). 서버가 지운 메시지의 평문이
  /// 이 기기에 남지 않도록 방·작성 시각·삭제 예정 시각을 함께 적어 둔다.
  /// [requireEnvelopeMatch]는 SecretKeyStore.readDecryptedText와 같다(같은 봉투를 푼 평문일 때만).
  Future<String?> readCachedDecryptedText(
    SecretTextRef ref, {
    bool requireEnvelopeMatch = false,
  }) => _keyStore.readDecryptedText(
    ref,
    requireEnvelopeMatch: requireEnvelopeMatch,
  );

  Future<void> cacheDecryptedText(SecretTextRef ref, String text) =>
      _keyStore.saveDecryptedText(ref, text);

  /// 메시지·댓글이 지워졌을 때(message:deleted / comment:deleted).
  Future<void> forgetDecryptedText(String roomId, String id) =>
      _keyStore.deleteDecryptedText(roomId, id);

  /// 서버가 메시지를 완전히 지웠을 때(message:expired) — 그 댓글 평문까지.
  Future<void> forgetExpiredMessage(String roomId, String messageId) =>
      _keyStore.deleteMessageTexts(roomId, messageId);

  /// 서버가 메시지 읽음을 확정했을 때(secret:message-read) — 그 자동 삭제 시각을 적어 둔다.
  Future<void> noteMessageRead(String messageId, DateTime? expiresAt) =>
      _keyStore.noteMessageRead(messageId, expiresAt);

  /// 이 기기가 타이머가 켜진 방에서 메시지 읽음을 보냈을 때 — 확정 알림을 못 받아도 지워지게 어림한
  /// 삭제 예정 시각을 먼저 적어 둔다.
  Future<void> noteLocalRead(String messageId, Duration selfDestruct) =>
      _keyStore.noteLocalRead(messageId, selfDestruct);

  /// 히스토리를 요청하기 직전에 잡아 두는 평문 캐시 저장 순번([reconcileHistoryPage]에 넘긴다).
  int get textCacheGeneration => _keyStore.textCacheGeneration;

  /// 히스토리 한 페이지로 서버가 더 이상 주지 않는(지운) 메시지·댓글의 평문을 지운다 — SecretKeyStore 참고.
  Future<List<SecretCachedTextInfo>> reconcileHistoryPage({
    required String roomId,
    required List<Message> page,
    required DateTime? before,
    required int limit,
    required int sinceGeneration,
  }) => _keyStore.reconcileHistoryPage(
    roomId: roomId,
    page: page,
    before: before,
    limit: limit,
    sinceGeneration: sinceGeneration,
  );

  /// 삭제 예정 시각이 지난 평문을 지운다(앱 시작·방 열기·포그라운드 복귀 때, 그리고 스스로 타이머로).
  Future<List<SecretCachedTextInfo>> purgeExpiredTexts() =>
      _keyStore.purgeExpiredTexts();

  /// 삭제 예정 시각이 지나 지운 항목을 알려 줄 곳(열려 있는 방 화면에서도 빼도록).
  set onExpiredTextsPurged(
    void Function(List<SecretCachedTextInfo> removed)? callback,
  ) => _keyStore.onExpiredTextsPurged = callback;

  /// 이 기기의 비밀 대화 평문 캐시 — Session이 방 화면 없이 서버와 맞추는 뒷정리(서버 시각 알려 주기, 히스토리
  /// 페이지 반영, 남은 방 찾기, 예전 형식 정리)에 쓴다. 방이 없어졌을 때는 키까지 지우는 [forgetRoom]을 쓴다.
  SecretKeyStore get textCache => _keyStore;

  /// 로그아웃·재로그인으로 이 매니저를 버릴 때 — 평문 정리 타이머를 멈춘다.
  void dispose() {
    _disposed = true;
    onTrustChanged = null;
    // 보낸 평문·키는 메모리에만 있다 — 로그아웃한 뒤 다른 계정이 같은 PC를 써도 남지 않게 비운다.
    _recentlySentPlaintext.clear();
    _v1SentKeys.clear();
    _ratchetStates.clear();
    _chainStates.clear();
    _v1Skipped.clear();
    _keyStore.dispose();
  }

  // ---- 암복호화 ----

  /// 방 [roomId]의 새 규약 래칫 상태 — 메모리에 없으면 저장소에서 읽는다(없거나 깨졌으면 null).
  Future<SecretRatchetState?> _ratchetStateOf(String roomId) async {
    if (_keepStateInMemory) {
      final cached = _ratchetStates[roomId];
      if (cached != null) return cached;
    }
    final stored = (await _keyStore.readRatchetState(roomId)).state;
    if (stored != null && _keepStateInMemory) _ratchetStates[roomId] = stored;
    return stored;
  }

  Future<void> _saveRatchetState(
    String roomId,
    SecretRatchetState state, {
    required bool skippedChanged,
  }) async {
    _ensureNotDisposed();
    try {
      await _keyStore.saveRatchetState(
        roomId,
        state,
        skippedChanged: skippedChanged,
      );
    } catch (_) {
      // 저장소에 무엇이 남았는지 모른다 — 다음에 저장소에서 다시 읽는다.
      _ratchetStates.remove(roomId);
      rethrow;
    }
    _ratchetStates[roomId] = state;
  }

  /// 방 [roomId]의 예전 규약 체인 상태 — 메모리에 없으면 저장소에서 읽는다(없거나 깨졌으면 null).
  Future<SecretChainState?> _chainStateOf(String roomId) async {
    if (_keepStateInMemory) {
      final cached = _chainStates[roomId];
      if (cached != null) return cached;
    }
    final stored = await _keyStore.readChainState(roomId);
    if (stored != null && _keepStateInMemory) _chainStates[roomId] = stored;
    return stored;
  }

  /// 방 [roomId]의 예전 규약에서 남겨 둔 메시지 키.
  Future<List<SecretSkippedKey>> _v1SkippedOf(String roomId) async {
    if (!_keepStateInMemory) return _keyStore.readV1SkippedKeys(roomId);
    return _v1Skipped[roomId] ??= await _keyStore.readV1SkippedKeys(roomId);
  }

  Future<void> _saveChainState(
    String roomId,
    SecretChainState state, {
    List<SecretSkippedKey>? skipped,
  }) async {
    _ensureNotDisposed();
    try {
      await _keyStore.saveChainState(roomId, state, skipped: skipped);
    } catch (_) {
      _chainStates.remove(roomId);
      _v1Skipped.remove(roomId);
      rethrow;
    }
    _chainStates[roomId] = state;
    if (skipped != null) _v1Skipped[roomId] = skipped;
  }

  Future<void> _saveV1Skipped(
    String roomId,
    List<SecretSkippedKey> skipped,
  ) async {
    _ensureNotDisposed();
    try {
      await _keyStore.saveV1SkippedKeys(roomId, skipped);
    } catch (_) {
      _v1Skipped.remove(roomId);
      rethrow;
    }
    _v1Skipped[roomId] = skipped;
  }

  /// 메시지/댓글 전송 직전 — 평문을 암호문 봉투(JSON)로 바꾼다. 세션이 아직 성립되지 않았으면(핸드셰이크 진행 중)
  /// null을 돌려준다 — 호출자는 전송을 보류해야 한다. 보안 확인에 실패해 멈춘 방이면 [SecretChatBlockedException],
  /// 이 기기에 저장한 키 상태가 깨졌으면 [SecretChatBrokenException]을 던진다. 키 상태는 봉투를 돌려주기 전에 저장한다
  /// (저장하지 못한 키로 보내면 다음 메시지가 같은 키를 다시 쓴다). [place]는 이 글이 놓이는 자리 — 새 규약이면 암호문
  /// 안에 함께 넣는다(없으면 새 메시지로 본다).
  Future<String?> encryptForRoom(
    String roomId,
    String plainText, {
    SecretTextPlace? place,
  }) => _inRoom(roomId, () async {
    _ensureNotDisposed();
    if ((await _securityOf(roomId)).blocked) {
      throw const SecretChatBlockedException();
    }
    final Map<String, dynamic> envelope;
    switch (await _protocolOf(roomId)) {
      case crypto.secretProtocolV3:
        final state = await _ratchetStateOf(roomId);
        if (state == null) throw const SecretChatBrokenException();
        final sealed = await state.encrypt(
          roomId: roomId,
          plainText: _wrapPlacedText(plainText, place),
        );
        await _saveRatchetState(roomId, sealed.state, skippedChanged: false);
        envelope = sealed.envelope;
      case 1:
        final state = await _chainStateOf(roomId);
        if (state == null) throw const SecretChatBrokenException();
        final step = await crypto.ratchetStep(state.chainKey);
        envelope = await crypto.encryptEnvelope(
          msgKey: step.msgKey,
          plainText: plainText,
          roomId: roomId,
          epoch: state.epoch,
          n: state.n,
        );
        await _saveChainState(
          roomId,
          SecretChainState(
            epoch: state.epoch,
            n: state.n + 1,
            chainKey: step.nextChainKey,
          ),
        );
        _rememberV1SentKey(
          roomId,
          state.epoch,
          state.n,
          step.msgKey,
          envelope['nonce'] as String,
        );
      default:
        return null;
    }
    final envelopeJson = jsonEncode(envelope);
    _rememberSent(
      roomId,
      envelope['nonce'] as String,
      plainText,
      envelopeJson,
      place,
    );
    return envelopeJson;
  });

  /// 수신한 암호문 봉투를 평문으로. 풀 수 없으면(다른 세션·변조·이미 받은 메시지·너무 많이 건너뜀·깨진 봉투) null —
  /// 그때는 저장된 키 상태를 바꾸지 않는다. [senderUserId]는 서버가 알려 준 보낸 사람(메시지·댓글의 senderId,
  /// 모르면 null) — 봉투가 그 사람의 것인지도 본다: 내가 보낸 것이라는 메시지는 이 기기가 보낼 때 들고 있던 평문으로만
  /// 보여 주고, 그 밖의 메시지(보낸 사람을 모르는 것 포함)는 상대의 키로 풀려야 한다(서버가 서로의 메시지를 바꿔 붙이지
  /// 못하게). [cacheAs]를 주면 푼 평문을 그 자리로 평문 캐시에 적는다 — 키 상태를 저장하기 전에 적어서, 그 사이 꺼져도
  /// 평문을 잃지 않는다(적지 못하면 키 상태를 저장하지 않아 나중에 같은 봉투를 다시 풀 수 있다). [slot]은 서버가 이 글을
  /// 보여 주는 자리 — 주면 새 규약의 암호문에 적힌 자리(또는 내가 보낼 때 놓은 자리)와 맞아야 푼다([SecretTextSlot.accepts]).
  Future<String?> decryptForRoom(
    String roomId,
    String envelopeJson, {
    String? senderUserId,
    SecretTextRef? cacheAs,
    SecretTextSlot? slot,
  }) => _inRoom(roomId, () async {
    try {
      return await _decrypt(roomId, envelopeJson, senderUserId, cacheAs, slot);
    } catch (e) {
      // 깨진 봉투(JSON이 아님 등)·저장소 오류 — 이 메시지만 풀지 못한 것으로 둔다(상태는 그대로라 다시 시도할 수 있다).
      debugPrint('[secret] 복호화 실패: room=$roomId $e');
      return null;
    }
  });

  Future<String?> _decrypt(
    String roomId,
    String envelopeJson,
    String? senderUserId,
    SecretTextRef? cacheAs,
    SecretTextSlot? slot,
  ) async {
    final decoded = jsonDecode(envelopeJson);
    if (decoded is! Map<String, dynamic>) return null;
    if (senderUserId != null && senderUserId == _myUserId) {
      // 내가 보낸 메시지가 되돌아온 것 — 보내는 체인은 이미 지나가 다시 풀 수 없어서 보낼 때 들고 있던 평문을 쓴다.
      // 멈춘 대화여도 내가 쓴 글이라 그대로 보인다. 없으면 내가 다른 기기에서, 또는 앱을 다시 켜기 전에 보낸 것이다.
      final nonce = decoded['nonce'];
      final sent = nonce is String
          ? _sentPlaintextFor(roomId, nonce, envelopeJson, slot)
          : null;
      // 평문 캐시에 메시지 id로 적었으면 메모리에서 뺀다 — 다시 와도 그 캐시가 준다.
      if (sent != null &&
          cacheAs != null &&
          await _cacheText(cacheAs, sent) &&
          nonce is String) {
        _recentlySentPlaintext.remove(_sentCacheKey(roomId, nonce));
      }
      return sent;
    }
    // 멈춘 대화는 새로 받은 것도 풀지 않는다 — 상대 기기 키를 믿을 수 없게 돼 멈췄으면(키 다툼·사용자가 키를 지움)
    // 이 세션을 서버와 맺었을 수 있어, 서버가 상대인 척 보낸 글을 그대로 보여 주게 된다. 이미 풀어 둔 평문은
    // 평문 캐시에서 그대로 보인다.
    if ((await _securityOf(roomId)).blocked) return null;
    // 상대가 보냈다는 메시지는 이 방에 묶인 상대의 것이어야 한다(비밀 대화는 두 사람뿐이다).
    if (senderUserId != null) {
      final binding = await _bindingOf(roomId);
      if (binding != null && binding.peerUserId != senderUserId) return null;
    }
    switch (await _protocolOf(roomId)) {
      case crypto.secretProtocolV3:
        return _decryptV3(roomId, decoded, cacheAs, slot);
      case 1:
        return _decryptV1(roomId, decoded, cacheAs);
      default:
        return null;
    }
  }

  /// 푼 평문을 [ref] 자리로 평문 캐시에 적는다. 적지 못했으면 false(부른 쪽은 키 상태를 저장하지 않는다).
  Future<bool> _cacheText(SecretTextRef? ref, String plain) async {
    if (ref == null) return true;
    try {
      await _keyStore.saveDecryptedText(ref, plain);
      return true;
    } catch (e) {
      debugPrint('[secret] 푼 평문을 저장하지 못함: room=${ref.roomId} $e');
      return false;
    }
  }

  Future<String?> _decryptV3(
    String roomId,
    Map<String, dynamic> json,
    SecretTextRef? cacheAs,
    SecretTextSlot? slot,
  ) async {
    final envelope = SecretEnvelopeV3.tryParse(json);
    if (envelope == null) return null;
    final state = await _ratchetStateOf(roomId);
    if (state == null) return null;
    final opened = await state.decrypt(roomId: roomId, envelope: envelope);
    if (opened == null) return null;
    // 암호문 안에 적힌 자리가 서버가 보여 주는 자리와 다르면(다른 글 아래로 옮긴 댓글 등) 풀지 않는다 — 키 상태도
    // 그대로 둬서, 제자리로 다시 오면 풀린다.
    final placed = _unwrapPlacedText(opened.plainText);
    if (placed == null) return null;
    if (slot != null && !slot.accepts(placed.place)) {
      debugPrint('[secret] 자리가 맞지 않는 글을 풀지 않음: room=$roomId');
      return null;
    }
    // 이 기기 쪽에서 상대 기기가 새 규약으로 말하는 것을 확인했다 — 그 기기와 나중에 예전 규약으로 맺게 하면 막는다.
    await _notePeerSpeaksV3(roomId);
    if (await _cacheText(cacheAs, placed.text)) {
      try {
        await _saveRatchetState(
          roomId,
          opened.state,
          skippedChanged: opened.skippedChanged,
        );
      } catch (e) {
        // 푼 평문은 이미 적어 뒀다 — 키 상태만 그대로 남는다(다음 메시지가 이 번호를 건너뛴 키로 남긴다).
        debugPrint('[secret] 키 상태를 저장하지 못함: room=$roomId $e');
      }
    }
    return placed.text;
  }

  /// 예전 규약(v1) 봉투 — 체인 하나를 두 사람이 함께 쓴다. 지금 위치보다 앞선 번호면 그만큼 감되 지나친 번호의 키는
  /// 남겨 두고(늦게 올 메시지), 지난 번호면 남겨 둔 키나 이 기기가 그 번호로 막 보낼 때 쓴 키(거의 동시에 보냄)로
  /// 푼다. 풀린 뒤에만 체인을 저장한다. 남겨 둔 키는 그 키를 쓰거나 새로 남길 때만 읽는다(차례대로 오는 메시지는 체인만).
  Future<String?> _decryptV1(
    String roomId,
    Map<String, dynamic> json,
    SecretTextRef? cacheAs,
  ) async {
    final epoch = json['epoch'];
    final n = json['n'];
    final nonce = json['nonce'];
    final cipherText = json['ciphertext'];
    if (epoch is! int || n is! int || n < 0) return null;
    // 같은 바이트를 다른 글자로 적은 nonce·암호문은 받지 않는다 — 내 봉투를 글자만 바꿔 되돌려 보내면 "다른 메시지"로
    // 보여, 동시에 보낸 메시지를 풀려고 들고 있는 내 키로 풀려 버린다(내 글이 상대 글로 보인다).
    if (nonce is! String ||
        cipherText is! String ||
        !crypto.isCanonicalBase64(nonce) ||
        !crypto.isCanonicalBase64(cipherText)) {
      return null;
    }
    final state = await _chainStateOf(roomId);
    if (state == null) return null;
    final chain = 'e$epoch';
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (epoch == state.epoch && n >= state.n) {
      if (n - state.n > crypto.v1MaxCatchUpSteps) return null;
      final added = <SecretSkippedKey>[];
      var key = state.chainKey;
      for (var i = state.n; i < n; i++) {
        final step = await crypto.ratchetStep(key);
        added.add(SecretSkippedKey(chain, i, step.msgKey, storedAtMs: nowMs));
        key = step.nextChainKey;
      }
      final step = await crypto.ratchetStep(key);
      final plain = await crypto.decryptEnvelope(
        msgKey: step.msgKey,
        envelope: json,
        roomId: roomId,
      );
      if (plain == null) return null;
      if (await _cacheText(cacheAs, plain)) {
        try {
          await _saveChainState(
            roomId,
            SecretChainState(
              epoch: state.epoch,
              n: n + 1,
              chainKey: step.nextChainKey,
            ),
            skipped: added.isEmpty
                ? null
                : appendSkippedKeys(
                    pruneExpiredSkippedKeys(await _v1SkippedOf(roomId), nowMs),
                    added,
                  ),
          );
        } catch (e) {
          debugPrint('[secret] 키 상태를 저장하지 못함: room=$roomId $e');
        }
      }
      return plain;
    }
    // 지난 번호 — 늦게 온 메시지거나, 상대가 거의 같은 때 같은 번호로 보낸 메시지다. 이 업데이트 전의 재키잉 직후 늦게
    // 온 지난 epoch 메시지는 풀지 않는다(그런 메시지가 있으면 그 재키잉에서 이미 두 기기의 체인이 갈라졌다).
    final skipped = pruneExpiredSkippedKeys(await _v1SkippedOf(roomId), nowMs);
    final known = indexOfSkippedKey(skipped, chain, n);
    if (known >= 0) {
      final plain = await crypto.decryptEnvelope(
        msgKey: skipped[known].key,
        envelope: json,
        roomId: roomId,
      );
      if (plain == null) return null;
      if (await _cacheText(cacheAs, plain)) {
        try {
          await _saveV1Skipped(roomId, [...skipped]..removeAt(known));
        } catch (e) {
          debugPrint('[secret] 남겨 둔 키를 저장하지 못함: room=$roomId $e');
        }
      }
      return plain;
    }
    final sentKey = _v1SentKeyFor(roomId, epoch, n, nonce);
    if (sentKey != null) {
      final plain = await crypto.decryptEnvelope(
        msgKey: sentKey,
        envelope: json,
        roomId: roomId,
      );
      if (plain != null) {
        if (await _cacheText(cacheAs, plain)) {
          _v1SentKeys.remove('$roomId|$epoch|$n');
        }
        return plain;
      }
    }
    return null;
  }

  /// 내가 보낸 평문을 nonce로, 그 봉투·놓은 자리와 함께 적어 둔다([_recentlySentPlaintext]) — 오래됐거나 넘치면 오래된
  /// 것부터 버린다.
  void _rememberSent(
    String roomId,
    String nonce,
    String plainText,
    String envelopeJson,
    SecretTextPlace? place,
  ) {
    final now = DateTime.now();
    _recentlySentPlaintext.removeWhere(
      (_, v) => now.difference(v.at) > _recentlySentLifetime,
    );
    _recentlySentPlaintext[_sentCacheKey(roomId, nonce)] = (
      text: plainText,
      envelope: envelopeJson,
      place: place,
      at: now,
    );
    while (_recentlySentPlaintext.length > _maxRecentlySent) {
      _recentlySentPlaintext.remove(_recentlySentPlaintext.keys.first);
    }
  }

  /// 내가 보낸 봉투([nonce] — 봉투 전체가 [envelopeJson]과 같아야 한다)의 평문. 오래돼 버렸거나, 서버가 보여 주는 자리
  /// [slot]이 보낼 때 놓은 자리와 다르면 null.
  String? _sentPlaintextFor(
    String roomId,
    String nonce,
    String envelopeJson,
    SecretTextSlot? slot,
  ) {
    final key = _sentCacheKey(roomId, nonce);
    final entry = _recentlySentPlaintext[key];
    if (entry == null || entry.envelope != envelopeJson) return null;
    final place = entry.place;
    if (slot != null && place != null && !slot.accepts(place)) return null;
    if (DateTime.now().difference(entry.at) > _recentlySentLifetime) {
      _recentlySentPlaintext.remove(key);
      return null;
    }
    return entry.text;
  }

  /// 예전 규약(v1) — 이 기기가 [n]번으로 보낼 때 쓴 메시지 키를 그 봉투의 [nonce]와 함께 잠깐 들고 있는다([_v1SentKeys]).
  void _rememberV1SentKey(
    String roomId,
    int epoch,
    int n,
    List<int> key,
    String nonce,
  ) {
    final now = DateTime.now();
    _v1SentKeys.removeWhere(
      (_, v) => now.difference(v.at) > _v1SentKeyLifetime,
    );
    _v1SentKeys['$roomId|$epoch|$n'] = (key: key, nonce: nonce, at: now);
    while (_v1SentKeys.length > _maxV1SentKeys) {
      _v1SentKeys.remove(_v1SentKeys.keys.first);
    }
  }

  /// 이 기기가 [n]번으로 보낸 키 — 받은 봉투의 [nonce]가 그때 내 봉투의 것이면(내 메시지가 되돌아옴) 쓰지 않는다.
  List<int>? _v1SentKeyFor(String roomId, int epoch, int n, Object? nonce) {
    final entry = _v1SentKeys['$roomId|$epoch|$n'];
    if (entry == null || nonce == entry.nonce) return null;
    if (DateTime.now().difference(entry.at) > _v1SentKeyLifetime) {
      _v1SentKeys.remove('$roomId|$epoch|$n');
      return null;
    }
    return entry.key;
  }

  // ---- 화면에 보여 줄 신뢰 상태·보안 코드 ----

  /// 방 [roomId]의 신뢰 상태 — [loadTrust]로 읽어 둔 값(아직 안 읽었으면 null).
  SecretRoomTrust? trustOf(String roomId) => _trust[roomId];

  /// 방 [roomId]의 신뢰 상태를 저장소에서 읽는다(예전 대화면 방 정보로 상대 기기를 묶어 본다). 바뀌었으면
  /// [onTrustChanged]로 알린다.
  Future<SecretRoomTrust> loadTrust(String roomId) async {
    try {
      await _bindingFor(roomId);
    } catch (_) {}
    await _refreshTrust(roomId);
    return _trust[roomId] ?? const SecretRoomTrust();
  }

  Future<void> _refreshTrust(String roomId) async {
    final binding = await _bindingOf(roomId);
    final security = await _securityOf(roomId);
    final myDeviceId = _myDeviceIdOrNull;
    final boundPin = await _boundPinOf(binding);
    // 다툼 중인 고정은 "확인함"으로 보이지 않는다 — 그 키가 진짜인지부터 알 수 없다.
    final verifiedAt =
        boundPin == null || boundPin.disputed || myDeviceId == null
        ? null
        : boundPin.verifiedAtFor(myDeviceId);
    final reset = await _keyResetState(binding, boundPin, security);
    final trust = SecretRoomTrust(
      peerUserId: binding?.peerUserId,
      peerDeviceId: binding?.peerDeviceId,
      verifiedAt: verifiedAt,
      security: security,
      resetDeviceId: reset.deviceId,
      peerKeyAlreadyReset: reset.alreadyReset,
      legacyProtocol: await _protocolOf(roomId) == 1,
    );
    if (_trust[roomId] == trust) return;
    _trust[roomId] = trust;
    if (!_disposed) onTrustChanged?.call(roomId);
  }

  /// [binding]이 묶인 상대 기기의 고정(없거나, 주인이 묶인 상대와 다르면 null).
  Future<SecretDevicePin?> _boundPinOf(SecretRoomBinding? binding) async {
    if (binding == null) return null;
    final pin = await _keyStore.readDevicePin(binding.peerDeviceId);
    return pin != null && pin.userId == binding.peerUserId ? pin : null;
  }

  /// "상대 기기 키 다시 받기"로 고정을 지울 수 있는 상대 기기와, 멈춘 방이면 그 원인이던 고정을 이미 지웠는지(또는 그
  /// 뒤 새로 받았는지). 멈춘 방은 고정해 둔 키 때문에 멈췄고([SecretRoomSecurity.blockedDeviceId]) 그 고정이 그때
  /// 그대로일 때만 지울 수 있다 — 지우고 다시 받은 새 고정을, 예전에 멈춘 이 방에서 또 지워 버리지 않게. 멈추지 않은
  /// 방은 이 방이 묶인 기기의 고정이다(보안 코드가 다를 때).
  Future<({String? deviceId, bool alreadyReset})> _keyResetState(
    SecretRoomBinding? binding,
    SecretDevicePin? boundPin,
    SecretRoomSecurity security,
  ) async {
    if (security.blocked) {
      final device = security.blockedDeviceId;
      if (device == null || !security.blockedReason!.allowsKeyReset) {
        return (deviceId: null, alreadyReset: false);
      }
      final entry = await _keyStore.readDevicePinEntry(device);
      // 깨진 고정 때문에 멈췄으면 고정 시각이 없다 — 아직 깨진 채로 있을 때만 같은 고정으로 본다.
      final samePin =
          entry.present &&
          entry.pin?.firstSeenAt.millisecondsSinceEpoch ==
              security.blockedPinSeenAt?.millisecondsSinceEpoch;
      return samePin
          ? (deviceId: device, alreadyReset: false)
          : (deviceId: null, alreadyReset: true);
    }
    return (
      deviceId: boundPin == null ? null : binding?.peerDeviceId,
      alreadyReset: false,
    );
  }

  /// 방 [roomId]의 보안 코드 — 상대 기기가 아직 묶이지 않았으면(핸드셰이크 전, 예전 대화를 묶지 못함) null.
  Future<SecretSafetyInfo?> safetyInfo(String roomId) async {
    final binding = await _bindingFor(roomId);
    if (binding == null) return null;
    final pin = await _keyStore.readDevicePin(binding.peerDeviceId);
    if (pin == null || pin.userId != binding.peerUserId) return null;
    final me = _me;
    final myDeviceId = _identity.deviceId;
    final groups = await crypto.computeSafetyNumber(
      crypto.safetyNumberEntry(
        userId: me,
        deviceId: myDeviceId,
        signingPublicKey: await publicKeyBase64(_identity.signingKeyPair),
      ),
      crypto.safetyNumberEntry(
        userId: binding.peerUserId,
        deviceId: binding.peerDeviceId,
        signingPublicKey: pin.signingPublicKey,
      ),
    );
    return SecretSafetyInfo(
      groups: groups,
      peerUserId: binding.peerUserId,
      peerDeviceId: binding.peerDeviceId,
      // 다툼이 생긴(서버가 두 가지 키를 알려 온) 키는 "확인함"으로 보이지 않는다 — _refreshTrust와 같은 기준.
      verifiedAt: pin.disputed ? null : pin.verifiedAtFor(myDeviceId),
      myKeyChanged:
          binding.myDeviceId != null && binding.myDeviceId != myDeviceId,
    );
  }

  /// 방 [roomId]의 상대 기기를 보안 코드로 확인했다고 표시하거나([verified]) 지운다. 확인하면 "상대 기기가 바뀜"
  /// 안내도 끈다. 같은 기기에 묶인 다른 방의 표시도 함께 바뀐다(확인은 기기 단위).
  Future<void> setPeerVerified(String roomId, bool verified) async {
    final binding = await _bindingOf(roomId);
    if (binding == null) return;
    final pin = await _boundPinOf(binding);
    if (pin == null || pin.disputed) return;
    final myDeviceId = _identity.deviceId;
    // 확인 표시만 바꾼다(고정한 키는 이걸로도 바뀌지 않는다) — 그 사이 고정을 지웠거나 다시 받았으면 아무것도 안 한다.
    final changed = await _keyStore.setDevicePinVerified(
      binding.peerDeviceId,
      pin,
      myDeviceId: myDeviceId,
      verifiedAt: verified ? DateTime.now() : null,
    );
    if (changed && verified) {
      final security = await _securityOf(roomId);
      if (security.peerDeviceChanged) {
        await _saveSecurity(
          roomId,
          security.copyWith(peerDeviceChanged: false),
        );
      }
    }
    for (final entry in _bindings.entries.toList()) {
      if (entry.value.peerDeviceId == binding.peerDeviceId) {
        await _refreshTrust(entry.key);
      }
    }
    await _refreshTrust(roomId);
  }

  /// "예전 앱" 안내를 닫는다.
  Future<void> dismissLegacyNotice(String roomId) async {
    final security = await _securityOf(roomId);
    await _saveSecurity(roomId, security.copyWith(legacyNoticeDismissed: true));
    await _refreshTrust(roomId);
  }

  /// "예전 방식으로 맺은 대화" 안내를 닫는다.
  Future<void> dismissProtocolNotice(String roomId) async {
    final security = await _securityOf(roomId);
    await _saveSecurity(
      roomId,
      security.copyWith(protocolNoticeDismissed: true),
    );
    await _refreshTrust(roomId);
  }

  /// "상대 기기가 바뀜" 안내를 닫는다.
  Future<void> dismissDeviceChangedNotice(String roomId) async {
    final security = await _securityOf(roomId);
    await _saveSecurity(roomId, security.copyWith(peerDeviceChanged: false));
    await _refreshTrust(roomId);
  }

  /// "상대 기기 키 다시 받기" — 방 [roomId]의 상대 기기([SecretRoomTrust.resetDeviceId])를 이 기기에 고정해 둔 키를
  /// 지운다. 사용자가 보안 코드가 다르다고 했거나, 상대가 앱을 다시 설치하는 등으로 그 기기의 키가 바뀐 것을 상대에게
  /// 직접 확인했을 때만 부른다(화면이 확인 창을 거친다) — 고정이 영영 맞지 않는 기기와 다시 대화할 길은 이것뿐이다.
  /// 그 키를 믿고 맺은 대화(그 기기에 묶인 방)는 더 믿을 근거가 없어 모두 멈춘다. 다음 새 대화에서 서버가 알려 주는
  /// 키를 처음 보는 기기처럼 다시 고정하므로, 그 대화에서 보안 코드를 꼭 비교해야 한다. 지운 기기 id(지울 수 있는
  /// 고정이 없었으면 null — 아무것도 하지 않는다).
  Future<String?> resetPeerDevicePin(String roomId) async {
    final binding = await _bindingOf(roomId);
    final security = await _securityOf(roomId);
    final target = (await _keyResetState(
      binding,
      await _boundPinOf(binding),
      security,
    )).deviceId;
    if (target == null) return null;
    await _keyStore.deleteDevicePin(target);
    _v3ConfirmedDevices.remove(target);
    await _blockRoomsBoundTo(
      target,
      SecretBlockReason.keyReset,
      notify: false, // 사용자가 고른 일이라 "보안 확인에 실패" 알림은 띄우지 않는다.
    );
    // 그 고정 때문에 멈춰 있던 방(묶이지 않은 방 포함)의 "다시 받기" 표시도 바뀐다 — 화면이 읽어 둔 방을 다시 본다.
    for (final id in {..._trust.keys, roomId}) {
      await _refreshTrust(id);
    }
    return target;
  }

  void _forgetRoomCaches(String roomId) {
    _forgetBinding(roomId);
    _securities.remove(roomId);
    _trust.remove(roomId);
    _forgetKeyState(roomId);
    _recentlySentPlaintext.removeWhere((key, _) => key.startsWith('$roomId|'));
  }

  /// 방 [roomId]의 핸드셰이크를 되돌린다(SecretKeyStore.clearSessionKeys) — 지우다 실패해도 들고 있는 상태는 버린다
  /// (저장소에 무엇이 남았는지 모른다 — 다음에 저장소에서 다시 읽는다). 방 줄 안에서만 부른다.
  Future<void> _clearSessionKeys(String roomId) async {
    try {
      await _keyStore.clearSessionKeys(roomId);
    } finally {
      _forgetRoomCaches(roomId);
    }
  }

  /// 방 [roomId]를 이 기기에서 지운다(SecretKeyStore.clearRoom) — [_clearSessionKeys]처럼 실패해도 들고 있는 상태는
  /// 버린다. 방 줄 안에서만 부른다.
  Future<void> _clearRoom(String roomId) async {
    try {
      await _keyStore.clearRoom(roomId);
    } finally {
      _forgetRoomCaches(roomId);
    }
  }

  /// 방이 없어졌을 때(종료·거절·나가기) — 그 방의 키 상태·묶인 상대 기기·보안 상태와 이 기기에 저장해 둔 평문까지
  /// 지운다. 상대 기기 고정은 남긴다(같은 기기와 새로 대화해도 그 키만 믿는다).
  Future<void> forgetRoom(String roomId) async {
    await _inRoom(roomId, () => _clearRoom(roomId));
    if (!_disposed) onTrustChanged?.call(roomId);
  }
}
