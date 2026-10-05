import { Router } from 'express';
import {
  findDevicePublicInfo,
  listDevicesForUser,
  revokeDevice,
  setDeviceFcmToken,
  setDeviceWebPushSubscription,
  upsertDevice,
} from './db/queries/devices.js';

function toDeviceDto(d) {
  return {
    id: d.id,
    name: d.name,
    identityPublicKey: d.identityPublicKey,
    signingPublicKey: d.signingPublicKey,
    createdAt: new Date(d.createdAt).getTime(),
    lastSeenAt: d.lastSeenAt ? new Date(d.lastSeenAt).getTime() : null,
    revoked: !!d.revokedAt,
  };
}

/** 비밀 대화(E2EE)용 기기 신원 등록/조회/폐기. 개인키는 절대 여기 안 온다 — 공개키만 다룬다. */
export function createDevicesRouter() {
  const router = Router();

  router.post('/devices', async (req, res) => {
    const { deviceId, name, identityPublicKey, signingPublicKey } = req.body ?? {};
    if (!deviceId || !identityPublicKey || !signingPublicKey) {
      return res.status(400).json({ error: 'deviceId, identityPublicKey, signingPublicKey가 필요합니다.' });
    }
    const device = await upsertDevice({
      id: deviceId,
      userId: req.user.sub,
      name: typeof name === 'string' ? name : null,
      identityPublicKey,
      signingPublicKey,
    });
    res.status(201).json(toDeviceDto(device));
  });

  router.get('/devices', async (req, res) => {
    res.json((await listDevicesForUser(req.user.sub)).map(toDeviceDto));
  });

  // 비밀 대화 핸드셰이크에서 상대 기기의 서명 검증키를 확인하는 용도(신원 서명 검증 —
  // MITM 방지). 공개키류만 내려주고 개인키는 절대 여기 없다.
  router.get('/devices/:deviceId/public-key', async (req, res) => {
    const device = await findDevicePublicInfo(req.params.deviceId);
    if (!device || device.revokedAt) return res.status(404).json({ error: '기기를 찾을 수 없습니다.' });
    res.json({
      userId: device.userId,
      identityPublicKey: device.identityPublicKey,
      signingPublicKey: device.signingPublicKey,
    });
  });

  // 앱이 완전히 꺼져도 알림을 받을 수 있게(FCM). null을 보내면(로그아웃 등) 토큰을 지워서
  // 더 이상 이 기기로 푸시를 보내지 않는다. 안드로이드 전용 — Windows 클라이언트는 호출 안 함.
  router.patch('/devices/:deviceId/fcm-token', async (req, res) => {
    const token = req.body?.token;
    if (token !== null && typeof token !== 'string') {
      return res.status(400).json({ error: 'token은 문자열 또는 null이어야 합니다.' });
    }
    const device = await setDeviceFcmToken(req.params.deviceId, req.user.sub, token);
    if (!device) return res.status(404).json({ error: '기기를 찾을 수 없습니다.' });
    res.json({ ok: true });
  });

  // 웹 앱의 웹 푸시 구독(fcm-token의 웹판, webPush.js). null을 보내면(로그아웃 등) 지운다.
  router.patch('/devices/:deviceId/web-push', async (req, res) => {
    const sub = req.body?.subscription;
    let stored = null;
    if (sub !== null) {
      const { endpoint, keys } = sub ?? {};
      if (
        typeof endpoint !== 'string' ||
        !endpoint.startsWith('https://') ||
        typeof keys?.p256dh !== 'string' ||
        typeof keys?.auth !== 'string'
      ) {
        return res.status(400).json({ error: 'subscription은 endpoint와 keys(p256dh, auth)가 있는 객체 또는 null이어야 합니다.' });
      }
      stored = JSON.stringify({ endpoint, keys: { p256dh: keys.p256dh, auth: keys.auth } });
    }
    const device = await setDeviceWebPushSubscription(req.params.deviceId, req.user.sub, stored);
    if (!device) return res.status(404).json({ error: '기기를 찾을 수 없습니다.' });
    res.json({ ok: true });
  });

  router.delete('/devices/:deviceId', async (req, res) => {
    const device = await revokeDevice(req.params.deviceId, req.user.sub);
    if (!device) return res.status(404).json({ error: '기기를 찾을 수 없습니다.' });
    res.json({ ok: true });
  });

  return router;
}
