CREATE TABLE "devices" (
	"id" text PRIMARY KEY NOT NULL,
	"user_id" uuid NOT NULL,
	"name" text,
	"identity_public_key" text NOT NULL,
	"signing_public_key" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_seen_at" timestamp with time zone,
	"revoked_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "secret_rekeys" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"room_id" text NOT NULL,
	"key_epoch" integer NOT NULL,
	"proposer_user_id" uuid NOT NULL,
	"proposer_ephemeral_public_key" text NOT NULL,
	"proposer_ephemeral_signature" text NOT NULL,
	"responder_ephemeral_public_key" text,
	"responder_ephemeral_signature" text,
	"status" text DEFAULT 'proposed' NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "secret_sessions" (
	"room_id" text PRIMARY KEY NOT NULL,
	"initiator_user_id" uuid NOT NULL,
	"initiator_device_id" text NOT NULL,
	"responder_user_id" uuid NOT NULL,
	"responder_device_id" text,
	"status" text DEFAULT 'pending' NOT NULL,
	"initiator_ephemeral_public_key" text NOT NULL,
	"initiator_ephemeral_signature" text NOT NULL,
	"responder_ephemeral_public_key" text,
	"responder_ephemeral_signature" text,
	"key_epoch" integer DEFAULT 0 NOT NULL,
	"self_destruct_seconds" integer,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"accepted_at" timestamp with time zone
);
--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "read_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "expires_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "rooms" ADD COLUMN "is_secret" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "devices" ADD CONSTRAINT "devices_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "secret_rekeys" ADD CONSTRAINT "secret_rekeys_room_id_rooms_id_fk" FOREIGN KEY ("room_id") REFERENCES "public"."rooms"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "secret_rekeys" ADD CONSTRAINT "secret_rekeys_proposer_user_id_users_id_fk" FOREIGN KEY ("proposer_user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "secret_sessions" ADD CONSTRAINT "secret_sessions_room_id_rooms_id_fk" FOREIGN KEY ("room_id") REFERENCES "public"."rooms"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "secret_sessions" ADD CONSTRAINT "secret_sessions_initiator_user_id_users_id_fk" FOREIGN KEY ("initiator_user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "secret_sessions" ADD CONSTRAINT "secret_sessions_initiator_device_id_devices_id_fk" FOREIGN KEY ("initiator_device_id") REFERENCES "public"."devices"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "secret_sessions" ADD CONSTRAINT "secret_sessions_responder_user_id_users_id_fk" FOREIGN KEY ("responder_user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "secret_sessions" ADD CONSTRAINT "secret_sessions_responder_device_id_devices_id_fk" FOREIGN KEY ("responder_device_id") REFERENCES "public"."devices"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "devices_user_id_idx" ON "devices" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "secret_rekeys_room_id_epoch_idx" ON "secret_rekeys" USING btree ("room_id","key_epoch");--> statement-breakpoint
CREATE INDEX "messages_expires_at_idx" ON "messages" USING btree ("expires_at");