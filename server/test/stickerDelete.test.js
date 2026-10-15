// 이모티콘·캐릭터 개별 삭제(stickerRules.js · stickers.js) — `node --test test/*.test.js`(DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import { STICKER_DELETE_MAX, parseStickerIds, stickerVisibility } from '../src/stickerRules.js';

const A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const B = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB';

test('개별 삭제 요청: uuid 목록만 받고 중복은 뺀다', () => {
  assert.deepEqual(parseStickerIds({ ids: [A, B, A] }), { ids: [A, B.toLowerCase()] });
  assert.ok(parseStickerIds({}).error, 'ids 없음');
  assert.ok(parseStickerIds({ ids: [] }).error, '빈 목록');
  assert.ok(parseStickerIds({ ids: 'x' }).error, '목록이 아님');
  assert.ok(parseStickerIds({ ids: [A, 'not-a-uuid'] }).error, 'uuid가 아님');
  assert.ok(parseStickerIds({ ids: [A, 3] }).error, '글자가 아님');
  assert.ok(parseStickerIds({ ids: Array(STICKER_DELETE_MAX + 1).fill(A) }).error, '너무 많음');
});

test('지운 그림은 숨긴 것으로도 내려가서 예전 앱의 선택창에서도 빠진다', () => {
  assert.deepEqual(stickerVisibility({ hidden: false, deletedAt: null }), { hidden: false, deleted: false });
  assert.deepEqual(stickerVisibility({ hidden: true, deletedAt: null }), { hidden: true, deleted: false });
  assert.deepEqual(stickerVisibility({ hidden: false, deletedAt: new Date() }), { hidden: true, deleted: true });
});

test('삭제는 행과 파일을 남기고 표시만 한다 — 라우트·쿼리·마이그레이션·캐릭터 고르기', () => {
  const route = fs.readFileSync(new URL('../src/stickers.js', import.meta.url), 'utf8');
  assert.match(route, /router\.post\('\/stickers\/packs\/:packId\/stickers\/delete', requireServerAdmin/);
  const query = fs.readFileSync(new URL('../src/db/queries/stickers.js', import.meta.url), 'utf8');
  assert.match(query, /export async function deleteStickers\(packId, ids\)/);
  assert.match(query, /\.set\(\{ deletedAt: new Date\(\) \}\)/);
  assert.doesNotMatch(query, /db\s*\.delete\(stickers\)/, '행을 지우지 않는다');
  const migration = fs.readFileSync(new URL('../drizzle/0108_sticker_deleted.sql', import.meta.url), 'utf8');
  assert.match(migration, /ALTER TABLE "stickers" ADD COLUMN "deleted_at"/);
  // 지운 캐릭터는 새로 프로필 사진으로 고를 수 없다.
  const users = fs.readFileSync(new URL('../src/users.js', import.meta.url), 'utf8');
  assert.match(users, /found\.hidden \|\|\s*found\.deletedAt/);
});
