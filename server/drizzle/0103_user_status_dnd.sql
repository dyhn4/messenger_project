ALTER TABLE "users" ADD COLUMN "status_emoji" text;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "status_text" text;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "status_until" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "dnd_until" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "dnd_schedule" jsonb;