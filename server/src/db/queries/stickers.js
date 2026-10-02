import { and, asc, eq, isNull, max } from 'drizzle-orm';
import { db } from '../client.js';
import { stickerPacks, stickers } from '../schema.js';

/** 세트 전부(숨긴 것 포함)와 그 안의 스티커 — 순서대로. [kind]를 주면('sticker' | 'character')
 * 그 종류의 세트만 돌려준다(stickers.js — 채팅용 이모티콘과 프로필용 캐릭터가 서로 섞이지
 * 않도록 목록을 받을 때 항상 걸러서 받는다). */
export async function listStickerPacks(kind) {
  const packs = await db
    .select()
    .from(stickerPacks)
    .where(kind ? eq(stickerPacks.kind, kind) : undefined)
    .orderBy(asc(stickerPacks.position), asc(stickerPacks.createdAt));
  const rows = await db.select().from(stickers).orderBy(asc(stickers.position), asc(stickers.createdAt));
  const byPack = new Map(packs.map((p) => [p.id, []]));
  for (const s of rows) byPack.get(s.packId)?.push(s);
  return packs.map((p) => ({ ...p, stickers: byPack.get(p.id) ?? [] }));
}

export async function findStickerPack(id) {
  const [row] = await db.select().from(stickerPacks).where(eq(stickerPacks.id, id));
  return row ?? null;
}

export async function findStickerPackByName(name) {
  const [row] = await db
    .select()
    .from(stickerPacks)
    .where(and(eq(stickerPacks.name, name), isNull(stickerPacks.deletedAt)));
  return row ?? null;
}

/** 새 세트 — 맨 뒤 순서로. [kind]는 'sticker'(기본, 채팅용) | 'character'(프로필용). */
export async function createStickerPack(name, kind = 'sticker') {
  const [{ value }] = await db.select({ value: max(stickerPacks.position) }).from(stickerPacks);
  const [row] = await db
    .insert(stickerPacks)
    .values({ name, kind, position: (value ?? -1) + 1 })
    .returning();
  return row;
}

export async function updateStickerPack(id, fields) {
  const [row] = await db.update(stickerPacks).set(fields).where(eq(stickerPacks.id, id)).returning();
  return row ?? null;
}

/** [items]({fileUrl, fileName, mimeType}) 를 세트 맨 뒤에 순서대로 붙인다. */
export async function addStickers(packId, items) {
  if (items.length === 0) return [];
  const [{ value }] = await db
    .select({ value: max(stickers.position) })
    .from(stickers)
    .where(eq(stickers.packId, packId));
  const start = (value ?? -1) + 1;
  return db
    .insert(stickers)
    .values(items.map((it, i) => ({ packId, position: start + i, ...it })))
    .returning();
}

export async function updateSticker(id, fields) {
  const [row] = await db.update(stickers).set(fields).where(eq(stickers.id, id)).returning();
  return row ?? null;
}

export async function findSticker(packId, id) {
  const [row] = await db.select().from(stickers).where(and(eq(stickers.id, id), eq(stickers.packId, packId)));
  return row ?? null;
}

/** 세트 id 없이 스티커 하나와 그 세트를 같이 찾는다 — "캐릭터를 프로필 사진으로 고르기"
 * (users.js)처럼 어느 세트인지 몰라도 되는 호출부용. 둘 다 있어야(세트가 지워지지 않았어도)
 * { ...sticker, pack }을, 없으면 null을 돌려준다. */
export async function findStickerWithPack(id) {
  const [row] = await db
    .select({ sticker: stickers, pack: stickerPacks })
    .from(stickers)
    .innerJoin(stickerPacks, eq(stickers.packId, stickerPacks.id))
    .where(eq(stickers.id, id));
  return row ? { ...row.sticker, pack: row.pack } : null;
}
