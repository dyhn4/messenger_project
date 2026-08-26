import cors from 'cors';
import express from 'express';
import { createServer } from 'node:https';
import os from 'node:os';
import readline from 'node:readline';
import { Server } from 'socket.io';
import { createAuthRouter, requireAuth } from './auth.js';
import { certPath, ensureTlsCredentials } from './certs.js';
import { PAIRING_PORT, PORT } from './config.js';
import { createCommentsRouter } from './comments.js';
import { createMessagesRouter } from './messages.js';
import { generatePairingCode, startPairingServer } from './pairing.js';
import { startRetentionJob } from './retention.js';
import { createRoomsRouter } from './rooms.js';
import { searchRouter } from './search.js';
import { registerSocket } from './socket.js';
import { filesRouter, uploadRouter } from './upload.js';
import { createUsersRouter } from './users.js';
import { versionRouter } from './version.js';

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
app.use('/api', requireAuth, createMessagesRouter(io));
app.use('/api', requireAuth, createCommentsRouter(io));
app.use('/api', requireAuth, searchRouter);
// 업로드 파일은 고정된 공개 경로로 서빙하지 않는다 — filesRouter가 짧게 만료되는
// 서명 링크(/files/<token>)로만 내려준다(upload.js의 signFileUrl 참고).
app.use(filesRouter);

app.get('/health', (req, res) => res.json({ ok: true }));
// 로그인 여부와 무관하게 앱 시작 직후 확인해야 하므로 인증 없이 공개(version.js 참고).
app.use(versionRouter);

registerSocket(io);
startRetentionJob();

httpServer.listen(PORT, () => {
  const lanAddresses = Object.values(os.networkInterfaces())
    .flat()
    .filter((i) => i && i.family === 'IPv4' && !i.internal)
    .map((i) => i.address);

  console.log(`메신저 서버 실행 중 (HTTPS, 포트 ${PORT})`);
  console.log('같은 와이파이의 다른 기기에서 접속할 주소:');
  for (const addr of lanAddresses) console.log(`  https://${addr}:${PORT}`);
  console.log(`TLS 인증서(자체 서명): ${certPath}`);
  console.log('클라이언트 앱의 "서버 주소 변경"에서 페어링 코드로 이 인증서를 받아 연결할 수 있습니다.');
  console.log('새 기기를 연결하려면 이 콘솔에 "pair"를 입력하고 Enter 하세요(pm2 등으로 띄웠다면 같은 PC에서 "npm run pair").');
});

startPairingServer({ port: PAIRING_PORT, getCertPem: () => tls.cert });

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', (line) => {
  if (line.trim() !== 'pair') return;
  const { code, expiresInMs } = generatePairingCode();
  console.log(`[pairing] 새 기기 연결 코드: ${code} (유효시간 ${Math.round(expiresInMs / 1000)}초, 1회용)`);
});
