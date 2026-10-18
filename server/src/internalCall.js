/**
 * 앱 API 라우터(/api — 댓글·할 일·일정·메시지 고치기)를 **사람 한 명으로서 안에서 부른다** — 공개 API(publicApi.js)가 사람 토큰(개인 API
 * 토큰·OAuth)으로 온 요청을 같은 규칙(권한·길이 상한·횟수 제한·알림·소켓 방송·감사 로그)으로 처리하려고 쓴다. 규칙을 두 벌 두면 한쪽만
 * 고쳐져 어긋나기 때문이다. 공개 API는 바깥 모양(publicDtos.js)과 받는 칸(pickFields)을 정하고, 경로는 검사한 id로만 만든다.
 *
 * [router]는 그 라우터(createCommentsRouter(io) 등 — 한 번 만들어 둔다), [from]은 원래 요청(IP·소켓 주소를 감사 로그·횟수 제한에 그대로
 * 쓴다). 결과는 `{ status, body }` — 응답을 보내지 않고 다음으로 넘기면(없는 경로) 404.
 */
export function internalCall(router, { from, userId, method, path, body = {}, query = {} }) {
  return new Promise((resolve, reject) => {
    const headers = { ...(from?.headers ?? {}) };
    delete headers.authorization;
    delete headers['content-length'];
    const req = {
      method,
      url: path,
      originalUrl: path,
      baseUrl: '',
      path,
      headers,
      body,
      query,
      params: {},
      user: { sub: userId },
      socket: from?.socket,
      connection: from?.socket,
      ip: from?.ip,
      protocol: from?.protocol ?? 'https',
      get: (name) => headers[String(name).toLowerCase()],
      header: (name) => headers[String(name).toLowerCase()],
    };
    let done = false;
    const finish = (status, payload) => {
      if (done) return;
      done = true;
      resolve({ status, body: payload });
    };
    const res = {
      statusCode: 200,
      headersSent: false,
      locals: {},
      status(code) {
        this.statusCode = code;
        return this;
      },
      set() {
        return this;
      },
      header() {
        return this;
      },
      setHeader() {},
      getHeader() {
        return undefined;
      },
      type() {
        return this;
      },
      json(payload) {
        this.headersSent = true;
        finish(this.statusCode, payload);
        return this;
      },
      send(payload) {
        this.headersSent = true;
        finish(this.statusCode, payload);
        return this;
      },
      end() {
        this.headersSent = true;
        finish(this.statusCode, null);
        return this;
      },
    };
    try {
      router(req, res, (err) => {
        if (err) return reject(err);
        finish(404, { error: '없는 API입니다.' });
      });
    } catch (err) {
      reject(err);
    }
  });
}
