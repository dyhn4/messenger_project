ALTER TABLE "announcements" ADD COLUMN "source_message_id" uuid;--> statement-breakpoint
ALTER TABLE "announcements" ADD COLUMN "image_url" text;--> statement-breakpoint
ALTER TABLE "announcements" ADD COLUMN "image_thumbnail_url" text;--> statement-breakpoint
ALTER TABLE "announcements" ADD COLUMN "image_name" text;--> statement-breakpoint
ALTER TABLE "announcements" ADD CONSTRAINT "announcements_source_message_id_messages_id_fk" FOREIGN KEY ("source_message_id") REFERENCES "public"."messages"("id") ON DELETE set null ON UPDATE no action;