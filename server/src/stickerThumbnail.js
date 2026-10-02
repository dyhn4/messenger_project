import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import sharp from 'sharp';

/** 이모티콘·캐릭터 그림의 화면용 썸네일 한 변(px) — 가장 크게 그려질 때(말풍선 이모티콘, 프로필
 * 미리보기)도 선명하도록 여유를 둔 크기. */
export const STICKER_THUMB_SIZE = 256;

// 원본이 이만큼 작으면 줄여 봐야 이득이 없다.
const SKIP_IF_SMALLER_BYTES = 40 * 1024;

/**
 * [filePath](업로드된 원본)의 썸네일을 같은 폴더에 만들고 파일 이름(예: "<uuid>.webp")을 돌려준다.
 * 아래 경우엔 만들지 않고 null — 호출부는 원본을 그대로 쓴다.
 *  - 움직이는 그림(GIF·WEBP 애니메이션): 줄이면 움직임이 사라진다.
 *  - 원본이 이미 작고 한 변도 [STICKER_THUMB_SIZE] 이하.
 *  - 읽을 수 없는 파일.
 * 투명 배경은 WEBP(알파 지원)로 만들어 그대로 유지한다.
 */
export async function makeStickerThumbnail(filePath) {
  try {
    const meta = await sharp(filePath, { animated: true }).metadata();
    if ((meta.pages ?? 1) > 1) return null;
    const side = Math.max(meta.width ?? 0, meta.height ?? 0);
    const bytes = fs.statSync(filePath).size;
    if (side <= STICKER_THUMB_SIZE && bytes <= SKIP_IF_SMALLER_BYTES) return null;

    const name = `${randomUUID()}.webp`;
    const out = path.join(path.dirname(filePath), name);
    await sharp(filePath)
      .rotate() // 사진의 EXIF 방향 반영
      .resize(STICKER_THUMB_SIZE, STICKER_THUMB_SIZE, { fit: 'inside', withoutEnlargement: true })
      .webp({ quality: 85 })
      .toFile(out);
    // 썸네일이 오히려 더 크면(이미 잘 압축된 작은 그림) 원본을 쓴다.
    if (fs.statSync(out).size >= bytes) {
      fs.rmSync(out, { force: true });
      return null;
    }
    return name;
  } catch {
    return null;
  }
}
