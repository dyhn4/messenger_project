// 번역 JSON → Dart 표 — `node tool/l10n/build.mjs`.
//   tool/l10n/en.json        { 한국어 원문: 영어 }  → lib/l10n/strings_en.dart (stringsEn)
//   tool/l10n/server_en.json { 서버 한국어: 영어 } → lib/l10n/server_en.dart (serverEn — 그대로 같은 글, serverTemplatesEn — {0} 자리가 있는 틀)
// 열쇠는 이름순으로 써서 고칠 때 차이가 작게 남는다.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { encodeSingle } from './dart_lexer.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.resolve(HERE, '../../lib/l10n');
const read = (name) => {
  const p = path.join(HERE, name);
  return fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, 'utf8')) : {};
};

const entries = (obj) =>
  Object.keys(obj)
    .sort()
    .filter((k) => typeof obj[k] === 'string') // 빈 글도 번역이다(영어에 없는 조사 '을'·'를' 등)
    .map((k) => `  '${encodeSingle(k)}': '${encodeSingle(obj[k])}',`)
    .join('\n');

const header = (src) =>
  `// 이 파일은 tool/l10n/build.mjs가 만든다 — 손으로 고치지 말고 tool/l10n/${src}을 고친 뒤 다시 만든다(README "다국어").\n` +
  '// ignore_for_file: lines_longer_than_80_chars\n';

const en = read('en.json');
fs.writeFileSync(
  path.join(OUT, 'strings_en.dart'),
  `${header('en.json')}\n/// 화면 글 — 한국어 원문(tr()의 열쇠) → 영어.\nconst Map<String, String> stringsEn = {\n${entries(en)}\n};\n`,
);

const server = read('server_en.json');
const exact = {};
const templates = {};
for (const [k, v] of Object.entries(server)) {
  if (/\{\d+\}/.test(k)) templates[k] = v;
  else exact[k] = v;
}
fs.writeFileSync(
  path.join(OUT, 'server_en.dart'),
  `${header('server_en.json')}\n/// 서버가 보내는 글 그대로(오류 문구·시스템 메시지·알림) → 영어.\nconst Map<String, String> serverEn = {\n${entries(exact)}\n};\n\n` +
    `/// 서버가 값을 넣어 만드는 글의 틀 — {0}·{1} 자리에 서버가 넣은 값이 온다(trServer가 맞춰 본다).\nconst Map<String, String> serverTemplatesEn = {\n${entries(templates)}\n};\n`,
);
console.log(`앱 ${Object.keys(en).length}개, 서버 ${Object.keys(exact).length}개 + 틀 ${Object.keys(templates).length}개`);
