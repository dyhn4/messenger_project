CREATE TABLE "message_reminders" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"message_id" uuid NOT NULL,
	"room_id" text NOT NULL,
	"remind_at" timestamp with time zone NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"fired_at" timestamp with time zone
);
--> statement-breakpoint
ALTER TABLE "messages" ADD COLUMN "reminder_card" jsonb;--> statement-breakpoint
ALTER TABLE "message_reminders" ADD CONSTRAINT "message_reminders_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "message_reminders" ADD CONSTRAINT "message_reminders_message_id_messages_id_fk" FOREIGN KEY ("message_id") REFERENCES "public"."messages"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "message_reminders" ADD CONSTRAINT "message_reminders_room_id_rooms_id_fk" FOREIGN KEY ("room_id") REFERENCES "public"."rooms"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "message_reminders_due_idx" ON "message_reminders" USING btree ("remind_at") WHERE "message_reminders"."fired_at" is null;--> statement-breakpoint
CREATE INDEX "message_reminders_user_idx" ON "message_reminders" USING btree ("user_id","remind_at");