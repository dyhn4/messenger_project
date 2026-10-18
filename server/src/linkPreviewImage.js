// 링크 미리보기 그림을 서버가 한 번 받아 업로드 파일로 둔다 — 메시지의 링크 카드(sendMessage.js)·링크 모아보기(links.js)·북마크
// 링크 정보(bookmarks.js)가 쓴다. 판단 규칙은 DB 없이 단위 테스트한다(test/linkPreviewImage.test.js).
//
// 왜: 예전엔 링크한 페이지가 적어 둔 og:image 주소를 그대로 저장해 보는 사람 모두에게 넘겼다. 그러면 메시지를 볼 때마다 각자의
// 앱이 그 사이트에 직접 접속한다 — 링크를 올린 사람이 그 페이지를 만들었다면 누가 언제 읽었는지와 각자의 공인 IP(집·LTE)를
// 알 수 있고, 이름이 사내 주소로 풀리는 그림이면 사내망 앱들이 사내 기기를 찌른다(페이지와 달리 그림 주소는 이름을 풀어 보지도
// 않았다). 이제는 서버가 페이지를 받을 때와 같은 SSRF 방어(linkPreview.js safeFetch — 이름을 푼 IP 검사·포트·리다이렉트마다
// 재검사)로 그림을 한 번 받고, 그림인지 확인한 뒤 작은 WEBP로 다시 만들어 업로드 파일로 둔다. 앱에는 서명된 /files 링크만 간다.
import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { RateLimiter } from './authGuard.js';
import { safeFetch } from './linkPreview.js';
import { uploadsDir, uploadsDirHasRoom } from './upload.js';

/** 받을 원본 그림의 상한(압축 해제 후) — 미리보기 그림은 보통 수백 KB다. */
export const PREVIEW_IMAGE_MAX_BYTES = 5 * 1024 * 1024;
/** 다시 만드는 그림의 한 변 — 말풍선 카드(360px)·링크 목록(48px)을 고해상도 화면에서도 선명하게. */
export const PREVIEW_IMAGE_MAX_SIDE = 800;
/** 원본 그림의 화소 상한 — 작은 파일이 엄청나게 큰 그림으로 풀리는 것(압축 폭탄)으로 서버 메모리를 채우지 못하게. */
const PREVIEW_IMAGE_MAX_PIXELS = 40_000_000;
const PREVIEW_IMAGE_DEADLINE_MS = 8000;
const PREVIEW_IMAGE_MAX_CONCURRENT = 3;

// 받는 형식 — 그림만. SVG는 받지 않는다(스크립트·바깥 참조를 품을 수 있는 문서다).
const PREVIEW_IMAGE_TYPES = new Set([
  'image/png',
  'image/jpeg',
  'image/jpg',
  'image/pjpeg',
  'image/gif',
  'image/webp',
  'image/bmp',
  'image/x-ms-bmp',
  'image/avif',
]);

/** 응답의 Content-Type이 받을 그림 형식인지. */
export function isPreviewImageType(contentType) {
  const type = String(contentType ?? '').split(';')[0].trim().toLowerCase();
  return PREVIEW_IMAGE_TYPES.has(type);
}

/** 내용 앞부분(파일 서명)으로 본 그림 종류 — png·jpeg·gif·webp·bmp·avif가 아니면 null. Content-Type만 믿지 않으려고 같이 본다. */
export function sniffImageType(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 12) return null;
  if (buf[0] === 0x89 && buf.toString('latin1', 1, 4) === 'PNG') return 'png';
  if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'jpeg';
  const head = buf.toString('latin1', 0, 6);
  if (head === 'GIF87a' || head === 'GIF89a') return 'gif';
  if (buf.toString('latin1', 0, 4) === 'RIFF' && buf.toString('latin1', 8, 12) === 'WEBP') return 'webp';
  if (buf.toString('latin1', 4, 8) === 'ftyp' && /^avi[fs]$/.test(buf.toString('latin1', 8, 12))) return 'avif';
  if (buf[0] === 0x42 && buf[1] === 0x4d) return 'bmp';
  return null;
}

/** 받아 볼 주소 후보인지 — http(s) 주소 문자열만(링크 미리보기의 og:image 후보·북마크에 붙인 바깥 그림 주소). */
export function isRemoteImageUrl(url) {
  return typeof url === 'string' && url.length <= 2000 && /^https?:\/\//i.test(url);
}

/** 받은 응답이 쓸 수 있는 그림인지 — 2xx, 그림 형식, 내용도 그림. */
export function acceptablePreviewResponse(res) {
  return (
    !!res &&
    res.status >= 200 &&
    res.status < 300 &&
    isPreviewImageType(res.headers?.['content-type']) &&
    sniffImageType(res.body) !== null
  );
}

// ── 받기·저장 ──────────────────────────────────────────────────────────

/**
 * 한 사람이 서버에게 바깥 그림을 받게 하는 횟수 — 링크를 바꿔 가며 계속 보내 서버 디스크·대역폭을 쓰게 하지 못하게. 넘으면 그림
 * 없이(제목·설명만) 미리보기가 붙는다. 사람이 대화하며 링크를 보내는 속도로는 닿지 않는다.
 */
const imageFetchLimiter = new RateLimiter({ max: 60, windowMs: 10 * 60 * 1000 });
setInterval(() => imageFetchLimiter.prune(), 10 * 60 * 1000).unref();

let activeDownloads = 0;

// 대화방 미리보기(누구의 파일도 아닌 그림)는 같은 그림 주소를 하루 동안 다시 받지 않고 같은 파일을 쓴다 — 많이 공유되는 기사
// 링크마다 같은 그림을 또 받지 않게.
const SHARED_CACHE_TTL_MS = 24 * 60 * 60 * 1000;
const SHARED_CACHE_MAX = 500;
const sharedCache = new Map(); // 그림 주소 → { stored, expiresAt }

async function cachedShared(url) {
  const hit = sharedCache.get(url);
  if (!hit) return null;
  if (hit.expiresAt <= Date.now()) {
    sharedCache.delete(url);
    return null;
  }
  try {
    await fs.promises.access(path.join(uploadsDir, path.basename(hit.stored)));
    return hit.stored;
  } catch {
    sharedCache.delete(url);
    return null;
  }
}

function rememberShared(url, stored) {
  if (sharedCache.size >= SHARED_CACHE_MAX) sharedCache.delete(sharedCache.keys().next().value);
  sharedCache.set(url, { stored, expiresAt: Date.now() + SHARED_CACHE_TTL_MS });
}

/**
 * 받은 그림을 미리보기용 WEBP로 다시 만든다 — 그림으로 풀리지 않으면 throw. 움직이는 그림은 첫 장면만. 다시 만들기 때문에 받은
 * 파일의 다른 내용(메타데이터·그림 뒤에 덧붙인 다른 파일)은 남지 않는다.
 */
export async function previewWebpOf(bytes, maxSide = PREVIEW_IMAGE_MAX_SIDE) {
  // sharp(네이티브 모듈)는 여기서 불러온다 — 이 파일의 판단 규칙만 쓰는 단위 테스트가 불러오지 않아도 되게.
  const { default: sharp } = await import('sharp');
  return sharp(bytes, { limitInputPixels: PREVIEW_IMAGE_MAX_PIXELS })
    .rotate() // 사진의 EXIF 방향 반영
    .resize(maxSide, maxSide, { fit: 'inside', withoutEnlargement: true })
    .webp({ quality: 80 })
    .toBuffer();
}

/** 업로드 폴더에 새 이름으로 쓰고 uploads 표에 남긴다(올린 사람 [ownerId] — 서버가 받은 대화방 미리보기는 null). 저장 경로. */
export async function storeUpload(bytes, ownerId) {
  if (!(await uploadsDirHasRoom(bytes.length))) return null;
  const fileName = `${randomUUID()}.webp`;
  const filePath = path.join(uploadsDir, fileName);
  await fs.promises.writeFile(filePath, bytes);
  try {
    // DB 모듈은 여기서 불러온다(upload.js의 /upload와 같은 이유 — 판단 규칙만 쓰는 단위 테스트가 DATABASE_URL 없이 돌게).
    const { insertUpload } = await import('./db/queries/uploads.js');
    await insertUpload({ fileName, uploaderId: ownerId ?? null });
  } catch (err) {
    await fs.promises.unlink(filePath).catch(() => {});
    throw err;
  }
  return `/uploads/${fileName}`;
}

const defaultDeps = { fetch: safeFetch, store: storeUpload, cached: cachedShared };

/**
 * 바깥 그림 주소([imageUrl])를 받아 업로드 파일로 두고 저장 경로(/uploads/<이름>.webp)를 돌려준다. 못 받으면(막힌 주소·그림 아님·
 * 너무 큼·시간 초과·횟수 초과·동시 받기 초과·디스크 부족) null — 미리보기는 그림 없이 붙는다.
 *  - [requesterId]: 이 받기를 일으킨 사람(링크를 보낸 사람·북마크 링크 정보를 연 사람) — 사람마다 횟수를 센다.
 *  - [ownerId]: uploads 표에 남길 올린 사람. 북마크처럼 그 사람이 곧 자기 기록에 붙일 그림이면 그 사람(fileRefs.js가 "직접 올린 파일"로
 *    알아본다), 대화방 미리보기면 null(누구도 첨부로 다시 실을 수 없다).
 * [deps]는 테스트가 네트워크·디스크 대신 넣는 받기·저장 함수.
 */
export async function storePreviewImage(imageUrl, { requesterId = null, ownerId = null } = {}, deps = defaultDeps) {
  if (!isRemoteImageUrl(imageUrl)) return null;
  const shared = ownerId == null;
  if (shared) {
    const cached = await deps.cached(imageUrl);
    if (cached) return cached;
  }
  if (requesterId && imageFetchLimiter.hit(requesterId) > 0) return null;
  if (activeDownloads >= PREVIEW_IMAGE_MAX_CONCURRENT) return null;
  activeDownloads++;
  try {
    const res = await deps.fetch(imageUrl, {
      maxBytes: PREVIEW_IMAGE_MAX_BYTES,
      accept: 'image/avif,image/webp,image/png,image/jpeg,image/gif;q=0.9,*/*;q=0.1',
      truncate: false,
      deadlineMs: PREVIEW_IMAGE_DEADLINE_MS,
    });
    if (!acceptablePreviewResponse(res)) return null;
    const webp = await previewWebpOf(res.body);
    const stored = await deps.store(webp, ownerId);
    if (stored && shared) rememberShared(imageUrl, stored);
    return stored;
  } catch (err) {
    console.warn('[linkPreview] 미리보기 그림을 받지 못했습니다:', err?.message ?? err);
    return null;
  } finally {
    activeDownloads--;
  }
}

/** 봇 메시지에 붙일 바깥 그림의 한 변 — 그래프·스크린샷이 읽히게 미리보기(800)보다 크게. 말풍선에는 미리보기 크기 사본을 쓴다. */
export const BOT_IMAGE_MAX_SIDE = 2048;
const BOT_IMAGE_MAX_BYTES = 10 * 1024 * 1024;

/**
 * 연동(웹훅의 image_url·그림 블록, 봇 API)이 준 바깥 그림을 받아 그림 첨부로 둔다 — 링크 미리보기와 같은 SSRF 방어(safeFetch — 공인
 * 주소만)로 받고, 그림인지 확인한 뒤 WEBP로 다시 만들어(원본 2048px·미리보기 800px) 업로드 파일로 둔다. 못 받으면 null.
 * 결과 { fileUrl, thumbnailUrl, fileName, fileSize, mimeType }. 동시 받기 수는 미리보기와 같이 센다.
 */
export async function storeRemoteImage(imageUrl, deps = defaultDeps) {
  if (!isRemoteImageUrl(imageUrl)) return null;
  if (activeDownloads >= PREVIEW_IMAGE_MAX_CONCURRENT) return null;
  activeDownloads++;
  try {
    const res = await deps.fetch(imageUrl, {
      maxBytes: BOT_IMAGE_MAX_BYTES,
      accept: 'image/avif,image/webp,image/png,image/jpeg,image/gif;q=0.9,*/*;q=0.1',
      truncate: false,
      deadlineMs: PREVIEW_IMAGE_DEADLINE_MS,
    });
    if (!acceptablePreviewResponse(res)) return null;
    const [full, thumb] = await Promise.all([previewWebpOf(res.body, BOT_IMAGE_MAX_SIDE), previewWebpOf(res.body)]);
    const fileUrl = await deps.store(full, null);
    if (!fileUrl) return null;
    const thumbnailUrl = await deps.store(thumb, null);
    const base = (() => {
      try {
        return decodeURIComponent(new URL(imageUrl).pathname.split('/').pop() || '').replace(/\.[^.]*$/, '');
      } catch {
        return '';
      }
    })();
    return { fileUrl, thumbnailUrl, fileName: `${(base || 'image').slice(0, 80)}.webp`, fileSize: full.length, mimeType: 'image/webp' };
  } catch (err) {
    console.warn('[integrations] 바깥 그림을 받지 못했습니다:', err?.message ?? err);
    return null;
  } finally {
    activeDownloads--;
  }
}
