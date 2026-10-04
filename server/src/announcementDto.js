// 공지 응답 모양(클라이언트 models/announcement.dart의 Announcement.fromJson과 1:1) — announcements.js가 쓴다.
// DB·서버 없이 단위 테스트할 수 있게(test/announcementDto.test.js) 파일 주소 서명 함수는 인자로 받는다.

/** count(...) 집계는 드라이버에 따라 문자열(bigint)로 올 수 있다 — 항상 0 이상의 정수로. */
export function normalizeCommentCount(raw) {
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : 0;
}

/**
 * announcements 행 → 응답 DTO. [row.commentCount]는 집계해서 붙인 값(없으면 0) — 목록(listAnnouncementsForRoom),
 * 채팅방 상단 공지바(findLatestAnnouncementForRoom → rooms.js latestAnnouncement), 수정(PATCH) 응답 모두
 * 실제 댓글 수를 싣는다(공지바가 댓글 수를 보여준다).
 */
export function toAnnouncementDto(row, signFileUrl) {
  // 출처 칸(sourceMessageId·image*)은 DB 이름 그대로 내보내지 않고 messageId와 서명된 이미지 주소로 바꾼다.
  const { sourceMessageId, imageUrl, imageThumbnailUrl, imageName, ...rest } = row;
  return {
    ...rest,
    // "메시지를 공지로 등록"으로 만든 공지면 원본 메시지 id(원본이 지워졌으면 null) — 말풍선의 공지 표시용.
    messageId: sourceMessageId ?? null,
    // 이미지 메시지에서 온 공지의 사진 한 장(없으면 전부 null). 원본이 지워져도 공지 쪽 스냅샷이 남는다.
    imageUrl: imageUrl ? signFileUrl(imageUrl, imageName) : null,
    imageThumbnailUrl: imageThumbnailUrl ? signFileUrl(imageThumbnailUrl) : null,
    imageName: imageName ?? null,
    commentCount: normalizeCommentCount(row.commentCount),
    createdAt: new Date(row.createdAt).getTime(),
    editedAt: row.editedAt ? new Date(row.editedAt).getTime() : null,
    autoUnpinAt: row.autoUnpinAt ? new Date(row.autoUnpinAt).getTime() : null,
  };
}
