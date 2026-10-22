CREATE TABLE "message_removals" (
	"message_id" uuid PRIMARY KEY NOT NULL,
	"room_id" text NOT NULL,
	"removed_at" timestamp (3) with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "changed_at" timestamp (3) with time zone;--> statement-breakpoint
CREATE INDEX "message_removals_removed_at_idx" ON "message_removals" USING btree ("removed_at","message_id");--> statement-breakpoint
CREATE INDEX "messages_changed_at_idx" ON "messages" USING btree ("changed_at","id") WHERE changed_at is not null;--> statement-breakpoint
-- 메시지가 보낸 뒤에 바뀐 시각(changed_at)을 트리거로 찍는다 — 코드에서 messages를 고치는 경로가 여럿이라(수정·삭제·고정·
-- 첨부 지우기·링크 미리보기·통화 카드·탈퇴한 사람 이름 등) 하나라도 빠지면 앱의 "이후 바뀐 것" 동기화(messageChanges.js)가
-- 그 변화를 놓친다. 같은 값으로만 고친 UPDATE는 찍지 않는다.
CREATE OR REPLACE FUNCTION messages_touch_changed_at() RETURNS trigger AS $$
BEGIN
  NEW.changed_at := now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
--> statement-breakpoint
CREATE TRIGGER messages_touch_changed_at BEFORE UPDATE ON "messages"
  FOR EACH ROW WHEN (OLD.* IS DISTINCT FROM NEW.*) EXECUTE FUNCTION messages_touch_changed_at();
--> statement-breakpoint
-- 메시지에 딸린 행(공감·댓글·첨부·투표)이 바뀌면 그 메시지도 바뀐 것으로 — 메시지를 만드는 같은 트랜잭션 안의 것(첨부·투표를
-- 함께 넣을 때)은 새 메시지라 찍지 않는다(created_at = now()).
CREATE OR REPLACE FUNCTION message_child_touch() RETURNS trigger AS $$
DECLARE
  target uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN target := OLD.message_id; ELSE target := NEW.message_id; END IF;
  UPDATE messages SET changed_at = now() WHERE id = target AND created_at < now();
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;
--> statement-breakpoint
CREATE TRIGGER message_reactions_touch AFTER INSERT OR UPDATE OR DELETE ON "message_reactions"
  FOR EACH ROW EXECUTE FUNCTION message_child_touch();
--> statement-breakpoint
CREATE TRIGGER message_comments_touch AFTER INSERT OR UPDATE OR DELETE ON "message_comments"
  FOR EACH ROW EXECUTE FUNCTION message_child_touch();
--> statement-breakpoint
CREATE TRIGGER message_attachments_touch AFTER INSERT OR UPDATE OR DELETE ON "message_attachments"
  FOR EACH ROW EXECUTE FUNCTION message_child_touch();
--> statement-breakpoint
CREATE TRIGGER polls_touch AFTER UPDATE ON "polls"
  FOR EACH ROW EXECUTE FUNCTION message_child_touch();
--> statement-breakpoint
-- 투표의 보기·표는 poll_id로만 이어져 있어 투표 행을 거쳐 그 메시지를 찾는다.
CREATE OR REPLACE FUNCTION poll_child_touch() RETURNS trigger AS $$
DECLARE
  target uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN target := OLD.poll_id; ELSE target := NEW.poll_id; END IF;
  UPDATE messages SET changed_at = now()
    WHERE id = (SELECT message_id FROM polls WHERE id = target) AND created_at < now();
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;
--> statement-breakpoint
CREATE TRIGGER poll_votes_touch AFTER INSERT OR UPDATE OR DELETE ON "poll_votes"
  FOR EACH ROW EXECUTE FUNCTION poll_child_touch();
--> statement-breakpoint
CREATE TRIGGER poll_options_touch AFTER INSERT OR UPDATE OR DELETE ON "poll_options"
  FOR EACH ROW EXECUTE FUNCTION poll_child_touch();
--> statement-breakpoint
-- 완전히 지운 메시지의 흔적(message_removals) — 비밀 대화와 방째 지운 것(방 행이 먼저 없어져 EXISTS가 거짓)은 남기지 않는다.
CREATE OR REPLACE FUNCTION messages_record_removal() RETURNS trigger AS $$
BEGIN
  INSERT INTO message_removals (message_id, room_id)
    SELECT OLD.id, OLD.room_id
    WHERE EXISTS (SELECT 1 FROM rooms WHERE id = OLD.room_id AND NOT is_secret)
    ON CONFLICT (message_id) DO NOTHING;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;
--> statement-breakpoint
CREATE TRIGGER messages_record_removal AFTER DELETE ON "messages"
  FOR EACH ROW EXECUTE FUNCTION messages_record_removal();
