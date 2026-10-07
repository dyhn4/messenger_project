CREATE TABLE "uploads" (
	"file_name" text PRIMARY KEY NOT NULL,
	"uploader_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "invite_links" ADD COLUMN "max_uses" integer;--> statement-breakpoint
ALTER TABLE "uploads" ADD CONSTRAINT "uploads_uploader_id_users_id_fk" FOREIGN KEY ("uploader_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "uploads_uploader_id_idx" ON "uploads" USING btree ("uploader_id");