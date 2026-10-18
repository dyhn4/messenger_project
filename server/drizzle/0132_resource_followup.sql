DROP INDEX "resource_bookings_event_idx";--> statement-breakpoint
ALTER TABLE "groupware_options" ADD COLUMN "booking_reminder_minutes" integer DEFAULT 10 NOT NULL;--> statement-breakpoint
ALTER TABLE "resource_bookings" ADD COLUMN "status" text DEFAULT 'confirmed' NOT NULL;--> statement-breakpoint
ALTER TABLE "resource_bookings" ADD COLUMN "series_id" uuid;--> statement-breakpoint
ALTER TABLE "resource_bookings" ADD COLUMN "reminded_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "resources" ADD COLUMN "requires_approval" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "resources" ADD COLUMN "approver_ids" jsonb DEFAULT '[]'::jsonb NOT NULL;--> statement-breakpoint
ALTER TABLE "resources" ADD COLUMN "allowed_user_ids" jsonb DEFAULT '[]'::jsonb NOT NULL;--> statement-breakpoint
ALTER TABLE "resources" ADD COLUMN "available_days" jsonb;--> statement-breakpoint
ALTER TABLE "resources" ADD COLUMN "available_from" integer;--> statement-breakpoint
ALTER TABLE "resources" ADD COLUMN "available_to" integer;--> statement-breakpoint
ALTER TABLE "resources" ADD COLUMN "max_minutes" integer;--> statement-breakpoint
ALTER TABLE "resources" ADD COLUMN "display_token" text;--> statement-breakpoint
ALTER TABLE "resources" ADD COLUMN "display_quick_book" boolean DEFAULT false NOT NULL;--> statement-breakpoint
CREATE INDEX "resource_bookings_series_idx" ON "resource_bookings" USING btree ("series_id");--> statement-breakpoint
CREATE UNIQUE INDEX "resources_display_token_idx" ON "resources" USING btree ("display_token");--> statement-breakpoint
CREATE INDEX "resource_bookings_event_idx" ON "resource_bookings" USING btree ("event_id");