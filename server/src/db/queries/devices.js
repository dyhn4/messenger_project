import { and, desc, eq, inArray, isNotNull, isNull, ne, notInArray, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { devices, users } from '../schema.js';

/**
 * 한 사람에게 푸시(FCM·웹 푸시)를 보내는 기기 수 상한. 알림 하나가 기기 수만큼의 바깥 요청이 되는데, 기기 등록
 * (POST /devices)은 개수 제한이 없어서(앱을 다시 깔 때마다 새 기기 id가 생긴다) 이게 없으면 가짜 기기를 잔뜩 등록해
 * 두고 알림 하나로 서버가 수백·수천 건을 보내게 할 수 있었다. 등록 자체를 막지 않고 최근에 쓴 기기(lastSeenAt)부터
 * 이만큼만 남기므로, 여러 번 다시 깔아 옛 기기 행이 쌓인 사람도 지금 쓰는 기기로는 그대로 받는다. 밀려난 기기도 앱을
 * 다시 켜면 토큰·구독을 새로 등록하면서(client session.dart) 맨 앞으로 돌아온다.
 */
export const PUSH_DEVICES_PER_USER = 10;

/** 최근에 쓴 기기 먼저 — lastSeenAt이 없는 아주 옛 행은 맨 뒤. */
function recentFirst() {
  return [sql`${devices.lastSeenAt} desc nulls last`, desc(devices.createdAt)];
}

/**
 * 알림을 받을 수 있는 계정 — 정지·탈퇴하지 않은 계정(기기 행과 users를 이어서 본다). 모든 푸시(채팅·멘션·프로젝트·통화·비밀 대화
 * 요청 — push.js, webPush.js)가 아래 두 조회로 받는 기기를 고르므로 여기 한 곳에서 거른다. 예전엔 계정 상태를 아무 데서도 안 봐서,
 * 정지되거나 탈퇴한 사람의 폰·브라우저에도 메시지 미리보기·업무 제목 같은 알림이 계속 갔다(로그인·소켓만 막혔다). 정지·강제
 * 로그아웃·탈퇴 때는 기기의 토큰·구독도 지우지만(clearPushTargetsForUser — admin.js, users.js), 그게 실패했거나 그 전에 등록된
 * 값이 남아 있어도 여기서 한 번 더 막는다.
 */
function pushableAccount() {
  return and(isNull(users.suspendedAt), isNull(users.deletedAt));
}

/**
 * 기기 [deviceId]의 [field]('fcmToken' | 'webPushSubscription')에 [value]를 막 저장한 뒤의 정리.
 * ①같은 값이 남아 있는 다른 기기 행에서 지운다 — 같은 앱 설치의 토큰·같은 브라우저의 구독은 기기 하나 것이다. 공용
 *   기기에서 계정을 바꿔 로그인했는데 앞 사람의 로그아웃(토큰 지우기)이 서버에 못 닿았으면 앞 사람 알림(미리보기
 *   포함)까지 지금 사람 화면에 뜨고, 같은 사람의 두 행이면 알림이 두 번 오면서 상한 자리만 차지한다.
 * ②이 사람 기기 중 최근에 쓴 PUSH_DEVICES_PER_USER개만 남긴다(폐기된 기기의 값도 이때 같이 지워진다).
 */
async function settlePushTarget(field, deviceId, userId, value) {
  const column = devices[field];
  await db
    .update(devices)
    .set({ [field]: null })
    .where(and(eq(column, value), ne(devices.id, deviceId)));
  const kept = db
    .select({ id: devices.id })
    .from(devices)
    .where(and(eq(devices.userId, userId), isNull(devices.revokedAt), isNotNull(column)))
    .orderBy(...recentFirst())
    .limit(PUSH_DEVICES_PER_USER);
  await db
    .update(devices)
    .set({ [field]: null })
    .where(and(eq(devices.userId, userId), isNotNull(column), notInArray(devices.id, kept)));
}

/** 기기 등록은 멱등 — 같은 deviceId로 다시 등록하면 공개키/이름만 갱신한다(재설치 등으로
 * 키가 바뀐 경우도 이걸로 자연스럽게 갱신됨 — 다만 그러면 기존 비밀 대화 세션은 더 이상
 * 복호화할 수 없다, 이는 E2EE의 당연한 결과). */
export async function upsertDevice({ id, userId, name, identityPublicKey, signingPublicKey, kind = null }) {
  const [row] = await db
    .insert(devices)
    .values({ id, userId, name, identityPublicKey, signingPublicKey, kind, lastSeenAt: new Date() })
    .onConflictDoUpdate({
      target: devices.id,
      // 종류는 알려 줬을 때만 바꾼다(예전 앱이 다시 등록해도 이미 아는 종류를 지우지 않게).
      set: { name, identityPublicKey, signingPublicKey, revokedAt: null, lastSeenAt: new Date(), ...(kind ? { kind } : {}) },
      // 같은 사람의 기기일 때만 갱신한다. 예전엔 다른 사람 것도 덮어써서(소유자까지 바꿔서), 비밀 대화
      // 상대에게 보이는 기기 id만 알면 그 기기를 가로채 상대의 비밀 대화를 깨고 푸시를 엉뚱하게 보낼 수
      // 있었다. 공용 PC에서 계정을 바꿔 로그인하면 여기서 null이 되고, 앱이 새 기기 id를 만들어 다시
      // 등록한다(client device_identity.dart).
      // 키도 같아야 한다 — 앱은 기기 id와 키를 늘 함께 만들어서(키를 잃으면 새 id) 같은 id의 키가 바뀔 일이 없다.
      // 상대 앱들은 이 기기의 서명 키를 처음 본 값으로 고정해 두므로(비밀 대화 키 고정), 로그인을 훔친 사람이 같은
      // id에 다른 키를 올려 두면 그 기기와의 비밀 대화가 모두 멈춘다. 그래서 바뀐 키는 받지 않는다(같은 409라 앱은
      // 위와 같이 새 기기 id로 다시 등록한다).
      setWhere: and(
        eq(devices.userId, userId),
        eq(devices.identityPublicKey, identityPublicKey),
        eq(devices.signingPublicKey, signingPublicKey),
      ),
    })
    .returning();
  return row ?? null;
}

export function findDeviceById(id) {
  return db
    .select()
    .from(devices)
    .where(eq(devices.id, id))
    .then((rows) => rows[0] ?? null);
}

/** 소켓/비밀 대화 인증에 쓴다 — 이 deviceId가 실제로 이 유저 소유이고 폐기되지 않았는지. */
export function findActiveDeviceForUser(id, userId) {
  return db
    .select()
    .from(devices)
    .where(and(eq(devices.id, id), eq(devices.userId, userId), isNull(devices.revokedAt)))
    .then((rows) => rows[0] ?? null);
}

/** 신원 서명 검증용 — 상대방(다른 유저) 기기의 공개키 조회. deviceId는 PK라 유저 무관하게 하나로
 * 특정되고, 이 값들은 그 자체가 공개되도록 설계된 값(공개키/서명 검증키)이라 소유자 검사 없이도
 * 안전하다 — 어차피 로그인한 사람만 접근 가능하고(requireAuth), 여기서 개인키는 절대 안 나간다. */
export function findDevicePublicInfo(deviceId) {
  return db
    .select({
      id: devices.id,
      userId: devices.userId,
      identityPublicKey: devices.identityPublicKey,
      signingPublicKey: devices.signingPublicKey,
      revokedAt: devices.revokedAt,
    })
    .from(devices)
    .where(eq(devices.id, deviceId))
    .then((rows) => rows[0] ?? null);
}

export function listDevicesForUser(userId) {
  return db.select().from(devices).where(eq(devices.userId, userId));
}

export async function touchDeviceLastSeen(id) {
  await db.update(devices).set({ lastSeenAt: new Date() }).where(eq(devices.id, id));
}

export async function setDeviceFcmToken(id, userId, token) {
  const [row] = await db
    .update(devices)
    .set({ fcmToken: token, lastSeenAt: new Date() })
    .where(and(eq(devices.id, id), eq(devices.userId, userId), isNull(devices.revokedAt)))
    .returning();
  if (row && token) await settlePushTarget('fcmToken', id, userId, token);
  return row ?? null;
}

/** 오프라인(소켓 미연결)인 사용자에게 FCM 푸시를 보낼 때 쓴다 — 폐기되지 않은 기기 중
 * 토큰이 등록된 것만(같은 사람이 여러 기기를 갖고 있으면 다 받는다). 단 최근에 쓴 기기부터
 * PUSH_DEVICES_PER_USER개까지 — 등록할 때도 이만큼만 남기지만, 그 전에 쌓인 행까지 여기서 한 번 더 묶는다.
 * 정지·탈퇴한 계정이면 아무 기기도 돌려주지 않는다(pushableAccount). */
export function listFcmTokensForUser(userId) {
  return db
    .select({ deviceId: devices.id, fcmToken: devices.fcmToken })
    .from(devices)
    .innerJoin(users, eq(users.id, devices.userId))
    .where(and(eq(devices.userId, userId), isNull(devices.revokedAt), isNotNull(devices.fcmToken), pushableAccount()))
    .orderBy(...recentFirst())
    .limit(PUSH_DEVICES_PER_USER)
    .then((rows) => rows.filter((r) => !!r.fcmToken));
}

/** 웹 앱의 웹 푸시 구독(JSON 문자열, null이면 지움) — setDeviceFcmToken의 웹판. 값 검사는 부르는 쪽
 * (devices.js — webPushEndpoint.js의 parseWebPushSubscription)이 한다. */
export async function setDeviceWebPushSubscription(id, userId, subscriptionJson) {
  const [row] = await db
    .update(devices)
    .set({ webPushSubscription: subscriptionJson, lastSeenAt: new Date() })
    .where(and(eq(devices.id, id), eq(devices.userId, userId), isNull(devices.revokedAt)))
    .returning();
  if (row && subscriptionJson) await settlePushTarget('webPushSubscription', id, userId, subscriptionJson);
  return row ?? null;
}

/** 오프라인 사용자에게 웹 푸시를 보낼 때 — 폐기되지 않은 기기 중 구독이 있는 것만, 최근에 쓴 기기부터
 * PUSH_DEVICES_PER_USER개까지(listFcmTokensForUser와 같은 이유). 정지·탈퇴한 계정이면 빈 목록이다. 파싱해서 돌려주고,
 * 망가진 값은 subscription을 null로 준다 — 검사·정리는 발송하는 쪽(webPush.js)이 한 곳에서 한다. */
export async function listWebPushSubscriptionsForUser(userId) {
  const rows = await db
    .select({ deviceId: devices.id, kind: devices.kind, webPushSubscription: devices.webPushSubscription })
    .from(devices)
    .innerJoin(users, eq(users.id, devices.userId))
    .where(
      and(
        eq(devices.userId, userId),
        isNull(devices.revokedAt),
        isNotNull(devices.webPushSubscription),
        pushableAccount(),
      ),
    )
    .orderBy(...recentFirst())
    .limit(PUSH_DEVICES_PER_USER);
  return rows.map((r) => {
    let subscription = null;
    try {
      subscription = JSON.parse(r.webPushSubscription);
    } catch {
      // 망가진 값 — null로 넘기면 webPush.js가 지운다.
    }
    return { deviceId: r.deviceId, kind: r.kind ?? null, subscription };
  });
}

/**
 * 이 사람의 앱 기기 id들 — `{ windows: [PC 앱], android: [안드로이드 앱] }`(폐기된 것은 빼고). 웹 푸시를 같은 종류 기기의
 * 브라우저로 보낼지 정할 때 쓴다(webPush.js — presence.js webPushTargets).
 */
export async function listAppDeviceIds(userId) {
  const rows = await db
    .select({ id: devices.id, kind: devices.kind })
    .from(devices)
    .where(and(eq(devices.userId, userId), inArray(devices.kind, ['windows', 'android']), isNull(devices.revokedAt)));
  return {
    windows: rows.filter((r) => r.kind === 'windows').map((r) => r.id),
    android: rows.filter((r) => r.kind === 'android').map((r) => r.id),
  };
}

/**
 * 이 사람의 모든 기기에서 푸시 토큰·웹 푸시 구독을 지운다 — 탈퇴(users.js)·정지·강제 로그아웃(admin.js)처럼 그 계정의 모든 기기가
 * 로그아웃되는 때. 앱의 로그아웃은 인증이 살아 있을 때만 자기 토큰을 지울 수 있어서, 쫓겨난 기기의 값은 서버가 지워야 한다(다시
 * 로그인하면 앱이 새로 등록한다). 기기 행과 공개키는 지난 비밀 대화 기록 때문에 그대로 둔다.
 */
export async function clearPushTargetsForUser(userId) {
  await db
    .update(devices)
    .set({ fcmToken: null, webPushSubscription: null })
    .where(eq(devices.userId, userId));
}

export async function revokeDevice(id, userId) {
  const [row] = await db
    .update(devices)
    .set({ revokedAt: new Date() })
    .where(and(eq(devices.id, id), eq(devices.userId, userId)))
    .returning();
  return row ?? null;
}
