import http from 'node:http';

/**
 * 화상회의 신호(LiveKit WebSocket /rtc, 실패 시 확인용 HTTP /rtc/validate)를 메인 HTTPS 포트의
 * /livekit/ 아래로 받아서 같은 PC의 LiveKit(평문, LIVEKIT_PORT)으로 넘긴다.
 *
 * 예전에는 클라이언트가 ws://<서버>:7880으로 LiveKit에 직접 붙었다. 그러면 ①사내망 밖에서 쓰려면
 * 7880도 공유기에서 열어야 하고 ②참가 토큰이 든 신호가 평문으로 인터넷을 지난다. 여기로 받으면
 * 공유기에는 메인 포트 하나만 열면 되고, 신호는 앱이 핀닝한 이 서버 인증서의 TLS로 보호된다
 * (앱의 LiveKit SDK도 dart:io HttpClient를 쓰므로 PinnedTls의 전역 HttpOverrides가 그대로 걸린다).
 * 미디어(UDP/TCP ICE)는 여기를 거치지 않고 클라이언트↔LiveKit이 직접 주고받는다(livekitNat.js).
 */
export const LIVEKIT_PROXY_PREFIX = '/livekit';

function rawHeaderLines(rawHeaders) {
  const lines = [];
  for (let i = 0; i < rawHeaders.length; i += 2) lines.push(`${rawHeaders[i]}: ${rawHeaders[i + 1]}`);
  return lines;
}

/** 실제 접속한 클라이언트 IP를 LiveKit 로그에 남기도록 X-Forwarded-For를 붙인다. */
function forwardedHeaders(req, port) {
  const prior = req.headers['x-forwarded-for'];
  const client = req.socket.remoteAddress ?? '';
  return {
    ...req.headers,
    host: `127.0.0.1:${port}`,
    'x-forwarded-for': prior ? `${prior}, ${client}` : client,
    'x-forwarded-proto': 'https',
  };
}

/**
 * /livekit 아래 일반 HTTP 요청(/rtc/validate 등)을 넘기는 미들웨어. 본문을 그대로 흘려보내야 해서
 * express.json()보다 먼저 app.use(LIVEKIT_PROXY_PREFIX, ...)로 붙인다.
 */
export function livekitHttpProxy(port) {
  return (req, res) => {
    const upstream = http.request(
      { host: '127.0.0.1', port, method: req.method, path: req.url, headers: forwardedHeaders(req, port) },
      (upRes) => {
        res.writeHead(upRes.statusCode ?? 502, upRes.headers);
        upRes.pipe(res);
      },
    );
    upstream.on('error', () => {
      if (!res.headersSent) res.status(502).json({ error: '화상회의 서버에 연결할 수 없습니다.' });
      else res.end();
    });
    req.pipe(upstream);
  };
}

/**
 * [server]의 WebSocket 업그레이드 중 /livekit/ 경로만 LiveKit으로 넘긴다. socket.io도 같은 server의
 * 'upgrade'를 듣지만 자기 경로(/socket.io/)만 처리한다.
 */
export function attachLivekitUpgradeProxy(server, port) {
  server.on('upgrade', (req, socket, head) => {
    if (!req.url?.startsWith(`${LIVEKIT_PROXY_PREFIX}/`)) return;
    const upstream = http.request({
      host: '127.0.0.1',
      port,
      method: 'GET',
      path: req.url.slice(LIVEKIT_PROXY_PREFIX.length),
      headers: forwardedHeaders(req, port),
    });

    upstream.on('upgrade', (upRes, upSocket, upHead) => {
      socket.write(
        [`HTTP/1.1 ${upRes.statusCode} ${upRes.statusMessage}`, ...rawHeaderLines(upRes.rawHeaders), '', ''].join('\r\n'),
      );
      if (upHead?.length) socket.write(upHead);
      if (head?.length) upSocket.write(head);
      upSocket.on('error', () => socket.destroy());
      socket.on('error', () => upSocket.destroy());
      upSocket.on('close', () => socket.destroy());
      socket.on('close', () => upSocket.destroy());
      upSocket.pipe(socket);
      socket.pipe(upSocket);
    });

    // 업그레이드 대신 일반 응답(토큰 거부 401 등)이 오면 그대로 돌려주고 닫는다.
    upstream.on('response', (upRes) => {
      socket.write(
        [`HTTP/1.1 ${upRes.statusCode} ${upRes.statusMessage}`, ...rawHeaderLines(upRes.rawHeaders), '', ''].join('\r\n'),
      );
      upRes.pipe(socket);
    });

    upstream.on('error', () => {
      socket.end('HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
    });
    socket.on('error', () => upstream.destroy());
    upstream.end();
  });
}
