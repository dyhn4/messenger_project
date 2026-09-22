-- 우선순위 기본값에 '긴급'·'대기'·'없음'을 더하고, 보여주는 순서를 높은 순위부터로 맞춘다
-- (server/src/db/queries/projects.js의 DEFAULT_TASK_PRIORITIES와 같은 목록).
-- 이름이 겹치면 건너뛰므로 사용자가 직접 만들어 둔 우선순위는 그대로 남는다.
INSERT INTO "task_priorities" ("project_id", "name", "color", "level", "position")
SELECT p."id", v.name, v.color, v.level, v.pos
FROM "projects" p
CROSS JOIN (VALUES
  ('긴급', '#DC2626', 'high', 0),
  ('높음', '#EF4444', 'high', 1),
  ('보통', '#5B8DEF', 'normal', 2),
  ('낮음', '#94A3B8', 'low', 3),
  ('대기', '#A78BFA', 'low', 4),
  ('없음', '#CBD5E1', 'low', 5)
) AS v(name, color, level, pos)
ON CONFLICT DO NOTHING;
--> statement-breakpoint
-- 예전 프로젝트는 낮음(0)·보통(1)·높음(2) 순이라 위에서 넣은 자리와 뒤섞인다 — 표준 이름은
-- 정해진 자리로 다시 매기고, 사용자가 만든 것은 뒤로 밀어 서로 부딪히지 않게 한다.
UPDATE "task_priorities" SET "position" = CASE "name"
  WHEN '긴급' THEN 0
  WHEN '높음' THEN 1
  WHEN '보통' THEN 2
  WHEN '낮음' THEN 3
  WHEN '대기' THEN 4
  WHEN '없음' THEN 5
  ELSE "position" + 100
END;
