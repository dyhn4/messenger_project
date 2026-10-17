import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Router } from 'express';
import { cert, deleteApp, initializeApp } from 'firebase-admin/app';
import { getMessaging } from 'firebase-admin/messaging';
import { listFcmTokensForUser, setDeviceFcmToken } from './db/queries/devices.js';
import { listMutedUserIdsForRoom } from './db/queries/rooms.js';
import { findTeamById } from './db/queries/teams.js';
import { listActiveUsersByIds } from './db/queries/users.js';
import { isUserInDnd } from './statusRules.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { isDeviceConnected, skipsPush } from './presence.js';
import { signFileUrl } from './upload.js';
import { sendWebPushToUser } from './webPush.js';

// 웹 앱(webPush.js)은 FCM과 따로 간다 — FCM이 아직 설정 안 된 서버(서비스 계정 없음)여도 웹 푸시는
// VAPID 키만으로 보낼 수 있어서, 아래 발송 함수들은 messaging이 없어도 웹 푸시는 보낸다.

const __dirname = path.dirname(fileURLToPath(import.meta.url));
// 예전 방식(파일을 서버 폴더에 직접 놓기) — 이미 이렇게 설정해둔 기존 설치를 깨지 않으려고
// DB 값이 없을 때의 폴백으로만 남겨둔다. 새 설치는 관리자 콘솔(/admin/fcm-settings)을 쓴다.
const legacyKeyPath = path.join(__dirname, '..', 'firebase-service-account.json');

/** FCM 발송용 firebase-admin 앱을 지연 초기화하고 캐싱한다. admin.js가 서비스 계정을
 * 새로 저장하면 invalidateMessagingCache()를 불러서 이 캐시를 지운다 — 그러면 서버를
 * 재시작하지 않아도 다음 발송부터 바로 새 설정으로 붙는다(version.js가 releases/version.json
 * 변경을 fs.watch로 즉시 반영하는 것과 같은 "재시작 없이" 철학).
 *
 * DB(server_settings.fcmServiceAccountJson)를 1순위로, 비어 있으면 legacyKeyPath 파일을
 * 2순위로 본다. 서비스 계정이 전혀 없으면(로컬 개발 중, 아직 설정 전 등) messaging이 null인
 * 채로 캐싱되고, 발송 함수들은 이때 조용히 아무것도 안 한다. */
let messagingCache; // undefined = 아직 로드 전; 로드 후엔 항상 { messaging } 형태.
let currentApp = null;

/**
 * 이 사람의 FCM 토큰 중 지금 보낼 것 — 소켓이 붙어 있는 기기는 뺀다(소켓으로 알림을 받는다). 그래서 PC 앱이 켜져 있어도
 * 접속해 있지 않은 휴대폰에는 간다("다른 기기 접속 중에도 푸시" — 끈 사람은 호출부가 skipsPush로 이미 뺐다).
 */
async function pushableFcmTokens(userId) {
  return (await listFcmTokensForUser(userId)).filter(({ deviceId }) => !isDeviceConnected(deviceId));
}

export function invalidateMessagingCache() {
  messagingCache = undefined;
  if (currentApp) {
    deleteApp(currentApp).catch(() => {});
    currentApp = null;
  }
}

async function loadServiceAccount() {
  const settings = await getServerSettings();
  if (settings.fcmServiceAccountJson) {
    try {
      return JSON.parse(settings.fcmServiceAccountJson);
    } catch {
      console.error('[push] DB에 저장된 FCM 서비스 계정이 올바른 JSON이 아닙니다.');
      return null;
    }
  }
  if (fs.existsSync(legacyKeyPath)) {
    return JSON.parse(fs.readFileSync(legacyKeyPath, 'utf8'));
  }
  return null;
}

async function getMessagingInstance() {
  if (messagingCache !== undefined) return messagingCache;
  const serviceAccount = await loadServiceAccount();
  if (!serviceAccount) {
    console.warn('[push] FCM 서비스 계정이 설정되지 않아 푸시가 비활성화됩니다.');
    messagingCache = { messaging: null };
    return messagingCache;
  }
  // 앱 이름을 매번 다르게 줘서(invalidate 후 재초기화 시) firebase-admin의 "같은 이름의
  // 앱이 이미 있다" 에러를 피한다 — deleteApp이 비동기라 직전 앱 정리가 아직 안 끝났을 수 있다.
  currentApp = initializeApp({ credential: cert(serviceAccount) }, `push-${Date.now()}`);
  messagingCache = { messaging: getMessaging(currentApp) };
  return messagingCache;
}

/** 클라이언트가 Firebase.initializeApp()에 쓸 4개 값 — Android 클라이언트 API 키는
 * 패키지명+SHA-1로 제한돼 비밀값이 아니므로(구글 공식 안내) 인증 없이 공개한다(GET /version과
 * 같은 성격). 관리자가 아직 설정 안 했으면 전부 null을 돌려주고, 클라이언트는 이 경우 FCM을
 * 그냥 비활성 상태로 둔다(main.dart/session.dart 참고). */
export const firebaseConfigRouter = Router();
firebaseConfigRouter.get('/firebase-client-config', async (req, res) => {
  const settings = await getServerSettings();
  res.json({
    apiKey: settings.fcmApiKey ?? null,
    appId: settings.fcmAppId ?? null,
    projectId: settings.fcmProjectId ?? null,
    messagingSenderId: settings.fcmMessagingSenderId ?? null,
  });
});

/** 이모지는 스티커 id로부터 클라이언트에서만 찾을 수 있어서(client/lib/data/stickers.dart),
 * 서버는 그냥 "이모티콘을 보냈습니다"로만 표시한다 — session.dart의 로컬 알림 미리보기
 * 규칙과 최대한 맞추되, 서버가 알 수 있는 정보만 쓴다. */
export function previewFor(entry) {
  switch (entry.type) {
    case 'text':
      return entry.text ?? '';
    case 'image':
      return '사진을 보냈습니다';
    case 'file':
      return entry.fileName ? `${entry.fileName} 파일을 보냈습니다` : '파일을 보냈습니다';
    case 'sticker':
      return '이모티콘을 보냈습니다';
    case 'post':
      // 보드 뷰 게시글은 본문이 길어서 제목만 보여준다(방 목록 미리보기도 같은 문구).
      return `게시글: ${entry.title ?? ''}`;
    case 'poll':
      // 투표는 messages.text에 제목이 들어 있다(polls.js).
      return `[투표] ${entry.text ?? ''}`;
    default:
      return '';
  }
}

export const SECRET_PREVIEW_PLACEHOLDER = '새 메시지가 있습니다';

/** session.dart의 _handleIncomingMessage와 같은 규칙(알림 제목의 [태그] 부분). */
export function roomTagFor(room) {
  // 나와의 대화는 1:1이 아니라 내 메모 공간이다 — 탱고톡 환영 안내·팀원 참여/제외 알림이 여기로 온다.
  if (room.isSelf) return '나와의 대화';
  if (room.type === 'dm') return '1:1';
  if (room.type === 'group') return room.name ?? '그룹채팅';
  if (room.type === 'topic') return room.name ?? null;
  return null;
}

/** 방에 새 메시지/댓글이 생겼을 때, 지금 소켓이 하나도 안 붙어있는(=완전히 앱이 꺼져있을
 * 가능성이 높은) 멤버들에게만 FCM 푸시를 보낸다. 소켓이 붙어있으면 이미 실시간으로
 * message:new/comment:new를 받아 로컬 알림이 뜨므로 중복 발송하지 않는다.
 *
 * [entry]는 { type, text, fileName } 형태(메시지/댓글 DTO에서 필요한 필드만).
 * [room]은 { id, teamId, isSecret, name, type } — roomTag 계산과 팀 이름 배지에 쓴다.
 * [sender]는 { avatarType, avatarEmoji, avatarColor, avatarUrl } — 알림의 큰 프로필
 * 아이콘(largeIcon)용. 앱이 완전히 꺼진 상태에서 이 데이터만으로 알림을 그려야 해서
 * (main.dart의 백그라운드 핸들러 참고), avatarUrl은 여기서 미리 서명해서 넘긴다. */
/** 알림 제목 끝에 붙일 팀 이름 배지(" [영업팀]") — 팀을 못 찾으면 빈 문자열. */
async function teamBadgeFor(teamId) {
  if (!teamId) return { name: null, badge: '' };
  const name = (await findTeamById(teamId))?.name ?? null;
  return { name, badge: name ? ` [${name}]` : '' };
}

export async function notifyOfflineMembers({
  memberIds,
  senderId,
  senderName,
  sender,
  room,
  entry,
  roomTag,
  kind, // 'message' | 'comment' | 'announcement'
  excludeUserIds = [], // 같은 글로 멘션 푸시를 이미 받는 사람 — 두 번 울리지 않게 뺀다(notifications.js).
}) {
  const mutedIds = new Set(await listMutedUserIdsForRoom(room.id));
  const excluded = new Set(excludeUserIds);
  const targets = memberIds.filter(
    (id) => id !== senderId && !skipsPush(id) && !mutedIds.has(id) && !excluded.has(id),
  );
  if (targets.length === 0) return;

  const preview = room.isSecret ? SECRET_PREVIEW_PLACEHOLDER : previewFor(entry);
  const conversationTitle = roomTag
    ? kind === 'comment'
      ? `${roomTag}·댓글`
      : kind === 'announcement'
        ? `${roomTag}·공지`
        : roomTag
    : null;
  await sendChatDataPush({ targets, room, sender, senderName, kind, conversationTitle, body: preview });
}

/**
 * 멘션·게시글 수정처럼 **알림 기록(notifications)에서 고른 사람**에게 채팅 푸시와 같은 모양으로 보낸다 — 누구에게
 * 보낼지(뮤트·mentionAll 설정·온라인 여부)는 notificationRules.js의 pushTargetsFor가 이미 골랐다. [kind]는 'mention' |
 * 'mention_all' | 'board_edit'이고 [conversationTag]는 제목 꼬리표('멘션' 등). 탭하면 그 방이 열린다(roomId).
 */
export async function notifyRecordPush({ targets, room, sender, senderName, kind, conversationTag, body, roomTag }) {
  if (targets.length === 0) return;
  const conversationTitle = roomTag ? `${roomTag}·${conversationTag}` : conversationTag;
  await sendChatDataPush({ targets, room, sender, senderName, kind, conversationTitle, body });
}

/**
 * [userIds] 중 지금 방해 금지 중이 아닌 사람만(statusRules.js isUserInDnd — "지금부터 n시간"과 매일 일정). 방해 금지 중인
 * 사람에게는 푸시를 보내지 않는다 — 메시지·안 읽은 수는 그대로 쌓이고, 앱을 열면 보인다. 화상회의 호출(notifyIncomingCall)은
 * 이것을 거치지 않는다(급한 일이라 방해 금지여도 울린다).
 */
async function withoutDndUsers(userIds) {
  if (userIds.length === 0) return userIds;
  const now = Date.now();
  const inDnd = new Set((await listActiveUsersByIds(userIds)).filter((u) => isUserInDnd(u, now)).map((u) => u.id));
  return inDnd.size === 0 ? userIds : userIds.filter((id) => !inDnd.has(id));
}

/** 채팅 푸시 본체 — notifyOfflineMembers(메시지·댓글·공지)와 notifyRecordPush(멘션 등)가 같은 모양으로 보낸다. */
async function sendChatDataPush({ targets: requested, room, sender, senderName, kind, conversationTitle, body: preview }) {
  const targets = await withoutDndUsers(requested);
  if (targets.length === 0) return;
  const { messaging } = await getMessagingInstance();
  // 여러 팀 알림이 섞여 오므로 제목 끝에 팀 이름을 배지처럼 붙인다(앱이 켜져 있을 때 뜨는
  // 로컬 알림과 같은 모양 — client/lib/services/session.dart 참고).
  const { name: teamName, badge: teamBadge } = await teamBadgeFor(room.teamId);
  // 안드로이드는 title을 통째로 쓰지 않고 "보낸사람"과 "대화방 이름"을 따로 받아서 대화
  // 레이아웃을 그린다(notification_service.dart 참고) — 그래서 합친 title과 별개로 조각도 보낸다.
  const title = conversationTitle
    ? `${senderName} [${conversationTitle}]${teamBadge}`
    : `${senderName}${teamBadge}`;
  const avatarUrl = sender?.avatarUrl ? signFileUrl(sender.avatarUrl) : null;
  // 웹 알림은 그림을 합성할 수 없어서 비밀 대화는 PC 앱 토스트처럼 제목 앞에 자물쇠를 붙인다.
  const webPayload = {
    kind,
    roomId: room.id,
    title: room.isSecret ? `🔒 ${title}` : title,
    body: preview,
  };

  await Promise.all(
    targets.map(async (userId) => {
      await sendWebPushToUser(userId, webPayload);
      if (!messaging) return;
      const tokens = await pushableFcmTokens(userId);
      await Promise.all(
        tokens.map(({ deviceId, fcmToken }) =>
          messaging
            .send({
              token: fcmToken,
              // data-only(알림 payload 없음) — 클라이언트가 flutter_local_notifications로
              // 직접 그려야 기존 로컬 알림(자물쇠 배지 등)과 모양이 같아진다. notification
              // 필드를 같이 넣으면 앱이 꺼져있을 때 OS가 그 필드로 자체 렌더링해버려서
              // onBackgroundMessage 핸들러가 아예 안 불릴 수 있다.
              data: {
                kind,
                roomId: room.id,
                title,
                body: preview,
                senderName,
                ...(conversationTitle
                  ? { conversationTitle: teamName ? `${conversationTitle} · ${teamName}` : conversationTitle }
                  : {}),
                isSecret: String(!!room.isSecret),
                avatarType: sender?.avatarType ?? 'initial',
                ...(sender?.avatarEmoji ? { avatarEmoji: sender.avatarEmoji } : {}),
                ...(sender?.avatarColor ? { avatarColor: sender.avatarColor } : {}),
                ...(avatarUrl ? { avatarUrl } : {}),
              },
              android: { priority: 'high' },
            })
            .catch(async (err) => {
              // 토큰이 만료/폐기됐으면(재설치, 앱 삭제 등) 정리해서 다음부터 헛발송 안 하게.
              if (err?.code === 'messaging/registration-token-not-registered') {
                await setDeviceFcmToken(deviceId, userId, null).catch(() => {});
                return;
              }
              console.error('[push] 발송 실패:', err?.message ?? err);
            }),
        ),
      );
    }),
  );
}

/**
 * 프로젝트 알림(업무 배정/댓글/마감 임박 등)을 소켓이 안 붙어있는 사람에게만 FCM으로 보낸다.
 * 채팅 푸시와 달리 알림 payload(notification)를 넣어서, 앱이 꺼져 있어도 OS가 바로 그려준다.
 */
export async function notifyProjectPush({ userId, title, body, projectId, taskId }) {
  if (skipsPush(userId)) return;
  if ((await withoutDndUsers([userId])).length === 0) return;
  await sendWebPushToUser(userId, { kind: 'project', projectId, title, body });
  const { messaging } = await getMessagingInstance();
  if (!messaging) return;
  const tokens = await pushableFcmTokens(userId);
  await Promise.all(
    tokens.map(({ deviceId, fcmToken }) =>
      messaging
        .send({
          token: fcmToken,
          notification: { title, body },
          data: { kind: 'project', projectId, ...(taskId ? { taskId } : {}) },
          android: { priority: 'high' },
        })
        .catch(async (err) => {
          if (err?.code === 'messaging/registration-token-not-registered') {
            await setDeviceFcmToken(deviceId, userId, null).catch(() => {});
            return;
          }
          console.error('[push] 프로젝트 알림 발송 실패:', err?.message ?? err);
        }),
    ),
  );
}

/**
 * 전자결재 알림(결재 요청·승인·반려 등 — groupware.js)을 프로젝트 알림과 같은 방식으로 보낸다 — 접속해 있지 않은 기기로, 알림
 * payload를 넣어 앱이 꺼져 있어도 OS가 그린다. 방해 금지 중인 사람에게는 보내지 않는다. 알림을 누르면 앱이 그 문서를 열 수 있게
 * 문서 id와 문서의 팀 id(회사 전체 범위면 빈 글자 — FCM data 값은 글자만 된다)를 싣는다.
 */
export async function notifyGroupwarePush({ userId, title, body, documentId, teamId = null }) {
  if (skipsPush(userId)) return;
  if ((await withoutDndUsers([userId])).length === 0) return;
  await sendWebPushToUser(userId, { kind: 'groupware', documentId, teamId: teamId ?? '', title, body });
  const { messaging } = await getMessagingInstance();
  if (!messaging) return;
  const tokens = await pushableFcmTokens(userId);
  await Promise.all(
    tokens.map(({ deviceId, fcmToken }) =>
      messaging
        .send({
          token: fcmToken,
          notification: { title, body },
          data: { kind: 'groupware', documentId, teamId: teamId ?? '' },
          android: { priority: 'high' },
        })
        .catch(async (err) => {
          if (err?.code === 'messaging/registration-token-not-registered') {
            await setDeviceFcmToken(deviceId, userId, null).catch(() => {});
            return;
          }
          console.error('[push] 결재 알림 발송 실패:', err?.message ?? err);
        }),
    ),
  );
}

/**
 * 화상회의가 시작됐을 때, 소켓이 안 붙어있는(=앱이 꺼져 있을 가능성이 높은) 멤버들에게
 * "전화가 왔다"고 FCM으로 알린다. 온라인인 사람은 이미 call:state 소켓 이벤트로 수신
 * 화면을 보고 있으므로 중복으로 보내지 않는다(메시지 푸시와 같은 분리 방식).
 *
 * 메시지 푸시와 다른 점은 **우선순위와 만료**다: 전화는 늦게 도착하면 의미가 없으므로
 * 안드로이드 high priority로 보내고(도즈 모드에서도 즉시 깨움), ttl을 통화 호출이 의미
 * 있는 시간(45초)으로 짧게 잡아서 나중에 켰을 때 지나간 전화가 울리지 않게 한다.
 * 클라이언트는 이 kind:'call'을 보고 일반 알림이 아니라 전체화면 수신 화면을 띄운다
 * (client/lib/main.dart의 백그라운드 핸들러).
 */
export async function notifyIncomingCall({ memberIds, callerId, caller, room, roomTag }) {
  const { messaging } = await getMessagingInstance();

  // 알림을 끈(뮤트) 방은 전화도 울리지 않는다 — 메시지 푸시(notifyOfflineMembers)와 같은 규칙. 안 그러면 뮤트해 둔 큰 토픽에서
  // 누가 통화를 걸 때마다 전체화면 수신 알림이 뜬다(앱이 켜져 있을 때의 수신 창도 같은 규칙 — client session.dart).
  const mutedIds = new Set(await listMutedUserIdsForRoom(room.id));
  const targets = memberIds.filter((id) => id !== callerId && !skipsPush(id) && !mutedIds.has(id));
  if (targets.length === 0) return;

  const callerName = caller?.name ?? caller?.username ?? '알 수 없음';
  const { name: teamName, badge: teamBadge } = await teamBadgeFor(room.teamId);
  const avatarUrl = caller?.avatarUrl ? signFileUrl(caller.avatarUrl) : null;

  await Promise.all(
    targets.map(async (userId) => {
      // 웹 앱은 전화 화면 없이 알림만 — 눌러서 열면 통화에 참여한다(sw.js의 'call:' payload). 늦은 전화는 의미가 없어 45초만.
      await sendWebPushToUser(
        userId,
        {
          kind: 'call',
          roomId: room.id,
          title: `${callerName}${teamBadge}`,
          body: roomTag ? `${roomTag} · 화상회의 요청` : '화상회의 요청',
        },
        { ttl: 45 },
      );
      if (!messaging) return;
      const tokens = await pushableFcmTokens(userId);
      await Promise.all(
        tokens.map(({ deviceId, fcmToken }) =>
          messaging
            .send({
              token: fcmToken,
              data: {
                kind: 'call',
                roomId: room.id,
                title: `${callerName}${teamBadge}`,
                body: '화상회의 요청',
                senderName: callerName,
                ...(roomTag
                  ? { conversationTitle: teamName ? `${roomTag} · ${teamName}` : roomTag }
                  : {}),
                // 비밀 대화는 통화를 걸 수 없지만(callAccess.js callRoomDenial) 방의 실제 값을 보낸다.
                isSecret: String(!!room.isSecret),
                avatarType: caller?.avatarType ?? 'initial',
                ...(caller?.avatarEmoji ? { avatarEmoji: caller.avatarEmoji } : {}),
                ...(caller?.avatarColor ? { avatarColor: caller.avatarColor } : {}),
                ...(avatarUrl ? { avatarUrl } : {}),
              },
              android: { priority: 'high', ttl: 45_000 },
            })
            .catch(async (err) => {
              if (err?.code === 'messaging/registration-token-not-registered') {
                await setDeviceFcmToken(deviceId, userId, null).catch(() => {});
                return;
              }
              console.error('[push] 통화 알림 발송 실패:', err?.message ?? err);
            }),
        ),
      );
    }),
  );
}

/** 비밀 대화 요청(secret:invite)을 상대가 오프라인일 때만 FCM으로 알린다 — 온라인이면
 * 소켓으로 바로 받아서(session.dart) 클라이언트가 직접 로컬 알림을 그리므로(같은 알림이
 * 두 번 뜨지 않게) 여기서는 건너뛴다. notifyOfflineMembers와 같은 분리 방식.
 * [teamId]는 제목 끝의 팀 이름 배지에만 쓴다(방이 속한 팀). */
export async function notifySecretChatInvite({ targetUserId, initiator, roomId, teamId }) {
  if (skipsPush(targetUserId)) return;

  const senderName = initiator?.name ?? initiator?.username ?? '알 수 없음';
  const { name: teamName, badge: teamBadge } = await teamBadgeFor(teamId);
  await sendWebPushToUser(targetUserId, {
    kind: 'secretInvite',
    roomId,
    title: `🔒 ${senderName} [비밀대화 요청]${teamBadge}`,
    body: '비밀 대화(종단간 암호화)를 요청했습니다.',
  });

  const { messaging } = await getMessagingInstance();
  if (!messaging) return;
  const tokens = await pushableFcmTokens(targetUserId);
  if (tokens.length === 0) return;
  const avatarUrl = initiator?.avatarUrl ? signFileUrl(initiator.avatarUrl) : null;

  await Promise.all(
    tokens.map(({ deviceId, fcmToken }) =>
      messaging
        .send({
          token: fcmToken,
          data: {
            kind: 'secretInvite',
            roomId,
            title: `${senderName} [비밀대화 요청]${teamBadge}`,
            body: '비밀 대화(종단간 암호화)를 요청했습니다.',
            senderName,
            conversationTitle: teamName ? `비밀대화 요청 · ${teamName}` : '비밀대화 요청',
            isSecret: 'true',
            avatarType: initiator?.avatarType ?? 'initial',
            ...(initiator?.avatarEmoji ? { avatarEmoji: initiator.avatarEmoji } : {}),
            ...(initiator?.avatarColor ? { avatarColor: initiator.avatarColor } : {}),
            ...(avatarUrl ? { avatarUrl } : {}),
          },
          android: { priority: 'high' },
        })
        .catch(async (err) => {
          if (err?.code === 'messaging/registration-token-not-registered') {
            await setDeviceFcmToken(deviceId, targetUserId, null).catch(() => {});
            return;
          }
          console.error('[push] 비밀대화 요청 발송 실패:', err?.message ?? err);
        }),
    ),
  );
}
