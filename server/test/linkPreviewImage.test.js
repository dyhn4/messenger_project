// 링크 미리보기 그림을 서버가 받아 두는 규칙 단위 테스트(linkPreviewImage.js) — `node --test test/*.test.js` (DB·서버·네트워크 없이
// 돈다). 받기·저장은 가짜를 넣고, 다시 만들기(sharp)는 테스트 안에서 만든 그림으로 실제로 돌린다.
import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import sharp from 'sharp';
import {
  acceptablePreviewResponse,
  isPreviewImageType,
  isRemoteImageUrl,
  PREVIEW_IMAGE_MAX_SIDE,
  previewWebpOf,
  sniffImageType,
  storePreviewImage,
} from '../src/linkPreviewImage.js';
import { parseOgTags } from '../src/linkPreview.js';
import { resolveRawUrl, signedUploadOrNull } from '../src/upload.js';

process.env.DATABASE_URL = 'postgres://test:test@127.0.0.1:1/unused';
const { db } = await import('../src/db/client.js');
for (const method of ['select', 'insert', 'update', 'delete', 'execute', 'transaction']) {
  mock.method(db, method, () => {
    throw new Error(`이 테스트는 DB를 쓰면 안 된다(db.${method})`);
  });
}
const { toMessageDto } = await import('../src/messages.js');

const png = await sharp({ create: { width: 1600, height: 900, channels: 3, background: { r: 200, g: 60, b: 40 } } })
  .png()
  .toBuffer();
const svg = Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>');
const html = Buffer.from('<!doctype html><html><body>not an image</body></html>');

/** safeFetch가 돌려주는 모양의 응답. */
const response = (body, type, status = 200) => ({ status, headers: { 'content-type': type }, body, url: 'https://cdn.example/x' });

/** 받기·저장을 가짜로 — 부른 기록을 남긴다. */
function fakeDeps(res) {
  const calls = { fetch: [], store: [] };
  return {
    calls,
    async fetch(url, options) {
      calls.fetch.push({ url, options });
      if (res instanceof Error) throw res;
      return res;
    },
    async store(bytes, ownerId) {
      calls.store.push({ bytes, ownerId });
      return '/uploads/11111111-1111-4111-8111-111111111111.webp';
    },
    async cached() {
      return null;
    },
  };
}

test('받는 형식: 그림만(SVG·HTML 제외), 내용도 그림이어야 한다', () => {
  for (const type of ['image/png', 'image/jpeg', 'IMAGE/WEBP; charset=binary', 'image/gif', 'image/avif']) {
    assert.equal(isPreviewImageType(type), true, type);
  }
  for (const type of ['image/svg+xml', 'text/html', 'application/octet-stream', '', undefined]) {
    assert.equal(isPreviewImageType(type), false, String(type));
  }
  assert.equal(sniffImageType(png), 'png');
  assert.equal(sniffImageType(Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0, 0, 0, 0, 0])), 'jpeg');
  assert.equal(sniffImageType(Buffer.from('GIF89a......')), 'gif');
  assert.equal(sniffImageType(Buffer.from('RIFF\0\0\0\0WEBPVP8 ')), 'webp');
  assert.equal(sniffImageType(svg), null);
  assert.equal(sniffImageType(html), null);
  assert.equal(sniffImageType(Buffer.alloc(4)), null);
  // Content-Type이 그림이라고 해도 내용이 그림이 아니면(HTML을 그림이라고 속인 응답) 받지 않는다.
  assert.equal(acceptablePreviewResponse(response(html, 'image/png')), false);
  assert.equal(acceptablePreviewResponse(response(png, 'text/html')), false);
  assert.equal(acceptablePreviewResponse(response(png, 'image/png', 404)), false);
  assert.equal(acceptablePreviewResponse(response(png, 'image/png')), true);
  assert.equal(acceptablePreviewResponse(null), false);
});

test('받아 볼 주소는 http(s)만', () => {
  assert.equal(isRemoteImageUrl('https://cdn.example/a.png'), true);
  for (const bad of ['/uploads/a.png', 'file:///etc/passwd', 'data:image/png;base64,AAAA', `https://x/${'a'.repeat(2000)}`, null]) {
    assert.equal(isRemoteImageUrl(bad), false, String(bad).slice(0, 40));
  }
});

test('다시 만들기: 작은 WEBP로(한 변 800px 이하) — 그림이 아니면 실패', async () => {
  const webp = await previewWebpOf(png);
  assert.equal(sniffImageType(webp), 'webp');
  const meta = await sharp(webp).metadata();
  assert.ok(Math.max(meta.width, meta.height) <= PREVIEW_IMAGE_MAX_SIDE);
  await assert.rejects(previewWebpOf(html));
});

test('storePreviewImage: 그림이면 다시 만들어 저장 경로를, 아니면 null — 받은 바이트를 그대로 저장하지 않는다', async () => {
  const ok = fakeDeps(response(png, 'image/png'));
  const stored = await storePreviewImage('https://cdn.example/og.png', { ownerId: null }, ok);
  assert.equal(stored, '/uploads/11111111-1111-4111-8111-111111111111.webp');
  assert.equal(ok.calls.store.length, 1);
  assert.equal(sniffImageType(ok.calls.store[0].bytes), 'webp');
  assert.equal(ok.calls.store[0].ownerId, null);
  // 받을 때는 잘린 응답을 쓰지 않고(truncate: false), 크기 상한을 둔다.
  assert.equal(ok.calls.fetch[0].options.truncate, false);
  assert.ok(ok.calls.fetch[0].options.maxBytes <= 5 * 1024 * 1024);

  for (const res of [response(svg, 'image/svg+xml'), response(html, 'image/png'), new Error('차단된 주소입니다: intranet')]) {
    const deps = fakeDeps(res);
    assert.equal(await storePreviewImage('https://cdn.example/og.png', {}, deps), null);
    assert.equal(deps.calls.store.length, 0);
  }
  // 바깥 주소가 아니면 받지도 않는다.
  const none = fakeDeps(response(png, 'image/png'));
  assert.equal(await storePreviewImage('/uploads/a.png', {}, none), null);
  assert.equal(none.calls.fetch.length, 0);
});

test('storePreviewImage: 북마크처럼 그 사람이 붙일 그림이면 그 사람의 파일로 남긴다', async () => {
  const deps = fakeDeps(response(png, 'image/png'));
  await storePreviewImage('https://cdn.example/og.png', { requesterId: 'u-bookmark', ownerId: 'u-bookmark' }, deps);
  assert.equal(deps.calls.store[0].ownerId, 'u-bookmark');
});

test('storePreviewImage: 한 사람이 서버에게 받게 하는 횟수는 상한이 있다(넘으면 그림 없이)', async () => {
  const tiny = await sharp({ create: { width: 16, height: 16, channels: 3, background: '#336699' } }).png().toBuffer();
  const deps = fakeDeps(response(tiny, 'image/png'));
  const results = [];
  for (let i = 0; i < 61; i++) results.push(await storePreviewImage(`https://cdn.example/${i}.png`, { requesterId: 'u-flood' }, deps));
  assert.equal(results.filter(Boolean).length, 60);
  assert.equal(results.at(-1), null);
});

test('앱에 넘기는 그림은 서버에 둔 파일의 서명 링크뿐 — 예전에 저장된 바깥 주소는 넘기지 않는다', () => {
  const signed = signedUploadOrNull('/uploads/11111111-1111-4111-8111-111111111111.webp');
  assert.match(signed, /^\/files\//);
  assert.equal(resolveRawUrl(signed), '/uploads/11111111-1111-4111-8111-111111111111.webp');
  assert.equal(signedUploadOrNull('https://attacker.example/t/42.png'), null);
  assert.equal(signedUploadOrNull(null), null);

  const base = {
    id: 'm1',
    roomId: 'r1',
    senderId: 'u1',
    senderName: '김철수',
    type: 'text',
    text: 'https://news.example/a',
    createdAt: new Date(),
    linkPreviewUrl: 'https://news.example/a',
    linkPreviewSiteName: 'news.example',
  };
  // 예전 행: 바깥 그림 주소 + 제목 → 카드는 남고 그림만 빠진다.
  const legacy = toMessageDto({ ...base, linkPreviewTitle: '기사 제목', linkPreviewImageUrl: 'https://attacker.example/t/42.png' });
  assert.equal(legacy.linkPreview.title, '기사 제목');
  assert.equal(legacy.linkPreview.imageUrl, null);
  assert.equal(legacy.linkPreview.imageFileUrl, null);
  // 그림만 있던 예전 행은 카드 자체가 없다(빈 카드가 남지 않게).
  assert.equal(toMessageDto({ ...base, linkPreviewImageUrl: 'https://attacker.example/t/42.png' }).linkPreview, null);
  // 새 행: 서버가 받아 둔 파일 → 서명 링크는 새 칸(imageFileUrl)으로만. 예전 칸(imageUrl)은 비워 둔다 — 예전 앱은 imageUrl을
  // 바깥 주소로 알고 받다가 실패해 카드 위에 빈 칸만 남긴다(external_image.dart).
  const fresh = toMessageDto({
    ...base,
    linkPreviewTitle: '기사 제목',
    linkPreviewImageUrl: '/uploads/11111111-1111-4111-8111-111111111111.webp',
  });
  assert.match(fresh.linkPreview.imageFileUrl, /^\/files\//);
  assert.equal(resolveRawUrl(fresh.linkPreview.imageFileUrl), '/uploads/11111111-1111-4111-8111-111111111111.webp');
  assert.equal(fresh.linkPreview.imageUrl, null);
  // 그림만 있는 새 행도 카드는 남는다(새 앱은 그림을 그린다).
  const imageOnly = toMessageDto({ ...base, linkPreviewImageUrl: '/uploads/11111111-1111-4111-8111-111111111111.webp' });
  assert.match(imageOnly.linkPreview.imageFileUrl, /^\/files\//);
  assert.equal(imageOnly.linkPreview.imageUrl, null);
});

test('og:image 후보는 여전히 페이지에서 읽되(서버가 받아 볼 주소), 사설 IP를 직접 적은 주소는 후보에서도 뺀다', () => {
  const page = 'https://example.com/a';
  const og = (src) => parseOgTags(`<meta property="og:title" content="t"><meta property="og:image" content="${src}">`, page);
  assert.equal(og('https://cdn.example.com/x.png').imageUrl, 'https://cdn.example.com/x.png');
  assert.equal(og('http://10.0.0.5/x.png').imageUrl, null);
});
