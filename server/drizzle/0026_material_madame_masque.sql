CREATE TABLE "position_options" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"label" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "position_options_label_unique" UNIQUE("label")
);
--> statement-breakpoint
INSERT INTO "position_options" ("label") VALUES
	('사원'), ('주임'), ('대리'), ('과장'), ('차장'), ('부장'), ('이사'), ('대표')
ON CONFLICT ("label") DO NOTHING;
