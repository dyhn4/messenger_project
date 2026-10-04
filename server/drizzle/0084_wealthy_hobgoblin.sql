CREATE TABLE "todo_favorites" (
	"user_id" uuid NOT NULL,
	"todo_id" uuid NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "todo_favorites_user_id_todo_id_pk" PRIMARY KEY("user_id","todo_id")
);
--> statement-breakpoint
ALTER TABLE "todo_assignees" ADD COLUMN "progress" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "todo_assignees" ADD COLUMN "completed_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "todo_assignees" ADD COLUMN "updated_at" timestamp with time zone DEFAULT now() NOT NULL;--> statement-breakpoint
ALTER TABLE "todo_favorites" ADD CONSTRAINT "todo_favorites_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "todo_favorites" ADD CONSTRAINT "todo_favorites_todo_id_todos_id_fk" FOREIGN KEY ("todo_id") REFERENCES "public"."todos"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "todo_favorites_todo_id_idx" ON "todo_favorites" USING btree ("todo_id");--> statement-breakpoint
-- 지금까지는 할 일마다 공용 진척률 하나였으므로, 각 담당자에게 그 값(과 완료 시각)을 그대로 나눠 준다.
UPDATE "todo_assignees" AS ta SET "progress" = t."progress", "completed_at" = t."completed_at" FROM "todos" AS t WHERE t."id" = ta."todo_id";