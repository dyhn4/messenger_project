CREATE TABLE "scheduled_messages" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"team_id" uuid NOT NULL,
	"room_id" text,
	"room_name" text,
	"user_id" uuid NOT NULL,
	"title" text,
	"text" text NOT NULL,
	"text_format" jsonb,
	"attachments" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"send_at" timestamp with time zone NOT NULL,
	"status" text DEFAULT 'scheduled' NOT NULL,
	"fail_reason" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "rooms" ADD COLUMN "is_self" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "scheduled_messages" ADD CONSTRAINT "scheduled_messages_team_id_teams_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "scheduled_messages" ADD CONSTRAINT "scheduled_messages_room_id_rooms_id_fk" FOREIGN KEY ("room_id") REFERENCES "public"."rooms"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "scheduled_messages" ADD CONSTRAINT "scheduled_messages_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "scheduled_messages_user_team_idx" ON "scheduled_messages" USING btree ("user_id","team_id");--> statement-breakpoint
CREATE INDEX "scheduled_messages_status_send_at_idx" ON "scheduled_messages" USING btree ("status","send_at");