// 다른 어떤 로컬 모듈보다 먼저 .env를 읽어야 한다 — 지금까지는 auth.js가 (db 모듈보다 먼저)
// config.js를 import하는 순서 덕에 어쩌다 보니 되고 있었을 뿐이었다. attachments.js가
// 알파벳 순으로 auth.js보다 먼저 들어오면서 db/client.js(process.env.DATABASE_URL을 즉시
// 읽음)가 config.js보다 먼저 실행돼 "DATABASE_URL이 설정되어 있지 않습니다" 오류가 났다 —
// 로컬 import 순서에 우연히 기대지 않도록 여기서 명시적으로 제일 먼저 로드한다.
import 'dotenv/config';

import cors from 'cors';
import express from 'express';
// Express 4는 async 라우트 핸들러 안에서 던져진 예외/거부된 Promise를 자동으로 next(err)로
// 넘겨주지 않는다(Express 5부터 해결됨) — 그래서 지금까지는 그런 에러가 나면 요청이 응답
// 없이 그대로 멈춰버렸다(클라이언트는 응답을 기다리다 타임아웃). 이 패키지가 Router의
// get/post/patch/delete를 감싸서, async 핸들러가 던지거나 reject한 에러를 자동으로
// next(err)로 넘겨준다 — 아래 에러 처리 미들웨어가 그걸 받아 깔끔한 JSON 에러로 바로
// 응답한다(요청이 실패하는 건 똑같지만, 몇십 초 멈춰 있다가 "요청 시간 초과"로 끝나는 대신
// 즉시 실제 원인이 담긴 메시지로 끝난다).
import 'express-async-errors';
import { createServer } from 'node:https';
import os from 'node:os';
import readline from 'node:readline';
import { Server } from 'socket.io';
import { attachmentsRouter } from './attachments.js';
import { linksRouter } from './links.js';
import { createStickersRouter } from './stickers.js';
import { createAuthRouter, requireAuth } from './auth.js';
import { certPath, ensureTlsCredentials } from './certs.js';
import { PAIRING_PORT, PORT } from './config.js';
import { createCallsRouter } from './calls.js';
import { createCommentsRouter } from './comments.js';
import { createDevicesRouter } from './devices.js';
import { createInvitesRouter } from './invites.js';
import { createTeamInvitesRouter } from './teamInvites.js';
import { createMessagesRouter } from './messages.js';
import { checkPendingMigrations } from './migrationCheck.js';
import { generatePairingCode, startPairingServer } from './pairing.js';
import { startRetentionJob } from './retention.js';
import { createAdminRouter } from './admin.js';
import { createAnnouncementsRouter } from './announcements.js';
import { createInquiriesRouter } from './inquiries.js';
import { createProjectsRouter } from './projects.js';
import { createRoomsRouter } from './rooms.js';
import { createScheduledMessagesRouter, startScheduledMessageJob } from './scheduledMessages.js';
import { createSecretChatsRouter } from './secretChats.js';
import { startSecretExpiryJob } from './secretExpiry.js';
import { startAnnouncementAutoUnpinJob } from './announcementAutoUnpin.js';
import { startProjectDueReminderJob } from './projectNotify.js';
import { searchRouter } from './search.js';
import { createTeamsRouter } from './teams.js';
import { registerSocket } from './socket.js';
import { filesRouter, uploadErrorHandler, uploadRouter } from './upload.js';
import { createUsersRouter } from './users.js';
import { guideStatic, helpApiRouter, versionRouter, watchForVersionChanges } from './version.js';
import { firebaseConfigRouter } from './push.js';

// 위 express-async-errors 덕에 라우트 안에서 난 에러는 이제 거의 다 아래 에러 처리
// 미들웨어로 잡힌다. 이건 그 바깥(소켓 이벤트 핸들러, 백그라운드 작업 등 요청/응답 주기
// 밖)에서 난 에러를 위한 마지막 방어선이다 — 그대로 두면 처리되지 않은 예외/Promise 거부로
// Node 프로세스 전체가 죽는다(실제로 비밀 대화 거절 후 dmKey unique 제약 위반으로 이 문제가
// 발생해 서버 전체가 다운됐었다 — 근본 원인은 secretChats.js에서 고쳤다). 로그만 남기고
// 서버 프로세스는 계속 띄워둔다.
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
app.use('/api', requireAuth, createAnnouncementsRouter(io));
app.use('/api', requireAuth, createInquiriesRouter(io));
app.use('/api', requireAuth, createProjectsRouter(io));
app.use('/api', requireAuth, createMessagesRouter(io));
// 메시지 예약 발송 — 만든 사람만 보고 고친다. 실제 발송은 아래 startScheduledMessageJob이 한다.
app.use('/api', requireAuth, createScheduledMessagesRouter(io));
app.use('/api', requireAuth, createCommentsRouter(io));
app.use('/api', requireAuth, createDevicesRouter());
// 화상회의(LiveKit) 참가 토큰 — LiveKit 비밀값이 없으면 라우트가 503으로 알려준다(calls.js).
app.use('/api', requireAuth, createCallsRouter());
app.use('/api', requireAuth, createSecretChatsRouter(io));
app.use('/api', requireAuth, searchRouter);
app.use('/api', requireAuth, attachmentsRouter);
app.use('/api', requireAuth, linksRouter);
app.use('/api', requireAuth, createStickersRouter());
// "메신저 설명서"(관리자 이상) 열람용 5분짜리 링크 발급 — 권한은 라우터 안에서 확인(version.js).
app.use('/api', requireAuth, helpApiRouter);
// 업로드 파일은 고정된 공개 경로로 서빙하지 않는다 — filesRouter가 짧게 만료되는
// 서명 링크(/files/<token>)로만 내려준다(upload.js의 signFileUrl 참고).
app.use(filesRouter);

app.get('/health', (req, res) => res.json({ ok: true }));
// 로그인 여부와 무관하게 앱 시작 직후 확인해야 하므로 인증 없이 공개(version.js 참고).
app.use(versionRouter);
// 초보자용 도움말(server/guide/ 정적 페이지) — 모든 회원이 보는 공개 문서라 인증 없이(version.js).
app.use('/guide', guideStatic);
// FCM 클라이언트 초기화 값 — 비밀값이 아니라 인증 없이 공개한다(push.js 참고).
app.use(firebaseConfigRouter);

// 모든 라우트 다음에 두는 공통 에러 처리 — express-async-errors 덕에 라우트 안에서 던진/
// reject한 에러가 여기로 온다. 이게 없던 동안에는 그런 요청이 응답 없이 그대로 멈춰서
// 클라이언트가 몇십 초 뒤 "요청 시간 초과"로만 보게 됐다(예: DB 마이그레이션이 아직
// 안 된 서버에서 새 테이블을 조회하는 라우트를 치면 — 실제로 이 증상으로 발견됨). 이제는
// 그 자리에서 바로 500 + 에러 메시지로 응답한다.
app.use((err, req, res, next) => {
  if (res.headersSent) return next(err);
  console.error(`[요청 처리 오류] ${req.method} ${req.originalUrl}:`, err);
  // drizzle-orm의 DrizzleQueryError는 진짜 원인(예: Postgres의 "릴레이션이 없습니다")을
  // err.message가 아니라 err.cause에 담아둔다 — err.message만 보내면 "Failed query: ..."
  // 라는 SQL문만 보이고 정작 왜 실패했는지는 안 보인다. 콘솔을 못 보는 상황(운영 서버 등)
  // 에서도 화면 메시지만으로 원인을 알 수 있도록 cause도 같이 붙여 보낸다.
  const detail = err?.cause?.message ? ` — ${err.cause.message}` : '';
  res.status(500).json({ error: (err?.message || '서버 오류가 발생했습니다.') + detail });
});

registerSocket(io);
watchForVersionChanges(io);
startRetentionJob();
startSecretExpiryJob(io);
startAnnouncementAutoUnpinJob(io);
startProjectDueReminderJob(io);
startScheduledMessageJob(io);

// 코드가 기대하는 스키마와 DB가 어긋난 채로 뜨면, 서버는 멀쩡해 보이는데 새 컬럼을 읽는
// 화면만 조용히 비어 보인다 — 뜨기 전에 확인해서 콘솔에 크게 알린다(막지는 않는다).
await checkPendingMigrations();

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
