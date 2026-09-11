ALTER TABLE "position_options" ADD COLUMN "sort_order" integer DEFAULT 0 NOT NULL;
--> statement-breakpoint
UPDATE "position_options" AS p
SET "sort_order" = t.rn
FROM (
  SELECT "id", ROW_NUMBER() OVER (ORDER BY "created_at") - 1 AS rn
  FROM "position_options"
) AS t
WHERE p."id" = t."id";