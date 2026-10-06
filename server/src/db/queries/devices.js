import { and, eq, isNull } from 'drizzle-orm';
import { db } from '../client.js';
import { devices } from '../schema.js';

/** 기기 등록은 멱등 — 같은 deviceId로 다시 등록하면 공개키/이름만 갱신한다(재설치 등으로
 * 키가 바뀐 경우도 이걸로 자연스럽게 갱신됨 — 다만 그러면 기존 비밀 대화 세션은 더 이상
 * 복호화할 수 없다, 이는 E2EE의 당연한 결과). */
export async function upsertDevice({ id, userId, name, identityPublicKey, signingPublicKey }) {
  const [row] = await db
    .insert(devices)
    .values({ id, userId, name, identityPublicKey, signingPublicKey, lastSeenAt: new Date() })
    .onConflictDoUpdate({
      target: devices.id,
      set: { name, identityPublicKey, signingPublicKey, revokedAt: null, lastSeenAt: new Date() },
      // 같은 사람의 기기일 때만 갱신한다. 예전엔 다른 사람 것도 덮어써서(소유자까지 바꿔서), 비밀 대화
      // 상대에게 보이는 기기 id만 알면 그 기기를 가로채 상대의 비밀 대화를 깨고 푸시를 엉뚱하게 보낼 수
      // 있었다. 공용 PC에서 계정을 바꿔 로그인하면 여기서 null이 되고, 앱이 새 기기 id를 만들어 다시
      // 등록한다(client device_identity.dart).
      setWhere: eq(devices.userId, userId),
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
  return row ?? null;
}

/** 오프라인(소켓 미연결)인 사용자에게 FCM 푸시를 보낼 때 쓴다 — 폐기되지 않은 기기 중
 * 토큰이 등록된 것만(같은 사람이 여러 기기를 갖고 있으면 전부 받는다). */
export function listFcmTokensForUser(userId) {
  return db
    .select({ deviceId: devices.id, fcmToken: devices.fcmToken })
    .from(devices)
    .where(and(eq(devices.userId, userId), isNull(devices.revokedAt)))
    .then((rows) => rows.filter((r) => !!r.fcmToken));
}

/** 웹 앱의 웹 푸시 구독(JSON 문자열, null이면 지움) — setDeviceFcmToken의 웹판. */
export async function setDeviceWebPushSubscription(id, userId, subscriptionJson) {
  const [row] = await db
    .update(devices)
    .set({ webPushSubscription: subscriptionJson, lastSeenAt: new Date() })
    .where(and(eq(devices.id, id), eq(devices.userId, userId), isNull(devices.revokedAt)))
    .returning();
  return row ?? null;
}

/** 오프라인 사용자에게 웹 푸시를 보낼 때 — 폐기되지 않은 기기 중 구독이 있는 것만(파싱해서 돌려준다). */
export async function listWebPushSubscriptionsForUser(userId) {
  const rows = await db
    .select({ deviceId: devices.id, webPushSubscription: devices.webPushSubscription })
    .from(devices)
    .where(and(eq(devices.userId, userId), isNull(devices.revokedAt)));
  const result = [];
  for (const r of rows) {
    if (!r.webPushSubscription) continue;
    try {
      result.push({ deviceId: r.deviceId, subscription: JSON.parse(r.webPushSubscription) });
    } catch {
      // 망가진 값은 건너뛴다(다음 구독 등록 때 덮어써진다).
    }
  }
  return result;
}

export async function revokeDevice(id, userId) {
  const [row] = await db
    .update(devices)
    .set({ revokedAt: new Date() })
    .where(and(eq(devices.id, id), eq(devices.userId, userId)))
    .returning();
  return row ?? null;
}
