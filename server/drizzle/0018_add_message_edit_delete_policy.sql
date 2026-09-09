ALTER TABLE "teams" ADD COLUMN "message_edit_delete_enabled" boolean DEFAULT true NOT NULL;--> statement-breakpoint
ALTER TABLE "teams" ADD COLUMN "message_edit_delete_window_seconds" integer DEFAULT 300 NOT NULL;--> statement-breakpoint
-- [메시지 설정]이 삭제 전용에서 수정/삭제 공용으로 바뀌면서 컬럼 이름도 함께 바꾼다.
-- 이름만 바꾸는 것이므로 기존에 팀이 정해둔 값을 그대로 옮겨온다(옛 컬럼은 0019에서 지운다).
UPDATE "teams" SET
  "message_edit_delete_enabled" = "message_delete_enabled",
  "message_edit_delete_window_seconds" = "message_delete_window_seconds";
