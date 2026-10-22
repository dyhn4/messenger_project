CREATE TABLE "call_whiteboards" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"room_id" text NOT NULL,
	"title" text NOT NULL,
	"data" jsonb NOT NULL,
	"page_count" integer DEFAULT 1 NOT NULL,
	"created_by" uuid,
	"created_by_name" text NOT NULL,
	"updated_by_name" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "call_recordings" ADD COLUMN "file_size" bigint;--> statement-breakpoint
ALTER TABLE "call_recordings" ADD COLUMN "purged_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "call_recordings" ADD COLUMN "purge_reason" text;--> statement-breakpoint
ALTER TABLE "call_recordings" ADD COLUMN "speaker_tracks" jsonb DEFAULT '[]'::jsonb NOT NULL;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "call_recording_retention_days" integer;--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "call_recording_max_gb" integer;--> statement-breakpoint
ALTER TABLE "call_whiteboards" ADD CONSTRAINT "call_whiteboards_room_id_rooms_id_fk" FOREIGN KEY ("room_id") REFERENCES "public"."rooms"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "call_whiteboards" ADD CONSTRAINT "call_whiteboards_created_by_users_id_fk" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "call_whiteboards_room_idx" ON "call_whiteboards" USING btree ("room_id","updated_at" DESC NULLS LAST);