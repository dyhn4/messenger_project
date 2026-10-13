// DDNS(DuckDNS) 자동 갱신(ddns.js)과 관리자 콘솔 연결(admin.js) — `node --test test/*.test.js`. 네트워크·DB 없이 돈다
// (DuckDNS 응답은 가짜 fetch로, admin.js는 index.js처럼 import하면 DB에 붙으므로 소스 글만 확인한다).
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import {
  createDdnsUpdater,
  isDuckDnsToken,
  parseDuckDnsDomains,
  parseDuckDnsResponse,
  updateDuckDns,
} from '../src/ddns.js';

const TOKEN = 'a7c4d0ad-114e-40ef-ba1d-d217904a50f2';
const quiet = { log() {}, warn() {}, error() {} };

test('도메인: 이름·전체 주소를 받아 .duckdns.org를 뗀 소문자 이름으로, 겹치면 하나', () => {
  assert.deepEqual(parseDuckDnsDomains('TangoTalk, tangotalk-dev.duckdns.org  https://tangotalk.duckdns.org:3010/x').names, [
    'tangotalk',
    'tangotalk-dev',
  ]);
  assert.deepEqual(parseDuckDnsDomains('').names, []);
  assert.match(parseDuckDnsDomains('bad_name').error, /올바르지 않습니다/);
  assert.match(parseDuckDnsDomains('-a').error, /올바르지 않습니다/);
  assert.match(parseDuckDnsDomains('a b c d e f').error, /5개까지/);
  assert.match(parseDuckDnsDomains(3).error, /글자/);
});

test('토큰: DuckDNS 토큰(UUID) 모양만', () => {
  assert.equal(isDuckDnsToken(TOKEN), true);
  assert.equal(isDuckDnsToken(` ${TOKEN.toUpperCase()} `), true);
  assert.equal(isDuckDnsToken('abc'), false);
  assert.equal(isDuckDnsToken(null), false);
});

test('응답: OK면 IP와 바뀌었는지, KO면 실패', () => {
  assert.deepEqual(parseDuckDnsResponse('OK\n203.0.113.7\n\nUPDATED'), { ok: true, ip: '203.0.113.7', changed: true });
  assert.deepEqual(parseDuckDnsResponse('OK\r\n203.0.113.7\r\n\r\nNOCHANGE'), {
    ok: true,
    ip: '203.0.113.7',
    changed: false,
  });
  assert.deepEqual(parseDuckDnsResponse('KO'), { ok: false });
  assert.deepEqual(parseDuckDnsResponse(''), { ok: false });
});

test('갱신 요청: 도메인을 쉼표로, ip는 비워서(요청이 온 공인 IP), 오류 글에 토큰을 넣지 않는다', async () => {
  let asked;
  const result = await updateDuckDns({
    domains: ['tangotalk', 'tangotalk-dev'],
    token: TOKEN,
    fetchImpl: async (url) => {
      asked = new URL(url);
      return new Response('OK\n203.0.113.7\n\nNOCHANGE');
    },
  });
  assert.equal(asked.origin, 'https://www.duckdns.org');
  assert.equal(asked.pathname, '/update');
  assert.equal(asked.searchParams.get('domains'), 'tangotalk,tangotalk-dev');
  assert.equal(asked.searchParams.get('token'), TOKEN);
  assert.equal(asked.searchParams.get('ip'), '');
  assert.equal(asked.searchParams.get('verbose'), 'true');
  assert.deepEqual(result, { ok: true, ip: '203.0.113.7', changed: false });

  await assert.rejects(
    updateDuckDns({ domains: ['x'], token: TOKEN, fetchImpl: async () => new Response('KO') }),
    /거절/,
  );
  await assert.rejects(
    updateDuckDns({ domains: ['x'], token: TOKEN, fetchImpl: async () => new Response('', { status: 502 }) }),
    /HTTP 502/,
  );
  const failure = await updateDuckDns({
    domains: ['x'],
    token: TOKEN,
    fetchImpl: async (url) => {
      throw new TypeError(`fetch failed ${url}`, { cause: { code: 'ENOTFOUND' } });
    },
  }).catch((e) => e);
  assert.match(failure.message, /연결하지 못했습니다\(ENOTFOUND\)/);
  assert.equal(failure.message.includes(TOKEN), false);
});

/** 가짜 시계·타이머로 갱신기를 만든다. */
function harness(settings, respond = () => new Response('OK\n203.0.113.7\n\nUPDATED')) {
  let t = 1_000_000;
  const timers = [];
  const calls = [];
  const updater = createDdnsUpdater({
    loadSettings: async () => settings(),
    fetchImpl: async (url) => {
      calls.push(new URL(url));
      return respond(calls.length);
    },
    now: () => t,
    intervalMs: 300_000,
    setTimer: (fn, ms) => {
      const timer = { fn, at: t + ms, cleared: false };
      timers.push(timer);
      return timer;
    },
    clearTimer: (timer) => {
      timer.cleared = true;
    },
    log: quiet,
  });
  return {
    updater,
    calls,
    advance: async (ms) => {
      t += ms;
      for (const timer of timers.splice(0)) {
        if (!timer.cleared && timer.at <= t) timer.fn();
        else if (!timer.cleared) timers.push(timer);
      }
      await new Promise((r) => setImmediate(r));
      await new Promise((r) => setImmediate(r));
    },
    pending: () => timers.filter((x) => !x.cleared).length,
  };
}

test('갱신기: 꺼져 있으면 DuckDNS에 묻지도, 다음 갱신을 잡지도 않는다', async () => {
  const h = harness(() => ({ enabled: false, domains: ['tangotalk'], token: TOKEN }));
  await h.updater.start();
  assert.equal(h.calls.length, 0);
  assert.equal(h.pending(), 0);
  const s = h.updater.status();
  assert.equal(s.enabled, false);
  assert.equal(s.ok, null);
  assert.equal(s.nextAttemptAt, null);
});

test('갱신기: 켜면 바로 한 번, 그 뒤 5분마다 — 결과·다음 시각을 보여 준다', async () => {
  const h = harness(() => ({ enabled: true, domains: ['tangotalk'], token: TOKEN }));
  await h.updater.start();
  assert.equal(h.calls.length, 1);
  let s = h.updater.status();
  assert.equal(s.ok, true);
  assert.equal(s.ip, '203.0.113.7');
  assert.equal(s.changed, true);
  assert.equal(s.lastSuccessAt, 1_000_000);
  assert.equal(s.nextAttemptAt, 1_300_000);
  assert.equal(s.intervalMinutes, 5);

  await h.advance(300_000);
  assert.equal(h.calls.length, 2);
  s = h.updater.status();
  assert.equal(s.lastAttemptAt, 1_300_000);
  assert.equal(s.nextAttemptAt, 1_600_000);
  assert.equal(h.pending(), 1);
  h.updater.stop();
  assert.equal(h.pending(), 0);
});

test('갱신기: 실패해도 다음 주기에 다시 하고, 실패 이유를 남긴다', async () => {
  const h = harness(
    () => ({ enabled: true, domains: ['tangotalk'], token: TOKEN }),
    (n) => new Response(n === 1 ? 'KO' : 'OK\n203.0.113.9\n\nUPDATED'),
  );
  await h.updater.start();
  let s = h.updater.status();
  assert.equal(s.ok, false);
  assert.match(s.error, /거절/);
  assert.equal(s.lastSuccessAt, null);
  assert.equal(h.pending(), 1);

  await h.advance(300_000);
  s = h.updater.status();
  assert.equal(s.ok, true);
  assert.equal(s.error, null);
  assert.equal(s.ip, '203.0.113.9');
});

test('갱신기: 토큰을 못 읽거나 도메인이 없으면 묻지 않고 이유만 남긴다', async () => {
  let settings = { enabled: true, domains: ['tangotalk'], token: null, tokenError: '저장된 토큰을 읽지 못했습니다' };
  const h = harness(() => settings);
  await h.updater.start();
  assert.equal(h.calls.length, 0);
  assert.match(h.updater.status().error, /토큰을 읽지 못했습니다/);
  settings = { enabled: true, domains: [], token: TOKEN };
  await h.updater.runNow();
  assert.equal(h.calls.length, 0);
  assert.match(h.updater.status().error, /도메인이 없습니다/);
});

test('갱신기: 지금 갱신을 겹쳐 눌러도 DuckDNS에는 한 번만 묻고, 타이머도 하나만 남는다', async () => {
  const h = harness(() => ({ enabled: true, domains: ['tangotalk'], token: TOKEN }));
  await Promise.all([h.updater.runNow(), h.updater.runNow(), h.updater.runNow()]);
  assert.equal(h.calls.length, 1);
  assert.equal(h.pending(), 1);
  await h.updater.runNow();
  assert.equal(h.calls.length, 2);
  assert.equal(h.pending(), 1);
});

test('갱신기: 끄면 지난 결과를 비우고 다음 갱신도 거둔다', async () => {
  let enabled = true;
  const h = harness(() => ({ enabled, domains: ['tangotalk'], token: TOKEN }));
  await h.updater.start();
  assert.equal(h.updater.status().ok, true);
  enabled = false;
  await h.updater.runNow();
  const s = h.updater.status();
  assert.equal(s.enabled, false);
  assert.equal(s.ok, null);
  assert.equal(s.ip, null);
  assert.equal(s.nextAttemptAt, null);
  assert.equal(h.pending(), 0);
});

// ─────────────────────────────── admin.js · index.js 연결 ───────────────────────────────

const adminSource = fs.readFileSync(new URL('../src/admin.js', import.meta.url), 'utf8');
const indexSource = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');

test('admin.js: DDNS 라우트는 서버 운영자 확인(/admin 미들웨어) 뒤에 있다', () => {
  const guard = adminSource.indexOf("router.use('/admin'");
  assert.ok(guard > 0);
  for (const route of ["router.get('/admin/ddns'", "router.patch('/admin/ddns'", "router.post('/admin/ddns/update'"]) {
    const at = adminSource.indexOf(route);
    assert.ok(at > guard, `${route}가 운영자 확인 뒤에 있어야 한다`);
  }
});

test('admin.js: 토큰은 암호화해 저장하고 응답·감사 로그에 싣지 않는다', () => {
  const view = adminSource.slice(adminSource.indexOf('async function ddnsView'), adminSource.indexOf("router.get('/admin/ddns'"));
  assert.match(view, /tokenConfigured: !!settings\.ddnsToken/);
  assert.equal(/ddnsToken[^C]/.test(view.replace('!!settings.ddnsToken', '')), false);
  const patch = adminSource.slice(adminSource.indexOf("router.patch('/admin/ddns'"), adminSource.indexOf("router.post('/admin/ddns/update'"));
  assert.match(patch, /encryptField\(token\)/);
  const audit = patch.slice(patch.indexOf('const detail'), patch.indexOf('recordAudit'));
  assert.equal(audit.includes('body.token'), false);
  assert.equal(/\$\{[^}]*token/i.test(audit), false);
});

test('admin.js: 서버 설정 변경 응답은 설정 행 전체(비밀값 포함)가 아니라 그 네 값만', () => {
  const route = adminSource.slice(adminSource.indexOf("router.patch('/admin/settings'"), adminSource.indexOf("router.get('/admin/fcm-settings'"));
  assert.equal(route.includes('res.json(updated)'), false);
  assert.match(route, /teamCreation: updated\.teamCreation/);
});

test('index.js: 서버가 뜰 때 DDNS 갱신기를 시작한다', () => {
  assert.match(indexSource, /import \{ ddnsUpdater \} from '\.\/ddnsService\.js'/);
  assert.match(indexSource, /ddnsUpdater\.start\(\)/);
});
