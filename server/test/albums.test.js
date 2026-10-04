// 앨범 순수 규칙 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  ALBUM_ITEMS_PER_REQUEST_MAX,
  ALBUM_SHARE_TEXT_MAX,
  albumKindOfMime,
  albumPerms,
  albumRoomDenial,
  albumShareSnapshot,
  albumShareTargetDenial,
  albumWriteDenial,
  canDeleteAlbum,
  canDeleteAlbumItem,
  canEditAlbum,
  parseAlbumFields,
  parseAlbumItems,
  parseAlbumListQuery,
  parseAlbumShareMessage,
  parseItemIds,
  partitionDeletableItems,
  shareMessageType,
  toSharedAlbumDto,
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

test('앨범 공유 메시지: 필수·5,000자, 앞 공백을 떼면 서식·멘션 구간도 당긴다', () => {
  assert.equal(parseAlbumShareMessage({ text: '  ' }).error, '메시지를 입력하세요.');
  assert.ok(parseAlbumShareMessage({}).error);
  assert.ok(parseAlbumShareMessage({ text: 5 }).error);
  assert.equal(parseAlbumShareMessage({ text: 'a'.repeat(ALBUM_SHARE_TEXT_MAX + 1) }).error, '메시지는 5,000자 이내로 입력하세요.');
  // 이모지 한 덩어리는 1자.
  assert.equal(parseAlbumShareMessage({ text: '👍'.repeat(ALBUM_SHARE_TEXT_MAX) }).error, undefined);

  const parsed = parseAlbumShareMessage({
    text: '  @김철수 사진 보세요  ',
    textFormat: [{ s: 6, e: 8, f: 1 }],
    mentions: [{ type: 'user', userId: 'u2', s: 2, e: 6 }],
  });
  assert.equal(parsed.text, '@김철수 사진 보세요');
  assert.deepEqual(parsed.textFormat, [{ s: 4, e: 6, f: 1 }]);
  assert.deepEqual(parsed.mentions, [{ type: 'user', userId: 'u2', s: 0, e: 4 }]);
  // 구간이 없으면 null(그대로 sendUserMessage가 정리한다).
  assert.equal(parseAlbumShareMessage({ text: 'hi' }).textFormat, null);
});

test('앨범 카드 DTO: 공유 메시지에만, 지운 메시지는 null, 앨범이 지워졌으면 id null', () => {
  const snap = albumShareSnapshot({ title: '제주 여행' }, '잔디팀');
  assert.deepEqual(snap, { title: '제주 여행', teamName: '잔디팀' });
  assert.equal(albumShareSnapshot({ title: 'x' }, '').teamName, null);

  assert.deepEqual(toSharedAlbumDto({ albumId: ID1, albumShare: snap }), { id: ID1, title: '제주 여행', teamName: '잔디팀' });
  assert.deepEqual(toSharedAlbumDto({ albumId: null, albumShare: snap }), { id: null, title: '제주 여행', teamName: '잔디팀' });
  assert.equal(toSharedAlbumDto({ albumId: ID1, albumShare: snap, deletedAt: new Date() }), null);
  assert.equal(toSharedAlbumDto({ albumId: null, albumShare: null }), null);
  assert.equal(toSharedAlbumDto({}), null);
});

test('앨범 권한 묶음: 방 멤버는 규칙대로, 공유로만 보는 사람은 보기 전용', () => {
  assert.deepEqual(albumPerms({ album, userId: 'creator', access: member }), {
    canEdit: true,
    canDelete: true,
    canDeleteAnyItem: true,
    canShare: true,
    viewOnly: false,
  });
  const other = albumPerms({ album, userId: 'x', access: roomAdmin });
  assert.equal(other.canEdit, true); // 방 관리자는 고칠 수 있지만
  assert.equal(other.canDelete, false); // 지우지는 못한다
  assert.equal(other.viewOnly, false);
  // 공유 메시지로만 보는 사람 — 만든 사람이어도(방을 나간 경우) 아무것도 못 고친다.
  assert.deepEqual(albumPerms({ album, userId: 'creator', access: null, viaShare: true }), {
    canEdit: false,
    canDelete: false,
    canDeleteAnyItem: false,
    canShare: false,
    viewOnly: true,
  });
});
