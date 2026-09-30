// 폴더 하나의 그림들을 이모티콘 세트로 한 번에 올린다(서버 PC에서 실행).
//
//   cd server
//   node scripts/import-stickers.mjs "C:\경로\리마인"            ← 세트 이름 = 폴더 이름
//   node scripts/import-stickers.mjs "C:\경로\리마인" --pack 리마인
//
// 같은 이름의 세트가 이미 있으면 그 세트 맨 뒤에 붙인다(없으면 새로 만든다). 파일은 이름 순서
// (1, 2, … 10 — 숫자는 숫자로)대로 붙고, 업로드 폴더(.env의 UPLOADS_DIR)에 새 이름으로 복사된다.
// PNG·JPG·GIF·WEBP만, 한 장 5MB 이하. 앱의 "서버 관리 > 이모티콘"에서 올리는 것과 결과가 같다.
import 'dotenv/config';
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

const { addStickers, createStickerPack, findStickerPackByName } = await import('../src/db/queries/stickers.js');
const { uploadsDir } = await import('../src/upload.js');
const { naturalCompare, STICKER_MIME: MIME } = await import('../src/stickers.js');

const MAX_FILE_BYTES = 5 * 1024 * 1024;

const args = process.argv.slice(2);
const folder = args.find((a) => !a.startsWith('--'));
const packFlag = args.indexOf('--pack');
if (!folder || !fs.existsSync(folder) || !fs.statSync(folder).isDirectory()) {
  console.error('사용법: node scripts/import-stickers.mjs <그림 폴더> [--pack 세트이름]');
  process.exit(1);
}
const packName = (packFlag >= 0 ? args[packFlag + 1] : path.basename(path.resolve(folder)))?.trim();
if (!packName) {
  console.error('세트 이름이 비어 있습니다.');
  process.exit(1);
}

const files = fs
  .readdirSync(folder)
  .filter((f) => MIME[path.extname(f).toLowerCase()])
  .sort(naturalCompare);
const skipped = [];
const items = [];
for (const name of files) {
  const src = path.join(folder, name);
  if (fs.statSync(src).size > MAX_FILE_BYTES) {
    skipped.push(`${name} (5MB 초과)`);
    continue;
  }
  const ext = path.extname(name).toLowerCase();
  const stored = `${randomUUID()}${ext}`;
  fs.copyFileSync(src, path.join(uploadsDir, stored));
  items.push({ fileUrl: `/uploads/${stored}`, fileName: name, mimeType: MIME[ext] });
}
if (items.length === 0) {
  console.error('올릴 그림이 없습니다(PNG·JPG·GIF·WEBP).');
  process.exit(1);
}

const pack = (await findStickerPackByName(packName)) ?? (await createStickerPack(packName));
const added = await addStickers(pack.id, items);
console.log(`세트 "${pack.name}"에 ${added.length}개를 올렸습니다.`);
if (skipped.length) console.log(`건너뜀: ${skipped.join(', ')}`);
process.exit(0);
