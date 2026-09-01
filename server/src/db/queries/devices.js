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
      // userId도 갱신 대상에 포함 — 같은 물리 기기에서 계정을 바꿔가며 로그인해도(예: 공용
      // PC) 이 deviceId는 항상 "마지막으로 로그인한 계정 소유"로 정리된다. 개인키가 로컬에만
      // 있으니 이전 계정은 어차피 이 deviceId로 서명 검증을 통과할 수 없어 안전하다.
      set: { userId, name, identityPublicKey, signingPublicKey, revokedAt: null, lastSeenAt: new Date() },
    })
    .returning();
  return row;
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

export async function revokeDevice(id, userId) {
  const [row] = await db
    .update(devices)
    .set({ revokedAt: new Date() })
    .where(and(eq(devices.id, id), eq(devices.userId, userId)))
    .returning();
  return row ?? null;
}
