// 다른 어떤 로컬 모듈보다 먼저 .env를 읽어야 한다 — 지금까지는 auth.js가 (db 모듈보다 먼저)
// config.js를 import하는 순서 덕에 어쩌다 보니 되고 있었을 뿐이었다. attachments.js가
// 알파벳 순으로 auth.js보다 먼저 들어오면서 db/client.js(process.env.DATABASE_URL을 즉시
// 읽음)가 config.js보다 먼저 실행돼 "DATABASE_URL이 설정되어 있지 않습니다" 오류가 났다 —
// 로컬 import 순서에 우연히 기대지 않도록 여기서 명시적으로 제일 먼저 로드한다.
import 'dotenv/config';

import cors from 'cors';
import express from 'express';
import { createServer } from 'node:https';
import os from 'node:os';
import readline from 'node:readline';
import { Server } from 'socket.io';
import { attachmentsRouter } from './attachments.js';
import { createAuthRouter, requireAuth } from './auth.js';
import { certPath, ensureTlsCredentials } from './certs.js';
import { PAIRING_PORT, PORT } from './config.js';
import { createCommentsRouter } from './comments.js';
import { createDevicesRouter } from './devices.js';
import { createInvitesRouter } from './invites.js';
import { createTeamInvitesRouter } from './teamInvites.js';
import { createMessagesRouter } from './messages.js';
import { generatePairingCode, startPairingServer } from './pairing.js';
import { startRetentionJob } from './retention.js';
import { createAdminRouter } from './admin.js';
import { createRoomsRouter } from './rooms.js';
import { createSecretChatsRouter } from './secretChats.js';
import { startSecretExpiryJob } from './secretExpiry.js';
import { searchRouter } from './search.js';
import { createTeamsRouter } from './teams.js';
import { registerSocket } from './socket.js';
import { filesRouter, uploadErrorHandler, uploadRouter } from './upload.js';
import { createUsersRouter } from './users.js';
import { versionRouter } from './version.js';

// Express 4는 async 라우트 핸들러 안에서 던져진 예외/거부된 Promise를 자동으로 잡아주지
// 않는다 — 그대로 두면 처리되지 않은 Promise 거부가 되어 Node 프로세스 전체가 죽는다
// (실제로 비밀 대화 거절 후 dmKey unique 제약 위반으로 이 문제가 발생해 서버 전체가
// 다운됐었다). 근본 원인(secretChats.js)은 고쳤지만, 앞으로 어떤 라우터에서든 예상 못한
// DB 오류 하나가 전체 서비스를 끊는 일이 없도록 마지막 방어선을 둔다 — 요청 하나는
// 실패하더라도(클라이언트가 타임아웃/에러로 보게 됨) 서버 자체는 계속 떠 있게 한다.
process.on('unhandledRejection', (reason) => {
  console.error('[unhandledRejection]', reason);
});
process.on('uncaughtException', (err) => {
  console.error('[uncaughtException]', err);
});

const app = express();
app.use(cors());
app.use(express.json());

const tls = await ensureTlsCredentials();
const httpServer = createServer(tls, app);
const io = new Server(httpServer, { cors: { origin: '*' } });

app.use('/auth', createAuthRouter(io));
app.use('/api', requireAuth, uploadRouter);
app.use('/api', uploadErrorHandler);
app.use('/api', requireAuth, createUsersRouter(io));
// 서버 운영자 전용(관리자 콘솔) — 라우터 안에서 isServerAdmin을 다시 확인한다.
app.use('/api', requireAuth, createAdminRouter(io));
app.use('/api', requireAuth, createTeamsRouter(io));
app.use('/api', requireAuth, createInvitesRouter());
app.use('/api', requireAuth, createTeamInvitesRouter());
app.use('/api', requireAuth, createRoomsRouter(io));
app.use('/api', requireAuth, createMessagesRouter(io));
app.use('/api', requireAuth, createCommentsRouter(io));
app.use('/api', requireAuth, createDevicesRouter());
app.use('/api', requireAuth, createSecretChatsRouter(io));
app.use('/api', requireAuth, searchRouter);
app.use('/api', requireAuth, attachmentsRouter);
// 업로드 파일은 고정된 공개 경로로 서빙하지 않는다 — filesRouter가 짧게 만료되는
// 서명 링크(/files/<token>)로만 내려준다(upload.js의 signFileUrl 참고).
app.use(filesRouter);

app.get('/health', (req, res) => res.json({ ok: true }));
// 로그인 여부와 무관하게 앱 시작 직후 확인해야 하므로 인증 없이 공개(version.js 참고).
app.use(versionRouter);

registerSocket(io);
startRetentionJob();
startSecretExpiryJob(io);

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

startPairingServer({ port: PAIRING_PORT, mainPort: PORT, getCertPem: () => tls.cert });

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', (line) => {
  if (line.trim() !== 'pair') return;
  const { code, expiresInMs } = generatePairingCode();
  console.log(`[pairing] 새 기기 연결 코드: ${code} (유효시간 ${Math.round(expiresInMs / 1000)}초, 1회용)`);
});
