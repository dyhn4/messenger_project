import { sql } from 'drizzle-orm';

/**
 * 파일 형식 분류 — 파일 패널(attachments.js)과 검색 패널의 "파일" 탭(search.js)이 같은 기준을 쓴다.
 * 값(image/pdf/…)은 client/lib/models/file_category.dart의 FileCategory 이름과 정확히 일치해야 한다.
 * 패턴은 JS(RegExp)와 Postgres(`~*`) 양쪽에서 같은 뜻이 되도록 공통 문법(선택 |, \., ^, $)만 쓴다.
 * MIME이 비어 있어도(예전 업로드) 확장자로 한 번 더 본다.
 */
export const FILE_KIND_PATTERNS = {
  image: { mime: '^image/', name: '\\.(jpe?g|png|gif|bmp|webp|heic|heif|svg|tiff?)$' },
  pdf: { mime: '^application/pdf$', name: '\\.pdf$' },
  document: { mime: 'word|msword|text/plain|hwp', name: '\\.(docx?|hwpx?|txt|rtf)$' },
  excel: { mime: 'excel|spreadsheet', name: '\\.(xlsx?|csv)$' },
  powerpoint: { mime: 'powerpoint|presentation', name: '\\.pptx?$' },
  video: { mime: '^video/', name: '\\.(mp4|mov|avi|mkv|wmv|webm|m4v)$' },
  audio: { mime: '^audio/', name: '\\.(mp3|wav|m4a|aac|ogg|flac)$' },
  archive: { mime: 'zip|rar|7z|compressed', name: '\\.(zip|rar|7z|tar|gz)$' },
};

/** 위 어느 것에도 안 들어가는 파일이 "기타"다. */
export const FILE_KINDS = [...Object.keys(FILE_KIND_PATTERNS), 'other'];

const COMPILED = Object.fromEntries(
  Object.entries(FILE_KIND_PATTERNS).map(([k, p]) => [k, { mime: new RegExp(p.mime, 'i'), name: new RegExp(p.name, 'i') }]),
);

function matchesOne(kind, mime, name) {
  const c = COMPILED[kind];
  return c.mime.test(mime ?? '') || c.name.test(name ?? '');
}

/** 이 (MIME, 파일명)이 [kind] 형식인가. 알 수 없는 kind면 거르지 않는다(true). */
export function matchesFileKind(kind, mime, name) {
  if (kind === 'other') return !Object.keys(COMPILED).some((k) => matchesOne(k, mime, name));
  if (!COMPILED[kind]) return true;
  return matchesOne(kind, mime, name);
}

/** 알려진 형식 이름이면 그대로, 아니면 null(= 전체 파일). */
export function parseFileKind(value) {
  return typeof value === 'string' && FILE_KINDS.includes(value) ? value : null;
}

/** [matchesFileKind]와 같은 조건의 SQL 조각 — mimeCol/nameCol은 drizzle 컬럼. */
export function fileKindSql(kind, mimeCol, nameCol) {
  const one = (k) => {
    const p = FILE_KIND_PATTERNS[k];
    return sql`(coalesce(${mimeCol}, '') ~* ${p.mime} or coalesce(${nameCol}, '') ~* ${p.name})`;
  };
  if (kind === 'other') {
    return sql`not (${sql.join(Object.keys(FILE_KIND_PATTERNS).map(one), sql` or `)})`;
  }
  return one(kind);
}
