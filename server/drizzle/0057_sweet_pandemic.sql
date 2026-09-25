ALTER TABLE "message_comments" ADD COLUMN "text_format" jsonb;--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "text_format" jsonb;--> statement-breakpoint
ALTER TABLE "task_comments" ADD COLUMN "text_format" jsonb;