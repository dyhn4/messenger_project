CREATE TABLE "topic_folder_items" (
	"folder_id" uuid NOT NULL,
	"room_id" text NOT NULL,
	"user_id" uuid NOT NULL
);
--> statement-breakpoint
CREATE TABLE "topic_folders" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"team_id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	"name" text NOT NULL,
	"position" integer DEFAULT 0 NOT NULL,
	"collapsed" boolean DEFAULT false NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "title" text;--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "pinned_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "room_members" ADD COLUMN "role" text DEFAULT 'member' NOT NULL;--> statement-breakpoint
ALTER TABLE "rooms" ADD COLUMN "view_mode" text DEFAULT 'chat' NOT NULL;--> statement-breakpoint
ALTER TABLE "rooms" ADD COLUMN "read_only" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "rooms" ADD COLUMN "auto_invite" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "rooms" ADD COLUMN "quiet_leave" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "rooms" ADD COLUMN "archived_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "topic_folder_items" ADD CONSTRAINT "topic_folder_items_folder_id_topic_folders_id_fk" FOREIGN KEY ("folder_id") REFERENCES "public"."topic_folders"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "topic_folder_items" ADD CONSTRAINT "topic_folder_items_room_id_rooms_id_fk" FOREIGN KEY ("room_id") REFERENCES "public"."rooms"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "topic_folder_items" ADD CONSTRAINT "topic_folder_items_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "topic_folders" ADD CONSTRAINT "topic_folders_team_id_teams_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "topic_folders" ADD CONSTRAINT "topic_folders_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "topic_folder_items_user_room_idx" ON "topic_folder_items" USING btree ("user_id","room_id");--> statement-breakpoint
CREATE INDEX "topic_folder_items_folder_idx" ON "topic_folder_items" USING btree ("folder_id");--> statement-breakpoint
CREATE INDEX "topic_folders_user_team_idx" ON "topic_folders" USING btree ("user_id","team_id");--> statement-breakpoint
-- 지금까지 공개 토픽은 새로 팀에 들어오는 정회원을 전부 자동으로 넣어줬다 — 기존 공개 토픽은 그 동작을
-- 그대로 이어가도록 '정회원 자동 초대'를 켜 둔다(새로 만드는 토픽은 기본 꺼짐, 찾아서 참여하는 방식).
UPDATE "rooms" SET "auto_invite" = true WHERE "type" = 'topic' AND ("is_public" IS NULL OR "is_public" = true);--> statement-breakpoint
-- 토픽을 만든 사람이 아직 멤버면 토픽 관리자로 — 만든 사람이 나간 토픽은 토픽 관리자 없이 남고,
-- 팀 관리자가 관리하면서 새로 지정할 수 있다.
UPDATE "room_members" rm SET "role" = 'admin' FROM "rooms" r WHERE rm."room_id" = r."id" AND r."type" = 'topic' AND r."created_by" = rm."user_id"::text;