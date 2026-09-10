CREATE TABLE "team_invite_links" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"token" text NOT NULL,
	"team_id" uuid NOT NULL,
	"assigned_role" text DEFAULT 'member' NOT NULL,
	"created_by" uuid,
	"created_by_name" text NOT NULL,
	"label" text,
	"expires_at" timestamp with time zone NOT NULL,
	"revoked_at" timestamp with time zone,
	"used_count" integer DEFAULT 0 NOT NULL,
	"last_used_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "team_invite_links_token_unique" UNIQUE("token")
);
--> statement-breakpoint
ALTER TABLE "server_settings" ADD COLUMN "team_invite_link_creation" text DEFAULT 'admin' NOT NULL;--> statement-breakpoint
ALTER TABLE "team_invite_links" ADD CONSTRAINT "team_invite_links_team_id_teams_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "team_invite_links" ADD CONSTRAINT "team_invite_links_created_by_users_id_fk" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "team_invite_links_created_by_idx" ON "team_invite_links" USING btree ("created_by");--> statement-breakpoint
CREATE INDEX "team_invite_links_team_id_idx" ON "team_invite_links" USING btree ("team_id");