ALTER TABLE "messages" ADD COLUMN "album_id" uuid;--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "album_share" jsonb;--> statement-breakpoint
ALTER TABLE "messages" ADD CONSTRAINT "messages_album_id_albums_id_fk" FOREIGN KEY ("album_id") REFERENCES "public"."albums"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "messages_album_id_idx" ON "messages" USING btree ("album_id");