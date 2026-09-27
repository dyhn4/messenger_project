ALTER TABLE "note_comments" ADD COLUMN "text_format" jsonb;--> statement-breakpoint
ALTER TABLE "note_comments" ADD COLUMN "parent_comment_id" uuid;--> statement-breakpoint
ALTER TABLE "note_comments" ADD COLUMN "edited_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "note_comments" ADD CONSTRAINT "note_comments_parent_comment_id_note_comments_id_fk" FOREIGN KEY ("parent_comment_id") REFERENCES "public"."note_comments"("id") ON DELETE cascade ON UPDATE no action;