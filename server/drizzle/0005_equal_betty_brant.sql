ALTER TABLE "message_comments" ALTER COLUMN "text" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "message_comments" ADD COLUMN "type" text DEFAULT 'text' NOT NULL;--> statement-breakpoint
ALTER TABLE "message_comments" ADD COLUMN "file_url" text;--> statement-breakpoint
ALTER TABLE "message_comments" ADD COLUMN "file_name" text;--> statement-breakpoint
ALTER TABLE "message_comments" ADD COLUMN "file_size" integer;--> statement-breakpoint
ALTER TABLE "message_comments" ADD COLUMN "mime_type" text;