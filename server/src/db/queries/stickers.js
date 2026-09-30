import { and, asc, eq, isNull, max } from 'drizzle-orm';
import { db } from '../client.js';
import { stickerPacks, stickers } from '../schema.js';

/** 세트 전부(숨긴 것 포함)와 그 안의 스티커 — 순서대로. */
export async function listStickerPacks() {
  const packs = await db.select().from(stickerPacks).orderBy(asc(stickerPacks.position), asc(stickerPacks.createdAt));
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

/** 새 세트 — 맨 뒤 순서로. */
export async function createStickerPack(name) {
  const [{ value }] = await db.select({ value: max(stickerPacks.position) }).from(stickerPacks);
  const [row] = await db
    .insert(stickerPacks)
    .values({ name, position: (value ?? -1) + 1 })
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
