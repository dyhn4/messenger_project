// 지금 소켓으로 연결되어 있는 사용자(온라인) 추적. 같은 사람이 여러 기기(PC+폰)로 동시에
// 붙어있을 수 있어서 단순 Set이 아니라 연결 개수를 센다 — 기기 하나만 닫아도 다른 기기가
// 아직 붙어있으면 여전히 온라인으로 남아야 한다.
const connectionCounts = new Map(); // userId -> 활성 소켓 개수
// 푸시를 기기마다 따로 정하려고 기기별로도 센다(같은 기기가 소켓을 잠깐 둘 가질 수 있다 — 재연결 겹침). 소켓 인증에서
// 확인된 기기(socket.data.deviceId)만 센다 — 기기를 모르는 연결은 사람 단위(connectionCounts)에만 들어간다.
const deviceConnectionCounts = new Map(); // deviceId -> 활성 소켓 개수
// "다른 기기 접속 중에도 푸시"(notification_settings.pushWhileOnline) — 접속해 있는 동안만 의미가 있어서(접속해 있지
// 않으면 어차피 보낸다) 접속할 때 읽어 두고, 마지막 연결이 끊기면 지운다. 접속 중에 바꾸면 setPushWhileOnline.
const pushWhileOnlineByUser = new Map(); // userId -> boolean
// 아이폰 앱이 뒤로 간 기기(소켓은 아직 붙어 있다) — iOS는 뒤로 간 앱을 몇 초 안에 멈춰서 소켓으로 받은 알림을 앱이 그리지
// 못하고, 멈춘 앱의 소켓은 서버가 핑 시간 초과로 끊을 때까지(수십 초) 붙어 있는 것처럼 보인다. 그사이 온 알림이 사라지지
// 않게 이 기기는 붙어 있어도 푸시(APNs)로 보낸다(push.js). 앱이 알려 주고(socket.js 'app:background'), 기기의 마지막 소켓이
// 끊기면 지운다.
const backgroundDevices = new Set(); // deviceId

/**
 * 소켓이 연결됐을 때 호출. 반환값이 true면 방금 오프라인→온라인으로 막 바뀐 것(첫 연결). [deviceId]는 인증된 기기(없으면
 * null), [pushWhileOnline]은 그 사람의 설정(접속할 때 DB에서 읽은 값 — 같은 사람의 다른 연결이 읽은 값을 덮어도 같다).
 */
export function markConnected(userId, { deviceId = null, pushWhileOnline } = {}) {
  const next = (connectionCounts.get(userId) ?? 0) + 1;
  connectionCounts.set(userId, next);
  if (deviceId) deviceConnectionCounts.set(deviceId, (deviceConnectionCounts.get(deviceId) ?? 0) + 1);
  if (typeof pushWhileOnline === 'boolean') pushWhileOnlineByUser.set(userId, pushWhileOnline);
  return next === 1;
}

/** 소켓이 끊겼을 때 호출. 반환값이 true면 방금 온라인→오프라인으로 막 바뀐 것(마지막 연결이 끊김). */
export function markDisconnected(userId, deviceId = null) {
  if (deviceId) {
    const deviceNext = Math.max(0, (deviceConnectionCounts.get(deviceId) ?? 0) - 1);
    if (deviceNext === 0) {
      deviceConnectionCounts.delete(deviceId);
      backgroundDevices.delete(deviceId);
    } else {
      deviceConnectionCounts.set(deviceId, deviceNext);
    }
  }
  const current = connectionCounts.get(userId) ?? 0;
  const next = Math.max(0, current - 1);
  if (next === 0) {
    connectionCounts.delete(userId);
    pushWhileOnlineByUser.delete(userId);
  } else {
    connectionCounts.set(userId, next);
  }
  return next === 0;
}

/** 이 기기에 지금 소켓이 붙어 있는지 — 붙어 있으면 소켓으로 알림을 받으니 그 기기로는 푸시를 보내지 않는다(push.js). */
export function isDeviceConnected(deviceId) {
  return deviceConnectionCounts.has(deviceId);
}

/**
 * 아이폰 앱이 뒤로 갔다(true)/돌아왔다(false) — 소켓이 붙어 있는 기기만 받는다(끊긴 기기는 어차피 푸시로 간다). 같은 기기의
 * 소켓이 둘이어도(재연결 겹침) 기기 단위로 하나다 — 앱은 다시 붙을 때마다 지금 상태를 다시 알린다.
 */
export function setDeviceBackground(deviceId, background) {
  if (!deviceId) return;
  if (background && deviceConnectionCounts.has(deviceId)) backgroundDevices.add(deviceId);
  else backgroundDevices.delete(deviceId);
}

/** 이 기기로 푸시를 보낼지 — 소켓이 붙어 있지 않거나, 붙어 있어도 아이폰 앱이 뒤로 가 있으면 보낸다(push.js). */
export function pushesToDevice(deviceId) {
  return !deviceConnectionCounts.has(deviceId) || backgroundDevices.has(deviceId);
}

/**
 * 웹 푸시를 실제로 보낼 구독들 — [subscriptions]는 [{ deviceId, kind, subscription }], [appDeviceIds]는 이 사람의 앱 기기 id들
 * `{ windows, android }`(queries/devices.js listAppDeviceIds). 소켓이 붙어 있는 기기(웹 앱 탭이 열려 있음)는 소켓으로 알림을
 * 받으니 뺀다. 그리고 같은 종류의 앱이 접속해 있으면 그 종류의 브라우저도 뺀다 — PC 앱이 접속해 있으면 PC 브라우저
 * (kind='web-desktop'), 안드로이드 앱이 접속해 있으면 안드로이드 브라우저(kind='web-android'). 앱을 켜 둔 기기에서 웹 앱 탭을
 * 닫으면 브라우저 서비스 워커가 웹 푸시를 받아, 앱 알림과 브라우저 알림이 둘 다 떴다. 아이폰·아이패드 브라우저(web-mobile)와
 * 종류를 모르는 예전 기기(null)는 그대로 보낸다. (다른 PC·다른 안드로이드 기기의 브라우저도 함께 조용해지지만, 그때는 접속해
 * 있는 앱으로 받는다.)
 */
export function webPushTargets(subscriptions, appDeviceIds = {}) {
  const online = (ids) => (ids ?? []).some((id) => isDeviceConnected(id));
  const desktopAppOnline = online(appDeviceIds.windows);
  const androidAppOnline = online(appDeviceIds.android);
  return subscriptions.filter(
    ({ deviceId, kind }) =>
      !isDeviceConnected(deviceId) &&
      !(desktopAppOnline && kind === 'web-desktop') &&
      !(androidAppOnline && kind === 'web-android'),
  );
}

/** 접속 중에 설정을 바꿨을 때(notifications.js PATCH) — 접속해 있지 않으면 다음 접속 때 읽으니 둘 필요가 없다. */
export function setPushWhileOnline(userId, value) {
  if (connectionCounts.has(userId)) pushWhileOnlineByUser.set(userId, !!value);
}

/**
 * 이 사람에게 푸시를 아예 보내지 않을지 — 어느 기기로든 접속해 있고 "다른 기기 접속 중에도 푸시"를 끈 사람만 참(예전처럼
 * 접속 중이면 소켓 알림으로 충분하다고 보는 경우). 켠 사람(기본)은 거짓이라 대상에 남고, push.js가 접속해 있지 않은
 * 기기로만 보낸다([isDeviceConnected]). 설정을 아직 모르면(접속할 때 못 읽었으면) 기본값(켬)으로 본다.
 */
export function skipsPush(userId) {
  return connectionCounts.has(userId) && pushWhileOnlineByUser.get(userId) === false;
}

export function isOnline(userId) {
  return connectionCounts.has(userId);
}

/**
 * [userId]의 접속 상태가 바뀌었음을 그 사람과 팀을 같이 쓰는 사람들(user:<id> 방)에게만 알린다(presence:update). 예전엔
 * io.emit으로 서버에 붙은 모든 소켓에 모든 사람의 접속·해제를 흘려서, 팀이 없는 준회원도 서버 전체 회원의 접속 여부를 볼
 * 수 있었다. 범위는 회원 목록(GET /api/users)과 같다 — [listCoTeamMemberIds]로 db/queries/teams.js의 같은 이름 함수를
 * 받는다(이 파일이 DB를 몰라 테스트가 가짜를 넣는다).
 *
 * 받는 사람을 찾는 조회가 끝난 시점의 **지금** 상태를 보낸다(바뀐 순간의 값이 아니라) — 붙자마자 끊겨 두 조회가 끝나는
 * 순서가 뒤바뀌어도 마지막에 도착하는 알림이 실제 상태와 같다. 부르는 건 지금처럼 진짜 온라인↔오프라인 전환 때뿐이다
 * (markConnected/markDisconnected가 true일 때 — socket.js).
 */
export async function broadcastPresence(io, userId, listCoTeamMemberIds) {
  const ids = await listCoTeamMemberIds(userId);
  // 빈 목록으로 io.to([])를 부르면 socket.io는 "방 조건 없음 = 모두에게"로 보낸다 — 팀이 없으면 알릴 사람도 없다.
  if (ids.length === 0) return;
  io.to(ids.map((id) => `user:${id}`)).emit('presence:update', { userId, online: isOnline(userId) });
}
