CREATE TABLE "dm_history_floors" (
	"room_id" text NOT NULL,
	"user_id" uuid NOT NULL,
	"hidden_before_at" timestamp with time zone NOT NULL,
	CONSTRAINT "dm_history_floors_room_id_user_id_pk" PRIMARY KEY("room_id","user_id")
);
--> statement-breakpoint
ALTER TABLE "dm_history_floors" ADD CONSTRAINT "dm_history_floors_room_id_rooms_id_fk" FOREIGN KEY ("room_id") REFERENCES "public"."rooms"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "dm_history_floors" ADD CONSTRAINT "dm_history_floors_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;