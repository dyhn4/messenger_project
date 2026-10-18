// 번역이 빠진 글 확인 — `node tool/l10n/check.mjs`(extract.mjs를 먼저 돌린다). 빠진 게 있으면 목록을 보이고 1로 끝난다.
// 새 화면 글을 넣는 순서: 한국어로 tr('…')을 쓴다(또는 wrap.mjs로 감싼다) → extract.mjs → tool/l10n/pending.json의 글을
// en.json(서버 글은 server_en.json)에 옮겨 적는다 → build.mjs → check.mjs.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const read = (name, fallback) => {
  const p = path.join(HERE, name);
  return fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, 'utf8')) : fallback;
};
const keys = read('keys.json', []);
const en = read('en.json', {});
const missing = keys.filter((k) => !(k in en));
const ph = (s) => (s.match(/\{[^{}\s]+\}/g) || []).sort().join(' ');
const broken = keys.filter((k) => k in en && ph(k) !== ph(en[k]));
if (missing.length === 0 && broken.length === 0) {
  console.log(`번역 빠짐 없음(${keys.length}개)`);
} else {
  for (const k of missing) console.log(`빠짐: ${JSON.stringify(k)}`);
  for (const k of broken) console.log(`자리 다름: ${JSON.stringify(k)} → ${JSON.stringify(en[k])}`);
  process.exit(1);
}
