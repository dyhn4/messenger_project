// 공지 응답 모양 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { normalizeCommentCount, toAnnouncementDto } from '../src/announcementDto.js';

const sign = (url, name) => `/files/signed(${url}${name ? `|${name}` : ''})`;

const row = (extra = {}) => ({
  id: 'a1',
  roomId: 'r1',
  authorId: 'u1',
  authorName: '김철수',
  text: '금요일 회식',
  pinned: true,
  createdAt: new Date('2026-10-01T03:44:00Z'),
  editedAt: null,
  autoUnpinAt: null,
  deletedAt: null,
  sourceMessageId: null,
  imageUrl: null,
  imageThumbnailUrl: null,
  imageName: null,
  ...extra,
});

test('normalizeCommentCount: 문자열 집계·null·음수·NaN도 0 이상의 정수로', () => {
  assert.equal(normalizeCommentCount(3), 3);
  assert.equal(normalizeCommentCount('12'), 12);
  assert.equal(normalizeCommentCount(undefined), 0);
  assert.equal(normalizeCommentCount(null), 0);
  assert.equal(normalizeCommentCount(-1), 0);
  assert.equal(normalizeCommentCount('abc'), 0);
  assert.equal(normalizeCommentCount(2.7), 2);
});

test('toAnnouncementDto: 공지바용 댓글 수를 싣는다 — 집계 값이 없으면 0', () => {
  assert.equal(toAnnouncementDto(row({ commentCount: 4 }), sign).commentCount, 4);
  // pg count(*)는 문자열로 올 수 있다.
  assert.equal(toAnnouncementDto(row({ commentCount: '7' }), sign).commentCount, 7);
  // 예전처럼 집계 없이 만든 행(새 공지 직후 등)은 0.
  assert.equal(toAnnouncementDto(row(), sign).commentCount, 0);
});

test('toAnnouncementDto: 시각은 밀리초 epoch, 출처 칸은 messageId로, 작성자 칸은 그대로', () => {
  const dto = toAnnouncementDto(
    row({ sourceMessageId: 'm1', editedAt: new Date('2026-10-02T00:00:00Z'), commentCount: 1 }),
    sign,
  );
  assert.equal(dto.createdAt, Date.parse('2026-10-01T03:44:00Z'));
  assert.equal(dto.editedAt, Date.parse('2026-10-02T00:00:00Z'));
  assert.equal(dto.autoUnpinAt, null);
  assert.equal(dto.messageId, 'm1');
  assert.equal('sourceMessageId' in dto, false);
  assert.equal(dto.authorId, 'u1');
  assert.equal(dto.authorName, '김철수');
  assert.equal(dto.imageUrl, null);
  assert.equal(dto.imageThumbnailUrl, null);
  assert.equal(dto.imageName, null);
});

test('toAnnouncementDto: 사진 공지는 원본(파일 이름 포함)·축소본을 서명해서 내보낸다', () => {
  const dto = toAnnouncementDto(
    row({ text: '', imageUrl: '/uploads/a.png', imageThumbnailUrl: '/uploads/a_t.png', imageName: 'a.png' }),
    sign,
  );
  assert.equal(dto.imageUrl, '/files/signed(/uploads/a.png|a.png)');
  assert.equal(dto.imageThumbnailUrl, '/files/signed(/uploads/a_t.png)');
  assert.equal(dto.imageName, 'a.png');
});
