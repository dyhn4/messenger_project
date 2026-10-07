// 메시지 첨부 저장의 두 가지 규칙 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
//   - 빈 파일 경로('')의 첨부는 "첨부 없음"으로 뺀다(sendMessage.js isSentAttachment) — 남겨 두면 저장할 경로가 없어
//     message_attachments.file_url(비울 수 없다)에서 DB 오류가 났다.
//   - 메시지와 첨부 목록은 한 트랜잭션으로 넣는다(db/queries/messages.js insertMessageWithAttachments) — 첨부에서 실패해도 방에 알리지
//     않은 반쪽짜리 메시지가 남지 않는다.
// 쿼리는 drizzle의 실제 쿼리 빌더에 가짜 pg 클라이언트를 붙여 본다(접속 주소도 닿지 않는 값 — fileRefCheck.test.js와 같은 방식).
import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import { drizzle } from 'drizzle-orm/node-postgres';

process.env.DATABASE_URL = 'postgres://test:test@127.0.0.1:1/unused';
const { db } = await import('../src/db/client.js');
for (const method of ['select', 'insert', 'update', 'delete', 'execute', 'transaction']) {
  mock.method(db, method, () => {
    throw new Error(`이 테스트는 DB를 쓰면 안 된다(db.${method})`);
  });
}
const { isSentAttachment } = await import('../src/sendMessage.js');
const { insertMessageWithAttachments } = await import('../src/db/queries/messages.js');

test('isSentAttachment: 파일 경로(빈 값이 아닌 문자열)가 있는 첨부만 저장한다', () => {
  assert.equal(isSentAttachment({ kind: 'image', fileUrl: '/uploads/a.png' }), true);
  assert.equal(isSentAttachment({ fileUrl: '/files/token' }), true);
  for (const a of [{ fileUrl: '' }, { fileUrl: null }, { fileUrl: 3 }, {}, null, undefined, '/uploads/a.png']) {
    assert.equal(isSentAttachment(a), false, JSON.stringify(a));
  }
  // 앱이 보낸 목록에서 빈 경로 첨부만 빠진다(예전처럼 — 나머지는 그대로 보낸다).
  const sent = [{ fileUrl: '/uploads/a.png' }, { fileUrl: '' }, { fileUrl: '/uploads/b.png' }].filter(isSentAttachment);
  assert.deepEqual(
    sent.map((a) => a.fileUrl),
    ['/uploads/a.png', '/uploads/b.png'],
  );
});

/**
 * 이 테스트 동안 db.transaction을 가짜 pg 클라이언트에 붙인 drizzle로 돌린다. 받은 문장을 [seen]에 남기고, insert … returning에는
 * 돌려 달라는 칸 수만큼(값은 null — id·position만 채운다) 행을 돌려준다. [failOn]이 표 이름이면 그 표에 넣을 때 실패한다.
 */
function fakeTransaction(t, { failOn = null } = {}) {
  const seen = [];
  const fake = drizzle({
    client: {
      async query(config, values = []) {
        const text = typeof config === 'string' ? config : config.text;
        const table = /^insert into "(\w+)"/.exec(text)?.[1] ?? null;
        seen.push(table ? `insert ${table}` : text.trim());
        if (!table) return { rows: [] };
        if (table === failOn) throw new Error('null value in column "file_url" violates not-null constraint');
        const returning = /returning (.*)$/.exec(text)?.[1].split(', ').map((c) => c.replaceAll('"', '')) ?? [];
        const tuples = (text.match(/\), \(/g)?.length ?? 0) + 1;
        const rows = Array.from({ length: tuples }, (_, i) =>
          returning.map((column) => (column === 'id' ? `${table}-${i}` : column === 'position' ? tuples - 1 - i : null)),
        );
        return { rows, values };
      },
    },
  });
  t.mock.method(db, 'transaction', (...args) => fake.transaction(...args));
  return seen;
}

const fields = { id: 'm1', roomId: 'r1', senderId: null, senderName: '김철수', type: 'image', text: null };
const items = [
  { kind: 'image', fileUrl: '/uploads/a.png', fileName: 'a.png', fileSize: 1, mimeType: 'image/png', thumbnailUrl: null },
  { kind: 'image', fileUrl: '/uploads/b.png', fileName: 'b.png', fileSize: 2, mimeType: 'image/png', thumbnailUrl: null },
];

test('insertMessageWithAttachments: 메시지와 첨부를 한 트랜잭션으로 넣고, 첨부는 position 순으로 돌려준다', async (t) => {
  const seen = fakeTransaction(t);
  const created = await insertMessageWithAttachments(fields, items);
  assert.deepEqual(seen, ['begin', 'insert messages', 'insert message_attachments', 'commit']);
  assert.equal(created.attachments.length, 2);
  assert.deepEqual(
    created.attachments.map((a) => a.position),
    [0, 1],
  );
});

test('insertMessageWithAttachments: 첨부를 넣다 실패하면 메시지도 되돌린다(반쪽짜리 메시지가 남지 않는다)', async (t) => {
  const seen = fakeTransaction(t, { failOn: 'message_attachments' });
  // drizzle은 드라이버 오류를 "Failed query: …"로 감싸고 원래 오류를 cause에 둔다.
  await assert.rejects(insertMessageWithAttachments(fields, items), (err) => /not-null/.test(err.cause?.message ?? err.message));
  assert.deepEqual(seen, ['begin', 'insert messages', 'insert message_attachments', 'rollback']);
});
