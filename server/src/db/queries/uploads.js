import { and, eq, gte, inArray, isNull, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { ACTIVE_PROJECT_MEMBER } from './projects.js';
import {
  albumItems,
  albums,
  announcements,
  bookmarks,
  dmHistoryFloors,
  favoriteFiles,
  inquiries,
  messageAttachments,
  messageComments,
  messages,
  noteVersions,
  projectMembers,
  projectNotes,
  roomMembers,
  rooms,
  scheduledMessages,
  stickers,
  teams,
  todoAttachments,
  uploads,
  users,
} from '../schema.js';

/** 올린 파일 하나를 기록한다 — POST /api/upload(upload.js)가 저장 이름과 올린 사람을 남긴다. */
export async function insertUpload({ fileName, uploaderId }) {
  await db.insert(uploads).values({ fileName, uploaderId });
}

/** 저장 이름(<uuid>.<확장자>) 하나의 기록 — 없으면 null(이 표가 생기기 전에 올린 파일, 이모티콘 그림 등). */
export function findUpload(fileName) {
  return db
    .select()
    .from(uploads)
    .where(eq(uploads.fileName, fileName))
    .then((rows) => rows[0] ?? null);
}

/** 저장 이름들 → 올린 사람 id(그 계정이 지워졌으면 null)의 Map. 기록이 없는 이름은 Map에 없다. */
export async function findUploaders(fileNames) {
  const names = [...new Set(fileNames)];
  if (names.length === 0) return new Map();
  const rows = await db
    .select({ fileName: uploads.fileName, uploaderId: uploads.uploaderId })
    .from(uploads)
    .where(inArray(uploads.fileName, names));
  return new Map(rows.map((r) => [r.fileName, r.uploaderId]));
}

/**
 * 저장 경로([paths] — 미서명 /uploads/<이름>) 가운데 [userId]가 지금 들어가 있는 방(비밀 대화 제외)에서 볼 수 있는 것들(Set) —
 * 지워지지 않은 메시지의 파일·미리보기 칸, 지워지지 않은 첨부 목록, 지워지지 않은 댓글 첨부, 앨범 항목(앨범이 있는 방). 메시지
 * 전달처럼 남이 올린 파일을 다시 실을 때 "그 파일을 지금도 볼 수 있는 사람인가"를 본다(fileRefs.js) — /files/resign(fileResign.js)이
 * 새 링크를 줄 때와 같은 범위다. 방에서 나갔거나 파일·메시지가 지워졌으면 빠진다.
 *
 * 1:1 "진짜 나가기"(dm_history_floors) 이전 글의 파일도 빠진다 — 방 메시지 목록·메시지 한 건 조회·즐겨찾기·앨범 목록이 그 글을 이
 * 사람에게 더는 보여 주지 않으므로, 예전에 받아 둔 링크로 다른 방에 다시 실어(서명만 맞으면 만료된 링크도 받는다) 영영 받아 갈 수
 * 있으면 안 된다. 기준 시각은 그 글이 화면에 보이는지를 정하는 시각과 같다: 메시지·첨부는 메시지, 댓글은 부모 메시지(GET
 * /comments/:id와 같다), 앨범 항목은 앨범을 만든 시각(앨범 목록과 같다). LEFT JOIN이라 하한이 없는 방은 그대로 통과한다.
 *
 * 표마다 경로를 가진 행의 방을 모은 뒤(경로 칸에 인덱스가 없어 표를 훑는다 — 남의 파일을 다시 싣는 드문 경우에만 부른다),
 * 그 방들 가운데 이 사람이 멤버인 방을 한 번에 본다.
 */
export async function findReachableUploadPaths(userId, paths) {
  const candidates = [...new Set(paths)];
  if (candidates.length === 0 || !userId) return new Set();
  const matches = (fileUrl, thumbnailUrl) => or(inArray(fileUrl, candidates), inArray(thumbnailUrl, candidates));
  const myFloor = (roomIdColumn) => and(eq(dmHistoryFloors.roomId, roomIdColumn), eq(dmHistoryFloors.userId, userId));
  const notBeforeMyFloor = (createdAtColumn) =>
    or(isNull(dmHistoryFloors.hiddenBeforeAt), gte(createdAtColumn, dmHistoryFloors.hiddenBeforeAt));
  const [messageRows, attachmentRows, commentRows, albumRows] = await Promise.all([
    db
      .select({ roomId: messages.roomId, fileUrl: messages.fileUrl, thumbnailUrl: messages.thumbnailUrl })
      .from(messages)
      .leftJoin(dmHistoryFloors, myFloor(messages.roomId))
      .where(
        and(
          matches(messages.fileUrl, messages.thumbnailUrl),
          isNull(messages.deletedAt),
          isNull(messages.fileDeletedAt),
          notBeforeMyFloor(messages.createdAt),
        ),
      ),
    db
      .select({
        roomId: messages.roomId,
        fileUrl: messageAttachments.fileUrl,
        thumbnailUrl: messageAttachments.thumbnailUrl,
      })
      .from(messageAttachments)
      .innerJoin(messages, eq(messages.id, messageAttachments.messageId))
      .leftJoin(dmHistoryFloors, myFloor(messages.roomId))
      .where(
        and(
          matches(messageAttachments.fileUrl, messageAttachments.thumbnailUrl),
          isNull(messageAttachments.deletedAt),
          isNull(messages.deletedAt),
          notBeforeMyFloor(messages.createdAt),
        ),
      ),
    db
      .select({
        roomId: messageComments.roomId,
        fileUrl: messageComments.fileUrl,
        thumbnailUrl: messageComments.thumbnailUrl,
      })
      .from(messageComments)
      .innerJoin(messages, eq(messages.id, messageComments.messageId))
      .leftJoin(dmHistoryFloors, myFloor(messageComments.roomId))
      .where(
        and(
          matches(messageComments.fileUrl, messageComments.thumbnailUrl),
          isNull(messageComments.deletedAt),
          notBeforeMyFloor(messages.createdAt),
        ),
      ),
    db
      .select({ roomId: albums.roomId, fileUrl: albumItems.fileUrl, thumbnailUrl: albumItems.thumbnailUrl })
      .from(albumItems)
      .innerJoin(albums, eq(albums.id, albumItems.albumId))
      .leftJoin(dmHistoryFloors, myFloor(albums.roomId))
      .where(and(matches(albumItems.fileUrl, albumItems.thumbnailUrl), notBeforeMyFloor(albums.createdAt))),
  ]);

  // 경로 → 그 경로가 실린 방들.
  const wanted = new Set(candidates);
  const roomsByPath = new Map();
  for (const row of [...messageRows, ...attachmentRows, ...commentRows, ...albumRows]) {
    for (const path of [row.fileUrl, row.thumbnailUrl]) {
      if (!wanted.has(path)) continue;
      if (!roomsByPath.has(path)) roomsByPath.set(path, new Set());
      roomsByPath.get(path).add(row.roomId);
    }
  }
  const roomIds = [...new Set([...roomsByPath.values()].flatMap((s) => [...s]))];
  if (roomIds.length === 0) return new Set();
  // 비밀 대화의 파일은 빼고 본다 — 그 방의 키로만 풀리는 암호문이라 다른 방에서는 쓸모가 없고, 다른 곳에 실리면 자동 삭제가 그
  // 파일을 지우지 못한다(secretExpiry.js — 아직 쓰는 곳이 있는 파일은 남긴다).
  const memberRows = await db
    .select({ roomId: roomMembers.roomId })
    .from(roomMembers)
    .innerJoin(rooms, eq(rooms.id, roomMembers.roomId))
    .where(and(eq(roomMembers.userId, userId), inArray(roomMembers.roomId, roomIds), eq(rooms.isSecret, false)));
  const memberOf = new Set(memberRows.map((r) => r.roomId));
  return new Set([...roomsByPath].filter(([, roomSet]) => [...roomSet].some((id) => memberOf.has(id))).map(([path]) => path));
}

// 프로젝트 노트 본문(과 수정 이력)의 그림·파일 링크 — 내려줄 때 다운로드 링크로 바꾸는 모양(`](/uploads/…)` — fileRefRules.js
// NOTE_SIGN_PATTERN, projects.js signNoteBody) 그대로 찾는다. JS 쪽은 닫히지 않은 주소 칸을 한 덩어리로 건너뛰는 갈래를 더 두지만
// (V8 정규식은 시작점마다 되짚어 읽어 시간이 본문 길이의 제곱으로 는다) 찾는 링크는 같다 — PostgreSQL 정규식은 이 모양을 되짚지 않고
// 한 번에 훑는다. 앞의 표식은 그런 링크가 아예 없는 노트를 정규식 없이 먼저 거르는 데 쓴다.
const NOTE_LINK_MARK = '](/uploads/';
const NOTE_LINK_PATTERN = String.raw`\]\((/uploads/[^)\s]+)\)`;

/**
 * 저장 경로([paths] — 미서명 /uploads/<이름>) 가운데 [userId]가 지금 구성원인 프로젝트의 노트 본문이나 그 노트의 수정 이력에 들어 있는
 * 것들(Set). 노트를 복제하거나 다른 노트(이력)의 그림을 옮겨 붙이면 앱은 받아 둔 서명 링크를 그대로 보내므로, 그 그림을 쓴 사람이
 * 지금도 볼 수 있는지를 본다(fileRefs.js filterNoteFileLinks — 방에서 볼 수 있는 파일은 findReachableUploadPaths가 따로 본다).
 * 구성원은 노트를 여는 라우트와 같은 기준이다(유효한 구성원 행 — ACTIVE_PROJECT_MEMBER: 팀에 아직 있고 정회원 이상이며 정지·탈퇴하지
 * 않은 사람) — 프로젝트에서 빠졌거나 자격을 잃었으면 그 프로젝트의 노트는 세지 않는다. 노트 본문을 통째로 훑으므로(경로에 인덱스가
 * 없다) 쓴 사람이 직접 올리지 않은 그림을 서명 링크로 실었을 때만 부른다.
 */
export async function findNoteReachableUploadPaths(userId, paths) {
  const candidates = [...new Set(paths)];
  if (candidates.length === 0 || !userId) return new Set();
  const wanted = sql`${sql.param(candidates)}::text[]`;
  const memberOfProject = (projectIdColumn) => sql`exists (
    select 1 from ${projectMembers}
    where ${projectMembers.projectId} = ${projectIdColumn} and ${projectMembers.userId} = ${userId}
      and ${ACTIVE_PROJECT_MEMBER})`;
  const result = await db.execute(sql`
    select m.link[1] as p
    from ${projectNotes}, regexp_matches(${projectNotes.body}, ${NOTE_LINK_PATTERN}, 'g') as m(link)
    where strpos(${projectNotes.body}, ${NOTE_LINK_MARK}) > 0 and m.link[1] = any(${wanted})
      and ${memberOfProject(projectNotes.projectId)}
    union
    select m.link[1] as p
    from ${noteVersions}
      join ${projectNotes} on ${projectNotes.id} = ${noteVersions.noteId},
      regexp_matches(${noteVersions.body}, ${NOTE_LINK_PATTERN}, 'g') as m(link)
    where strpos(${noteVersions.body}, ${NOTE_LINK_MARK}) > 0 and m.link[1] = any(${wanted})
      and ${memberOfProject(projectNotes.projectId)}`);
  return new Set(result.rows.map((r) => r.p));
}

/**
 * 저장 경로([paths] — 미서명 /uploads/<이름>) 가운데 아직 어딘가에서 쓰는 것들(Set). 비밀 대화 자동 삭제(secretExpiry.js)가 파일을
 * 실제로 지우기 직전에 본다 — 같은 파일이 전달된 메시지·공지·앨범·할 일·프로필 사진 같은 다른 곳에도 걸려 있으면 지우면 안 된다.
 * [excludeMessageIds]는 곧 지울 메시지들이다 — 그 행과, 메시지와 함께 지워지는(FK cascade) 첨부·댓글·파일 즐겨찾기 행은 세지 않는다.
 *
 * 경로를 담을 수 있는 칸은 전부 본다(schema.js에 그런 칸을 새로 만들면 여기에도 넣을 것):
 *   - 칸 값이 경로 그대로: 메시지 파일·미리보기·링크 미리보기 그림, 첨부 목록, 댓글 첨부, 파일 즐겨찾기, 공지 사진, 문의 첨부,
 *     프로필 사진, 팀·그룹 아이콘, 이모티콘 그림, 할 일 첨부, 북마크 이미지, 앨범 항목
 *   - 값 안에 경로가 들어 있음: 예약 메시지 첨부(JSON 목록), 프로젝트 노트 본문과 그 수정 이력(글 속 링크)
 * 저장 값은 업로드 응답·서명 링크 되돌리기(resolveRawUrl 등)가 만든 이 모양 그대로라 같은 문자열로 비교한다.
 *
 * 경로 칸에는 인덱스가 없어 표를 통째로 훑는다 — 후보 전체를 배열 하나로 넘겨(후보가 많아도 매개변수가 늘지 않는다) 표마다 한 번만
 * 훑게 하고, 질의도 하나로 묶는다. 그래도 가벼운 일은 아니라서 지울 후보가 있을 때만 부른다.
 */
export async function findReferencedUploadPaths(paths, { excludeMessageIds = [] } = {}) {
  const candidates = [...new Set(paths)];
  if (candidates.length === 0) return new Set();
  const wanted = sql`${sql.param(candidates)}::text[]`;
  const expiring = sql`${sql.param(excludeMessageIds)}::uuid[]`;
  const notExpiring = (column) => sql`${column} <> all(${expiring})`;

  // 칸 값이 경로 그대로인 표 — 걸린 행의 칸 값 가운데 후보인 것만 돌려준다(한 행의 원본·미리보기가 둘 다 후보일 수 있다).
  const inColumns = (table, columns, extraWhere = null) => sql`
    select p from (
      select unnest(array[${sql.join(columns, sql`, `)}]) as p from ${table}
      where (${sql.join(
        columns.map((c) => sql`${c} = any(${wanted})`),
        sql` or `,
      )})${extraWhere ? sql` and ${extraWhere}` : sql.empty()}
    ) as hits where p = any(${wanted})`;

  // 예약 메시지 첨부 — [{ fileUrl, thumbnailUrl, ... }] 목록(JSON)에 그 경로를 가진 항목이 있는지. 보내면 지워지는 행이라 적다.
  const inScheduledAttachments = sql`
    select c.p from unnest(${wanted}) as c(p)
    where exists (
      select 1 from ${scheduledMessages}
      where ${scheduledMessages.attachments} @> jsonb_build_array(jsonb_build_object('fileUrl', c.p))
         or ${scheduledMessages.attachments} @> jsonb_build_array(jsonb_build_object('thumbnailUrl', c.p))
    )`;

  // 노트 본문 속 링크 — 본문마다 링크를 한 번씩 뽑아 후보와 맞춘다(후보가 몇 개든 한 번만 훑는다).
  const inNoteLinks = (table, body) => sql`
    select m.link[1] as p from ${table}, regexp_matches(${body}, ${NOTE_LINK_PATTERN}, 'g') as m(link)
    where strpos(${body}, ${NOTE_LINK_MARK}) > 0 and m.link[1] = any(${wanted})`;

  const result = await db.execute(
    sql.join(
      [
        inColumns(
          messages,
          [messages.fileUrl, messages.thumbnailUrl, messages.linkPreviewImageUrl],
          notExpiring(messages.id),
        ),
        inColumns(
          messageAttachments,
          [messageAttachments.fileUrl, messageAttachments.thumbnailUrl],
          notExpiring(messageAttachments.messageId),
        ),
        inColumns(
          messageComments,
          [messageComments.fileUrl, messageComments.thumbnailUrl],
          notExpiring(messageComments.messageId),
        ),
        inColumns(favoriteFiles, [favoriteFiles.fileUrl], notExpiring(favoriteFiles.messageId)),
        inColumns(announcements, [announcements.imageUrl, announcements.imageThumbnailUrl]),
        inColumns(inquiries, [inquiries.fileUrl, inquiries.thumbnailUrl]),
        inColumns(users, [users.avatarUrl]),
        inColumns(teams, [teams.iconUrl]),
        inColumns(rooms, [rooms.iconUrl]),
        inColumns(stickers, [stickers.fileUrl, stickers.thumbnailUrl]),
        inColumns(todoAttachments, [todoAttachments.fileUrl, todoAttachments.thumbnailUrl]),
        inColumns(bookmarks, [bookmarks.imageUrl]),
        inColumns(albumItems, [albumItems.fileUrl, albumItems.thumbnailUrl]),
        inScheduledAttachments,
        inNoteLinks(projectNotes, projectNotes.body),
        inNoteLinks(noteVersions, noteVersions.body),
      ],
      sql` union `,
    ),
  );
  return new Set(result.rows.map((r) => r.p));
}
