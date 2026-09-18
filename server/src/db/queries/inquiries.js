import { and, desc, eq } from 'drizzle-orm';
import { db } from '../client.js';
import { inquiries } from '../schema.js';

export async function insertInquiry(fields) {
  const [row] = await db.insert(inquiries).values(fields).returning();
  return row;
}

/** [status]가 없으면 전체(최신순). */
export function listInquiriesForRecipient(recipientId, status) {
  const conditions = [eq(inquiries.recipientId, recipientId)];
  if (status) conditions.push(eq(inquiries.status, status));
  return db
    .select()
    .from(inquiries)
    .where(and(...conditions))
    .orderBy(desc(inquiries.createdAt));
}

export function listInquiriesForSender(senderId) {
  return db
    .select()
    .from(inquiries)
    .where(eq(inquiries.senderId, senderId))
    .orderBy(desc(inquiries.createdAt));
}

export function findInquiryById(id) {
  return db
    .select()
    .from(inquiries)
    .where(eq(inquiries.id, id))
    .then((rows) => rows[0] ?? null);
}

export async function updateInquiryStatus(id, status) {
  const [row] = await db
    .update(inquiries)
    .set({ status, statusUpdatedAt: new Date() })
    .where(eq(inquiries.id, id))
    .returning();
  return row;
}
