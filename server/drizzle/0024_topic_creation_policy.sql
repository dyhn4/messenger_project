ALTER TABLE "teams" RENAME COLUMN "invite_policy" TO "topic_creation_policy";--> statement-breakpoint
ALTER TABLE "teams" DROP COLUMN "domain";
