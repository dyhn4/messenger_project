// web/sw.js의 앱 파일 보관 — 서비스 워커 전역(self·caches·fetch)을 흉내 내 vm에서 돌린다. 브라우저 없이:
//   node --test test/web/sw_test.mjs   (client 폴더에서)
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

const SOURCE = fs.readFileSync(new URL('../../web/sw.js', import.meta.url), 'utf8');
const SCOPE = 'https://chat.example.com/';

/** 서버 답 — 실제 Response는 clone()하면 type이 'default'가 되어 'basic'을 흉내 낼 수 없어 간단한 모양으로. */
function reply(body, status = 200) {
  return { body, status, ok: status >= 200 && status < 300, type: 'basic', clone: () => reply(body, status) };
}

function load({ server }) {
  const listeners = {};
  const stores = new Map([['tangotalk-app-v0', new Map()], ['other-cache', new Map()]]);
  const keyOf = (req) => (typeof req === 'string' ? req : req.url);
  const caches = {
    async open(name) {
      if (!stores.has(name)) stores.set(name, new Map());
      const store = stores.get(name);
      return {
        put: async (req, res) => void store.set(keyOf(req), res),
        match: async (req) => store.get(keyOf(req)),
      };
    },
    async match(req) {
      for (const store of stores.values()) {
        const hit = store.get(keyOf(req));
        if (hit) return hit;
      }
      return undefined;
    },
    keys: async () => [...stores.keys()],
    delete: async (name) => stores.delete(name),
  };
  const fetched = [];
  const self = {
    registration: { scope: SCOPE },
    clients: { claim: async () => {}, matchAll: async () => [] },
    addEventListener: (type, fn) => (listeners[type] = fn),
    skipWaiting: () => {},
  };
  const context = vm.createContext({
    self,
    caches,
    URL,
    console,
    fetch: async (req) => {
      const url = keyOf(req);
      fetched.push(url);
      return server(url);
    },
    // 서버를 오래 기다리는 시간(4초)을 시험에서는 짧게.
    setTimeout: (fn) => setTimeout(fn, 20),
    clearTimeout,
  });
  vm.runInContext(SOURCE, context);

  /** fetch 이벤트를 보내 respondWith로 준 답(맡지 않으면 null). */
  async function request(url, mode = 'no-cors') {
    let responded = null;
    listeners.fetch({ request: { url, method: 'GET', mode }, respondWith: (p) => (responded = p) });
    return responded === null ? null : await responded;
  }
  async function dispatch(type, data) {
    let wait;
    listeners[type]({ data, waitUntil: (p) => (wait = p) });
    await wait;
  }
  const app = () => stores.get('tangotalk-app-v1') ?? new Map();
  return { request, dispatch, stores, app, fetched };
}

test('앱 파일만 맡는다 — API·업로드·다른 서버 페이지·다른 서버는 그대로', async () => {
  const sw = load({ server: (url) => reply(url) });
  for (const url of [
    `${SCOPE}api/rooms`,
    `${SCOPE}uploads/a.png`,
    `${SCOPE}socket.io/?EIO=4`,
    `${SCOPE}version`,
    'https://fonts.gstatic.com/x.woff2',
  ]) {
    assert.equal(await sw.request(url), null, url);
  }
  // 첫 페이지가 아닌 서버 페이지로의 이동.
  assert.equal(await sw.request(`${SCOPE}guide`, 'navigate'), null);
  assert.equal(await sw.request(`${SCOPE}pair/abc`, 'navigate'), null);
  for (const path of [
    'main.dart.js',
    'main.dart.js_1.part.js',
    'flutter_bootstrap.js',
    'assets/fonts/NanumBarunGothic-YetHangul.ttf',
    'canvaskit/chromium/canvaskit.wasm',
    'icons/Icon-192.png',
    'version.json',
  ]) {
    assert.ok(await sw.request(`${SCOPE}${path}`), path);
  }
  assert.ok(await sw.request(SCOPE, 'navigate'));
});

test('서버 것을 먼저 받아 보관하고, 서버가 꺼지면 보관한 것으로 연다', async () => {
  let up = true;
  const sw = load({
    server: (url) => {
      if (!up) throw new TypeError('Failed to fetch');
      return reply(`new:${url}`);
    },
  });
  assert.equal((await sw.request(`${SCOPE}main.dart.js?v=1`)).body, `new:${SCOPE}main.dart.js?v=1`);
  assert.equal((await sw.request(`${SCOPE}?notification=r1`, 'navigate')).body, `new:${SCOPE}?notification=r1`);
  await new Promise((r) => setTimeout(r, 0));
  // 물음표 뒤를 뗀 주소로, 첫 페이지는 범위 주소 하나로.
  assert.deepEqual([...sw.app().keys()].sort(), [SCOPE, `${SCOPE}main.dart.js`].sort());

  up = false;
  assert.equal((await sw.request(`${SCOPE}main.dart.js`)).body, `new:${SCOPE}main.dart.js?v=1`);
  assert.equal((await sw.request(`${SCOPE}index.html`, 'navigate')).body, `new:${SCOPE}?notification=r1`);
  // 보관한 것이 없으면 실패 그대로.
  await assert.rejects(sw.request(`${SCOPE}assets/FontManifest.json`));
});

test('프록시가 5xx로 답하거나 서버가 답이 없으면 보관한 것으로', async () => {
  let mode = 'up';
  const sw = load({
    server: (url) => {
      if (mode === 'proxy-down') return reply('Bad Gateway', 502);
      if (mode === 'hang') return new Promise(() => {});
      return reply(`ok:${url}`);
    },
  });
  await sw.request(`${SCOPE}flutter.js`);
  await new Promise((r) => setTimeout(r, 0));
  mode = 'proxy-down';
  assert.equal((await sw.request(`${SCOPE}flutter.js`)).body, `ok:${SCOPE}flutter.js`);
  mode = 'hang';
  assert.equal((await sw.request(`${SCOPE}flutter.js`)).body, `ok:${SCOPE}flutter.js`);
  // 5xx는 보관하지 않는다.
  assert.equal(sw.app().get(`${SCOPE}flutter.js`).status, 200);
});

test('페이지가 넘긴 파일 목록 — 앱 파일만, 이미 있는 것은 다시 받지 않는다', async () => {
  const sw = load({ server: (url) => reply(`ok:${url}`) });
  await sw.request(`${SCOPE}main.dart.js`);
  await new Promise((r) => setTimeout(r, 0));
  sw.fetched.length = 0;
  await sw.dispatch('message', {
    type: 'keep-app-files',
    urls: [
      `${SCOPE}?notification=x`,
      `${SCOPE}main.dart.js`,
      `${SCOPE}canvaskit/chromium/canvaskit.js`,
      `${SCOPE}canvaskit/chromium/canvaskit.wasm`,
      `${SCOPE}api/me`,
      'https://fonts.gstatic.com/x.woff2',
      'not a url::',
    ],
  });
  assert.deepEqual(sw.fetched, [SCOPE, `${SCOPE}canvaskit/chromium/canvaskit.js`, `${SCOPE}canvaskit/chromium/canvaskit.wasm`]);
  assert.equal(sw.app().size, 4);
});

test('활성화 — 예전 판의 앱 파일 보관함만 치운다', async () => {
  const sw = load({ server: (url) => reply(url) });
  await sw.dispatch('activate');
  assert.deepEqual([...sw.stores.keys()], ['other-cache']);
});
