ALTER TABLE "projects" ALTER COLUMN "note_delete_permission" SET DEFAULT 'creator_admin';--> statement-breakpoint
-- 노트 삭제 권한 기본값을 '생성자와 관리자'로 — 이 설정이 생기기 전에는 작성자 본인과 관리자만 노트를
-- 지울 수 있었다. 0067이 기존 프로젝트를 모두 'all'로 채웠으므로(누가 고른 값이 아님) 예전 동작으로 되돌린다.
UPDATE "projects" SET "note_delete_permission" = 'creator_admin' WHERE "note_delete_permission" = 'all';