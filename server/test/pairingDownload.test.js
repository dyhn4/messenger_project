// 평문 페어링 서버의 설치 파일 고르기와 마지막 오류 처리(pairingPaths.js installerFor·pairingErrorHandler) 단위 테스트 —
// `node --test test/*.test.js` (DB·서버 없이 돈다).
//
// 지키려는 것: /invite/<토큰>/download/constructor처럼 객체의 기본 속성 이름을 플랫폼으로 넣어도 처리 중 예외가 나지 않고,
// 어디서 예외가 나든 이 포트(사내망 밖에도 열린다)는 NODE_ENV와 상관없이 스택 추적(서버의 절대 경로) 없는 짧은 JSON만 준다.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { allowedFromOutside, installerFor, pairingErrorHandler, pathForLog } from '../src/pairingPaths.js';

test('installerFor: 정해 둔 플랫폼만 — 객체의 기본 속성 이름은 플랫폼이 아니다', () => {
  assert.deepEqual(installerFor('windows'), { file: 'client-windows-setup.exe', downloadName: 'TangoTalk-Setup.exe' });
  assert.deepEqual(installerFor('android'), { file: 'client-android.apk', downloadName: 'TangoTalk.apk' });
  for (const bad of [
    'constructor',
    'toString',
    'valueOf',
    'hasOwnProperty',
    '__proto__',
    '__defineGetter__',
    'Windows',
    'ios',
    '',
    undefined,
    null,
    ['windows'],
  ]) {
    assert.equal(installerFor(bad), null, String(bad));
  }
});

test('밖에서는 실제 설치 파일이 있는 플랫폼의 다운로드 주소만 열린다', () => {
  assert.equal(allowedFromOutside('/invite/abc123/download/windows'), true);
  assert.equal(allowedFromOutside('/team-invite/t1/download/android'), true);
  for (const p of ['/invite/abc123/download/constructor', '/team-invite/t1/download/tostring', '/invite/abc/download/valueof']) {
    assert.equal(allowedFromOutside(p), false, p);
  }
});

/** 오류 처리에 넘길 가짜 응답 — 보낸 상태·본문을 적어 둔다. */
function fakeRes({ headersSent = false } = {}) {
  const out = { status: null, body: null, headersSent };
  const res = {
    headersSent,
    status(code) {
      out.status = code;
      return res;
    },
    json(body) {
      out.body = body;
      return res;
    },
  };
  return { res, out };
}

/** 오류 처리를 부르고 { out, nextErr, logs } — 그동안 console.error로 나간 것도 모은다. */
function handle(err, { path = '/invite/secret-token/download/windows', headersSent = false } = {}) {
  const { res, out } = fakeRes({ headersSent });
  let nextErr;
  const logs = [];
  const original = console.error;
  console.error = (...args) => logs.push(args);
  try {
    pairingErrorHandler(err, { method: 'GET', path }, res, (e) => (nextErr = e));
  } finally {
    console.error = original;
  }
  return { out, nextErr, logs };
}

test('pairingErrorHandler: 예외는 500 + 짧은 JSON — 스택 추적·오류 문구·서버 경로를 보내지 않는다', () => {
  const err = new TypeError('The "path" argument must be of type string. Received undefined');
  err.stack = 'TypeError: ...\n    at downloadInstaller (C:\\TangoTalk-Server\\server\\src\\pairing.js:405:20)';
  const { out, nextErr, logs } = handle(err);
  assert.equal(out.status, 500);
  assert.deepEqual(out.body, { error: '서버 오류가 발생했습니다.' });
  assert.equal(nextErr, undefined);
  const sent = JSON.stringify(out.body);
  assert.doesNotMatch(sent, /pairing\.js|TangoTalk-Server|TypeError|argument/);
  // 자세한 내용은 서버 콘솔에만 — 초대 토큰은 가린다.
  assert.equal(logs.length, 1);
  assert.match(String(logs[0][0]), /\/invite\/<토큰>\/download\/windows/);
  assert.doesNotMatch(String(logs[0][0]), /secret-token/);
});

test('pairingErrorHandler: Express가 붙인 4xx(깨진 주소 등)는 그 상태로, 문구는 짧게', () => {
  const badUri = Object.assign(new URIError("Failed to decode param '%E0%A4%A'"), { status: 400, statusCode: 400 });
  let r = handle(badUri);
  assert.equal(r.out.status, 400);
  assert.deepEqual(r.out.body, { error: '요청을 처리할 수 없습니다.' });
  assert.equal(r.logs.length, 0);

  r = handle(Object.assign(new Error('ENOENT: no such file or directory, stat C:\\x'), { status: 404 }));
  assert.equal(r.out.status, 404);
  assert.deepEqual(r.out.body, { error: '찾을 수 없습니다.' });

  // 5xx나 이상한 값은 500으로.
  for (const status of [503, 302, '400', undefined]) {
    assert.equal(handle(Object.assign(new Error('x'), { status })).out.status, 500, String(status));
  }
  assert.equal(handle(null).out.status, 500);
});

test('pairingErrorHandler: 이미 보내기 시작한 응답은 건드리지 않고 Express에 넘긴다', () => {
  const err = new Error('socket hang up');
  const { out, nextErr } = handle(err, { headersSent: true });
  assert.equal(nextErr, err);
  assert.equal(out.status, null);
  assert.equal(out.body, null);
});

test('pairingErrorHandler는 Express가 오류 처리로 알아보는 모양(인자 4개)이다', () => {
  assert.equal(pairingErrorHandler.length, 4);
});

test('pathForLog: 초대 토큰만 가린다', () => {
  assert.equal(pathForLog('/invite/abc123'), '/invite/<토큰>');
  assert.equal(pathForLog('/team-invite/t-1/download/android'), '/team-invite/<토큰>/download/android');
  assert.equal(pathForLog('/guide/a.png'), '/guide/a.png');
  assert.equal(pathForLog(undefined), '');
});
