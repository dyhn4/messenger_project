ALTER TABLE "messages" ADD COLUMN "quoted_sender_name" text;--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "quoted_preview" text;--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "forwarded_from_sender_name" text;--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "forwarded_from_created_at" timestamp with time zone;