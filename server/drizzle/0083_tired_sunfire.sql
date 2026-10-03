CREATE TABLE "album_items" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"album_id" uuid NOT NULL,
	"uploader_id" uuid,
	"kind" text NOT NULL,
	"file_url" text NOT NULL,
	"file_name" text,
	"file_size" integer,
	"mime_type" text,
	"thumbnail_url" text,
	"width" integer,
	"height" integer,
	"duration_ms" integer,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "albums" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"team_id" uuid NOT NULL,
	"room_id" text NOT NULL,
	"creator_id" uuid,
	"title" text NOT NULL,
	"description" text,
	"cover_item_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "bookmarks" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"team_id" uuid NOT NULL,
	"kind" text NOT NULL,
	"owner_id" uuid,
	"creator_id" uuid,
	"title" text NOT NULL,
	"url" text NOT NULL,
	"image_url" text,
	"position" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "todo_assignees" (
	"todo_id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "todo_assignees_todo_id_user_id_pk" PRIMARY KEY("todo_id","user_id")
);
--> statement-breakpoint
CREATE TABLE "todo_attachments" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"todo_id" uuid NOT NULL,
	"kind" text NOT NULL,
	"file_url" text NOT NULL,
	"file_name" text,
	"file_size" integer,
	"mime_type" text,
	"thumbnail_url" text,
	"position" integer DEFAULT 0 NOT NULL
);
--> statement-breakpoint
CREATE TABLE "todo_reminders" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"todo_id" uuid NOT NULL,
	"remind_at" timestamp with time zone NOT NULL,
	"sent_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "todos" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"team_id" uuid NOT NULL,
	"room_id" text NOT NULL,
	"creator_id" uuid,
	"title" text NOT NULL,
	"description" text,
	"start_date" date,
	"due_date" date,
	"progress" integer DEFAULT 0 NOT NULL,
	"completed_at" timestamp with time zone,
	"source_message_id" uuid,
	"source_comment_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "message_attachments" ADD COLUMN "deleted_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "message_attachments" ADD COLUMN "deleted_by" uuid;--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "file_deleted_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "album_items" ADD CONSTRAINT "album_items_album_id_albums_id_fk" FOREIGN KEY ("album_id") REFERENCES "public"."albums"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "album_items" ADD CONSTRAINT "album_items_uploader_id_users_id_fk" FOREIGN KEY ("uploader_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "albums" ADD CONSTRAINT "albums_team_id_teams_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "albums" ADD CONSTRAINT "albums_room_id_rooms_id_fk" FOREIGN KEY ("room_id") REFERENCES "public"."rooms"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "albums" ADD CONSTRAINT "albums_creator_id_users_id_fk" FOREIGN KEY ("creator_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "bookmarks" ADD CONSTRAINT "bookmarks_team_id_teams_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "bookmarks" ADD CONSTRAINT "bookmarks_owner_id_users_id_fk" FOREIGN KEY ("owner_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "bookmarks" ADD CONSTRAINT "bookmarks_creator_id_users_id_fk" FOREIGN KEY ("creator_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "todo_assignees" ADD CONSTRAINT "todo_assignees_todo_id_todos_id_fk" FOREIGN KEY ("todo_id") REFERENCES "public"."todos"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "todo_assignees" ADD CONSTRAINT "todo_assignees_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "todo_attachments" ADD CONSTRAINT "todo_attachments_todo_id_todos_id_fk" FOREIGN KEY ("todo_id") REFERENCES "public"."todos"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "todo_reminders" ADD CONSTRAINT "todo_reminders_todo_id_todos_id_fk" FOREIGN KEY ("todo_id") REFERENCES "public"."todos"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "todos" ADD CONSTRAINT "todos_team_id_teams_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "todos" ADD CONSTRAINT "todos_room_id_rooms_id_fk" FOREIGN KEY ("room_id") REFERENCES "public"."rooms"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "todos" ADD CONSTRAINT "todos_creator_id_users_id_fk" FOREIGN KEY ("creator_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "todos" ADD CONSTRAINT "todos_source_message_id_messages_id_fk" FOREIGN KEY ("source_message_id") REFERENCES "public"."messages"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "todos" ADD CONSTRAINT "todos_source_comment_id_message_comments_id_fk" FOREIGN KEY ("source_comment_id") REFERENCES "public"."message_comments"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "album_items_album_created_idx" ON "album_items" USING btree ("album_id","created_at");--> statement-breakpoint
CREATE INDEX "albums_room_created_idx" ON "albums" USING btree ("room_id","created_at" DESC NULLS LAST);--> statement-breakpoint
CREATE INDEX "albums_team_id_idx" ON "albums" USING btree ("team_id");--> statement-breakpoint
CREATE INDEX "bookmarks_team_kind_position_idx" ON "bookmarks" USING btree ("team_id","kind","position");--> statement-breakpoint
CREATE INDEX "bookmarks_owner_id_idx" ON "bookmarks" USING btree ("owner_id");--> statement-breakpoint
CREATE INDEX "todo_assignees_user_id_idx" ON "todo_assignees" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "todo_attachments_todo_id_idx" ON "todo_attachments" USING btree ("todo_id","position");--> statement-breakpoint
CREATE INDEX "todo_reminders_due_idx" ON "todo_reminders" USING btree ("remind_at","sent_at");--> statement-breakpoint
CREATE INDEX "todo_reminders_todo_id_idx" ON "todo_reminders" USING btree ("todo_id");--> statement-breakpoint
CREATE INDEX "todos_team_created_idx" ON "todos" USING btree ("team_id","created_at");--> statement-breakpoint
CREATE INDEX "todos_room_id_idx" ON "todos" USING btree ("room_id");--> statement-breakpoint
CREATE INDEX "todos_creator_id_idx" ON "todos" USING btree ("creator_id");--> statement-breakpoint
ALTER TABLE "message_attachments" ADD CONSTRAINT "message_attachments_deleted_by_users_id_fk" FOREIGN KEY ("deleted_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "message_comments_sender_created_idx" ON "message_comments" USING btree ("sender_id","created_at" DESC NULLS LAST);--> statement-breakpoint
CREATE INDEX "messages_sender_created_idx" ON "messages" USING btree ("sender_id","created_at" DESC NULLS LAST);--> statement-breakpoint
CREATE INDEX "poll_votes_user_poll_idx" ON "poll_votes" USING btree ("user_id","poll_id");--> statement-breakpoint
CREATE INDEX "polls_room_created_idx" ON "polls" USING btree ("room_id","created_at" DESC NULLS LAST);--> statement-breakpoint
CREATE INDEX "polls_creator_created_idx" ON "polls" USING btree ("creator_id","created_at" DESC NULLS LAST);