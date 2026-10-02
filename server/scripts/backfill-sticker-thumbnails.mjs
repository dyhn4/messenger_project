// 예전에 올린 이모티콘·캐릭터 그림에 썸네일을 만들어 채운다(한 번 돌리면 된다 — 이미 있는 건 건너뜀).
// 사용: node scripts/backfill-sticker-thumbnails.mjs
import 'dotenv/config';
import path from 'node:path';
import { eq, isNull } from 'drizzle-orm';
import { db } from '../src/db/client.js';
import { stickers } from '../src/db/schema.js';
import { UPLOADS_DIR } from '../src/config.js';
import { makeStickerThumbnail } from '../src/stickerThumbnail.js';

const rows = await db.select().from(stickers).where(isNull(stickers.thumbnailUrl));
let made = 0;
let skipped = 0;
for (const s of rows) {
  const thumb = await makeStickerThumbnail(path.join(UPLOADS_DIR, path.basename(s.fileUrl)));
  if (!thumb) {
    skipped++;
    continue;
  }
  await db.update(stickers).set({ thumbnailUrl: `/uploads/${thumb}` }).where(eq(stickers.id, s.id));
  made++;
}
console.log(`썸네일 ${made}개 만들었습니다(건너뜀 ${skipped}개 — 움직이는 그림이거나 이미 작음).`);
process.exit(0);
