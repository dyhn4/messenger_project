import { randomUUID } from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import sharp from 'sharp';
import {
  ANTHROPIC_API_KEY,
  RECEIPT_OCR_API_KEY,
  RECEIPT_OCR_ENGINE,
  RECEIPT_OCR_MODEL,
  RECEIPT_OCR_URL,
} from './config.js';
import { findReceiptScan, saveReceiptScan } from './db/queries/corporateCards.js';
import {
  extractJson,
  normalizeClovaReceipt,
  normalizeReceipt,
  RECEIPT_PROMPT,
  RECEIPT_SCHEMA,
  receiptInputKind,
} from './receiptOcrRules.js';
import { uploadFileNameOf, uploadsDir } from './upload.js';

/**
 * 영수증 읽기 — 올린 영수증(이미지·PDF)을 관리자가 정한 서비스(config.js RECEIPT_OCR_ENGINE — Claude·사내 OpenAI 호환 비전 모델·CLOVA OCR
 * 영수증 특화)로 읽어 가맹점·날짜·금액·승인번호를 맞춘 모양(receiptOcrRules.js normalizeReceipt)으로 돌려준다. 같은 파일은 한 번만 읽고
 * 결과를 둔다(receipt_scans — 파일 이름마다). 사진은 보내기 전에 긴 변 2000px JPEG로 줄인다(글자는 읽히고 보내는 양·비용은 준다).
 *
 * 서비스 키·주소는 응답·오류에 넣지 않는다. 서비스가 꺼져 있으면 라우터가 503으로 답한다(앱은 "영수증 읽기" 단추를 숨긴다).
 */

const PDF_MAX = 10 * 1024 * 1024;
const IMAGE_MAX = 20 * 1024 * 1024;

export class ReceiptOcrError extends Error {
  constructor(message, status = 502) {
    super(message);
    this.status = status;
  }
}

/** 지금 쓰는 서비스 — 'claude' | 'openai' | 'clova' | null(꺼짐). 필요한 값이 빠졌으면 null. */
function engine() {
  if (RECEIPT_OCR_ENGINE === 'claude') return RECEIPT_OCR_API_KEY || ANTHROPIC_API_KEY ? 'claude' : null;
  if (RECEIPT_OCR_ENGINE === 'openai') return RECEIPT_OCR_URL && RECEIPT_OCR_MODEL ? 'openai' : null;
  if (RECEIPT_OCR_ENGINE === 'clova') return RECEIPT_OCR_URL && RECEIPT_OCR_API_KEY ? 'clova' : null;
  return null;
}

async function serviceError(res) {
  const body = (await res.text().catch(() => '')).replace(/\s+/g, ' ').slice(0, 200);
  return new ReceiptOcrError(`영수증 읽기 서비스가 ${res.status}로 거절했습니다${body ? `: ${body}` : ''}`);
}

/** Claude — 이미지(또는 PDF 문서)와 지시를 보내 구조화 출력(JSON 스키마)으로 받는다. 거절(refusal)이면 다른 모델로 넘긴다(fallbacks). */
async function readWithClaude({ data, mediaType, kind }) {
  const source = { type: 'base64', media_type: mediaType, data: data.toString('base64') };
  const res = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': RECEIPT_OCR_API_KEY || ANTHROPIC_API_KEY,
      'anthropic-version': '2023-06-01',
      'anthropic-beta': 'server-side-fallback-2026-07-01',
    },
    body: JSON.stringify({
      model: RECEIPT_OCR_MODEL || 'claude-opus-5-5',
      max_tokens: 4000,
      fallbacks: 'default',
      // 글자 옮겨 적기라 깊이 생각할 일이 아니다.
      output_config: { effort: 'low', format: { type: 'json_schema', schema: RECEIPT_SCHEMA } },
      messages: [
        {
          role: 'user',
          content: [kind === 'pdf' ? { type: 'document', source } : { type: 'image', source }, { type: 'text', text: RECEIPT_PROMPT }],
        },
      ],
    }),
    signal: AbortSignal.timeout(120_000),
  });
  if (!res.ok) throw await serviceError(res);
  const json = await res.json();
  if (json?.stop_reason === 'refusal') throw new ReceiptOcrError('영수증 읽기 서비스가 이 파일을 읽지 않았습니다.');
  const text = (json?.content ?? [])
    .filter((b) => b?.type === 'text')
    .map((b) => b.text)
    .join('');
  const parsed = extractJson(text);
  if (!parsed) throw new ReceiptOcrError('영수증 읽기 서비스의 응답을 읽지 못했습니다.');
  return normalizeReceipt(parsed);
}

/** OpenAI 호환 비전 모델 — JSON 응답을 요구하고(못 하는 서버면 한 번 더 일반 응답으로), 글에서 JSON을 꺼낸다. */
async function readWithOpenAi({ data, mediaType, kind }) {
  if (kind === 'pdf') throw new ReceiptOcrError('이 영수증 읽기 서비스는 PDF를 읽지 못합니다. 사진(JPG·PNG)으로 올리세요.', 400);
  const send = (jsonMode) =>
    fetch(`${RECEIPT_OCR_URL}/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...(RECEIPT_OCR_API_KEY && { Authorization: `Bearer ${RECEIPT_OCR_API_KEY}` }) },
      body: JSON.stringify({
        model: RECEIPT_OCR_MODEL,
        temperature: 0,
        ...(jsonMode && { response_format: { type: 'json_object' } }),
        messages: [
          {
            role: 'user',
            content: [
              { type: 'text', text: `${RECEIPT_PROMPT}\n칸: merchant, bizNo, date, time, total, vat, cardLast4, approvalNo, items` },
              { type: 'image_url', image_url: { url: `data:${mediaType};base64,${data.toString('base64')}` } },
            ],
          },
        ],
      }),
      signal: AbortSignal.timeout(180_000),
    });
  let res = await send(true);
  if (res.status === 400) res = await send(false);
  if (!res.ok) throw await serviceError(res);
  const json = await res.json();
  const parsed = extractJson(String(json?.choices?.[0]?.message?.content ?? ''));
  if (!parsed) throw new ReceiptOcrError('영수증 읽기 서비스의 응답을 읽지 못했습니다.');
  return normalizeReceipt(parsed);
}

/** CLOVA OCR 영수증 특화 모델(V2) — JSON 본문에 base64 이미지. */
async function readWithClova({ data, kind }) {
  const res = await fetch(RECEIPT_OCR_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-OCR-SECRET': RECEIPT_OCR_API_KEY },
    body: JSON.stringify({
      version: 'V2',
      requestId: randomUUID(),
      timestamp: Date.now(),
      images: [{ format: kind === 'pdf' ? 'pdf' : 'jpg', name: 'receipt', data: data.toString('base64') }],
    }),
    signal: AbortSignal.timeout(120_000),
  });
  if (!res.ok) throw await serviceError(res);
  return normalizeClovaReceipt(await res.json());
}

const defaultDeps = {
  engine,
  read: ({ engine: name, ...input }) =>
    name === 'claude' ? readWithClaude(input) : name === 'openai' ? readWithOpenAi(input) : readWithClova(input),
  findScan: findReceiptScan,
  saveScan: saveReceiptScan,
};
let deps = { ...defaultDeps };

/** 시험용 — 서비스·저장을 바꿔 끼운다(인자 없이 부르면 원래대로). */
export function setReceiptOcrDepsForTest(overrides) {
  deps = overrides ? { ...defaultDeps, ...overrides } : { ...defaultDeps };
}

/** 영수증 읽기가 켜져 있는지(앱이 단추를 보일지). */
export const receiptOcrEnabled = () => !!deps.engine();

/** 보낼 바이트 — 이미지는 EXIF 방향대로 돌려 긴 변 2000px JPEG로, PDF는 그대로(10MB까지). */
async function prepare(localPath, kind) {
  const stat = await fs.stat(localPath).catch(() => null);
  if (!stat) throw new ReceiptOcrError('영수증 파일을 찾을 수 없습니다.', 404);
  if (kind === 'pdf') {
    if (stat.size > PDF_MAX) throw new ReceiptOcrError('PDF가 너무 큽니다(10MB까지).', 400);
    return { data: await fs.readFile(localPath), mediaType: 'application/pdf' };
  }
  if (stat.size > IMAGE_MAX) throw new ReceiptOcrError('사진이 너무 큽니다(20MB까지).', 400);
  try {
    const data = await sharp(localPath, { failOn: 'none' })
      .rotate()
      .resize({ width: 2000, height: 2000, fit: 'inside', withoutEnlargement: true })
      .jpeg({ quality: 85 })
      .toBuffer();
    return { data, mediaType: 'image/jpeg' };
  } catch {
    throw new ReceiptOcrError('사진을 열지 못했습니다. JPG·PNG로 다시 올리세요.', 400);
  }
}

/**
 * 영수증 하나를 읽는다 — [fileUrl]은 미서명 저장 경로(/uploads/<이름> — 호출 쪽이 checkFileRefs로 확인한 것). 읽은 적 있으면 저장해 둔 결과.
 * `{ receipt, engine, cached }`. 실패하면 ReceiptOcrError(status — 400 형식, 404 파일 없음, 502 서비스, 503 꺼짐).
 */
export async function readReceipt({ fileUrl, mimeType, fileName, userId }) {
  const name = uploadFileNameOf(fileUrl);
  if (!name) throw new ReceiptOcrError('영수증 파일을 찾을 수 없습니다.', 404);
  const which = deps.engine();
  if (!which) throw new ReceiptOcrError('영수증 읽기가 꺼져 있습니다. 관리자에게 문의하세요.', 503);
  const cached = await deps.findScan(name);
  if (cached) return { receipt: normalizeReceipt(cached.result), engine: cached.engine, cached: true };
  const kind = receiptInputKind(mimeType, fileName ?? name);
  if (kind === 'heic') throw new ReceiptOcrError('HEIC 사진은 읽지 못합니다. 휴대폰 카메라 설정을 "호환성 우선"(JPG)으로 바꾸거나 캡처해서 올리세요.', 400);
  if (!kind) throw new ReceiptOcrError('영수증은 사진(JPG·PNG·WebP)이나 PDF만 읽을 수 있습니다.', 400);
  const input = await prepare(path.join(uploadsDir, name), kind);
  const receipt = await deps.read({ engine: which, kind, ...input });
  await deps.saveScan({ fileName: name, userId, engine: which, result: receipt }).catch((e) =>
    console.error('[receipt-ocr] 결과 저장 실패:', e?.message ?? e),
  );
  return { receipt, engine: which, cached: false };
}
