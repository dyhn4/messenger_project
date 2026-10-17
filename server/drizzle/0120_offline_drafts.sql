CREATE TABLE "chat_drafts" (
	"user_id" uuid NOT NULL,
	"room_id" text NOT NULL,
	"text" text NOT NULL,
	"text_format" jsonb,
	"mentions" jsonb,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "chat_drafts_user_id_room_id_pk" PRIMARY KEY("user_id","room_id")
);
--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "client_id" text;--> statement-breakpoint
ALTER TABLE "chat_drafts" ADD CONSTRAINT "chat_drafts_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "chat_drafts" ADD CONSTRAINT "chat_drafts_room_id_rooms_id_fk" FOREIGN KEY ("room_id") REFERENCES "public"."rooms"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "messages_sender_client_id_idx" ON "messages" USING btree ("sender_id","client_id") WHERE client_id is not null;