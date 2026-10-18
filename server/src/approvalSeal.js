import crypto from 'node:crypto';

/**
 * 결재 **전자서명**(위변조 방지 — 순수 규칙). 결재자가 승인·반려·반대할 때 서버가 그 결정을 서버의 서명 키(Ed25519 — approvalSealKeys.js)로
 * 서명해 칸에 남긴다(approval_steps.seal). 서명하는 내용은
 *  - 문서 지문([documentDigest]) — 번호·종류·올린 사람·제목·내용·payload(양식 칸·금액 등)·첨부 목록·올린 시각의 SHA-256,
 *  - 그 칸의 결정 — 순서·단계·역할·결재자·상태·의견·결정 시각·대결한 사람,
 *  - 결재 칸에 들어간 서명·도장 그림 파일의 SHA-256(approval_steps.signature_hash),
 *  - 앞서 서명한 칸의 서명(사슬 — 앞 칸을 고치면 뒤 칸도 깨진다)
 * 이다(사람은 그때 적어 둔 이름으로 — 계정이 지워지면 id 칸이 비어도 서명이 깨지지 않게). 나중에 [verifyDocument]가 지금 DB 값과 파일로 다시 계산해 맞춰 본다 — DB의 제목·금액·결재 기록을 고치거나 서명 그림 파일을 바꾸면
 * "바뀜"으로 드러난다. 이 기능 전에 결정한 칸은 서명이 없어 "서명 없음"이다. `node --test`로 시험한다(test/approvalFollowup.test.js).
 */

export const SEAL_VERSION = 1;

/** 키 순서를 고정한 JSON(같은 값이면 늘 같은 글). */
export function canonicalJson(value) {
  if (value === undefined) return 'null';
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (value instanceof Date) return JSON.stringify(value.toISOString());
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  const keys = Object.keys(value).filter((k) => value[k] !== undefined).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalJson(value[k])}`).join(',')}}`;
}

const sha256 = (text) => crypto.createHash('sha256').update(text).digest('hex');
const iso = (v) => (v ? new Date(v).toISOString() : null);

/** 문서 지문 — 결재로 바뀌지 않는 내용만(상태·결정 시각은 칸 서명이 따로 덮는다). */
export function documentDigest(doc) {
  return sha256(
    canonicalJson({
      v: SEAL_VERSION,
      id: doc.id,
      scopeKey: doc.scopeKey,
      kind: doc.kind,
      docNumber: doc.docNumber ?? null,
      authorName: doc.authorName,
      title: doc.title,
      body: doc.body ?? null,
      payload: doc.payload ?? null,
      attachments: (Array.isArray(doc.attachments) ? doc.attachments : []).map((a) => ({
        fileUrl: a.fileUrl ?? null,
        fileName: a.fileName ?? null,
        fileSize: a.fileSize ?? null,
      })),
      createdAt: iso(doc.createdAt),
    }),
  );
}

/** 서명하는 칸의 결정. */
const DECIDED = new Set(['approved', 'rejected', 'disagreed']);
export const isDecidedStep = (s) => DECIDED.has(s.status) && !!s.decidedAt;

/** 칸 하나의 서명 대상 글. */
export function stepSealText({ digest, step, prevSeal }) {
  return canonicalJson({
    v: SEAL_VERSION,
    doc: digest,
    order: step.stepOrder,
    stage: step.stage ?? null,
    role: step.role ?? 'approve',
    approverName: step.approverName,
    status: step.status,
    comment: step.comment ?? null,
    decidedAt: iso(step.decidedAt),
    actedByName: step.actedByName ?? null,
    signatureHash: step.signatureHash ?? null,
    prev: prevSeal ?? null,
  });
}

/** 서명한 칸들의 순서 — 결정 시각, 같으면 칸 순서(합의는 같은 단계에서 따로 결정된다). */
const sealOrder = (steps) =>
  [...steps].sort((a, b) => new Date(a.decidedAt) - new Date(b.decidedAt) || a.stepOrder - b.stepOrder);

/**
 * 이번에 결정된 칸([stepIds])들의 서명 → `[{ id, seal }]`. [steps]는 결정을 반영한 문서의 모든 칸(signatureHash 포함), [sign]은 글 →
 * base64 서명. 사슬은 이미 서명한 칸 중 마지막 것부터 잇는다.
 */
export function sealsFor({ doc, steps, stepIds, sign }) {
  const digest = documentDigest(doc);
  const sealed = sealOrder(steps.filter((s) => s.seal && isDecidedStep(s) && !stepIds.includes(s.id)));
  let prev = sealed.length ? sealed[sealed.length - 1].seal : null;
  const out = [];
  for (const step of sealOrder(steps.filter((s) => stepIds.includes(s.id) && isDecidedStep(s)))) {
    const seal = sign(stepSealText({ digest, step, prevSeal: prev }));
    out.push({ id: step.id, seal });
    prev = seal;
  }
  return out;
}

/**
 * 문서 검증 → `{ digest, ok, steps: [{ id, order, approverName, status, result, reason? }] }`. [verify](글, 서명) → 맞는지,
 * [fileHashOf](칸) → 지금 서명 그림 파일의 SHA-256(파일이 없으면 null, 서명 그림을 안 넣은 칸이면 undefined).
 *  - result 'valid' 맞음 | 'invalid' 바뀜(내용·결정 기록·앞 칸) | 'signatureChanged' 서명 그림 파일이 바뀜 | 'signatureMissing' 서명 그림
 *    파일이 없음 | 'unsealed' 이 기능 전에 결정해 서명 없음. 결정하지 않은 칸은 빼고 보낸다.
 * [ok]는 서명한 칸이 하나 이상이고 모두 맞을 때.
 */
export function verifyDocument({ doc, steps, verify, fileHashOf }) {
  const digest = documentDigest(doc);
  const results = [];
  let prev = null;
  let sealedCount = 0;
  for (const step of sealOrder(steps.filter(isDecidedStep))) {
    const base = { id: step.id, order: step.stepOrder, approverName: step.approverName, status: step.status };
    if (!step.seal) {
      results.push({ ...base, result: 'unsealed' });
      continue;
    }
    sealedCount += 1;
    const valid = verify(stepSealText({ digest, step, prevSeal: prev }), step.seal);
    prev = step.seal;
    if (!valid) {
      results.push({ ...base, result: 'invalid' });
      continue;
    }
    if (step.signatureHash) {
      const now = fileHashOf(step);
      if (now === null) {
        results.push({ ...base, result: 'signatureMissing' });
        continue;
      }
      if (now !== undefined && now !== step.signatureHash) {
        results.push({ ...base, result: 'signatureChanged' });
        continue;
      }
    }
    results.push({ ...base, result: 'valid' });
  }
  results.sort((a, b) => a.order - b.order);
  return { digest, ok: sealedCount > 0 && results.every((r) => r.result === 'valid' || r.result === 'unsealed'), steps: results };
}

/** 공개 키 지문 — 공개 키(DER)의 SHA-256 앞 32자리를 4자리씩(관리 화면·인쇄에 보임). */
export function keyFingerprint(publicKeyDer) {
  return crypto
    .createHash('sha256')
    .update(publicKeyDer)
    .digest('hex')
    .slice(0, 32)
    .toUpperCase()
    .replace(/(.{4})(?=.)/g, '$1-');
}
