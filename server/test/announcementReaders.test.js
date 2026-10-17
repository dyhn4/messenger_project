// 공지 읽음 확인 규칙(announcementReadRules.js) — `node --test test/*.test.js`(DB 없이 돈다).
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import { splitAnnouncementReaders } from '../src/announcementReadRules.js';

const posted = new Date('2026-10-17T09:00:00Z');
const at = (iso) => new Date(iso);

test('공지가 올라온 뒤 공지를 연 사람만 읽음 — 쓴 사람은 늘 읽음, 읽은 쪽은 먼저 읽은 순·안 읽은 쪽은 이름순', () => {
  const { read, unread } = splitAnnouncementReaders({
    announcement: { authorId: 'a', createdAt: posted },
    members: [
      { userId: 'a', name: '작성자', lastReadAnnouncementAt: null },
      { userId: 'b', name: '나중', lastReadAnnouncementAt: at('2026-10-17T11:00:00Z') },
      { userId: 'c', name: '먼저', lastReadAnnouncementAt: at('2026-10-17T10:00:00Z') },
      { userId: 'd', name: '하늘', lastReadAnnouncementAt: at('2026-10-16T10:00:00Z') },
      { userId: 'e', name: '가람', lastReadAnnouncementAt: null },
    ],
  });
  assert.deepEqual(
    read.map((r) => r.userId),
    ['a', 'c', 'b'],
  );
  assert.equal(read[0].readAt, posted.getTime(), '쓴 사람은 올린 시각에 읽은 것으로');
  assert.deepEqual(
    unread.map((r) => r.name),
    ['가람', '하늘'],
    '공지가 올라오기 전에 연 사람은 안 읽음',
  );
});

test('올라온 바로 그 시각에 연 것도 읽음, 멤버가 없으면 빈 목록', () => {
  const { read } = splitAnnouncementReaders({
    announcement: { authorId: null, createdAt: posted },
    members: [{ userId: 'b', name: 'b', lastReadAnnouncementAt: posted }],
  });
  assert.equal(read.length, 1);
  assert.deepEqual(splitAnnouncementReaders({ announcement: { authorId: 'a', createdAt: posted }, members: [] }), {
    read: [],
    unread: [],
  });
});

test('연결: 읽음 확인 경로는 토픽 멤버만, 탈퇴한 사람은 빼고 센다', () => {
  const src = fs.readFileSync(new URL('../src/announcements.js', import.meta.url), 'utf8');
  assert.match(src, /router\.get\('\/rooms\/:id\/announcements\/:announcementId\/readers'[\s\S]{0,120}requireTopicMember/);
  const rooms = fs.readFileSync(new URL('../src/db/queries/rooms.js', import.meta.url), 'utf8');
  assert.match(rooms, /listMembersAnnouncementRead[\s\S]{0,500}isNull\(users\.deletedAt\)/);
});
