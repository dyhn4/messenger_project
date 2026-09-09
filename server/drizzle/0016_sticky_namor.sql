ALTER TABLE "team_members" ADD COLUMN "department" text;--> statement-breakpoint
ALTER TABLE "team_members" ADD COLUMN "position" text;--> statement-breakpoint
ALTER TABLE "teams" ADD COLUMN "domain" text;--> statement-breakpoint
ALTER TABLE "teams" ADD COLUMN "invite_policy" text DEFAULT 'member' NOT NULL;--> statement-breakpoint
ALTER TABLE "teams" ADD CONSTRAINT "teams_domain_unique" UNIQUE("domain");