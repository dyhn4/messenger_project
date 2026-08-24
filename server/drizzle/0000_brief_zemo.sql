CREATE TABLE "messages" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"room_id" text NOT NULL,
	"sender_id" uuid,
	"sender_name" text NOT NULL,
	"type" text NOT NULL,
	"text" text,
	"file_url" text,
	"file_name" text,
	"file_size" integer,
	"mime_type" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "room_members" (
	"room_id" text NOT NULL,
	"user_id" uuid NOT NULL,
	"last_read_at" timestamp with time zone,
	CONSTRAINT "room_members_room_id_user_id_pk" PRIMARY KEY("room_id","user_id")
);
--> statement-breakpoint
CREATE TABLE "rooms" (
	"id" text PRIMARY KEY NOT NULL,
	"type" text NOT NULL,
	"name" text,
	"description" text,
	"is_public" boolean,
	"dm_key" text,
	"created_by" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "rooms_dm_key_unique" UNIQUE("dm_key")
);
--> statement-breakpoint
CREATE TABLE "users" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"username" text NOT NULL,
	"name" text NOT NULL,
	"email_enc" text,
	"email_lookup" text,
	"password_hash" text NOT NULL,
	"token_version" integer DEFAULT 0 NOT NULL,
	"avatar_type" text DEFAULT 'initial' NOT NULL,
	"avatar_emoji" text,
	"avatar_color" text,
	"avatar_url" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone,
	"messages_purged_at" timestamp with time zone,
	CONSTRAINT "users_username_unique" UNIQUE("username"),
	CONSTRAINT "users_email_lookup_unique" UNIQUE("email_lookup")
);
--> statement-breakpoint
ALTER TABLE "messages" ADD CONSTRAINT "messages_room_id_rooms_id_fk" FOREIGN KEY ("room_id") REFERENCES "public"."rooms"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "messages" ADD CONSTRAINT "messages_sender_id_users_id_fk" FOREIGN KEY ("sender_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "room_members" ADD CONSTRAINT "room_members_room_id_rooms_id_fk" FOREIGN KEY ("room_id") REFERENCES "public"."rooms"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "room_members" ADD CONSTRAINT "room_members_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "messages_room_id_created_at_idx" ON "messages" USING btree ("room_id","created_at");--> statement-breakpoint
CREATE INDEX "messages_sender_id_idx" ON "messages" USING btree ("sender_id");--> statement-breakpoint
CREATE INDEX "room_members_user_id_idx" ON "room_members" USING btree ("user_id");