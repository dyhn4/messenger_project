ALTER TABLE "projects" ADD COLUMN "color" text DEFAULT '#5B8DEF' NOT NULL;--> statement-breakpoint
ALTER TABLE "projects" ADD COLUMN "is_public" boolean DEFAULT false NOT NULL;