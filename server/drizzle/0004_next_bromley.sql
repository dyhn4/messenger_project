ALTER TABLE "message_comments" ADD COLUMN "edited_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "message_comments" ADD COLUMN "deleted_at" timestamp with time zone;