CREATE TABLE "call_recordings" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"room_id" text NOT NULL,
	"call_message_id" uuid,
	"started_by" uuid,
	"started_by_name" text NOT NULL,
	"started_at" timestamp with time zone DEFAULT now() NOT NULL,
	"ended_at" timestamp with time zone,
	"audio_only" boolean DEFAULT false NOT NULL,
	"egress_id" text,
	"file_path" text,
	"minutes_egress_id" text,
	"minutes_file_path" text,
	"status" text DEFAULT 'recording' NOT NULL,
	"error" text,
	"duration_ms" integer,
	"message_id" uuid,
	"minutes_status" text DEFAULT 'none' NOT NULL,
	"transcript" text,
	"summary" text,
	"minutes_error" text,
	"participant_names" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "call_recordings" ADD CONSTRAINT "call_recordings_room_id_rooms_id_fk" FOREIGN KEY ("room_id") REFERENCES "public"."rooms"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "call_recordings" ADD CONSTRAINT "call_recordings_call_message_id_messages_id_fk" FOREIGN KEY ("call_message_id") REFERENCES "public"."messages"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "call_recordings" ADD CONSTRAINT "call_recordings_started_by_users_id_fk" FOREIGN KEY ("started_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "call_recordings" ADD CONSTRAINT "call_recordings_message_id_messages_id_fk" FOREIGN KEY ("message_id") REFERENCES "public"."messages"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "call_recordings_room_idx" ON "call_recordings" USING btree ("room_id","started_at");--> statement-breakpoint
CREATE INDEX "call_recordings_status_idx" ON "call_recordings" USING btree ("status");