import { decryptField } from './crypto.js';
import { createDdnsUpdater, parseDuckDnsDomains } from './ddns.js';
import { getServerSettings } from './db/queries/serverSettings.js';

/** DB의 server_settings에 둔 DDNS 설정을 갱신기가 쓸 모양으로 — 토큰은 여기서만 풀어 쓴다. */
async function loadDdnsSettings() {
  const settings = await getServerSettings();
  const { names } = parseDuckDnsDomains(settings.ddnsDomains ?? '');
  let token = null;
  let tokenError = null;
  if (settings.ddnsToken) {
    try {
      token = decryptField(settings.ddnsToken);
    } catch {
      // 암호화 키(server/.db-encryption-key)가 바뀐 채 복원한 경우 등 — 토큰을 다시 넣으면 된다.
      tokenError = '저장된 토큰을 읽지 못했습니다 — 관리자 콘솔에서 토큰을 다시 넣으세요.';
    }
  }
  return { enabled: !!settings.ddnsEnabled, domains: names ?? [], token, tokenError };
}

/** 서버 전체에서 하나 — index.js가 시작하고, 관리자 콘솔(admin.js)이 상태를 보고 다시 돌린다. */
export const ddnsUpdater = createDdnsUpdater({ loadSettings: loadDdnsSettings });
