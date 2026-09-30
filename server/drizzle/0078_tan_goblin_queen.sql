CREATE TABLE "comment_favorites" (
	"user_id" uuid NOT NULL,
	"comment_id" uuid NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "comment_favorites_user_id_comment_id_pk" PRIMARY KEY("user_id","comment_id")
);
--> statement-breakpoint
CREATE TABLE "member_favorites" (
	"user_id" uuid NOT NULL,
	"team_id" uuid NOT NULL,
	"favorite_user_id" uuid NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "member_favorites_user_id_team_id_favorite_user_id_pk" PRIMARY KEY("user_id","team_id","favorite_user_id")
);
--> statement-breakpoint
CREATE TABLE "message_favorites" (
	"user_id" uuid NOT NULL,
	"message_id" uuid NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "message_favorites_user_id_message_id_pk" PRIMARY KEY("user_id","message_id")
);
--> statement-breakpoint
ALTER TABLE "comment_favorites" ADD CONSTRAINT "comment_favorites_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "comment_favorites" ADD CONSTRAINT "comment_favorites_comment_id_message_comments_id_fk" FOREIGN KEY ("comment_id") REFERENCES "public"."message_comments"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "member_favorites" ADD CONSTRAINT "member_favorites_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "member_favorites" ADD CONSTRAINT "member_favorites_team_id_teams_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "member_favorites" ADD CONSTRAINT "member_favorites_favorite_user_id_users_id_fk" FOREIGN KEY ("favorite_user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "message_favorites" ADD CONSTRAINT "message_favorites_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "message_favorites" ADD CONSTRAINT "message_favorites_message_id_messages_id_fk" FOREIGN KEY ("message_id") REFERENCES "public"."messages"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "comment_favorites_user_created_idx" ON "comment_favorites" USING btree ("user_id","created_at");--> statement-breakpoint
CREATE INDEX "member_favorites_user_team_idx" ON "member_favorites" USING btree ("user_id","team_id","created_at");--> statement-breakpoint
CREATE INDEX "message_favorites_user_created_idx" ON "message_favorites" USING btree ("user_id","created_at");