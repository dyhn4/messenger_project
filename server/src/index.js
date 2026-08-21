import cors from 'cors';
import express from 'express';
import { createServer } from 'node:https';
import os from 'node:os';
import { Server } from 'socket.io';
import { createAuthRouter, requireAuth } from './auth.js';
import { certPath, ensureTlsCredentials } from './certs.js';
import { PORT } from './config.js';
import { createRoomsRouter } from './rooms.js';
import { searchRouter } from './search.js';
import { registerSocket } from './socket.js';
import { filesRouter, uploadRouter } from './upload.js';
import { createUsersRouter } from './users.js';

const app = express();
app.use(cors());
app.use(express.json());

const tls = await ensureTlsCredentials();
const httpServer = createServer(tls, app);
const io = new Server(httpServer, { cors: { origin: '*' } });

app.use('/auth', createAuthRouter(io));
app.use('/api', requireAuth, uploadRouter);
app.use('/api', requireAuth, createUsersRouter(io));
app.use('/api', requireAuth, createRoomsRouter(io));
app.use('/api', requireAuth, searchRouter);
// 업로드 파일은 고정된 공개 경로로 서빙하지 않는다 — filesRouter가 짧게 만료되는
// 서명 링크(/files/<token>)로만 내려준다(upload.js의 signFileUrl 참고).
app.use(filesRouter);

app.get('/health', (req, res) => res.json({ ok: true }));

registerSocket(io);

httpServer.listen(PORT, () => {
  const lanAddresses = Object.values(os.networkInterfaces())
    .flat()
    .filter((i) => i && i.family === 'IPv4' && !i.internal)
    .map((i) => i.address);

  console.log(`메신저 서버 실행 중 (HTTPS, 포트 ${PORT})`);
  console.log('같은 와이파이의 다른 기기에서 접속할 주소:');
  for (const addr of lanAddresses) console.log(`  https://${addr}:${PORT}`);
  console.log(`TLS 인증서(자체 서명): ${certPath}`);
  console.log('클라이언트 앱은 이 인증서를 신뢰하도록 빌드돼 있어야 접속됩니다 (client/assets/server_cert.pem).');
});
