ALTER TABLE "inquiries" ADD COLUMN "file_url" text;--> statement-breakpoint
ALTER TABLE "inquiries" ADD COLUMN "file_name" text;--> statement-breakpoint
ALTER TABLE "inquiries" ADD COLUMN "file_size" integer;--> statement-breakpoint
ALTER TABLE "inquiries" ADD COLUMN "mime_type" text;--> statement-breakpoint
ALTER TABLE "inquiries" ADD COLUMN "thumbnail_url" text;