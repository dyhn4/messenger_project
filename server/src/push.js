import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { cert, initializeApp } from 'firebase-admin/app';
import { getMessaging } from 'firebase-admin/messaging';
import { listFcmTokensForUser, setDeviceFcmToken } from './db/queries/devices.js';
import { listMutedUserIdsForRoom } from './db/queries/rooms.js';
import { isOnline } from './presence.js';
import { signFileUrl } from './upload.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const keyPath = path.join(__dirname, '..', 'firebase-service-account.json');

// 서비스 계정 키가 없어도(아직 FCM을 안 붙였거나 로컬 개발 중) 서버 자체는 정상 기동해야
// 한다 — notifyOfflineMembers는 이때 조용히 아무것도 안 한다. version.js의 releases/ 폴더와
// 같은 패턴(선택적 기능, 없으면 그냥 비활성).
let messaging = null;
if (fs.existsSync(keyPath)) {
  const serviceAccount = JSON.parse(fs.readFileSync(keyPath, 'utf8'));
  const app = initializeApp({ credential: cert(serviceAccount) });
  messaging = getMessaging(app);
} else {
  console.warn('[push] firebase-service-account.json이 없어 FCM 푸시가 비활성화됩니다.');
}

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
    default:
      return '';
  }
}

export const SECRET_PREVIEW_PLACEHOLDER = '새 메시지가 있습니다';

/** session.dart의 _handleIncomingMessage와 같은 규칙(알림 제목의 [태그] 부분). */
export function roomTagFor(room) {
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
 * [room]은 { id, isSecret, name, type } — roomTag 계산에 필요한 최소 정보.
 * [sender]는 { avatarType, avatarEmoji, avatarColor, avatarUrl } — 알림의 큰 프로필
 * 아이콘(largeIcon)용. 앱이 완전히 꺼진 상태에서 이 데이터만으로 알림을 그려야 해서
 * (main.dart의 백그라운드 핸들러 참고), avatarUrl은 여기서 미리 서명해서 넘긴다. */
export async function notifyOfflineMembers({
  memberIds,
  senderId,
  senderName,
  sender,
  room,
  entry,
  roomTag,
  kind, // 'message' | 'comment'
}) {
  if (!messaging) return;

  const mutedIds = new Set(await listMutedUserIdsForRoom(room.id));
  const targets = memberIds.filter(
    (id) => id !== senderId && !isOnline(id) && !mutedIds.has(id),
  );
  if (targets.length === 0) return;

  const preview = room.isSecret ? SECRET_PREVIEW_PLACEHOLDER : previewFor(entry);
  // 안드로이드는 title을 통째로 쓰지 않고 "보낸사람"과 "대화방 이름"을 따로 받아서 대화
  // 레이아웃을 그린다(notification_service.dart 참고) — 그래서 합친 title과 별개로 조각도 보낸다.
  const conversationTitle = roomTag ? (kind === 'comment' ? `${roomTag}·댓글` : roomTag) : null;
  const title = conversationTitle ? `${senderName} [${conversationTitle}]` : senderName;
  const avatarUrl = sender?.avatarUrl ? signFileUrl(sender.avatarUrl) : null;

  await Promise.all(
    targets.map(async (userId) => {
      const tokens = await listFcmTokensForUser(userId);
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
                ...(conversationTitle ? { conversationTitle } : {}),
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

/** 비밀 대화 요청(secret:invite)을 상대가 오프라인일 때만 FCM으로 알린다 — 온라인이면
 * 소켓으로 바로 받아서(session.dart) 클라이언트가 직접 로컬 알림을 그리므로(같은 알림이
 * 두 번 뜨지 않게) 여기서는 건너뛴다. notifyOfflineMembers와 같은 분리 방식. */
export async function notifySecretChatInvite({ targetUserId, initiator, roomId }) {
  if (!messaging) return;
  if (isOnline(targetUserId)) return;

  const tokens = await listFcmTokensForUser(targetUserId);
  if (tokens.length === 0) return;

  const senderName = initiator?.name ?? initiator?.username ?? '알 수 없음';
  const avatarUrl = initiator?.avatarUrl ? signFileUrl(initiator.avatarUrl) : null;

  await Promise.all(
    tokens.map(({ deviceId, fcmToken }) =>
      messaging
        .send({
          token: fcmToken,
          data: {
            kind: 'secretInvite',
            roomId,
            title: `${senderName} [비밀대화 요청]`,
            body: '비밀 대화(종단간 암호화)를 요청했습니다.',
            senderName,
            conversationTitle: '비밀대화 요청',
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
