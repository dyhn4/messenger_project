import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/message.dart';
import 'secret_peer_store.dart';
import 'secret_ratchet.dart';

/// 예전 규약(v1) 비밀 대화 방 하나의 현재 래칫 상태. chainKey는 항상 "다음 메시지에 쓸" 체인키를 가리킨다
/// (secret_chat_crypto.dart의 ratchet 함수가 매 메시지 후 이 자리를 갱신한다). 새 규약(v3) 방은
/// secret_ratchet.dart의 SecretRatchetState를 쓴다.
class SecretChainState {
  final int epoch;
  final int n;
  final List<int> chainKey;
  const SecretChainState({
    required this.epoch,
    required this.n,
    required this.chainKey,
  });

  String encode() =>
      jsonEncode({'e': epoch, 'n': n, 'k': base64Encode(chainKey)});

  /// 깨진 값이면 null.
  static SecretChainState? decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final epoch = json['e'];
      final n = json['n'];
      final key = json['k'];
      if (epoch is! int || n is! int || n < 0 || key is! String) return null;
      final bytes = base64Decode(key);
      if (bytes.length != 32) return null;
      return SecretChainState(epoch: epoch, n: n, chainKey: bytes);
    } on FormatException {
      return null;
    }
  }
}

/// 이 기기에 저장해 둔 비밀 대화 평문 하나의 자리·만료 정보 — 메모리 색인용이라 평문 자체는 담지 않는다.
class SecretCachedTextInfo {
  const SecretCachedTextInfo({
    required this.roomId,
    required this.id,
    this.parentId,
    required this.createdAtMs,
    this.expiresAtMs,
    this.expiryFixed = false,
    this.generation = 0,
  });

  final String roomId;

  /// 메시지 id 또는 댓글 id.
  final String id;

  /// 댓글이면 그 댓글이 달린 원본 메시지 id, 메시지면 null — 서버는 원본을 완전히 지울 때 댓글도
  /// 함께 지운다(FK cascade).
  final String? parentId;

  /// 서버가 매긴 작성 시각 — 히스토리 응답이 어느 범위를 훑었는지와 견줄 때 쓴다.
  final int createdAtMs;

  /// 이 시각이 지나면 서버가 지웠을 것이므로 이 기기에서도 지운다. null이면 아직 모르거나 자동
  /// 삭제되지 않는 항목이다(타이머 없는 비밀 대화는 계속 남아야 재시작 뒤에도 히스토리가 보인다).
  final int? expiresAtMs;

  /// [expiresAtMs]가 서버가 확정한 값(상대가 읽은 뒤의 readAt/expiresAt)인지. 확정한 값은 서버 시계 기준이라
  /// 서버의 지금(SecretKeyStore.noteServerTime)과 비교한다. false면 아직 모르거나, 이 기기가 읽음을 보낸
  /// 시각과 방 타이머로 어림한 값이다(이 기기 시계 기준 — 서버 값이 오면 그것으로 바뀐다).
  final bool expiryFixed;

  /// 이 기기 메모리에서만 쓰는 저장 순번(앱을 켤 때 저장소에서 읽은 항목·예전 형식에서 옮긴 항목은 0). 히스토리를
  /// 요청한 뒤에 처음 저장된 항목은 그 응답보다 늦게 생긴 메시지일 수 있어서, 응답에 없어도 지우지 않으려고 쓴다.
  final int generation;

  bool get isComment => parentId != null;

  /// 삭제 예정 시각만 바꾼 값 — 저장 순번은 그대로 둔다(메시지가 새로 생긴 게 아니라서, 순번을 올리면 그 뒤
  /// 히스토리 재조정이 이 항목을 "요청 뒤에 생긴 것"으로 보고 건너뛴다).
  SecretCachedTextInfo _withExpiry(int? expiresAtMs, {required bool fixed}) =>
      SecretCachedTextInfo(
        roomId: roomId,
        id: id,
        parentId: parentId,
        createdAtMs: createdAtMs,
        expiresAtMs: expiresAtMs,
        expiryFixed: fixed,
        generation: generation,
      );
}

/// 평문 캐시를 읽고 쓸 메시지(또는 댓글) 하나 — Session.decryptInPlace/decryptCommentInPlace가 만든다.
class SecretTextRef {
  const SecretTextRef({
    required this.roomId,
    required this.id,
    this.parentId,
    required this.createdAt,
    this.expiryKnown = false,
    this.expiresAt,
    this.envelope,
    this.fromMe,
    this.senderId,
  });

  final String roomId;
  final String id;

  /// 댓글이면 원본 메시지 id.
  final String? parentId;
  final DateTime createdAt;

  /// 서버가 이 메시지(댓글이면 원본 메시지)의 읽음을 확정했는지(readAt이 있음). 그러면 [expiresAt]이
  /// 서버가 정한 자동 삭제 시각 그대로다 — null이면 읽을 때 타이머가 꺼져 있어 자동 삭제되지 않는다.
  final bool expiryKnown;
  final DateTime? expiresAt;

  /// 서버가 지금 이 메시지로 보여 주는 암호문 봉투(text) — 저장할 때 그 지문을 함께 적고, 읽을 때 지문이 다르면(수정된
  /// 메시지·서버가 다른 봉투를 붙임) 저장해 둔 평문을 주지 않는다. 모르면 null(확인하지 않는다).
  final String? envelope;

  /// 서버가 이 메시지를 내가 보낸 것으로 보여 주는지 — 저장할 때 적고, 읽을 때 다르면(서버가 보낸 사람을 바꿔 붙임)
  /// 저장해 둔 평문을 주지 않는다. 모르면 null.
  final bool? fromMe;

  /// 서버가 알려 준 보낸 사람 id(탈퇴한 사람이면 null) — [fromMe]와 같이 적고, 둘 다 알 때 다르면(서버가 다른 사람으로
  /// 바꿔 붙임) 저장해 둔 평문을 주지 않는다.
  final String? senderId;
}

const _textKeyPrefix = 'secretcache/';

/// 예전 형식 — 평문만 있고 어느 방·언제 것인지 몰라서 만료·재조정을 할 수 없다. 읽을 때 새 형식으로 옮긴다.
const _legacyTextKeyPrefix = 'secretmsg/';

/// 방별 키 상태(secret/<방>/<항목>) — 래칫 상태·대기 중인 임시키와, 그 방이 어느 계정 것인지([_ownerField]).
const _roomKeyPrefix = 'secret/';

/// 그 방을 목록에서 본 계정 id. 공용 PC처럼 한 기기를 여러 계정이 쓰면 다른 계정의 비밀 대화 키·평문도 같은
/// 저장소에 있다 — 지금 계정이 "멤버가 아님"을 받은 방이 내가 나온 방인지 남의 방인지 이걸로 가린다.
const _ownerField = 'owner';

/// 이 계정으로 갈 수 있는 비밀 대화방 히스토리를 한 번 처음부터 다 훑어 예전 형식 평문을 옮겼다는
/// 표시(secretcache-legacy/<계정 id>) — 다시 켤 때마다 전체 히스토리를 받지 않게 한다.
const _legacySweptKeyPrefix = 'secretcache-legacy/';

/// 상대 기기 고정(secretpin/<기기 id> — secret_peer_store.dart SecretDevicePin). 방별 키([_roomKeyPrefix])로 읽히면
/// 안 된다 — 그러면 "목록에 없는 방"으로 보여 뒷정리가 지울 수 있다. 'secret/'·'secretcache/'·'secretmsg/'로 시작하지
/// 않으므로 평문 캐시 색인·정리는 이 값을 건드리지 않고, 방이 없어져도(forgetRoom) 남는다.
const _pinKeyPrefix = 'secretpin/';

/// 방이 묶인 상대 기기(SecretRoomBinding)와 그 방의 보안 상태(SecretRoomSecurity) — 방별 키라 방이 없어지면 함께 지운다.
const _peerField = 'peer';
const _securityField = 'security';

/// 내가 건 초대가 응답을 기다리는 동안 대기 중인 임시키와 함께 들고 있는 것 — 초대한 상대와 그때 쓴 이 기기 id.
/// 상대가 수락하면 이걸로 수락 맥락 서명을 확인한다(서버가 알려 주는 "수락한 사람"을 그대로 믿지 않으려고).
const _pendingInitField = 'pendingInit';

/// 새 규약(v3) 방의 더블 래칫 상태(secret_ratchet.dart SecretRatchetState — 남겨 둔 메시지 키는 [_skippedField]에 따로).
const _ratchetField = 'ratchet';

/// 예전 규약(v1) 방의 래칫 상태 — epoch·n·체인키를 JSON 한 값에(한 번에 바뀐다). 예전에는 칸마다 따로 적어서, 그
/// 사이에 쓰기가 실패하거나 앱이 꺼지면 새 번호와 옛 체인키가 섞여 그 대화가 영영 어긋났다. 예전 칸은 [_legacyChainFields].
const _chainField = 'chain';

/// 이 업데이트 전 앱이 적던 예전 규약(v1) 래칫 상태의 칸들 — 읽기만 하고, 새로 적을 때([_chainField]) 지운다.
/// prevEpoch·prevChainKeySnapshot은 예전 재키잉 직전의 체인키라(재키잉을 하지 않아 더 쓸 데가 없다) 버린다. 이 순서로
/// 지운다 — chainKey가 마지막이라, 그것이 남아 있으면 다 지우지 못한 것이다(SecretKeyStore.readChainState가 다시 지운다).
const _legacyChainFields = [
  'epoch',
  'n',
  'prevEpoch',
  'prevChainKeySnapshot',
  'chainKey',
];

/// 늦게 올 메시지를 위해 남겨 둔 메시지 키(secret_ratchet.dart encodeSkippedKeys) — 방 하나는 한 규약만 쓰므로 두 규약이
/// 같은 칸을 쓴다. 바뀔 때만 다시 쓴다(키가 많으면 커서 메시지마다 다시 쓰지 않게).
const _skippedField = 'skipped';

/// 이 기기가 수락을 보냈는데 서버가 받았다는 답을 아직 못 받은 대화의 표시 — 있으면 같은 초대를 다시 수락할 수 있고
/// (응답을 못 받은 수락 다시 하기), 없으면 이미 맺은 대화라 다시 온 초대를 무시한다(SecretSessionManager.acceptInvite).
const _acceptPendingField = 'acceptPending';

/// 이 기기에 남은 방의 세션 키 상태(평문 캐시·계정 표시·보안 상태는 빼고) — 핸드셰이크를 되돌릴 때 지운다. 보안
/// 상태([_securityField])는 멈춤을 지키며 따로 정리한다(clearSessionKeys).
const _sessionKeyFields = [
  ..._legacyChainFields,
  _chainField,
  _skippedField,
  _ratchetField,
  _acceptPendingField,
  'pendingEphemeralSeed',
  _pendingInitField,
  'pendingRekeyEpoch',
  'pendingRekeySeed',
  _peerField,
];

/// 세션의 키 재료만(묶인 상대·보안 상태·대기 중인 초대는 빼고) — 멈춘 방에서 더 쓰지 않을 키를 지울 때와, 수락을 다시 해
/// 새 세션을 적기 전에 예전 것(다른 규약 포함)을 비울 때.
const _sessionKeyMaterialFields = [
  ..._legacyChainFields,
  _chainField,
  _skippedField,
  _ratchetField,
  'pendingRekeyEpoch',
  'pendingRekeySeed',
];

/// 예전 앱이 남긴 재키잉 임시키를 한 번 다 치웠다는 표시 — 새 앱은 재키잉 임시키를 만들지 않아서 한 번이면 된다.
/// 'secret/'·'secretcache/'·'secretmsg/'·'secretpin/'으로 시작하지 않아 방·평문·고정으로 읽히지 않는다.
const _staleRekeyCleanupKey = 'secretmeta/rekey-cleanup-v3';

/// GET /rooms/:id/messages가 한 번에 주는 최대 개수(server/src/rooms.js — 더 달라고 해도 이만큼만 준다).
const _serverHistoryPageMax = 200;

/// 자동 삭제 시각이 지나도 이만큼 기다렸다가 이 기기에서 지운다. 연결돼 있으면 서버의 message:expired
/// (5초마다 훑음)가 먼저 와서 지우므로 이건 그 알림을 놓쳤을 때(꺼져 있었음 등)의 뒷정리다.
@visibleForTesting
const secretTextExpiryGrace = Duration(minutes: 1);

/// 다음 정리까지 한 번에 기다리는 최대 시간 — 절전·시계 변경이 있어도 이 간격으로 다시 확인한다.
const _maxPurgeWait = Duration(minutes: 5);

/// 이 기기 시계가 서버보다 이만큼 넘게 빠르지는 않다고 본다 — 서버 시각을 아직 못 받았거나(꺼진 채 오프라인으로
/// 켬) 받은 것이 오래됐어도, "이 기기 시계 − 이만큼"까지는 서버 시각도 지났다고 보고 서버가 정한 시각이 그만큼
/// 지난 평문은 지운다. 기기 시계가 이보다 더 빠르면 그 차이만큼 일찍 지울 수 있다(자동 시간 맞춤이 꺼진 기기 등).
@visibleForTesting
const secretDeviceClockTolerance = Duration(days: 1);

/// 히스토리 한 페이지(GET /rooms/:id/messages 응답 [page] — [before]·[limit]으로 요청한 것)를 보고, [entries]
/// 중 "서버에서 없어졌다"고 확실히 말할 수 있는 항목의 id를 고른다. 이번 요청이 실제로 훑은 범위(창) 안의
/// 것만 본다 — 창 밖(더 오래됐거나 요청 뒤에 생긴 것)은 응답에 없어도 지워졌다는 뜻이 아니다. [entries]에는
/// 이 방 항목 중 요청을 보내기 전에 저장된 것만 넘긴다(그 뒤에 온 메시지는 응답보다 새것일 수 있다).
///
/// 서버 규칙(server/src/rooms.js): 창은 before보다 앞선 최근 [limit]개(최대 200)이고, 창 메시지의 댓글은
/// 전부, 창 시간대([가장 오래된 창 메시지 시각, before))에 달린 댓글은 부모가 창 밖이어도(outOfWindow 부모와
/// 함께) 온다.
/// - 아래 경계: 페이지가 꽉 찼으면 가장 오래된 창 메시지 시각 "초과"만 본다 — 같은 시각(밀리초 아래까지
///   같은 동점)의 메시지가 창 밖에 남았을 수 있다. 덜 찼으면 방의 처음까지 다 받은 것이다.
/// - 위 경계: before가 있으면 그 "미만", 없으면(최신 페이지) 끝까지.
/// - 댓글: 창 안 메시지의 댓글, 없어진 메시지의 댓글, 창 시간대의 댓글이 응답에 없으면 없어진 것이다.
Set<String> secretCacheIdsGoneFromPage({
  required Iterable<SecretCachedTextInfo> entries,
  required List<Message> page,
  required DateTime? before,
  required int limit,
}) {
  final present = <String>{};
  final inWindowIds = <String>{};
  int? oldestMs;
  for (final m in page) {
    present.add(m.id);
    for (final c in m.comments) {
      present.add(c.id);
    }
    if (m.outOfWindow) continue;
    inWindowIds.add(m.id);
    final ms = m.createdAt.millisecondsSinceEpoch;
    if (oldestMs == null || ms < oldestMs) oldestMs = ms;
  }
  final beforeMs = before?.millisecondsSinceEpoch;
  final reachedStart =
      inWindowIds.length < math.min(limit, _serverHistoryPageMax);
  bool inWindow(int ms) {
    if (beforeMs != null && ms >= beforeMs) return false;
    final lower = oldestMs;
    if (lower == null || reachedStart) return true;
    return ms > lower;
  }

  final gone = <String>{};
  for (final e in entries) {
    if (e.isComment || present.contains(e.id)) continue;
    if (inWindow(e.createdAtMs)) gone.add(e.id);
  }
  for (final e in entries) {
    final parentId = e.parentId;
    if (parentId == null || present.contains(e.id)) continue;
    if (inWindowIds.contains(parentId) ||
        gone.contains(parentId) ||
        inWindow(e.createdAtMs)) {
      gone.add(e.id);
    }
  }
  return gone;
}

/// 저장소 작업 하나가 한참 지나도 끝나지 않아(저장소가 멈춤) 그 작업이 끝날 때까지 다른 저장소 작업을 하지 않을 때 —
/// 그 사이 저장소를 건드리면 멈춘 작업이 뒤늦게 쓴 값과 섞여 키 상태가 되돌아가거나 어긋난다.
class SecretStorageBusyException implements Exception {
  const SecretStorageBusyException();

  @override
  String toString() => '비밀 대화 저장소가 응답하지 않습니다. 잠시 뒤 다시 시도해 주세요.';
}

/// flutter_secure_storage(Windows DPAPI / Android Keystore)에 방별 네임스페이스로 래칫 상태를
/// 저장한다. 여러 기기 동기화를 안 하는 요구사항의 핵심 — 이 값들은 이 기기에만 있고, 서버에는
/// 절대 올라가지 않는다.
class SecretKeyStore {
  final FlutterSecureStorage _storage;
  SecretKeyStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  // ---- 저장소 접근 줄 세우기 ----
  //
  // flutter_secure_storage의 Windows 구현은 모든 값을 파일 하나에 담아서, 쓰기·지우기마다 "파일 전체 읽기 →
  // 고치기 → 파일 전체 쓰기"를 한다. 두 작업이 겹치면 늦게 끝난 쪽이 먼저 끝난 쪽의 변경을 덮어써 버린다
  // (예: 체인키 저장이 평문 캐시 정리에 덮여 되돌아가면 같은 메시지 키를 한 번 더 쓰게 된다). 평문 캐시를
  // 뒤에서 정리하는 작업(자동 삭제 만료·히스토리 재조정)이 생기면서 겹칠 일이 늘어서, 이 클래스의 저장소
  // 접근을 앱 전체에서 한 줄로 세운다(인스턴스가 여럿이어도 저장소는 하나라 static). 줄 선 작업 안에서 다시
  // 줄을 서면(_serial 안의 _serial) 서로 기다리다 멈추므로, 줄 안에서 쓰는 도우미는 이름 끝에 Locked를 붙였다.
  static Future<void> _tail = Future<void>.value();

  /// 한참([storageOpTimeout]) 지나도 끝나지 않은 저장소 작업 — 끝날 때까지 뒤 작업은 저장소를 건드리지 않고 바로
  /// [SecretStorageBusyException]으로 실패한다.
  static Future<void>? _stuck;

  /// 저장소 작업 하나가 이만큼 지나도 끝나지 않으면 멈춘 것으로 본다.
  @visibleForTesting
  static const storageOpTimeout = Duration(seconds: 30);

  Future<T> _serial<T>(Future<T> Function() op) {
    final previous = _tail;
    final turn = Completer<void>();
    _tail = turn.future;
    return previous.then((_) {
      if (_stuck != null) {
        turn.complete();
        throw const SecretStorageBusyException();
      }
      final result = Future<T>.sync(op);
      final settled = result.then<void>((_) {}, onError: (Object _) {});
      // 저장소 호출 하나가 멈춰 버리면, 이 작업이 시작하고 한참 지난 뒤 줄은 넘기되 그 작업이 끝날 때까지 뒤 작업은
      // 저장소를 건드리지 않고 실패하게 한다(앱 전체가 영영 기다리지 않게). 멈춘 작업이 뒤늦게 쓰는 값과 뒤 작업의
      // 쓰기가 섞이면 래칫 상태가 되돌아가 같은 키를 다시 쓰거나 대화가 어긋난다. 시간은 이 작업이 시작한 때부터
      // 잰다 — 줄이 길 때(평문 캐시가 커서 쓰기 하나가 오래 걸리는데 읽음 표시가 한꺼번에 몰림 등) 앞 작업이 끝나기
      // 전에 뒤 작업이 실패하지 않게.
      final timer = Timer(storageOpTimeout, () {
        _stuck = settled;
        if (!turn.isCompleted) turn.complete();
      });
      unawaited(
        settled.whenComplete(() {
          timer.cancel();
          if (identical(_stuck, settled)) _stuck = null;
          if (!turn.isCompleted) turn.complete();
        }),
      );
      return result;
    });
  }

  String _k(String roomId, String field) => '$_roomKeyPrefix$roomId/$field';

  /// 예전 칸([_legacyChainFields])이 남아 있는 예전 규약 방(이번 실행에서 그 형식으로 읽었거나, 지우다 실패해 남은 것을
  /// 봄) — 다음에 적을 때 그 칸들을 지운다(그 체인키로 그 뒤 메시지를 풀 수 있어 남겨 두면 안 된다).
  final Set<String> _legacyChainRooms = {};

  /// 이번 실행에서 예전 칸이 남았는지 이미 본 방 — 읽을 때마다 다시 보지 않게.
  final Set<String> _legacyCheckedRooms = {};

  /// 예전 규약(v1) 방의 래칫 상태를 적는다 — 한 값([_chainField])이라 한 번에 바뀐다. [skipped]를 주면 늦게 올 메시지를
  /// 위해 남겨 둔 키도 같은 줄에서 먼저 바꾼다(비면 지운다) — 그 사이 꺼져도 다시 받은 메시지로 같은 키를 다시 만든다.
  Future<void> saveChainState(
    String roomId,
    SecretChainState state, {
    List<SecretSkippedKey>? skipped,
  }) => _serial(() async {
    _keyedRoomIds.add(roomId);
    if (skipped != null) await _writeSkippedLocked(roomId, skipped);
    await _storage.write(key: _k(roomId, _chainField), value: state.encode());
    // 이 업데이트 전 형식의 칸이 남아 있으면 지운다 — 새 값을 먼저 적었으니 그 사이 꺼져도 다음에는 새 값을 읽는다.
    // 지우다 실패해도 이 상태는 적혔으니 실패로 보지 않고, 다음에 적을 때 다시 지운다.
    if (_legacyChainRooms.contains(roomId)) {
      try {
        for (final field in _legacyChainFields) {
          await _storage.delete(key: _k(roomId, field));
        }
        _legacyChainRooms.remove(roomId);
      } catch (e) {
        debugPrint('[secret] 예전 형식의 체인 상태를 지우지 못함(다음에 다시): room=$roomId $e');
      }
    }
  });

  /// 예전 규약(v1) 방의 래칫 상태(없거나 깨졌으면 null). 이 업데이트 전 형식(칸마다 따로)도 읽는다.
  Future<SecretChainState?> readChainState(String roomId) => _serial(() async {
    final raw = await _storage.read(key: _k(roomId, _chainField));
    if (raw != null) {
      // 예전 칸을 지우다 실패해 남았으면(앱이 꺼졌거나 저장소 오류 — 체인키를 마지막에 지운다) 다음에 적을 때 지운다.
      if (_legacyCheckedRooms.add(roomId) &&
          await _storage.read(key: _k(roomId, 'chainKey')) != null) {
        _legacyChainRooms.add(roomId);
      }
      return SecretChainState.decode(raw);
    }
    final epoch = await _storage.read(key: _k(roomId, 'epoch'));
    final n = await _storage.read(key: _k(roomId, 'n'));
    final chainKey = await _storage.read(key: _k(roomId, 'chainKey'));
    if (epoch == null || n == null || chainKey == null) return null;
    final parsedEpoch = int.tryParse(epoch);
    final parsedN = int.tryParse(n);
    final List<int> key;
    try {
      key = base64Decode(chainKey);
    } on FormatException {
      return null;
    }
    if (parsedEpoch == null || parsedN == null || key.length != 32) return null;
    _legacyChainRooms.add(roomId);
    return SecretChainState(epoch: parsedEpoch, n: parsedN, chainKey: key);
  });

  Future<void> _writeSkippedLocked(
    String roomId,
    List<SecretSkippedKey> skipped,
  ) async {
    if (skipped.isEmpty) {
      await _storage.delete(key: _k(roomId, _skippedField));
    } else {
      await _storage.write(
        key: _k(roomId, _skippedField),
        value: jsonEncode(encodeSkippedKeys(skipped)),
      );
    }
  }

  Future<List<SecretSkippedKey>> _readSkippedLocked(String roomId) async {
    final raw = await _storage.read(key: _k(roomId, _skippedField));
    if (raw == null) return const [];
    try {
      return decodeSkippedKeys(jsonDecode(raw)) ?? const [];
    } on FormatException {
      return const [];
    }
  }

  /// 예전 규약(v1) 방에 남겨 둔 메시지 키만 바꾼다(늦게 온 메시지를 풀고 그 키를 지울 때 — 체인은 그대로).
  Future<void> saveV1SkippedKeys(
    String roomId,
    List<SecretSkippedKey> skipped,
  ) => _serial(() => _writeSkippedLocked(roomId, skipped));

  /// 예전 규약(v1) 방에 남겨 둔 메시지 키(없거나 깨졌으면 빈 목록).
  Future<List<SecretSkippedKey>> readV1SkippedKeys(String roomId) =>
      _serial(() => _readSkippedLocked(roomId));

  /// 새 규약(v3) 방의 더블 래칫 상태를 적는다. 남겨 둔 메시지 키([SecretRatchetState.skipped])는 따로 적고, 그 키가
  /// 바뀌었을 때([skippedChanged])만 다시 쓴다(먼저 — 그 사이 꺼지면 다시 받은 메시지로 같은 키를 다시 만들 뿐이다).
  Future<void> saveRatchetState(
    String roomId,
    SecretRatchetState state, {
    bool skippedChanged = true,
  }) => _serial(() async {
    _keyedRoomIds.add(roomId);
    if (skippedChanged) await _writeSkippedLocked(roomId, state.skipped);
    await _storage.write(
      key: _k(roomId, _ratchetField),
      value: state.encode(includeSkipped: false),
    );
  });

  /// 새 규약(v3) 방의 더블 래칫 상태(남겨 둔 키를 붙여서) — 없으면 [present]가 false, 있는데 깨졌으면 [state]만 null.
  Future<({bool present, SecretRatchetState? state})> readRatchetState(
    String roomId,
  ) => _serial(() async {
    final raw = await _storage.read(key: _k(roomId, _ratchetField));
    if (raw == null) return (present: false, state: null);
    final state = SecretRatchetState.decode(raw);
    if (state == null) return (present: true, state: null);
    final stored = await _readSkippedLocked(roomId);
    if (state.skipped.isEmpty) {
      return (present: true, state: state.withSkipped(stored));
    }
    // 남겨 둔 키를 상태 안에 함께 적은 값(이 형식을 정하기 전의 시험판) — 따로 적는 칸으로 옮긴다. 상태를 다시 적을 때는
    // 남겨 둔 키가 바뀌었을 때만 그 칸을 적어서, 옮기지 않으면 그 키를 잃는다.
    final merged = appendSkippedKeys(stored, state.skipped);
    await _writeSkippedLocked(roomId, merged);
    await _storage.write(
      key: _k(roomId, _ratchetField),
      value: state.encode(includeSkipped: false),
    );
    return (present: true, state: state.withSkipped(merged));
  });

  /// 이 방에 맺어 둔 세션의 규약 — 새 규약(더블 래칫)이면 3, 예전 규약이면 1, 세션이 없으면 null.
  /// 상태가 깨져 있어도 그 규약이다(세션이 없다고 보면 다시 맺거나 예전 대화로 잘못 묶는다).
  Future<int?> sessionProtocol(String roomId) => _serial(() async {
    if (await _storage.read(key: _k(roomId, _ratchetField)) != null) return 3;
    if (await _storage.read(key: _k(roomId, _chainField)) != null) return 1;
    if (await _storage.read(key: _k(roomId, 'chainKey')) != null) return 1;
    return null;
  });

  /// 이 방에 맺어 둔 세션(어느 규약이든)이 있는지.
  Future<bool> hasSession(String roomId) async =>
      await sessionProtocol(roomId) != null;

  /// 세션의 키 재료만 지운다([_sessionKeyMaterialFields] — 묶인 상대·보안 상태·대기 중인 초대는 둔다). 멈춘 방에서 더
  /// 쓰지 않을 키를 지울 때와, 수락을 다시 해 새 세션을 적기 전에 예전 것(다른 규약의 칸 포함)을 비울 때 쓴다.
  Future<void> deleteSessionKeyMaterial(String roomId) => _serial(() async {
    for (final field in _sessionKeyMaterialFields) {
      await _storage.delete(key: _k(roomId, field));
    }
    _legacyChainRooms.remove(roomId);
  });

  /// 이 기기가 보낸 수락을 서버가 받았다는 답을 아직 못 받았다고 적는다([_acceptPendingField]) — 세션을 적기 전에.
  Future<void> markAcceptPending(String roomId) => _serial(() async {
    _keyedRoomIds.add(roomId);
    await _storage.write(key: _k(roomId, _acceptPendingField), value: '1');
  });

  /// 서버가 이 기기의 수락을 받았다 — 그 표시를 지운다(없으면 쓰지 않는다).
  Future<void> clearAcceptPending(String roomId) => _serial(() async {
    final key = _k(roomId, _acceptPendingField);
    if (await _storage.read(key: key) != null) {
      await _storage.delete(key: key);
    }
  });

  /// 이 기기가 보낸 수락이 아직 확인되지 않았는지.
  Future<bool> hasAcceptPending(String roomId) => _serial(
    () async =>
        await _storage.read(key: _k(roomId, _acceptPendingField)) != null,
  );

  /// 계정 [userId]의 방들에서 예전 앱이 남긴 재키잉 임시키를 이미 다 치웠는지([_staleRekeyCleanupKey]).
  Future<bool> staleRekeyCleanupDone(String userId) => _serial(
    () async =>
        await _storage.read(key: '$_staleRekeyCleanupKey/$userId') != null,
  );

  Future<void> markStaleRekeyCleanupDone(String userId) => _serial(
    () => _storage.write(key: '$_staleRekeyCleanupKey/$userId', value: '1'),
  );

  /// 핸드셰이크 중에는 REST 왕복 사이 이 기기의 임시 개인키(시드)를 잠깐 들고 있어야
  /// 한다 — 상대가 응답하면 그때 공유비밀을 계산하고 즉시 지운다. [targetUserId]·[myDeviceId]는 초대한 상대와
  /// 그때의 이 기기 id — 수락이 오면 그 맥락 서명을 이 값으로 다시 만들어 확인한다. [offeredProtocol]은 초대에 실어
  /// 보낸 규약 번호(새 규약을 안다고 알렸으면 3) — 수락이 그 규약의 맥락 서명으로 왔는지 볼 때 쓴다.
  Future<void> savePendingEphemeralSeed(
    String roomId,
    List<int> seed, {
    String? targetUserId,
    String? myDeviceId,
    int? offeredProtocol,
  }) => _serial(() async {
    _keyedRoomIds.add(roomId);
    await _storage.write(
      key: _k(roomId, 'pendingEphemeralSeed'),
      value: base64Encode(seed),
    );
    if (targetUserId != null || myDeviceId != null || offeredProtocol != null) {
      await _storage.write(
        key: _k(roomId, _pendingInitField),
        value: jsonEncode({
          't': ?targetUserId,
          'd': ?myDeviceId,
          'p': ?offeredProtocol,
        }),
      );
    }
  });

  Future<List<int>?> readPendingEphemeralSeed(String roomId) =>
      _serial(() async {
        final v = await _storage.read(key: _k(roomId, 'pendingEphemeralSeed'));
        return v == null ? null : base64Decode(v);
      });

  /// 대기 중인 초대의 상대·이 기기 id·실어 보낸 규약 번호([savePendingEphemeralSeed]). 이 값을 남기기 전(업데이트
  /// 전)에 건 초대거나 깨진 값이면 모두 null.
  Future<({String? targetUserId, String? myDeviceId, int? offeredProtocol})>
  readPendingInit(String roomId) => _serial(() async {
    final raw = await _storage.read(key: _k(roomId, _pendingInitField));
    if (raw != null) {
      try {
        final json = jsonDecode(raw);
        if (json is Map) {
          final target = json['t'];
          final device = json['d'];
          final protocol = json['p'];
          return (
            targetUserId: target is String ? target : null,
            myDeviceId: device is String ? device : null,
            offeredProtocol: protocol is int ? protocol : null,
          );
        }
      } on FormatException {
        // 깨진 값 — 모르는 것으로 둔다(방 멤버로 상대를 정한다).
      }
    }
    return (targetUserId: null, myDeviceId: null, offeredProtocol: null);
  });

  Future<void> clearPendingEphemeralSeed(String roomId) => _serial(() async {
    await _storage.delete(key: _k(roomId, 'pendingEphemeralSeed'));
    await _storage.delete(key: _k(roomId, _pendingInitField));
  });

  /// 예전 앱이 재키잉을 제안하고 수락을 기다리며 남겨 둔 임시 개인키를 지운다 — 이제 재키잉을 하지 않아 쓸 일이
  /// 없다(secret_session_manager.dart). 남아 있어 지웠으면 true(없으면 저장소에 쓰지 않는다).
  Future<bool> clearStaleRekeySeed(String roomId) => _serial(() async {
    final epochKey = _k(roomId, 'pendingRekeyEpoch');
    final seedKey = _k(roomId, 'pendingRekeySeed');
    if (await _storage.read(key: epochKey) == null &&
        await _storage.read(key: seedKey) == null) {
      return false;
    }
    await _storage.delete(key: epochKey);
    await _storage.delete(key: seedKey);
    return true;
  });

  /// 방 나가기/비밀 대화 거절 시 이 방의 모든 로컬 키 상태를 흔적 없이 지운다 — 이 기기에 저장해 둔
  /// 그 방의 평문 캐시와 계정 표시, 묶인 상대 기기·보안 상태도 함께(서버는 방을 통째로 지웠거나 나를 뺐다).
  /// 상대 기기 고정([readDevicePin])은 방과 상관없는 값이라 남긴다 — 같은 기기와 새로 대화해도 그 키만 믿는다.
  Future<void> clearRoom(String roomId) async {
    await _serial(() async {
      for (final field in [..._sessionKeyFields, _securityField, _ownerField]) {
        await _storage.delete(key: _k(roomId, field));
      }
      _keyedRoomIds.remove(roomId);
      _roomOwners.remove(roomId);
      _legacyChainRooms.remove(roomId);
    });
    await clearRoomTexts(roomId);
  }

  /// 이 기기가 맺은 줄 알았던 핸드셰이크를 되돌린다 — 체인키·대기 중인 임시키·묶인 상대를 지우고 평문 캐시와 계정
  /// 표시는 둔다(서버가 이 기기의 수락을 받지 않았거나, 내 다른 기기가 먼저 수락했을 때). 보안 상태는 그 세션에 붙은
  /// 안내(예전 앱·상대 기기 바뀜)만 지우고 멈춤은 남긴다 — 이 되돌리기는 서버가 보내는 값(수락 알림·방 정보)을 보고
  /// 일어나서, 멈춤까지 지우면 가로채려다 들킨 서버가 그 멈춤을 스스로 풀 수 있다(멈춘 대화는 끝내고 새로 시작하는
  /// 것 말고는 되돌릴 수 없어야 한다). 깨진 보안 상태 값은 멈춘 것으로 읽히므로 그대로 둔다.
  Future<void> clearSessionKeys(String roomId) => _serial(() async {
    for (final field in _sessionKeyFields) {
      await _storage.delete(key: _k(roomId, field));
    }
    _legacyChainRooms.remove(roomId);
    final securityKey = _k(roomId, _securityField);
    final raw = await _storage.read(key: securityKey);
    if (raw == null) return;
    final security = SecretRoomSecurity.decode(raw);
    if (security == null) return;
    if (security.blocked) {
      await _storage.write(
        key: securityKey,
        value: security.blockOnly().encode(),
      );
    } else {
      await _storage.delete(key: securityKey);
    }
  });

  // ---- 상대 기기 고정(S5 — secret_peer_store.dart) ----
  //
  // 한 번 고정한 기기의 키·주인은 바꾸지 않는다. 처음 고정은 "없을 때만 적기"([pinDeviceIfAbsent]), "확인함" 표시는
  // 같은 고정일 때만 고치기([setDevicePinVerified]) — 둘 다 읽고 쓰기를 저장소 줄 안에서 한 번에 한다. 고정을
  // 없애는 것은 사용자가 고른 [deleteDevicePin]뿐이다.

  String _pinKey(String deviceId) => '$_pinKeyPrefix$deviceId';

  /// 기기 [deviceId]를 고정해 둔 값(없거나 깨졌으면 null — 둘을 가려야 하면 [readDevicePinEntry]).
  Future<SecretDevicePin?> readDevicePin(String deviceId) => _serial(() async {
    final raw = await _storage.read(key: _pinKey(deviceId));
    return raw == null ? null : SecretDevicePin.decode(raw);
  });

  /// 기기 [deviceId]의 고정 기록이 있는지([present])와 읽은 값([pin] — 깨졌으면 null). 깨진 고정을 없는 것으로 보면
  /// 서버가 알려 주는 키를 처음 보는 기기처럼 다시 믿게 되므로, 확인할 수 없는 것으로 다루려고 가린다.
  Future<({bool present, SecretDevicePin? pin})> readDevicePinEntry(
    String deviceId,
  ) => _serial(() async {
    final raw = await _storage.read(key: _pinKey(deviceId));
    return (
      present: raw != null,
      pin: raw == null ? null : SecretDevicePin.decode(raw),
    );
  });

  /// 테스트가 고정 상태를 미리 만들어 둘 때만 쓴다 — 앱은 이미 있는 고정을 덮어쓰지 않는 [pinDeviceIfAbsent]·
  /// [setDevicePinVerified]만 쓴다.
  @visibleForTesting
  Future<void> saveDevicePin(String deviceId, SecretDevicePin pin) => _serial(
    () => _storage.write(key: _pinKey(deviceId), value: pin.encode()),
  );

  /// 처음 본 기기 [deviceId]를 [candidate]로 고정한다 — 고정해 둔 값이 없을 때만 적고, 있으면 그대로 둔다. 읽고 쓰기를
  /// 저장소 줄 안에서 한 번에 해서, 같은 기기를 두 곳(다른 방의 핸드셰이크·예전 대화 묶기)에서 동시에 처음 고정해도
  /// 나중 것이 먼저 적은 값을 덮어쓰지 않는다 — 서버가 한쪽 답을 붙잡아 두었다가 늦게 풀면, 덮어쓴 값이 이미 다른
  /// 키로 맺은 대화의 보안 코드를 진짜처럼 바꿔 놓는다. 이미 다른 키·주인으로 고정돼 있으면(서버가 같은 기기를 두
  /// 가지로 알려 왔다 — 정상 기기는 기기 id 하나에 키 하나다) 그 고정에 다툼을 적는다.
  /// 지금 고정된 값을 돌려준다(새로 적었으면 [candidate]). 고정 값이 깨져 있으면 덮어쓰지 않고 null.
  Future<SecretDevicePin?> pinDeviceIfAbsent(
    String deviceId,
    SecretDevicePin candidate,
  ) => _serial(() async {
    final key = _pinKey(deviceId);
    final raw = await _storage.read(key: key);
    if (raw == null) {
      await _storage.write(key: key, value: candidate.encode());
      return candidate;
    }
    final existing = SecretDevicePin.decode(raw);
    if (existing == null ||
        existing.disputed ||
        existing.sameKeyAs(candidate)) {
      return existing;
    }
    final disputed = existing.markDisputed(DateTime.now());
    await _storage.write(key: key, value: disputed.encode());
    return disputed;
  });

  /// 기기 [deviceId]의 "확인함" 표시만 바꾼다([verifiedAt]이 null이면 지운다) — 지금 고정이 [expected]와 같은 고정이고
  /// 다툼이 없을 때만, 저장소 줄 안에서 한 번에. 그 사이 고정이 지워졌거나 다시 받은 것이면 아무것도 하지 않고 false.
  Future<bool> setDevicePinVerified(
    String deviceId,
    SecretDevicePin expected, {
    required String myDeviceId,
    required DateTime? verifiedAt,
  }) => _serial(() async {
    final key = _pinKey(deviceId);
    final raw = await _storage.read(key: key);
    final current = raw == null ? null : SecretDevicePin.decode(raw);
    if (current == null || current.disputed || !current.isSamePinAs(expected)) {
      return false;
    }
    await _storage.write(
      key: key,
      value:
          (verifiedAt == null
                  ? current.clearVerified()
                  : current.markVerified(myDeviceId, verifiedAt))
              .encode(),
    );
    return true;
  });

  /// 기기 [deviceId]의 고정을 지운다 — 사용자가 "상대 기기 키 다시 받기"를 골랐을 때만(SecretSessionManager.
  /// resetPeerDevicePin). 다음에 그 기기를 만나면 처음 보는 기기처럼 서버에 다시 묻는다.
  /// 기기 [deviceId]의 고정이 아직 [expected]와 같은 고정이면 "새 규약(v3)으로 말함"을 적는다(SecretDevicePin.speaksV3) —
  /// 바꿨으면 true. 그 사이 고정이 지워졌거나 다시 받았거나 다툼이 적혔으면 아무것도 안 한다.
  Future<bool> markDevicePinSpeaksV3(
    String deviceId,
    SecretDevicePin expected,
  ) => _serial(() async {
    final raw = await _storage.read(key: _pinKey(deviceId));
    final current = raw == null ? null : SecretDevicePin.decode(raw);
    if (current == null ||
        current.disputed ||
        current.speaksV3 ||
        !current.isSamePinAs(expected)) {
      return false;
    }
    await _storage.write(
      key: _pinKey(deviceId),
      value: current.markSpeaksV3().encode(),
    );
    return true;
  });

  Future<void> deleteDevicePin(String deviceId) =>
      _serial(() => _storage.delete(key: _pinKey(deviceId)));

  /// 상대 기기 [deviceId]에 묶인 방 id 전부(저장된 묶음 — [saveRoomBinding]) — 그 기기의 고정을 믿을 수 없게 됐을 때
  /// (다툼·사용자가 지움) 그 키로 맺은 대화를 모두 멈추려고 쓴다. 드문 일이라 저장소 전체 읽기를 감수한다. 못 읽으면
  /// 빈 목록.
  Future<List<String>> roomIdsBoundToDevice(String deviceId) async {
    const suffix = '/$_peerField';
    try {
      return await _serial(() async {
        final all = await _storage.readAll();
        return [
          for (final entry in all.entries)
            if (entry.key.startsWith(_roomKeyPrefix) &&
                entry.key.endsWith(suffix) &&
                entry.key.length > _roomKeyPrefix.length + suffix.length)
              if (SecretRoomBinding.decode(entry.value) case final binding?
                  when binding.peerDeviceId == deviceId)
                entry.key.substring(
                  _roomKeyPrefix.length,
                  entry.key.length - suffix.length,
                ),
        ];
      });
    } catch (_) {
      return const [];
    }
  }

  /// 사용자 [userId]의 기기로 고정해 둔 것 전부 — 상대가 예전에 보안 코드를 확인한 기기가 아닌 다른 기기로 대화를
  /// 맺었는지 볼 때만 쓴다(핸드셰이크 때 한 번이라 저장소 전체 읽기를 감수한다). 못 읽으면 빈 목록.
  Future<List<(String, SecretDevicePin)>> devicePinsOfUser(
    String userId,
  ) async {
    try {
      return await _serial(() async {
        final all = await _storage.readAll();
        return [
          for (final entry in all.entries)
            if (entry.key.startsWith(_pinKeyPrefix))
              if (SecretDevicePin.decode(entry.value) case final pin?)
                if (pin.userId == userId)
                  (entry.key.substring(_pinKeyPrefix.length), pin),
        ];
      });
    } catch (_) {
      return const [];
    }
  }

  /// 방 [roomId]가 묶인 상대 기기(아직 없거나 깨졌으면 null).
  Future<SecretRoomBinding?> readRoomBinding(String roomId) =>
      _serial(() async {
        final raw = await _storage.read(key: _k(roomId, _peerField));
        return raw == null ? null : SecretRoomBinding.decode(raw);
      });

  Future<void> saveRoomBinding(String roomId, SecretRoomBinding binding) =>
      _serial(() {
        _keyedRoomIds.add(roomId);
        return _storage.write(
          key: _k(roomId, _peerField),
          value: binding.encode(),
        );
      });

  /// 방 [roomId]의 묶음만 거둔다 — 예전 대화를 묶다가 그 기기의 고정을 적지 못했을 때(다음에 다시 묶게).
  Future<void> deleteRoomBinding(String roomId) =>
      _serial(() => _storage.delete(key: _k(roomId, _peerField)));

  /// 방 [roomId]의 보안 상태(없으면 [SecretRoomSecurity.none]). 깨진 값은 멈춘 것으로 본다 — 가로채기로 멈춘 방이
  /// 저장소 오류로 다시 풀리면 안 된다.
  Future<SecretRoomSecurity> readRoomSecurity(String roomId) =>
      _serial(() async {
        final raw = await _storage.read(key: _k(roomId, _securityField));
        if (raw == null) return SecretRoomSecurity.none;
        return SecretRoomSecurity.decode(raw) ?? _unreadableSecurity();
      });

  /// 방 [roomId]의 보안 상태를 적고, 실제로 적힌 값을 돌려준다. 이미 멈춘 방이면 처음 멈춘 이유를 그대로 두고 안내
  /// 표시만 바꾼다 — 멈춤은 방이 없어질 때([clearRoom])만 풀린다. 같은 상대 기기의 키 다툼처럼 다른 방의 일로 이 방이
  /// 멈추는 순간 이 방의 핸드셰이크가 안내 표시를 고쳐 적어도 멈춤이 지워지지 않게, 읽고 쓰기를 저장소 줄 안에서 한
  /// 번에 한다. 깨진 값(멈춘 것으로 읽힌다)은 덮어쓰지 않는다.
  Future<SecretRoomSecurity> saveRoomSecurity(
    String roomId,
    SecretRoomSecurity security,
  ) => _serial(() async {
    _keyedRoomIds.add(roomId);
    final key = _k(roomId, _securityField);
    final raw = await _storage.read(key: key);
    var next = security;
    if (raw != null) {
      final stored = SecretRoomSecurity.decode(raw);
      if (stored == null) return _unreadableSecurity();
      if (stored.blocked) next = security.withBlockOf(stored);
    }
    await _storage.write(key: key, value: next.encode());
    return next;
  });

  /// 깨진 보안 상태 값을 읽은 값 — 멈춘 것으로 본다(가로채기로 멈춘 방이 저장소 오류로 다시 풀리면 안 된다).
  static SecretRoomSecurity _unreadableSecurity() => SecretRoomSecurity.none
      .blockedWith(SecretBlockReason.badSignature, DateTime.now());

  // ---- 방별 계정 표시 ----

  /// 키 상태나 계정 표시가 이 기기에 있는 방 id(평문만 있는 방은 [_texts]로 안다) — 색인을 읽을 때 채운다.
  final Set<String> _keyedRoomIds = {};

  /// 방 id → 그 방을 목록에서 본 계정 id([_ownerField]).
  final Map<String, String> _roomOwners = {};

  /// 이 기기에 그 방의 키 상태·계정 표시·평문 중 무엇이든 남아 있는 비밀 대화방 id — [ensureTextIndex]가
  /// 성공한 뒤에만 빠짐없다. Session의 뒷정리가 "목록에 없는데 이 기기에 남은 방"을 찾는 데 쓴다.
  Set<String> get localSecretRoomIds => {
    ..._keyedRoomIds,
    for (final t in _texts.values) t.roomId,
  };

  /// 방 [roomId]를 목록에서 본 계정(없으면 null — 이 표시가 생기기 전부터 있던 방이거나 다른 경로로 생긴 방).
  String? roomOwner(String roomId) => _roomOwners[roomId];

  /// 방 [roomId]가 계정 [userId]의 방 목록에 있다 — 그렇게 적어 둔다(이미 그렇게 적혀 있으면 아무것도 안 한다).
  Future<void> noteRoomOwner(String roomId, String userId) async {
    if (!await _ensureTextIndex()) return;
    if (_roomOwners[roomId] == userId) return;
    try {
      await _serial(() async {
        await _storage.write(key: _k(roomId, _ownerField), value: userId);
        _roomOwners[roomId] = userId;
        _keyedRoomIds.add(roomId);
      });
    } catch (_) {
      // 못 적어도 다음 뒷정리 때 다시 적는다 — 그때까지는 "누구 방인지 모름"으로 조심스럽게 다룬다.
    }
  }

  // ---- 서버 시계 ----
  //
  // 서버가 확정한 자동 삭제 시각(expiresAt)은 서버 시계 기준이다. 이 기기 시계가 서버보다 빠르면(예: 2시간)
  // 이 기기 시계로 비교할 때 그만큼 일찍 지워서, 서버에 아직 있는 메시지가 다시 받으면 "복호화할 수 없음"으로
  // 보인다. 그래서 확정한 시각은 "서버의 지금"과 비교한다. 서버가 찍어 보낸 시각(새 메시지·댓글의 작성 시각,
  // 읽음 시각, 히스토리 항목의 시각, 방 목록의 마지막 활동 시각)은 받은 순간의 서버 시각보다 늦을 수 없으니,
  // 그중 가장 늦은 값에 받은 뒤 흐른 시간(단조 시계 — 기기 시계를 바꿔도, 절전에 들어가도 앞으로 튀지 않는다)을
  // 더한 것을 서버의 지금으로 본다. 늘 실제보다 같거나 이르므로 서버보다 먼저 지우는 일은 없다. 서버 시각을 아직
  // 못 받았으면 [secretDeviceClockTolerance]만큼 넉넉히 뺀 이 기기 시계를 쓴다.

  int? _serverStampMs;
  final Stopwatch _serverStampAge = Stopwatch();

  /// 받은 서버 시각으로 어림한 지금 서버 시각(ms) — 아직 서버 시각을 받은 적이 없으면 null.
  int? get _serverNowMs {
    final stamp = _serverStampMs;
    return stamp == null ? null : stamp + _serverStampAge.elapsedMilliseconds;
  }

  /// 서버가 정한 시각과 견줄 "적어도 이만큼은 지난" 서버 시각(ms) — 받은 서버 시각([serverNowMs]를 주면 그 값)과
  /// 넉넉히 뺀 이 기기 시계 중 늦은 쪽(둘 다 실제 서버 시각보다 이르다고 볼 수 있는 값이다).
  int _serverNowLowerBound(int localNowMs, {int? serverNowMs}) {
    final byDevice = localNowMs - secretDeviceClockTolerance.inMilliseconds;
    final known = serverNowMs ?? _serverNowMs;
    return known == null ? byDevice : math.max(known, byDevice);
  }

  /// 서버가 찍은 시각 하나를 알려 준다 — 받은 순간 서버의 지금보다 늦지 않은 값(작성·읽음 시각 등)만 넘긴다.
  /// 앞으로의 시각(expiresAt 등)을 넘기면 그만큼 일찍 지우게 된다.
  void noteServerTime(DateTime serverTime) {
    final ms = serverTime.millisecondsSinceEpoch;
    final current = _serverNowMs;
    if (current != null && ms <= current) return;
    _serverStampMs = ms;
    _serverStampAge
      ..reset()
      ..start();
    // 처음 알게 됐거나 크게 앞당겨졌으면 — 서버 시각을 몰라 미뤄 둔 항목의 정리 시각을 다시 잡는다.
    if (current == null || ms - current >= 1000) _scheduleNextPurge();
  }

  // ---- 복호화된 평문 캐시 ----
  //
  // 한 방향 래칫은 한 번 지나간 메시지의 키를 다시 계산할 수 없다(그게 순방향 비밀성의 핵심).
  // 그런데 채팅 화면은 방을 열 때마다(+재연결/앱 재시작 후) 서버에서 히스토리를 다시 받아와
  // 매번 복호화를 시도한다 — 그 시점의 로컬 래칫은 이미 최신 메시지 위치까지 전진해 있어서,
  // "이미 한 번 성공적으로 복호화했던" 과거 메시지들은 다시 시도하면 전부 실패한다(앱을
  // 재시작하면 그동안 주고받은 메시지가 전부 "복호화할 수 없음"으로 보이는 문제).
  // 그래서 메시지 하나를 처음 복호화하는 데 성공한 그 순간의 평문을 이 기기에만 영구 저장해두고,
  // 이후에는(재시작해도) 암호문을 다시 복호화하지 않고 이 캐시를 그대로 쓴다 — Session.decryptInPlace/
  // decryptCommentInPlace 참고.
  //
  // 다만 서버가 지운 메시지(자동 삭제 타이머 만료, 삭제)의 평문이 이 기기에만 계속 남으면 안 된다(S34). 지웠다는
  // 실시간 알림(message:expired/deleted)은 그 순간 연결돼 있어야 받고, 재연결해도 다시 오지 않는다. 그래서
  // 평문과 함께 방·작성 시각·(알면) 삭제 예정 시각을 적어 두고(secretcache/<방>/<id>), 알림 없이도
  //   1) 삭제 예정 시각이 지나면 스스로 지우고(앱 시작·방 열기·포그라운드 복귀·다음 예정 시각 타이머),
  //   2) 히스토리를 다시 받을 때 그 요청이 훑은 범위 안인데 서버가 더 이상 주지 않는 항목을 지운다(방 화면이
  //      받을 때와, Session의 뒷정리가 방 화면 없이 각 비밀 대화방의 최근 페이지를 받을 때).
  // 타이머 없는 비밀 대화의 평문은 삭제 예정 시각이 없어서 그대로 남는다(재시작 뒤에도 히스토리가 보여야 한다).
  // 저장해 둔 항목의 위치·만료 정보는 메모리 색인([_texts])에도 들고 있어서, 정리할 때마다 저장소 전체를
  // 다시 읽지 않고 없는 항목은 저장소를 읽지도 않는다.

  final Map<String, SecretCachedTextInfo> _texts = {};

  /// 예전 형식(`secretmsg/<id>`)으로 남아 있는 항목 id — 방·시각을 몰라서, 화면에 다시 나오거나 Session의
  /// 뒷정리가 히스토리에서 찾으면 새 형식으로 옮긴다.
  final Set<String> _legacyTextIds = {};

  /// 예전 형식 평문을 옮기려고 히스토리를 다 훑은 계정들([_legacySweptKeyPrefix]).
  final Set<String> _legacySweptUsers = {};
  bool _textsLoaded = false;
  Future<bool>? _textsLoading;

  /// 색인 읽기가 마지막으로 실패한 시각 — 저장소 전체 읽기는 무거워서, 실패하면 잠시 다시 시도하지 않는다.
  DateTime? _textsLoadFailedAt;
  int _generation = 0;
  Timer? _purgeTimer;

  /// 마지막 정리에서 지우지 못한 항목이 있었는지 — 그러면 다시 시도를 조금 늦춘다.
  bool _lastPurgeFailed = false;
  bool _disposed = false;

  /// 삭제 예정 시각이 지나 지운 항목들 — Session이 열려 있는 방 화면에서도 빼려고 듣는다.
  void Function(List<SecretCachedTextInfo> removed)? onExpiredTextsPurged;

  /// 지금까지의 저장 순번 — 히스토리를 요청하기 직전에 잡아서 [reconcileHistoryPage]에 넘긴다.
  int get textCacheGeneration => _generation;

  String _textKey(String roomId, String id) => '$_textKeyPrefix$roomId/$id';
  String _legacyTextKey(String id) => '$_legacyTextKeyPrefix$id';

  /// 메모리 색인을 채운다(처음 한 번 저장소 전체를 읽는다). 못 읽으면 false — 그동안 정리·재조정은 하지 않는다.
  Future<bool> ensureTextIndex() => _ensureTextIndex();

  /// 메모리 색인을 처음 한 번 채운다(저장소 전체를 한 번 읽는다). 실패하면 false — 다음 호출 때 다시
  /// 해 보고, 그동안 읽기·쓰기는 저장소를 직접 보며 정리(만료·재조정)는 건너뛴다(잘못 지우지 않게).
  Future<bool> _ensureTextIndex() {
    if (_textsLoaded) return Future.value(true);
    final failedAt = _textsLoadFailedAt;
    if (_textsLoading == null &&
        failedAt != null &&
        DateTime.now().difference(failedAt) < const Duration(minutes: 1)) {
      return Future.value(false);
    }
    return _textsLoading ??= _serial(() async {
      try {
        final all = Map<String, String>.of(await _storage.readAll());
        final broken = <String>[];
        for (final entry in all.entries) {
          final key = entry.key;
          if (key.startsWith(_roomKeyPrefix) &&
              (key.endsWith('/pendingRekeyEpoch') ||
                  key.endsWith('/pendingRekeySeed'))) {
            // 예전 앱이 재키잉을 제안하고 남겨 둔 임시 개인키 — 이제 재키잉을 하지 않아 쓸 일이 없다(목록에 없는 방 것도).
            broken.add(key);
            continue;
          }
          if (key.startsWith(_textKeyPrefix)) {
            final info = _parseTextEntry(key, entry.value);
            if (info == null) {
              broken.add(key);
            } else {
              // 색인을 채우기 전에 이번 실행에서 이미 쓴 항목은 그 순번을 그대로 둔다.
              _texts.putIfAbsent(info.id, () => info);
            }
          } else if (key.startsWith(_legacyTextKeyPrefix)) {
            final id = key.substring(_legacyTextKeyPrefix.length);
            if (id.isNotEmpty && !_texts.containsKey(id)) {
              _legacyTextIds.add(id);
            }
          } else if (key.startsWith(_roomKeyPrefix)) {
            final rest = key.substring(_roomKeyPrefix.length);
            final slash = rest.indexOf('/');
            if (slash > 0) {
              final roomId = rest.substring(0, slash);
              _keyedRoomIds.add(roomId);
              if (rest.substring(slash + 1) == _ownerField) {
                _roomOwners.putIfAbsent(roomId, () => entry.value);
              }
            }
          } else if (key.startsWith(_legacySweptKeyPrefix)) {
            _legacySweptUsers.add(key.substring(_legacySweptKeyPrefix.length));
          }
        }
        // 형식이 깨진 값은 읽을 수도 없고 언제 지워야 하는지도 몰라 지운다(쓸 일이 없는 예전 재키잉 임시키도 함께).
        for (final key in broken) {
          await _storage.delete(key: key);
        }
        _textsLoaded = true;
        _textsLoadFailedAt = null;
        return true;
      } catch (_) {
        _textsLoadFailedAt = DateTime.now();
        return false;
      } finally {
        _textsLoading = null;
      }
    });
  }

  static ({
    String text,
    int createdAtMs,
    String? parentId,
    int? expiresAtMs,
    bool expiryFixed,
    String? envelopeHash,
    bool? fromMe,
    String? senderId,
  })?
  _decodeTextValue(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final text = json['t'];
      final createdAt = json['c'];
      if (text is! String || createdAt is! num) return null;
      final parentId = json['p'];
      final expiresAt = json['e'];
      final hash = json['h'];
      final fromMe = json['o'];
      final sender = json['s'];
      return (
        text: text,
        createdAtMs: createdAt.toInt(),
        parentId: parentId is String ? parentId : null,
        expiresAtMs: expiresAt is num ? expiresAt.toInt() : null,
        expiryFixed: json['f'] == true,
        envelopeHash: hash is String ? hash : null,
        fromMe: fromMe is bool ? fromMe : null,
        senderId: sender is String ? sender : null,
      );
    } on FormatException {
      return null;
    }
  }

  /// [envelopeHash]·[fromMe]·[senderId]는 그 평문을 처음 풀 때 서버가 보여 준 봉투의 지문과 보낸 쪽·보낸 사람
  /// ([SecretTextRef]) — 이 칸이 생기기 전에 저장한 항목에는 없다. 삭제 예정 시각만 고쳐 적을 때도 그대로 옮겨 적어야
  /// 한다(빠지면 그 항목은 확인 없이 아무 메시지에나 붙는다).
  static String _encodeTextValue(
    String text,
    SecretCachedTextInfo info, {
    String? envelopeHash,
    bool? fromMe,
    String? senderId,
  }) => jsonEncode({
    't': text,
    'c': info.createdAtMs,
    if (info.parentId != null) 'p': info.parentId,
    if (info.expiresAtMs != null) 'e': info.expiresAtMs,
    if (info.expiryFixed) 'f': true,
    'h': ?envelopeHash,
    'o': ?fromMe,
    's': ?senderId,
  });

  /// 암호문 봉투의 지문 — SHA-256의 앞 16바이트(base64). 평문 캐시가 "그 봉투를 푼 평문"인지 견주는 데만 쓴다.
  static Future<String> _envelopeHash(String envelope) async {
    final digest = await Sha256().hash(utf8.encode(envelope));
    return base64Encode(digest.bytes.sublist(0, 16));
  }

  static SecretCachedTextInfo? _parseTextEntry(String key, String value) {
    final rest = key.substring(_textKeyPrefix.length);
    final slash = rest.indexOf('/');
    if (slash <= 0 || slash == rest.length - 1) return null;
    final decoded = _decodeTextValue(value);
    if (decoded == null) return null;
    return SecretCachedTextInfo(
      roomId: rest.substring(0, slash),
      id: rest.substring(slash + 1),
      parentId: decoded.parentId,
      createdAtMs: decoded.createdAtMs,
      expiresAtMs: decoded.expiresAtMs,
      expiryFixed: decoded.expiryFixed,
    );
  }

  /// 새로 적는 항목의 삭제 예정 시각 — [ref]가 서버 값을 알면 그것, 아니면 이미 적어 둔 값, 그것도
  /// 없으면(댓글) 원본 메시지 항목의 값을 물려받는다(원본이 지워질 때 댓글도 같이 지워진다).
  (int?, bool) _expiryFor(SecretTextRef ref) {
    if (ref.expiryKnown) {
      return (ref.expiresAt?.millisecondsSinceEpoch, true);
    }
    final known =
        _texts[ref.id] ?? (ref.parentId == null ? null : _texts[ref.parentId]);
    return (known?.expiresAtMs, known?.expiryFixed ?? false);
  }

  /// [migrated]면 예전 형식에서 옮기는 항목 — 원래 있던 메시지라 "요청 뒤에 생긴 것" 보호(저장 순번)가 필요 없다.
  SecretCachedTextInfo _newTextInfo(
    SecretTextRef ref, {
    bool migrated = false,
  }) {
    final (expiresAtMs, fixed) = _expiryFor(ref);
    return SecretCachedTextInfo(
      roomId: ref.roomId,
      id: ref.id,
      parentId: ref.parentId,
      createdAtMs: ref.createdAt.millisecondsSinceEpoch,
      expiresAtMs: expiresAtMs,
      expiryFixed: fixed,
      generation: migrated ? 0 : ++_generation,
    );
  }

  /// 처음 복호화에 성공한 평문을 저장한다(수정된 메시지면 덮어쓴다). [ref]의 봉투 지문·보낸 쪽도 함께 적는다.
  Future<void> saveDecryptedText(SecretTextRef ref, String text) async {
    final loaded = await _ensureTextIndex();
    final envelope = ref.envelope;
    final hash = envelope == null ? null : await _envelopeHash(envelope);
    await _serial(() async {
      final info = _newTextInfo(ref);
      await _storage.write(
        key: _textKey(ref.roomId, ref.id),
        value: _encodeTextValue(
          text,
          info,
          envelopeHash: hash,
          fromMe: ref.fromMe,
          senderId: ref.senderId,
        ),
      );
      _texts[ref.id] = info;
      // 예전 형식으로 남아 있던 값은 지운다 — 색인을 못 읽었으면 있는지 몰라서 그냥 지워 본다.
      if (_legacyTextIds.remove(ref.id) || !loaded) {
        await _storage.delete(key: _legacyTextKey(ref.id));
      }
    });
    if (ref.expiryKnown && ref.parentId == null) {
      // 서버가 확정한 원본 메시지의 값을 이미 저장해 둔 그 메시지의 댓글들에도 맞춘다.
      await _applyExpiry(
        ref.id,
        ref.expiresAt?.millisecondsSinceEpoch,
        fixed: true,
      );
    }
    _scheduleNextPurge();
  }

  /// 예전 형식 값 하나를 [ref]의 방·시각을 붙여 새 형식으로 옮기고 그 평문을 돌려준다(없으면 null).
  /// 저장소 줄 안에서만 부른다.
  Future<String?> _migrateLegacyLocked(SecretTextRef ref) async {
    final legacyKey = _legacyTextKey(ref.id);
    final legacy = await _storage.read(key: legacyKey);
    _legacyTextIds.remove(ref.id);
    if (legacy == null) return null;
    final migratedInfo = _newTextInfo(ref, migrated: true);
    await _storage.write(
      key: _textKey(ref.roomId, ref.id),
      value: _encodeTextValue(legacy, migratedInfo),
    );
    await _storage.delete(key: legacyKey);
    _texts[ref.id] = migratedInfo;
    return legacy;
  }

  /// 저장해 둔 평문(없으면 null). 예전 형식으로 저장된 값이면 [ref]의 방·시각을 붙여 새 형식으로 옮겨
  /// 적는다 — 그래야 이후 만료·재조정 대상이 된다. 서버가 확정한 삭제 예정 시각이 적어 둔 값과 다르면
  /// (끊긴 동안 상대가 읽음 등) 그 값으로 맞춘다.
  ///
  /// 서버가 보여 주는 것과 저장해 둔 것이 다르면 주지 않는다(서버가 메시지 id만 같게 해서 저장된 평문을 끌어다 쓰지
  /// 못하게): 다른 방의 메시지이거나, 댓글이 달린 원본 메시지가 다르거나(메시지를 댓글로·댓글을 다른 글 아래로 옮김),
  /// 보낸 쪽([SecretTextRef.fromMe])·보낸 사람([SecretTextRef.senderId])이 다르거나, 봉투 지문([SecretTextRef.envelope])이
  /// 다르면(수정된 메시지 등 — 새 봉투를 풀어야 한다). [requireEnvelopeMatch]면 봉투 지문이 저장돼 있고 같을 때만 준다
  /// (message:edited처럼 같은 id의 내용이 바뀌었을 수 있을 때 — 같은 봉투면 다시 풀 필요가 없다).
  Future<String?> readDecryptedText(
    SecretTextRef ref, {
    bool requireEnvelopeMatch = false,
  }) async {
    final loaded = await _ensureTextIndex();
    final envelope = ref.envelope;
    final hash = envelope == null ? null : await _envelopeHash(envelope);
    final (text, expiryStale, migrated) = await _serial<(String?, bool, bool)>(
      () async {
        final info = _texts[ref.id];
        if (info != null && info.roomId != ref.roomId) {
          return (null, false, false);
        }
        if (info != null || !loaded) {
          final key = _textKey(ref.roomId, ref.id);
          final raw = await _storage.read(key: key);
          final stored = raw == null ? null : _decodeTextValue(raw);
          if (stored != null) {
            final storedSender = stored.senderId;
            final sameSender =
                (stored.fromMe == null ||
                    ref.fromMe == null ||
                    stored.fromMe == ref.fromMe) &&
                (storedSender == null ||
                    ref.senderId == null ||
                    storedSender == ref.senderId);
            if (stored.parentId != ref.parentId) return (null, false, false);
            final storedHash = stored.envelopeHash;
            final sameEnvelope = storedHash == null || hash == null
                ? !requireEnvelopeMatch
                : storedHash == hash;
            if (!sameSender || !sameEnvelope) return (null, false, false);
            final stale =
                info != null &&
                ref.expiryKnown &&
                (!info.expiryFixed ||
                    info.expiresAtMs != ref.expiresAt?.millisecondsSinceEpoch);
            return (stored.text, stale, false);
          }
          if (info != null) {
            // 저장소에서 사라졌거나 깨진 값 — 색인에서도 뺀다.
            _texts.remove(ref.id);
            if (raw != null) await _storage.delete(key: key);
            return (null, false, false);
          }
        }
        // 예전 형식 값에는 봉투 지문이 없어 같은 봉투인지 알 수 없다.
        if (!requireEnvelopeMatch &&
            (!loaded || _legacyTextIds.contains(ref.id))) {
          final legacy = await _migrateLegacyLocked(ref);
          return (legacy, false, legacy != null);
        }
        return (null, false, false);
      },
    );
    if (expiryStale) {
      await _applyExpiry(
        ref.parentId ?? ref.id,
        ref.expiresAt?.millisecondsSinceEpoch,
        fixed: true,
      );
    }
    if (expiryStale || migrated) _scheduleNextPurge();
    return text;
  }

  /// 복호화하지 않고 히스토리 한 페이지(방 [roomId]의 [page])가 알려 주는 것만 캐시에 반영한다 — Session의
  /// 뒷정리가 방 화면 없이 서버와 맞출 때 쓴다(래칫을 건드리는 복호화는 방 화면이 할 일이라 여기서 하지 않는다).
  /// 서버가 읽음을 확정한(readAt이 있는) 메시지는 그 자동 삭제 시각을 그 메시지와 댓글 항목에 적고, 예전 형식으로
  /// 남은 항목이 이 페이지에 있으면 방·시각·삭제 예정 시각을 붙여 새 형식으로 옮긴다.
  Future<void> applyHistoryMetadata(String roomId, List<Message> page) async {
    if (!await _ensureTextIndex()) return;
    final confirmed = <String, int?>{
      for (final m in page)
        if (m.readAt != null) m.id: m.expiresAt?.millisecondsSinceEpoch,
    };
    final stale = [
      for (final t in _texts.values)
        if (t.roomId == roomId &&
            confirmed.containsKey(t.parentId ?? t.id) &&
            _needsExpiry(t, confirmed[t.parentId ?? t.id], true))
          t.id,
    ];
    for (final id in stale) {
      final current = _texts[id];
      if (current == null) continue;
      await _writeExpiry(id, confirmed[current.parentId ?? id], fixed: true);
    }
    var migratedAny = false;
    if (_legacyTextIds.isNotEmpty) {
      final refs = <SecretTextRef>[
        for (final m in page) ...[
          if (!m.deleted && _legacyTextIds.contains(m.id))
            SecretTextRef(
              roomId: roomId,
              id: m.id,
              createdAt: m.createdAt,
              expiryKnown: m.readAt != null,
              expiresAt: m.expiresAt,
            ),
          for (final c in m.comments)
            if (!c.deleted && _legacyTextIds.contains(c.id))
              SecretTextRef(
                roomId: roomId,
                id: c.id,
                parentId: c.messageId,
                createdAt: c.createdAt,
                expiryKnown: m.readAt != null,
                expiresAt: m.expiresAt,
              ),
        ],
      ];
      for (final ref in refs) {
        try {
          if (await _serial(() => _migrateLegacyLocked(ref)) != null) {
            migratedAny = true;
          }
        } catch (_) {
          // 못 옮긴 것은 다음에 그 메시지를 다시 볼 때 옮긴다.
        }
      }
    }
    if (stale.isNotEmpty || migratedAny) _scheduleNextPurge();
  }

  /// 메시지·댓글이 지워졌을 때(message:deleted / comment:deleted) 로컬에 남아있는 평문도 함께 지운다 —
  /// 안 그러면 "삭제"가 이 기기에서는 사실 안 지워진 게 된다.
  Future<void> deleteDecryptedText(String roomId, String id) async {
    final loaded = await _ensureTextIndex();
    try {
      await _serial(() async {
        final info = _texts.remove(id);
        if (info != null || !loaded) {
          await _storage.delete(key: _textKey(info?.roomId ?? roomId, id));
        }
        if (_legacyTextIds.remove(id) || !loaded) {
          await _storage.delete(key: _legacyTextKey(id));
        }
      });
    } catch (_) {
      // 지우지 못했으면 다음 재조정·만료 정리 때 다시 지운다.
    }
  }

  /// 서버가 메시지를 완전히 지웠다(자동 삭제 만료, 아무도 안 읽은 메시지 삭제 — message:expired). 서버가
  /// 그 댓글도 함께 지웠으므로 댓글 평문도 지운다(그 방 화면을 이번에 안 열어 봤어도).
  Future<void> deleteMessageTexts(String roomId, String messageId) async {
    await _ensureTextIndex();
    final ids = [
      messageId,
      for (final t in _texts.values)
        if (t.parentId == messageId) t.id,
    ];
    for (final id in ids) {
      await deleteDecryptedText(roomId, id);
    }
    _scheduleNextPurge();
  }

  /// 방이 통째로 없어졌다(비밀 대화 종료·거절·나가기) — 그 방의 평문을 전부 지운다.
  Future<void> clearRoomTexts(String roomId) async {
    if (!await _ensureTextIndex()) return;
    final ids = [
      for (final t in _texts.values)
        if (t.roomId == roomId) t.id,
    ];
    for (final id in ids) {
      await deleteDecryptedText(roomId, id);
    }
    _scheduleNextPurge();
  }

  /// 서버가 메시지 읽음을 확정했다(secret:message-read 또는 readAt이 있는 히스토리) — [expiresAt]이 null이면
  /// 타이머 없이 읽혀서 자동 삭제되지 않는다. 그 메시지의 댓글들도 같은 시각에 지워진다.
  Future<void> noteMessageRead(String messageId, DateTime? expiresAt) =>
      _applyExpiry(messageId, expiresAt?.millisecondsSinceEpoch, fixed: true);

  /// 이 기기가 [messageId]의 읽음을 서버에 보냈다 — 타이머가 켜진 방이면 서버도 지금부터 [selfDestruct]
  /// 뒤에 지운다. 그 확정 알림을 끊겨서 못 받아도 평문이 남지 않게 어림한 시각을 먼저 적어 둔다(아직
  /// 아무것도 모를 때만 — 서버 값이 오면 그것으로 바뀐다). 이 기기 시계로 재고 이 기기 시계로 비교하므로
  /// 기기 시계가 서버와 어긋나 있어도 상관없다.
  Future<void> noteLocalRead(
    String messageId,
    Duration selfDestruct, {
    DateTime? now,
  }) async {
    if (!await _ensureTextIndex()) return;
    final own = _texts[messageId];
    if (own == null || own.expiryFixed || own.expiresAtMs != null) return;
    await _applyExpiry(
      messageId,
      (now ?? DateTime.now()).add(selfDestruct).millisecondsSinceEpoch,
      fixed: false,
    );
  }

  bool _needsExpiry(SecretCachedTextInfo t, int? expiresAtMs, bool fixed) =>
      fixed
      ? !t.expiryFixed || t.expiresAtMs != expiresAtMs
      : !t.expiryFixed && t.expiresAtMs == null;

  /// 항목 [id]의 삭제 예정 시각을 저장소와 색인에 적는다(이미 그 값이면 그대로 둔다). 실패하면 조용히 넘어간다 —
  /// 시각을 못 고쳐도 평문은 그대로 있고, 다음에 히스토리를 받을 때 다시 맞춘다.
  Future<void> _writeExpiry(
    String id,
    int? expiresAtMs, {
    required bool fixed,
  }) async {
    try {
      await _serial(() async {
        final current = _texts[id];
        if (current == null || !_needsExpiry(current, expiresAtMs, fixed)) {
          return;
        }
        final key = _textKey(current.roomId, id);
        final raw = await _storage.read(key: key);
        final stored = raw == null ? null : _decodeTextValue(raw);
        if (stored == null) {
          _texts.remove(id);
          if (raw != null) await _storage.delete(key: key);
          return;
        }
        final next = current._withExpiry(expiresAtMs, fixed: fixed);
        await _storage.write(
          key: key,
          value: _encodeTextValue(
            stored.text,
            next,
            envelopeHash: stored.envelopeHash,
            fromMe: stored.fromMe,
            senderId: stored.senderId,
          ),
        );
        _texts[id] = next;
      });
    } catch (_) {}
  }

  /// 메시지 [messageId]와 그 댓글 항목들의 삭제 예정 시각을 바꾼다. 서버가 확정한 값([fixed])은 늘 덮어쓰고,
  /// 이 기기가 어림한 값은 아직 아무것도 모를 때만 적는다.
  Future<void> _applyExpiry(
    String messageId,
    int? expiresAtMs, {
    required bool fixed,
  }) async {
    if (!await _ensureTextIndex()) return;
    final targets = [
      for (final t in _texts.values)
        if ((t.id == messageId || t.parentId == messageId) &&
            _needsExpiry(t, expiresAtMs, fixed))
          t.id,
    ];
    if (targets.isEmpty) return;
    for (final id in targets) {
      await _writeExpiry(id, expiresAtMs, fixed: fixed);
    }
    _scheduleNextPurge();
  }

  /// 지울 때가 됐는지 — 서버가 확정한 시각은 서버의 지금([serverNowMs] — [_serverNowLowerBound])과, 이 기기가
  /// 어림한 시각은 이 기기의 지금과 비교한다.
  bool _isDue(SecretCachedTextInfo t, int localNowMs, int serverNowMs) {
    final expiresAt = t.expiresAtMs;
    if (expiresAt == null) return false;
    final now = t.expiryFixed ? serverNowMs : localNowMs;
    return expiresAt + secretTextExpiryGrace.inMilliseconds <= now;
  }

  /// 삭제 예정 시각이 지난 평문을 지우고 지운 항목을 돌려준다([onExpiredTextsPurged]에도 알린다). 서버의
  /// message:expired를 받았으면 이미 지워져 있어 할 일이 없다. [now]·[serverNow]는 테스트가 이 기기·서버의
  /// 지금을 정할 때만 준다(안 주면 이 기기 시계와 [noteServerTime]으로 어림한 서버 시각).
  Future<List<SecretCachedTextInfo>> purgeExpiredTexts({
    DateTime? now,
    DateTime? serverNow,
  }) async {
    if (!await _ensureTextIndex()) return const [];
    final localNowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final serverNowMs = _serverNowLowerBound(
      localNowMs,
      serverNowMs: serverNow?.millisecondsSinceEpoch,
    );
    final due = [
      for (final t in _texts.values)
        if (_isDue(t, localNowMs, serverNowMs)) t.id,
    ];
    final removed = <SecretCachedTextInfo>[];
    var failed = false;
    for (final id in due) {
      try {
        final info = await _serial(() async {
          final current = _texts[id];
          if (current == null || !_isDue(current, localNowMs, serverNowMs)) {
            return null;
          }
          await _storage.delete(key: _textKey(current.roomId, id));
          _texts.remove(id);
          return current;
        });
        if (info != null) removed.add(info);
      } catch (_) {
        // 이번에 못 지운 것은 다음 정리 때 다시 지운다.
        failed = true;
      }
    }
    _lastPurgeFailed = failed;
    _scheduleNextPurge();
    if (removed.isNotEmpty && !_disposed) {
      onExpiredTextsPurged?.call(removed);
    }
    return removed;
  }

  /// 서버와 다시 맞춰 볼 평문이 있는 방들 — 언제 지워질지 이 기기가 모르는 항목(타이머 없이 읽힌·아직 안 읽힌
  /// 메시지, 이 기기가 어림한 시각)이 있거나, 서버가 정한 시각이 이 기기 시계로는 지났는데 서버 시각으로는 아직
  /// 확인하지 못한(그래서 [purgeExpiredTexts]가 남겨 둔) 항목이 있는 방. 서버가 지웠으면 최근 히스토리에 없으므로,
  /// 그 페이지로 맞추면([reconcileHistoryPage]) 시계와 상관없이 정리된다. [now]는 테스트용.
  Set<String> roomsNeedingReconcile({DateTime? now}) {
    final localNowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final grace = secretTextExpiryGrace.inMilliseconds;
    return {
      for (final t in _texts.values)
        if (!t.expiryFixed ||
            t.expiresAtMs == null ||
            t.expiresAtMs! + grace <= localNowMs)
          t.roomId,
    };
  }

  /// 방 [roomId]의 히스토리 한 페이지를 받은 뒤 — 그 요청이 훑은 범위 안인데 응답에 없는 항목
  /// ([secretCacheIdsGoneFromPage])과, 지워진 것으로 표시돼 온(소프트 삭제) 메시지·댓글의 평문을 지우고 지운
  /// 항목을 돌려준다. [sinceGeneration]은 요청 직전에 잡은 [textCacheGeneration] — 그 뒤에 저장된 항목은
  /// 응답보다 늦게 생긴 메시지일 수 있어 건드리지 않는다. 색인을 못 읽었으면 아무것도 지우지 않는다.
  Future<List<SecretCachedTextInfo>> reconcileHistoryPage({
    required String roomId,
    required List<Message> page,
    required DateTime? before,
    required int limit,
    required int sinceGeneration,
  }) async {
    if (!await _ensureTextIndex()) return const [];
    final gone = secretCacheIdsGoneFromPage(
      entries: [
        for (final t in _texts.values)
          if (t.roomId == roomId && t.generation <= sinceGeneration) t,
      ],
      page: page,
      before: before,
      limit: limit,
    );
    final deleted = <String>{
      for (final m in page) ...[
        if (m.deleted) m.id,
        for (final c in m.comments)
          if (c.deleted) c.id,
      ],
    };
    final removed = <SecretCachedTextInfo>[];
    for (final id in {...gone, ...deleted}) {
      if (!_texts.containsKey(id) && !_legacyTextIds.contains(id)) continue;
      try {
        final info = await _serial(() async {
          final current = _texts[id];
          final softDeleted = deleted.contains(id);
          // 그 사이 다시 저장됐으면(요청 뒤에 온 수정 등) 이번 응답으로는 판단하지 않는다.
          if (current != null &&
              !softDeleted &&
              current.generation > sinceGeneration) {
            return null;
          }
          if (current != null) {
            await _storage.delete(key: _textKey(current.roomId, id));
            _texts.remove(id);
          }
          if (softDeleted && _legacyTextIds.remove(id)) {
            await _storage.delete(key: _legacyTextKey(id));
          }
          return current;
        });
        if (info != null) removed.add(info);
      } catch (_) {
        // 못 지운 것은 다음 히스토리 요청 때 다시 본다.
      }
    }
    if (removed.isNotEmpty) _scheduleNextPurge();
    return removed;
  }

  // ---- 예전 형식 평문 정리 ----

  /// 예전 형식(`secretmsg/<id>`)으로 남은 평문이 있는지 — [ensureTextIndex]가 성공한 뒤에만 정확하다.
  bool get hasLegacyTexts => _legacyTextIds.isNotEmpty;

  /// 계정 [userId]로 갈 수 있는 비밀 대화방 히스토리를 이미 한 번 다 훑었는지([markLegacySwept]).
  bool legacySweptFor(String userId) => _legacySweptUsers.contains(userId);

  /// 계정 [userId]로 갈 수 있는 비밀 대화방 히스토리를 처음부터 다 훑어, 거기 있던 예전 형식 평문을 모두 옮겼다.
  Future<void> markLegacySwept(String userId) async {
    if (_legacySweptUsers.contains(userId)) return;
    try {
      await _serial(() async {
        await _storage.write(key: '$_legacySweptKeyPrefix$userId', value: '1');
        _legacySweptUsers.add(userId);
      });
    } catch (_) {
      // 못 적으면 다음에 다시 훑는다.
    }
  }

  /// 남은 예전 형식 평문을 모두 지우고 지운 개수를 돌려준다. Session의 뒷정리가 이 계정으로 갈 수 있는 방을
  /// 모두 훑어 살아 있는 메시지의 평문은 다 옮긴 뒤, 이 기기에 다른 계정의 방일 수 있는 방이 남지 않았을 때만
  /// 부른다 — 그때 남은 것은 서버가 이미 지운 메시지의 평문뿐이다.
  Future<int> deleteLegacyTexts() async {
    if (!await _ensureTextIndex()) return 0;
    var deleted = 0;
    for (final id in _legacyTextIds.toList()) {
      try {
        await _serial(() async {
          await _storage.delete(key: _legacyTextKey(id));
          _legacyTextIds.remove(id);
        });
        deleted++;
      } catch (_) {
        // 못 지운 것은 다음 뒷정리 때 다시 지운다.
      }
    }
    if (_legacyTextIds.isEmpty) {
      // 더 옮길 것이 없으니 "다 훑었다" 표시도 치운다.
      for (final userId in _legacySweptUsers.toList()) {
        try {
          await _serial(() async {
            await _storage.delete(key: '$_legacySweptKeyPrefix$userId');
            _legacySweptUsers.remove(userId);
          });
        } catch (_) {}
      }
    }
    return deleted;
  }

  /// 가장 이른 삭제 예정 시각(+유예)에 맞춰 정리 타이머를 다시 건다 — 앱이 켜져 있는 동안 그 시각이 되면
  /// 알림 없이도 지워진다. 서버가 확정한 시각은 서버의 지금([_serverNowLowerBound])으로 잰다 — 서버 시각을
  /// 새로 알게 되면([noteServerTime]) 다시 건다.
  void _scheduleNextPurge() {
    if (_disposed) return;
    final localNowMs = DateTime.now().millisecondsSinceEpoch;
    final serverNowMs = _serverNowLowerBound(localNowMs);
    final grace = secretTextExpiryGrace.inMilliseconds;
    int? waitMs;
    for (final t in _texts.values) {
      final expiresAt = t.expiresAtMs;
      if (expiresAt == null) continue;
      final now = t.expiryFixed ? serverNowMs : localNowMs;
      final wait = expiresAt + grace - now;
      if (waitMs == null || wait < waitMs) waitMs = wait;
    }
    _purgeTimer?.cancel();
    _purgeTimer = null;
    if (waitMs == null) return;
    // 이미 지난 항목 — 방금 알게 된 시각(이미 지난 서버 값 등)이면 곧 지우고, 지우다 실패해서 남은 것이면
    // 저장소가 회복될 때까지 바로 다시 돌지 않고 조금 뒤에 다시 해 본다.
    final wait = waitMs <= 0
        ? (_lastPurgeFailed
              ? const Duration(minutes: 1)
              : const Duration(seconds: 5))
        : Duration(
            milliseconds: math.max(
              1000,
              math.min(waitMs, _maxPurgeWait.inMilliseconds),
            ),
          );
    _purgeTimer = Timer(wait, () {
      _purgeTimer = null;
      unawaited(purgeExpiredTexts());
    });
  }

  /// 로그아웃 등으로 이 저장소를 더 쓰지 않을 때 — 정리 타이머를 멈춘다(저장된 값은 그대로 둔다).
  void dispose() {
    _disposed = true;
    _purgeTimer?.cancel();
    _purgeTimer = null;
    onExpiredTextsPurged = null;
  }
}
