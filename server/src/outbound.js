import { signCommandRequest } from './integrationRules.js';
import { safeRequest } from './linkPreview.js';

/**
 * 서버가 연동의 바깥 주소로 **서명한 POST**를 보내는 한 곳 — 슬래시 명령(integrations.js), 단추 누름 알리기(integrationActions.js),
 * 나가는 웹훅·앱의 일 보내기(webhookDelivery.js)가 같이 쓴다.
 *
 * 서명: `X-TangoTalk-Signature: v1=HMAC-SHA256(서명 비밀, "{X-TangoTalk-Timestamp}.{본문}")`(받는 쪽은 같은 계산으로 맞춰 보고 시각이
 * 5분 넘게 차이 나면 버린다). [allowPrivate]면(서버 운영자가 정한 주소 — 명령·앱, 운영자가 만든 웹훅) 사내 주소로도 보내고, 아니면 공인
 * 주소로만(linkPreview.js safeRequest — 사설망·이 서버·80/443이 아닌 포트는 막는다). 어느 쪽이든 리다이렉트는 따라가지 않는다.
 * 결과 `{ status, contentType, bodyText }`(본문은 [maxBytes]까지), 연결 실패·시간 초과는 throw(err.timedOut).
 */
export async function signedPost({
  url,
  body,
  secret,
  allowPrivate = false,
  headers = {},
  timeoutMs = 10_000,
  maxBytes = 64 * 1024,
  userAgent = 'TangoTalk-Webhook/1',
}) {
  const timestamp = String(Math.floor(Date.now() / 1000));
  const allHeaders = {
    'content-type': 'application/json',
    'user-agent': userAgent,
    'x-tangotalk-timestamp': timestamp,
    'x-tangotalk-signature': signCommandRequest(secret ?? '', timestamp, body),
    ...headers,
  };
  try {
    if (!allowPrivate) {
      const res = await safeRequest(url, { method: 'POST', headers: allHeaders, body, maxBytes, deadlineMs: timeoutMs });
      return {
        status: res.status,
        contentType: String(res.headers['content-type'] ?? ''),
        bodyText: res.body.toString('utf8'),
      };
    }
    const response = await fetch(url, {
      method: 'POST',
      headers: allHeaders,
      body,
      redirect: 'manual',
      signal: AbortSignal.timeout(timeoutMs),
    });
    return { status: response.status, contentType: response.headers.get('content-type') ?? '', bodyText: await readLimited(response, maxBytes) };
  } catch (err) {
    const timedOut = err?.name === 'TimeoutError' || err?.name === 'AbortError' || err?.message === '시간 초과';
    const e = new Error(timedOut ? '시간 초과' : (err?.message ?? '연결 실패'));
    e.timedOut = timedOut;
    throw e;
  }
}

/** fetch 응답 본문을 [maxBytes]까지만 읽는다(넘으면 거기서 끊는다). */
async function readLimited(response, maxBytes) {
  const reader = response.body?.getReader();
  if (!reader) return '';
  const decoder = new TextDecoder();
  let size = 0;
  let text = '';
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > maxBytes) {
      await reader.cancel();
      break;
    }
    text += decoder.decode(value, { stream: true });
  }
  return text;
}
