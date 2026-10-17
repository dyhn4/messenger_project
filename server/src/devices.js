import { Router } from 'express';
import { issueTokenPair } from './auth.js';
import { invalidateDeviceState } from './authState.js';
import {
  findActiveDeviceForUser,
  findDevicePublicInfo,
  listDevicesForUser,
  revokeDevice,
  revokeOtherDevices,
  setDeviceFcmToken,
  setDeviceWebPushSubscription,
  upsertDevice,
} from './db/queries/devices.js';
import { findUserById, updateUser } from './db/queries/users.js';
import { isDeviceConnected } from './presence.js';
import { parseWebPushSubscription } from './webPushEndpoint.js';

/** 기기 한 대 → 응답 모양. [currentId]는 지금 요청한 기기(토큰의 `did`) — "내 기기" 화면이 "이 기기"로 표시한다. */
function toDeviceDto(d, currentId = null) {
  return {
    id: d.id,
    name: d.name,
    kind: d.kind ?? null,
    identityPublicKey: d.identityPublicKey,
    signingPublicKey: d.signingPublicKey,
    createdAt: new Date(d.createdAt).getTime(),
    lastSeenAt: d.lastSeenAt ? new Date(d.lastSeenAt).getTime() : null,
    revoked: !!d.revokedAt,
    current: !!currentId && d.id === currentId,
    online: isDeviceConnected(d.id),
  };
}

/** 이 사람의 소켓 중 [deviceId] 기기의 것만 끊는다(그 기기를 로그아웃시켰을 때 — 다른 기기는 그대로). */
async function disconnectDeviceSockets(io, userId, deviceId) {
  if (!io) return;
  for (const socket of await io.in(`user:${userId}`).fetchSockets()) {
    if (socket.data.deviceId === deviceId) socket.disconnect(true);
  }
}

/*
 * 기기 칸 검사 — 로그인한 누구나 부르는 경로라, 예전엔 문자열인지·길이도 안 보고 그대로 저장해서 한 사람이 아주 큰 값
 * (본문 상한 100KB 가까이)을 기기 이름·키·푸시 토큰으로 쌓아 둘 수 있었다(기기 목록·비밀 대화 상대의 키 조회·푸시 발송이
 * 그 값을 매번 읽는다). 앱이 실제로 보내는 값은 아래보다 훨씬 작다: 기기 id는 uuid v4(36자 — client device_identity.dart),
 * 공개키는 32바이트 X25519·Ed25519 키의 base64(44자), 이름은 운영체제 이름(windows·android·web), FCM 토큰은 200자 안팎.
 * 그 밖의 칸(플랫폼·모델·앱 버전 등)은 저장하지 않으므로 보지 않는다. DB 없이 테스트한다(test/deviceFields.test.js).
 */

/** 기기 id — 영문·숫자와 . _ : - 만, 128자까지(앱은 uuid). 주소(/devices/<id>/…)에도 들어가므로 / ? # 같은 글자는 받지 않는다. */
const DEVICE_ID_RE = /^[A-Za-z0-9._:-]{1,128}$/;
/** 공개키 — base64(표준·URL 안전, 패딩 포함). 실제 키는 44자라 넉넉하게 128자까지. */
const PUBLIC_KEY_RE = /^[A-Za-z0-9+/_-]{1,128}={0,2}$/;
export const DEVICE_NAME_MAX_LENGTH = 100;
/** FCM 등록 토큰 — 공백·제어 문자 없는 ASCII. 실제 토큰은 200자 안팎이라 넉넉하게 4096자까지. */
const FCM_TOKEN_RE = /^[\x21-\x7e]{1,4096}$/;
// 제어 문자(줄바꿈·탭 포함)와 방향을 바꾸는 보이지 않는 글자 — 기기 이름을 화면에 보일 때 줄이 깨지거나 글자가 뒤집히지 않게.
const NAME_STRIP_RE = /[\u0000-\u001f\u007f-\u009f​-‏‪-‮⁦-⁩﻿]/g;

export const isDeviceId = (value) => typeof value === 'string' && DEVICE_ID_RE.test(value);
const isPublicKey = (value) => typeof value === 'string' && PUBLIC_KEY_RE.test(value);

/**
 * 기기 이름 — 보여 주기만 하는 값이라 틀려도 등록을 막지 않고 다듬는다(앱이 이 등록 실패를 조용히 넘기면 비밀 대화를 못 쓰게
 * 된다): 문자열이 아니면 null, 제어·방향 글자는 빼고, 앞뒤 공백을 떼고, DEVICE_NAME_MAX_LENGTH자(글자 단위 — 이모지를 반으로
 * 자르지 않는다)까지만 둔다. 다 지우고 남는 게 없으면 null.
 */
export function parseDeviceName(value) {
  if (typeof value !== 'string') return null;
  const cleaned = value.replace(NAME_STRIP_RE, '').trim();
  if (!cleaned) return null;
  return Array.from(cleaned).slice(0, DEVICE_NAME_MAX_LENGTH).join('').trim();
}

/**
 * POST /devices 본문 → 저장할 칸 `{ fields: { id, name, identityPublicKey, signingPublicKey } }` | `{ error }`. 기기 id·공개키는
 * 다른 사람이 비밀 대화를 시작할 때 그대로 쓰는 값이라 모양이 틀리면 받지 않는다.
 */
/** 앱이 알려 주는 기기 종류(schema.js devices.kind) — 모르는 값이면 null(예전 앱처럼 "모름"으로 본다). */
export const DEVICE_KINDS = Object.freeze(['windows', 'android', 'ios', 'web-desktop', 'web-android', 'web-mobile']);

export function parseDeviceKind(value) {
  return DEVICE_KINDS.includes(value) ? value : null;
}

export function parseDeviceRegistration(body) {
  const { deviceId, name, identityPublicKey, signingPublicKey, kind } = body ?? {};
  if (deviceId == null || identityPublicKey == null || signingPublicKey == null) {
    return { error: 'deviceId, identityPublicKey, signingPublicKey가 필요합니다.' };
  }
  if (!isDeviceId(deviceId)) return { error: 'deviceId가 올바르지 않습니다.' };
  if (!isPublicKey(identityPublicKey) || !isPublicKey(signingPublicKey)) {
    return { error: '공개키(identityPublicKey, signingPublicKey)가 올바르지 않습니다.' };
  }
  return {
    fields: { id: deviceId, name: parseDeviceName(name), identityPublicKey, signingPublicKey, kind: parseDeviceKind(kind) },
  };
}

/**
 * PATCH /devices/:id/fcm-token의 token → `{ token }`(null이면 지운다) | `{ error }`. 빈 문자열은 지우기로 본다(앱은 로그아웃할 때
 * null을 보낸다).
 */
export function parseFcmToken(value) {
  if (value === null || value === '') return { token: null };
  if (typeof value !== 'string') return { error: 'token은 문자열 또는 null이어야 합니다.' };
  if (!FCM_TOKEN_RE.test(value)) return { error: 'token이 올바르지 않습니다.' };
  return { token: value };
}

const DEVICE_NOT_FOUND = '기기를 찾을 수 없습니다.';

/**
 * 기기 신원 등록/조회(비밀 대화 E2EE의 공개키 — 개인키는 절대 여기 안 온다)와 "내 기기"(목록·기기별 로그아웃·다른 모든 기기에서
 * 로그아웃). [io]는 로그아웃시킨 기기의 소켓을 끊는 데 쓴다.
 */
export function createDevicesRouter(io = null) {
  const router = Router();

  /**
   * 기기 등록(앱이 로그인할 때마다 — 멱등). 등록한 기기에 묶인 새 토큰 쌍(`tokens`)을 같이 돌려준다 — 앱이 그것으로 바꿔 끼우면
   * 이 기기만 따로 로그아웃시킬 수 있다(auth.js issueTokenPair). 로그아웃시킨 기기도 다시 로그인하면 여기서 되살아난다.
   */
  router.post('/devices', async (req, res) => {
    const parsed = parseDeviceRegistration(req.body);
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const device = await upsertDevice({ ...parsed.fields, userId: req.user.sub });
    // 다른 사람이 쓰는 기기 id — 덮어쓰지 않는다. 앱은 이 409를 받으면 새 기기 id로 다시 등록한다.
    if (!device) return res.status(409).json({ error: '다른 계정이 쓰고 있는 기기입니다.', code: 'device_owned_by_other' });
    invalidateDeviceState(device.id, req.user.sub);
    // 토큰 버전은 requireAuth가 지금 계정 값과 맞는지 이미 봤다 — DB를 다시 읽지 않고 그 토큰의 값으로 새로 낸다.
    const tokens = issueTokenPair(
      { id: req.user.sub, username: req.user.username, tokenVersion: req.user.tokenVersion ?? 0 },
      { deviceId: device.id, authAt: req.user.aat ?? req.user.iat },
    );
    res.status(201).json({ ...toDeviceDto(device, device.id), tokens });
  });

  /** 내 기기 목록 — 로그아웃시킨 기기도 `revoked`로 같이 온다(화면은 감춘다). `current`는 지금 이 요청을 보낸 기기. */
  router.get('/devices', async (req, res) => {
    const current = req.user.did ?? null;
    res.json((await listDevicesForUser(req.user.sub)).map((d) => toDeviceDto(d, current)));
  });

  /**
   * 다른 모든 기기에서 로그아웃 — 토큰 버전을 올려 이 계정의 모든 토큰을 무효로 하고(기기에 묶이지 않은 예전 토큰까지), 이 기기
   * 말고 전부 로그아웃(revoked)시킨 뒤, 이 기기에 묶인 새 토큰 쌍을 돌려준다(앱은 그것으로 바꾸고 소켓을 다시 붙인다). 이 기기는
   * 토큰의 `did`, 없으면(기기 등록 전 토큰) 본문 `deviceId` — 내 것이고 로그인돼 있어야 한다.
   */
  router.post('/devices/logout-others', async (req, res) => {
    const claimed = req.user.did ?? (isDeviceId(req.body?.deviceId) ? req.body.deviceId : null);
    const current = claimed ? await findActiveDeviceForUser(claimed, req.user.sub) : null;
    if (!current) return res.status(400).json({ error: '이 기기를 확인할 수 없습니다. 앱을 다시 시작한 뒤 시도하세요.' });
    const user = await findUserById(req.user.sub);
    if (!user) return res.status(404).json({ error: '사용자를 찾을 수 없습니다.' });
    const updated = await updateUser(user.id, { tokenVersion: (user.tokenVersion ?? 0) + 1 });
    const revoked = await revokeOtherDevices(user.id, current.id);
    for (const d of revoked) invalidateDeviceState(d.id, user.id);
    // 이 기기의 소켓도 옛 토큰 버전이라 같이 끊긴다 — 앱이 새 토큰으로 다시 붙는다.
    io?.in(`user:${user.id}`).disconnectSockets(true);
    res.json({
      ...issueTokenPair(updated, { deviceId: current.id, authAt: req.user.aat ?? req.user.iat }),
      revokedCount: revoked.length,
    });
  });

  // 비밀 대화 핸드셰이크에서 상대 기기의 서명 검증키를 확인하는 용도(신원 서명 검증 —
  // MITM 방지). 공개키류만 내려주고 개인키는 절대 여기 없다. 모양이 틀린 id는 그런 기기가 없으니 DB에 묻지 않는다.
  router.get('/devices/:deviceId/public-key', async (req, res) => {
    const device = isDeviceId(req.params.deviceId) ? await findDevicePublicInfo(req.params.deviceId) : null;
    if (!device || device.revokedAt) return res.status(404).json({ error: DEVICE_NOT_FOUND });
    res.json({
      userId: device.userId,
      identityPublicKey: device.identityPublicKey,
      signingPublicKey: device.signingPublicKey,
    });
  });

  // 앱이 완전히 꺼져도 알림을 받을 수 있게(FCM). null을 보내면(로그아웃 등) 토큰을 지워서
  // 더 이상 이 기기로 푸시를 보내지 않는다. 안드로이드 전용 — Windows 클라이언트는 호출 안 함.
  router.patch('/devices/:deviceId/fcm-token', async (req, res) => {
    const parsed = parseFcmToken(req.body?.token);
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    if (!isDeviceId(req.params.deviceId)) return res.status(404).json({ error: DEVICE_NOT_FOUND });
    const device = await setDeviceFcmToken(req.params.deviceId, req.user.sub, parsed.token);
    if (!device) return res.status(404).json({ error: DEVICE_NOT_FOUND });
    res.json({ ok: true });
  });

  // 웹 앱의 웹 푸시 구독(fcm-token의 웹판, webPush.js). null을 보내면(로그아웃 등) 지운다. 서버가 이 endpoint로
  // 직접 요청을 보내므로 브라우저 푸시 서비스 주소만 받는다(webPushEndpoint.js — SSRF 방지, 주소·키 길이도 거기서 본다).
  // 한 사람이 받는 기기 수는 queries/devices.js의 PUSH_DEVICES_PER_USER까지다(오래 안 쓴 기기의 구독부터 지워진다).
  router.patch('/devices/:deviceId/web-push', async (req, res) => {
    const sub = req.body?.subscription;
    let stored = null;
    if (sub !== null) {
      const parsed = parseWebPushSubscription(sub);
      if (parsed.error) {
        // 허용 목록 밖의 푸시 서비스면 호스트를 남긴다 — 새 브라우저가 다른 서비스를 쓰게 돼 막힌 건지 알아보려고.
        if (parsed.host) console.warn('[web-push] 허용 목록에 없는 푸시 서비스라 구독을 받지 않았습니다:', parsed.host);
        return res.status(400).json({ error: parsed.error });
      }
      stored = JSON.stringify(parsed.subscription);
    }
    if (!isDeviceId(req.params.deviceId)) return res.status(404).json({ error: DEVICE_NOT_FOUND });
    const device = await setDeviceWebPushSubscription(req.params.deviceId, req.user.sub, stored);
    if (!device) return res.status(404).json({ error: DEVICE_NOT_FOUND });
    res.json({ ok: true });
  });

  /**
   * 기기 로그아웃("내 기기") — 그 기기에 묶인 토큰은 REST·갱신·소켓에서 바로 막히고(authState.js deviceActive), 붙어 있던 소켓도
   * 끊긴다. 그 기기로는 푸시도 더는 가지 않는다(푸시 대상은 로그인된 기기만). 기기 등록 전 토큰(예전 앱)은 이걸로 못 막으니 화면은
   * "다른 모든 기기에서 로그아웃"도 같이 둔다.
   */
  router.delete('/devices/:deviceId', async (req, res) => {
    const device = isDeviceId(req.params.deviceId) ? await revokeDevice(req.params.deviceId, req.user.sub) : null;
    if (!device) return res.status(404).json({ error: DEVICE_NOT_FOUND });
    invalidateDeviceState(device.id, req.user.sub);
    await disconnectDeviceSockets(io, req.user.sub, device.id);
    res.json({ ok: true });
  });

  return router;
}
