-- 업무를 다른 프로젝트로 옮길 때의 뒷정리(db/queries/projects.js detachMovedTask)가 생기기 전에 옮긴 업무의 흔적을 한 번 정리한다.
-- 새로 옮길 때 하는 것과 똑같다: ① 부모 업무가 다른 프로젝트로 간 하위 업무는 원래 프로젝트의 독립 업무로 남기고,
-- ② 업무 댓글의 프로젝트를 그 업무의 지금 프로젝트로 맞춘다. 그대로 두면 옮겨 간 쪽 멤버가 옛 프로젝트의 하위 업무를 보고
-- 지울 수 있고(부모를 지우면 함께 지워짐), 옛 프로젝트 관리자가 옮겨 간 업무의 댓글을 계속 고치고 지울 수 있다.
-- 두 문장 모두 프로젝트가 어긋난 행만 고친다 — 같은 프로젝트 안의 하위 업무·댓글은 건드리지 않고, 다시 돌려도 바뀌는 것이 없다.
-- (하위 업무를 읽는 쿼리와 댓글 권한 확인도 이제 업무의 지금 프로젝트를 기준으로 보므로, 이 정리 전에도 그런 행은 드러나지 않는다.)
UPDATE "tasks" AS "child"
SET "parent_task_id" = NULL, "updated_at" = now()
FROM "tasks" AS "parent"
WHERE "child"."parent_task_id" = "parent"."id"
  AND "child"."project_id" <> "parent"."project_id";
--> statement-breakpoint
UPDATE "task_comments" AS "c"
SET "project_id" = "t"."project_id"
FROM "tasks" AS "t"
WHERE "c"."task_id" = "t"."id"
  AND "c"."project_id" <> "t"."project_id";
