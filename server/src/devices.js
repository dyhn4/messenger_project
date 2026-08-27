import { Router } from 'express';
import { findDevicePublicInfo, listDevicesForUser, revokeDevice, upsertDevice } from './db/queries/devices.js';

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

  router.delete('/devices/:deviceId', async (req, res) => {
    const device = await revokeDevice(req.params.deviceId, req.user.sub);
    if (!device) return res.status(404).json({ error: '기기를 찾을 수 없습니다.' });
    res.json({ ok: true });
  });

  return router;
}
