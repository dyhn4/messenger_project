// 앨범 순수 규칙 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  ALBUM_ITEMS_PER_REQUEST_MAX,
  albumKindOfMime,
  albumRoomDenial,
  albumShareTargetDenial,
  albumWriteDenial,
  canDeleteAlbum,
  canDeleteAlbumItem,
  canEditAlbum,
  parseAlbumFields,
  parseAlbumItems,
  parseAlbumListQuery,
  parseItemIds,
  partitionDeletableItems,
  shareMessageType,
  toShareAttachment,
} from '../src/albumRules.js';

const TEAM = '11111111-1111-4111-8111-111111111111';
const ID1 = '22222222-2222-4222-8222-222222222222';
const ID2 = '33333333-3333-4333-8333-333333333333';
const identity = (u) => u;

const member = { isMember: true, role: 'member', isOwner: false, canManage: false };
const teamAdmin = { isMember: true, role: 'admin', isOwner: false, canManage: false };
const owner = { isMember: true, role: 'member', isOwner: true, canManage: false };
const roomAdmin = { isMember: true, role: 'member', isOwner: false, canManage: true };
const album = { id: 'a', creatorId: 'creator' };

test('parseAlbumFields: 제목 1~50자 필수, 설명 0~300자', () => {
  assert.deepEqual(parseAlbumFields({ title: ' 여행 ', description: ' ' }), { title: '여행', description: null });
  assert.ok(parseAlbumFields({ title: ' ' }).error);
  assert.ok(parseAlbumFields({}).error);
  assert.ok(parseAlbumFields({ title: 'a'.repeat(51) }).error);
  assert.equal(parseAlbumFields({ title: 'a'.repeat(50) }).error, undefined);
  assert.ok(parseAlbumFields({ title: 'x', description: 'd'.repeat(301) }).error);
  assert.ok(parseAlbumFields({ title: 'x', description: 5 }).error);
});

test('parseAlbumFields: 수정(partial)은 준 키만 검사한다', () => {
  assert.deepEqual(parseAlbumFields({ description: '설명' }, { partial: true }), { description: '설명' });
  assert.deepEqual(parseAlbumFields({}, { partial: true }), {});
  assert.ok(parseAlbumFields({ title: '' }, { partial: true }).error);
});

test('albumKindOfMime: 이미지(GIF 포함)·영상만', () => {
  assert.equal(albumKindOfMime('image/png'), 'image');
  assert.equal(albumKindOfMime('image/gif'), 'image');
  assert.equal(albumKindOfMime('VIDEO/mp4'), 'video');
  assert.equal(albumKindOfMime('application/pdf'), null);
  assert.equal(albumKindOfMime(null), null);
});

function item(over = {}) {
  return { fileUrl: '/uploads/a.png', fileName: 'a.png', fileSize: 10, mimeType: 'image/png', ...over };
}

test('parseAlbumItems: 최대 100개, 이미지·영상만, kind는 mimeType으로 정한다', () => {
  const ok = parseAlbumItems({ items: [item({ kind: 'video' }), item({ mimeType: 'video/mp4', durationMs: 3000 })] }, identity);
  assert.equal(ok.items[0].kind, 'image'); // 클라이언트가 보낸 kind는 무시
  assert.equal(ok.items[1].kind, 'video');
  assert.equal(ok.items[1].durationMs, 3000);
  assert.equal(ok.items[0].durationMs, null);

  const hundred = Array.from({ length: ALBUM_ITEMS_PER_REQUEST_MAX }, () => item());
  assert.equal(parseAlbumItems({ items: hundred }, identity).items.length, 100);
  assert.ok(parseAlbumItems({ items: [...hundred, item()] }, identity).error);
  assert.ok(parseAlbumItems({ items: [] }, identity).error);
  assert.ok(parseAlbumItems({}, identity).error);
  assert.ok(parseAlbumItems({ items: [item({ mimeType: 'application/pdf' })] }, identity).error);
  assert.ok(parseAlbumItems({ items: [item({ fileUrl: 'https://evil/x.png' })] }, identity).error);
  assert.ok(parseAlbumItems({ items: [item({ fileUrl: '/uploads/../x.png' })] }, identity).error);
});

test('parseAlbumItems: 서명된 링크는 resolveUrl로 원본 경로를 받아 쓰고, 풀리지 않으면 거절', () => {
  const resolve = (u) => (u === '/files/tok' ? '/uploads/x.gif' : u === '/files/bad' ? null : u);
  const ok = parseAlbumItems({ items: [item({ fileUrl: '/files/tok', mimeType: 'image/gif', thumbnailUrl: '/files/bad' })] }, resolve);
  assert.equal(ok.items[0].fileUrl, '/uploads/x.gif');
  assert.equal(ok.items[0].thumbnailUrl, null);
  assert.ok(parseAlbumItems({ items: [item({ fileUrl: '/files/bad' })] }, resolve).error);
});

test('parseItemIds: UUID 배열, 중복은 합치고 개수 제한', () => {
  assert.deepEqual(parseItemIds([ID1, ID1, ID2], { max: 5 }).ids, [ID1, ID2]);
  assert.ok(parseItemIds([], { max: 5 }).error);
  assert.ok(parseItemIds(['x'], { max: 5 }).error);
  assert.ok(parseItemIds('x', { max: 5 }).error);
  assert.equal(parseItemIds([ID1, ID2], { max: 1, overLimitMessage: '많음' }).error, '많음');
});

test('parseAlbumListQuery: teamId 필수, limit은 1..100으로 눌러 담는다', () => {
  const q = parseAlbumListQuery({ teamId: TEAM, roomId: 'r1', limit: '999', before: '1700000000000' });
  assert.equal(q.roomId, 'r1');
  assert.equal(q.limit, 100);
  assert.ok(q.before instanceof Date);
  assert.ok(parseAlbumListQuery({}).error);
  assert.ok(parseAlbumListQuery({ teamId: TEAM, limit: '0' }).error);
  assert.ok(parseAlbumListQuery({ teamId: TEAM, before: 'abc' }).error);
});

test('권한: 수정은 만든 사람·방 관리자·팀 관리자, 삭제는 만든 사람·팀 관리자', () => {
  const as = (access, userId = 'someone') => ({ album, userId, access });
  assert.equal(canEditAlbum(as(member, 'creator')), true);
  assert.equal(canEditAlbum(as(member)), false);
  assert.equal(canEditAlbum(as(roomAdmin)), true);
  assert.equal(canEditAlbum(as(teamAdmin)), true);
  assert.equal(canEditAlbum(as(owner)), true);
  assert.equal(canEditAlbum(as({ ...teamAdmin, isMember: false })), false); // 팀에서 빠진 관리자
  assert.equal(canDeleteAlbum(as(member, 'creator')), true);
  assert.equal(canDeleteAlbum(as(roomAdmin)), false);
  assert.equal(canDeleteAlbum(as(teamAdmin)), true);
});

test('항목 삭제: 올린 사람·앨범 만든 사람·팀 관리자만, 섞이면 권한 있는 것만 나눈다', () => {
  const items = [
    { id: '1', uploaderId: 'me' },
    { id: '2', uploaderId: 'other' },
    { id: '3', uploaderId: 'creator' },
  ];
  const mine = partitionDeletableItems({ album, items, userId: 'me', access: member });
  assert.deepEqual(mine.allowed.map((i) => i.id), ['1']);
  assert.equal(mine.skipped.length, 2);
  const creator = partitionDeletableItems({ album, items, userId: 'creator', access: member });
  assert.equal(creator.allowed.length, 3);
  const admin = partitionDeletableItems({ album, items, userId: 'admin', access: teamAdmin });
  assert.equal(admin.allowed.length, 3);
  assert.equal(canDeleteAlbumItem({ album, item: items[1], userId: 'x', access: roomAdmin }), false);
});

test('방 규칙: 비밀 대화 제외, 읽기 전용·보관 토픽은 관리자만, 공유 대상은 보드 뷰·비밀 대화 제외', () => {
  assert.ok(albumRoomDenial({ isSecret: true }));
  assert.equal(albumRoomDenial({ type: 'dm', isSelf: true }), null);
  assert.equal(albumRoomDenial({ type: 'topic', viewMode: 'board' }), null);
  assert.ok(albumWriteDenial({ room: { type: 'topic', readOnly: true }, canManage: false }));
  assert.ok(albumWriteDenial({ room: { type: 'topic', archivedAt: new Date() }, canManage: false }));
  assert.equal(albumWriteDenial({ room: { type: 'topic', readOnly: true }, canManage: true }), null);
  assert.equal(albumWriteDenial({ room: { type: 'group' }, canManage: false }), null);
  assert.ok(albumShareTargetDenial({ isSecret: true, type: 'dm' }));
  assert.ok(albumShareTargetDenial({ type: 'topic', viewMode: 'board' }));
  assert.equal(albumShareTargetDenial({ type: 'topic', viewMode: 'chat' }), null);
  assert.equal(albumShareTargetDenial({ type: 'group' }), null);
  assert.equal(albumShareTargetDenial({ type: 'dm' }), null);
});

test('공유 메시지: 이미지만이면 image, 영상이 섞이면 file 첨부', () => {
  const img = { kind: 'image', fileUrl: '/uploads/a.png', fileName: 'a.png', fileSize: 1, mimeType: 'image/png', thumbnailUrl: null };
  const vid = { kind: 'video', fileUrl: '/uploads/b.mp4', fileName: 'b.mp4', fileSize: 2, mimeType: 'video/mp4', thumbnailUrl: null };
  assert.equal(shareMessageType([img, img]), 'image');
  assert.equal(shareMessageType([img, vid]), 'file');
  assert.equal(toShareAttachment(img).kind, 'image');
  assert.equal(toShareAttachment(vid).kind, 'file');
  assert.equal(toShareAttachment(vid).mimeType, 'video/mp4');
});
