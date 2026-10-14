CREATE TABLE "calendar_feeds" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"team_id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	"token_hash" text NOT NULL,
	"token_enc" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_access_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "external_calendar_events" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"external_calendar_id" uuid NOT NULL,
	"uid" text NOT NULL,
	"title" text NOT NULL,
	"description" text,
	"location" text,
	"start_at" timestamp with time zone NOT NULL,
	"end_at" timestamp with time zone NOT NULL,
	"all_day" boolean DEFAULT false NOT NULL
);
--> statement-breakpoint
CREATE TABLE "external_calendars" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"team_id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	"name" text NOT NULL,
	"url_enc" text NOT NULL,
	"host" text NOT NULL,
	"color" text NOT NULL,
	"hidden" boolean DEFAULT false NOT NULL,
	"content_hash" text,
	"last_fetched_at" timestamp with time zone,
	"last_success_at" timestamp with time zone,
	"last_error" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "calendar_feeds" ADD CONSTRAINT "calendar_feeds_team_id_teams_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "calendar_feeds" ADD CONSTRAINT "calendar_feeds_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "external_calendar_events" ADD CONSTRAINT "external_calendar_events_external_calendar_id_external_calendars_id_fk" FOREIGN KEY ("external_calendar_id") REFERENCES "public"."external_calendars"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "external_calendars" ADD CONSTRAINT "external_calendars_team_id_teams_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "external_calendars" ADD CONSTRAINT "external_calendars_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "calendar_feeds_user_team_idx" ON "calendar_feeds" USING btree ("user_id","team_id");--> statement-breakpoint
CREATE UNIQUE INDEX "calendar_feeds_token_idx" ON "calendar_feeds" USING btree ("token_hash");--> statement-breakpoint
CREATE INDEX "external_calendar_events_cal_start_idx" ON "external_calendar_events" USING btree ("external_calendar_id","start_at");--> statement-breakpoint
CREATE INDEX "external_calendars_user_team_idx" ON "external_calendars" USING btree ("user_id","team_id");--> statement-breakpoint
CREATE INDEX "external_calendars_fetched_idx" ON "external_calendars" USING btree ("last_fetched_at");