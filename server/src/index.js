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
import { randomUUID } from 'node:crypto';
import { createServer } from 'node:https';
import os from 'node:os';
import readline from 'node:readline';
import { Server } from 'socket.io';
import { attachmentsRouter } from './attachments.js';
import { linksRouter } from './links.js';
import { createStickersRouter } from './stickers.js';
import { createAuthRouter, hasValidAccessToken, requireAuth } from './auth.js';
import { createLoginSecurityRouter } from './loginSecurity.js';
import { loginMethodsView } from './loginSecurityRules.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { createSsoRouter, ssoRedirectUri } from './sso.js';
import { createIntegrationsRouter, webhookReceiveRoute } from './integrations.js';
import { createOAuthPublicRouter, createOAuthRouter } from './oauth.js';
import { createWebauthnRouter } from './webauthn.js';
import { startWebhookDeliveryJob } from './webhookDelivery.js';
import { backfillOrgTrees, createOrgTreeRouter } from './orgTree.js';
import { createPublicApiRouter } from './publicApi.js';
import { clientIp, isLanAddress, limits, rateLimit } from './authGuard.js';
import { bodyErrorReply, createJsonBodyParser } from './bodyLimit.js';
import { certPath, certsDir, ensureTlsCredentials, lanAddressesInCert } from './certs.js';
import {
  ACME_EMAIL,
  ACME_HTTP_PORT,
  ACME_STAGING,
  EXTERNAL_ADDRESS,
  LIVEKIT_PORT,
  LIVEKIT_URL,
  PAIRING_PORT,
  PORT,
  WEB_DIR,
  WEB_DOMAIN,
  WEB_HTTPS_PORT,
  WEB_TLS_CONFIG_ERROR,
} from './config.js';
import { startLivekitNatSync } from './livekitNat.js';
import { LIVEKIT_PROXY_PREFIX, attachLivekitUpgradeProxy, livekitHttpProxy } from './livekitProxy.js';
import { createBookmarksRouter } from './bookmarks.js';
import { closeStaleCallCards } from './callCards.js';
import { callsEnabled, createCallsRouter } from './calls.js';
import { createCallRecordingRouter, resumeCallRecordings } from './callRecording.js';
import { createCalendarsRouter } from './calendars.js';
import { createCommentsRouter } from './comments.js';
import { createFavoritesRouter } from './favorites.js';
import { createMyPostsRouter } from './myPosts.js';
import { createDevicesRouter } from './devices.js';
import { createInvitesRouter } from './invites.js';
import { createTeamInvitesRouter } from './teamInvites.js';
import { createMessagesRouter } from './messages.js';
import { createReactionsRouter } from './reactions.js';
import { createRemindersRouter, startReminderJob } from './reminders.js';
import { createExternalCalendarsRouter, startExternalCalendarJob } from './externalCalendars.js';
import { calendarFeedHandler, createCalendarFeedsRouter } from './calendarFeeds.js';
import { createMessageFilesRouter } from './messageFiles.js';
import { SOCKET_MAX_PAYLOAD_BYTES } from './messageLimits.js';
import { createNotificationsRouter } from './notifications.js';
import { checkPendingMigrations } from './migrationCheck.js';
import { createPairHandler, generatePairingCode, startPairingServer } from './pairing.js';
import { startRetentionJob } from './retention.js';
import { ddnsUpdater } from './ddnsService.js';
import { backupScheduler } from './backupService.js';
import { createAdminRouter } from './admin.js';
import { createAlbumsRouter } from './albums.js';
import { createAnnouncementsRouter } from './announcements.js';
import { createInquiriesRouter } from './inquiries.js';
import { createPollsRouter } from './polls.js';
import { createProjectsRouter } from './projects.js';
import { createRoomsRouter } from './rooms.js';
import { createScheduledMessagesRouter, startScheduledMessageJob } from './scheduledMessages.js';
import { createSecretChatsRouter } from './secretChats.js';
import { startSecretExpiryJob } from './secretExpiry.js';
import { startAnnouncementAutoUnpinJob } from './announcementAutoUnpin.js';
import { startProjectDueReminderJob } from './projectNotify.js';
import { searchRouter } from './search.js';
import { createTeamsRouter, sweepLeftoverTeamRoomMembers } from './teams.js';
import { createTodosRouter, startTodoReminderJob } from './todos.js';
import { registerSocket } from './socket.js';
import { filesRouter, uploadErrorHandler, uploadRouter } from './upload.js';
import { createFileResignRouter } from './fileResign.js';
import { createUsersRouter } from './users.js';
import { guideStatic, versionRouter, watchForVersionChanges } from './version.js';
import { firebaseConfigRouter } from './push.js';
import { webPushRouter } from './webPush.js';
import { getWebPublicUrl } from './webAddress.js';
import { isMailEnabled } from './mailer.js';
import { createGroupwareRouter } from './groupware.js';
import { startMentionDigestJob } from './mentionDigest.js';
import { createGroupwareWorkRouter, startAttendanceReminderJob } from './groupwareWork.js';
import { createGroupwareResourcesRouter, startBookingReminderJob } from './groupwareResources.js';
import { createRoomDisplayRouter } from './roomDisplay.js';
import { createGroupwareSurveysRouter } from './groupwareSurveys.js';
import { createGroupwareReportsRouter } from './groupwareReports.js';
import { createPayrollRouter } from './payroll.js';
import { createCardFeedRouter, createCorporateCardsRouter } from './corporateCards.js';
import { createDriveRouter } from './drive.js';
import { createWikiRouter, wikiDocs } from './wiki.js';
import { createWebmailRouter, startMailCheckJob } from './webmail.js';
import { startLocalMailServer } from './localMailServer.js';
import { createDraftsRouter, startDraftCleanupJob } from './drafts.js';
import { createBoardExtrasRouter } from './boardExtras.js';
import { startWebTls } from './webTls.js';

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
// 위키 동시 편집 문서는 마지막 연산 뒤 몇 초 지나 저장한다(wikiDocs.js) — 서버를 끌 때(pm2 restart·Ctrl+C) 그 몇 초를 잃지 않게
// 열린 문서를 저장하고 끈다. 저장이 오래 걸려도 3초 뒤에는 끈다.
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.once(signal, () => {
    setTimeout(() => process.exit(0), 3000).unref();
    wikiDocs
      .flushAll()
      .catch((err) => console.error('[wiki] 끌 때 저장 실패:', err?.message ?? err))
      .finally(() => process.exit(0));
  });
}

const app = express();
// 기본 보안 헤더 — 인터넷에 열리면서 붙였다. Express 이름을 숨기고, 형식 추측을 막고, 다른 사이트가 이 서버의
// 페이지(웹 앱·도움말)를 몰래 iframe에 띄워 누르게 만드는 것(클릭재킹)을 막고, 링크를 눌러 나갈 때 주소(서명된
// 파일 링크 등)가 상대 사이트에 넘어가지 않게 한다. 웹 앱 전용 CSP는 아래 express.static(WEB_DIR)에서 붙인다.
app.disable('x-powered-by');
app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'no-referrer');
  next();
});
// 다른 사이트(출처)의 브라우저 스크립트가 이 API를 부르는 건 막는다 — 앱(PC·안드로이드)은 출처 개념이 없고, 웹 앱은 같은
// 주소에서 내려받으니 CORS가 필요 없다. 개발 중 `flutter run -d chrome`(localhost의 다른 포트)만 열어 둔다.
const corsOptions = {
  origin: (origin, callback) => callback(null, !origin || /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin)),
};
app.use(cors(corsOptions));
// 화상회의 신호를 같은 PC의 LiveKit으로 넘긴다(livekitProxy.js) — 본문을 그대로 흘려야 해서 json 파서보다 먼저.
app.use(LIVEKIT_PROXY_PREFIX, livekitHttpProxy(LIVEKIT_PORT));
// JSON 본문 — 로그인한 요청은 정상 앱이 보내는 가장 큰 글(비밀 대화 봉투·서식이 붙은 긴 글 수정)이 들어가는 512KiB까지, 토큰 없는
// 요청(로그인·가입 등 인증 전 경로)은 기본 100KB 그대로(bodyLimit.js). 업로드(multipart — multer)는 이 파서가 건드리지 않는다.
app.use(createJsonBodyParser({ isSignedIn: hasValidAccessToken }));

const tls = await ensureTlsCredentials({ extraHosts: EXTERNAL_ADDRESS ? [EXTERNAL_ADDRESS.host] : [] });
const httpServer = createServer(tls, app);
// 소켓 한 번에 받는 크기 — 기본 1MB 대신 정상 앱이 보내는 가장 큰 메시지(비밀 대화 봉투·최대 길이 글)에 여유를 둔 값(messageLimits.js).
const io = new Server(httpServer, { cors: corsOptions, maxHttpBufferSize: SOCKET_MAX_PAYLOAD_BYTES });
attachLivekitUpgradeProxy(httpServer, LIVEKIT_PORT);
// 사내망 밖(LTE/5G)에서도 재페어링할 수 있게 메인 HTTPS 포트에도 페어링을 연다(pairing.js의 createPairHandler).
// 밖에서도 닿으므로 IP마다 시도 횟수를 제한한다(authGuard.js — 4자리 코드 맞혀보기 방지).
app.get('/pair/:code', rateLimit(limits.pairIp, '페어링 시도'), createPairHandler(() => tls.cert));
// 외부 주소가 있으면 LiveKit이 공인 IP도 알리게 livekit.yaml을 맞춘다(livekitNat.js).
const livekitMediaPorts = await startLivekitNatSync({ externalAddress: EXTERNAL_ADDRESS, enabled: callsEnabled() && !LIVEKIT_URL });

app.use('/auth', createAuthRouter(io));
// 2단계 인증(OTP)과 회사 계정 로그인(SSO) — 로그인 전에도 부르는 경로라 /auth 아래(각 경로가 필요하면 토큰을 직접 본다).
app.use('/auth', createLoginSecurityRouter());
app.use('/auth', createSsoRouter({ io }));
// 하드웨어 보안 키·패스키(WebAuthn — 웹 앱 주소의 페이지에서 등록·로그인·둘째 단계, webauthn.js).
app.use('/auth', createWebauthnRouter());
// 공개 API(개인 API 토큰·OAuth 토큰·봇 토큰 — publicApi.js) — 앱 토큰(requireAuth)이 아니라 API 토큰으로 열어서 아래 /api 묶음보다 먼저 건다.
// 법인카드 연동(ttc_ 연동 키 — corporateCards.js) — 공개 API의 토큰 확인보다 먼저.
app.use('/api/v1/corporate-cards', createCardFeedRouter(io));
app.use('/api/v1', createPublicApiRouter(io));
// OAuth 앱 — 승인 페이지(/oauth/authorize)·결과 묻기·토큰 받기는 로그인 없이(oauth.js — 사람은 앱에서 코드를 넣어 승인한다).
app.use(createOAuthPublicRouter());
// 회의실 앞 태블릿 화면(roomDisplay.js) — 로그인 없이 자원마다의 비밀 주소로 연다.
app.use(createRoomDisplayRouter(io));
app.use('/api', requireAuth, uploadRouter);
app.use('/api', uploadErrorHandler);
app.use('/api', requireAuth, createFileResignRouter());
app.use('/api', requireAuth, createUsersRouter(io));
// 서버 운영자 전용(관리자 콘솔) — 라우터 안에서 isServerAdmin을 다시 확인한다.
app.use('/api', requireAuth, createAdminRouter(io));
app.use('/api', requireAuth, createTeamsRouter(io));
app.use('/api', requireAuth, createInvitesRouter());
app.use('/api', requireAuth, createTeamInvitesRouter());
app.use('/api', requireAuth, createRoomsRouter(io));
app.use('/api', requireAuth, createAnnouncementsRouter(io));
app.use('/api', requireAuth, createInquiriesRouter(io));
// 그룹웨어 — 전자결재(휴가·지출·근태 수정)·법정 연차·출퇴근 기록(groupware.js).
app.use('/api', requireAuth, createGroupwareRouter(io));
// 그룹웨어 근태·휴가 관리 — 범위 설정(휴가 종류·지출 분류·출근 알림)·유연근무·주 52시간·연차 사용 촉진(groupwareWork.js).
app.use('/api', requireAuth, createGroupwareWorkRouter(io));
app.use('/api', requireAuth, createGroupwareResourcesRouter(io));
// 그룹웨어 설문(여러 문항)과 업무일지(일일·주간 업무보고 — 상위자가 읽고 댓글).
app.use('/api', requireAuth, createGroupwareSurveysRouter(io));
app.use('/api', requireAuth, createGroupwareReportsRouter(io));
// 급여명세서(payroll.js)·법인카드와 영수증 읽기(corporateCards.js).
app.use('/api', requireAuth, createPayrollRouter(io));
app.use('/api', requireAuth, createCorporateCardsRouter(io));
// 팀 공유 드라이브 — 폴더·파일 판·휴지통(drive.js).
app.use('/api', requireAuth, createDriveRouter(io));
// 팀 위키 — 페이지 나무·판·휴지통(wiki.js). 동시 편집은 소켓(wiki:* — socket.js가 registerWikiSocket을 붙인다).
app.use('/api', requireAuth, createWikiRouter(io));
app.use('/api', requireAuth, createWebmailRouter(io));
app.use('/api', requireAuth, createDraftsRouter(io));
app.use('/api', requireAuth, createBoardExtrasRouter(io));
app.use('/api', requireAuth, createProjectsRouter(io));
app.use('/api', requireAuth, createMessagesRouter(io));
// 메시지 공감(이모지 반응) — PUT /messages/:id/reaction(reactions.js).
app.use('/api', requireAuth, createReactionsRouter(io));
// 메시지 리마인더("나중에 알림") — POST /messages/:id/reminders, GET/DELETE /reminders(reminders.js).
app.use('/api', requireAuth, createRemindersRouter(io));
// 파일 삭제(업로드한 본인·팀 관리자) — 소프트 삭제라 댓글은 남는다(messageFiles.js).
app.use('/api', requireAuth, createMessageFilesRouter(io));
// 투표 — 만들기(방 메시지)·투표하기·마감·즐겨찾기. 소켓 message:send로는 못 만든다(polls.js).
app.use('/api', requireAuth, createPollsRouter(io));
// 앨범 — 대화방 안에서 이미지·영상을 주제별로 모으는 공간(만들기·항목 추가/삭제·공유). albums.js.
app.use('/api', requireAuth, createAlbumsRouter(io));
// 메시지 예약 발송 — 만든 사람만 보고 고친다. 실제 발송은 아래 startScheduledMessageJob이 한다.
app.use('/api', requireAuth, createScheduledMessagesRouter(io));
app.use('/api', requireAuth, createCommentsRouter(io));
app.use('/api', requireAuth, createFavoritesRouter(io));
// 내가 쓴 글 모아보기(내가 보낸 메시지·댓글) — myPosts.js.
app.use('/api', requireAuth, createMyPostsRouter());
// 북마크(팀/개인, 순서 변경, 링크 정보 가져오기) — bookmarks.js.
app.use('/api', requireAuth, createBookmarksRouter(io));
// 알림 센터(멘션·보드 알림 기록, 읽음, 알림 설정) — notifications.js.
app.use('/api', requireAuth, createNotificationsRouter(io));
// 캘린더(기본/팀/공유 캘린더, 일정, 반복, 공휴일·생일) — 권한은 calendars.js의 calendarAccess 한 곳에서 계산한다.
app.use('/api', requireAuth, createCalendarsRouter(io));
// 외부 캘린더 연동 — ICS 주소 구독(가져오기, externalCalendars.js)과 내 일정 ICS 구독 주소(내보내기, calendarFeeds.js).
app.use('/api', requireAuth, createExternalCalendarsRouter(io));
app.use('/api', requireAuth, createCalendarFeedsRouter());
// 할 일(To-Do) — 대화방에 딸린 가벼운 할 일(담당자·기한·첨부·알림 일정). 프로젝트 업무와는 별개(todos.js).
app.use('/api', requireAuth, createTodosRouter(io));
app.use('/api', requireAuth, createDevicesRouter(io));
// 외부 연동 — 웹훅(들어오는·나가는)·슬래시 명령·연동 앱·단추 누르기·개인 API 토큰 관리(integrations.js), OAuth 코드 승인·연결된 앱(oauth.js).
app.use('/api', requireAuth, createIntegrationsRouter(io));
app.use('/api', requireAuth, createOAuthRouter());
// 조직도 — 부서 트리·상위자(orgTree.js).
app.use('/api', requireAuth, createOrgTreeRouter(io));
// 화상회의(LiveKit) 참가 토큰 — LiveKit 비밀값이 없으면 라우트가 503으로 알려준다(calls.js).
app.use('/api', requireAuth, createCallsRouter());
// 화상회의 녹화(LiveKit Egress)·자동 회의록 — CALL_RECORDING_DIR이 없으면 시작이 503으로 알려 준다(callRecording.js·callMinutes.js).
app.use('/api', requireAuth, createCallRecordingRouter(io));
app.use('/api', requireAuth, createSecretChatsRouter(io));
app.use('/api', requireAuth, searchRouter);
app.use('/api', requireAuth, attachmentsRouter);
app.use('/api', requireAuth, linksRouter);
app.use('/api', requireAuth, createStickersRouter());
// 업로드 파일은 고정된 공개 경로로 서빙하지 않는다 — filesRouter가 짧게 만료되는
// 서명 링크(/files/<token>)로만 내려준다(upload.js의 signFileUrl 참고).
app.use(filesRouter);

app.get('/health', (req, res) => res.json({ ok: true }));
// 앱이 외부 접속 주소(.env의 EXTERNAL_ADDRESS)와 사내 주소들을 받아 저장해뒀다가, 지금 네트워크에서
// 되는 쪽으로 자동 전환한다(client session.dart) — 사내 주소로 연결해둔 앱은 밖에서 외부 주소로,
// 밖에서 외부 주소로 페어링한 앱은 사내로 돌아오면 사내 주소로. 로그인 전에도 받아야 해서 인증 없이
// 열어둔다 — 인증서 핀닝으로 이 서버가 맞는지는 이미 확인된 연결이다.
// 사내 주소(사설 IP)는 사내에서 묻거나 로그인한 앱이 물을 때만 알려준다 — 인터넷의 아무에게나 사내망 구성을 알려줄
// 필요는 없다(밖에서 로그인한 앱은 토큰을 붙여 묻는다).
// webUrl은 아이폰 등에 안내할 웹 앱 주소(https://WEB_DOMAIN) — 공인 인증서가 실제로 걸려 있을 때만 값이 있다(webTls.js, webAddress.js).
// mailEnabled는 메일(SMTP) 기능이 켜졌는지 — 앱이 가입(이메일 확인 코드)·아이디/비밀번호 찾기 화면을 고르는 데 쓴다(mailer.js).
app.get('/server-info', async (req, res) =>
  res.json({
    externalUrl: EXTERNAL_ADDRESS?.url ?? null,
    webUrl: getWebPublicUrl(),
    internalUrls:
      isLanAddress(clientIp(req)) || hasValidAccessToken(req)
        ? lanAddressesInCert(tls.cert).map((ip) => `https://${ip}:${PORT}`)
        : [],
    mailEnabled: await isMailEnabled().catch(() => false),
    // 로그인 화면에 보일 로그인 방법 — 회사 계정(SSO) 단추·회사 디렉터리(LDAP) 안내. 못 읽으면 아이디 로그인만.
    loginMethods: await getServerSettings()
      .then((s) => loginMethodsView(s, { redirectReady: !!ssoRedirectUri() }))
      .catch(() => ({ sso: [], ldap: false, otpPolicy: 'optional' })),
  }),
);
// 로그인 여부와 무관하게 앱 시작 직후 확인해야 하므로 인증 없이 공개(version.js 참고).
app.use(versionRouter);
// 초보자용 도움말(server/guide/ 정적 페이지) — 모든 회원이 보는 공개 문서라 인증 없이(version.js).
app.use('/guide', guideStatic);
// 내 일정 ICS 구독 주소 — Google·Outlook 캘린더가 로그인 없이 받아 가므로 인증 대신 주소의 긴 비밀 토큰으로 연다(calendarFeeds.js).
app.get('/calendar-feed/:token', rateLimit(limits.calendarFeedIp, '캘린더 피드 요청'), calendarFeedHandler);
// 들어오는 웹훅 — 바깥 서비스(모니터링·CI·설문)가 로그인 없이 보내므로 주소의 비밀 토큰으로 연다(integrations.js). JSON은 위 공통
// 파서가 읽고, 그냥 글(text/plain)과 Slack 옛 방식(form의 payload=), 파일을 함께 올리는 multipart(그림·로그 파일)도 받는다.
app.post(
  '/hooks/:token',
  express.text({ type: 'text/*', limit: '100kb' }),
  express.urlencoded({ extended: false, limit: '100kb' }),
  ...webhookReceiveRoute(io),
);
// FCM 클라이언트 초기화 값 — 비밀값이 아니라 인증 없이 공개한다(push.js 참고).
app.use(firebaseConfigRouter);
// 웹 앱의 웹 푸시 공개키(VAPID) — 브라우저가 구독할 때 쓰는 공개값이라 인증 없이(webPush.js).
app.use(webPushRouter);
// 웹 앱 페이지의 CSP — 스크립트는 이 서버에서 온 파일만(인라인·외부 스크립트 금지) 돌게 해서, 혹시 화면에 남의
// 글이 HTML로 섞여도 스크립트로 실행되지 않게 한다. Flutter 웹이 쓰는 것만 연다: CanvasKit(WebAssembly 컴파일),
// 인라인 스타일, 화면에 없는 글자용 구글 글꼴, 첨부·푸시용 blob:, 화상회의 wss:.
// 그림(img-src)은 이 서버(와 data:·blob:)의 것만 — 서버가 앱에 주는 그림 주소는 모두 이 서버의 서명 링크(/files/…)라서다(링크
// 미리보기·북마크는 서버가 받아 둔 그림만 주고 예전에 저장된 바깥 주소는 내려주지 않는다 — linkPreviewImage.js; 노트 속 바깥 그림은
// 앱이 받지 않고 링크로만 보여 준다). 예전엔 그 바깥 그림을 <img>로 그리려고(external_image.dart의 웹 fallback) https:·http:를 열어
// 둬서, 남이 심은 주소로 보는 사람의 브라우저가 그 사이트에 접속했다(IP·읽은 시각이 남는다). CanvasKit이 그림을 받는 fetch는
// connect-src를 따르는데 거기엔 처음부터 바깥 주소가 글꼴뿐이라, 이 변경으로 막히는 정상 경로는 없다.
const WEB_APP_CSP = [
  "default-src 'self'",
  "script-src 'self' 'wasm-unsafe-eval' blob:",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob:",
  "media-src 'self' data: blob:",
  "font-src 'self' data: https://fonts.gstatic.com",
  "connect-src 'self' data: blob: wss: https://fonts.gstatic.com https://fonts.googleapis.com",
  "worker-src 'self' blob:",
  "object-src 'none'",
  "base-uri 'self'",
  "frame-ancestors 'none'",
].join('; ');
// 웹 앱(Flutter 웹 빌드) — 위의 API 경로들에 걸리지 않은 요청만 여기로 온다. 페이지를 내려준 이
// 서버가 곧 웹 앱의 서버 주소다(client session.dart의 webServerUrl). 폴더가 없으면 404.
app.use(express.static(WEB_DIR, { setHeaders: (res) => res.setHeader('Content-Security-Policy', WEB_APP_CSP) }));

// 모든 라우트 다음에 두는 공통 에러 처리 — express-async-errors 덕에 라우트 안에서 던진/
// reject한 에러가 여기로 온다. 이게 없던 동안에는 그런 요청이 응답 없이 그대로 멈춰서
// 클라이언트가 몇십 초 뒤 "요청 시간 초과"로만 보게 됐다(예: DB 마이그레이션이 아직
// 안 된 서버에서 새 테이블을 조회하는 라우트를 치면 — 실제로 이 증상으로 발견됨). 이제는
// 그 자리에서 바로 500 + 에러 메시지로 응답한다.
app.use((err, req, res, next) => {
  if (res.headersSent) return next(err);
  // 본문을 읽다 난 오류(너무 큼·JSON 형식 오류 등)는 요청 쪽 잘못이라 500 대신 그 상태 코드(413·400 등)와 한국어 문구로 답한다
  // (bodyLimit.js) — 예전엔 "request entity too large" 같은 영어 문구의 500이라 서버 고장처럼 보였다. 서버 오류가 아니니 한 줄만 남긴다.
  const bodyError = bodyErrorReply(err, req, { isSignedIn: hasValidAccessToken });
  if (bodyError) {
    const size = err.type === 'entity.too.large' ? ` (${err.length ?? err.received ?? '?'}바이트, 한도 ${err.limit}바이트)` : '';
    console.warn(`[요청 본문 오류] ${req.method} ${req.originalUrl}: ${err.type}${size} → ${bodyError.status}`);
    return res.status(bodyError.status).json({ error: bodyError.error });
  }
  console.error(`[요청 처리 오류] ${req.method} ${req.originalUrl}:`, err);
  // drizzle-orm의 DrizzleQueryError는 진짜 원인(예: Postgres의 "릴레이션이 없습니다")을
  // err.message가 아니라 err.cause에 담아둔다 — err.message만 보내면 "Failed query: ..."
  // 라는 SQL문만 보이고 정작 왜 실패했는지는 안 보인다. 콘솔을 못 보는 상황(운영 서버 등)
  // 에서도 화면 메시지만으로 원인을 알 수 있도록 cause도 같이 붙여 보낸다.
  //
  // 단, 사내망 밖에서 온 요청에는 DB 오류를 그대로 보여주지 않는다 — "Failed query: <SQL> params: <값>"과
  // Postgres 오류문에 테이블 구조와 데이터가 그대로 실려서, 인터넷의 누구에게나 내부 구조를 알려주게 된다.
  // 그럴 땐 고유 번호만 주고 자세한 내용은 콘솔에만 남긴다(사내에서 보면 지금처럼 다 보인다).
  const isDbError = err?.name === 'DrizzleQueryError' || typeof err?.query === 'string' || !!err?.cause?.code;
  if (isDbError && !isLanAddress(clientIp(req))) {
    const ref = randomUUID().slice(0, 8);
    console.error(`[요청 처리 오류] 참조 번호 ${ref}`);
    return res.status(500).json({ error: `서버 오류가 발생했습니다. (참조 번호 ${ref})` });
  }
  const detail = err?.cause?.message ? ` — ${err.cause.message}` : '';
  res.status(500).json({ error: (err?.message || '서버 오류가 발생했습니다.') + detail });
});

registerSocket(io);
watchForVersionChanges(io);
startRetentionJob();
// 오래 접속하지 않은 사람에게 안 읽은 멘션 요약 메일 — 메일이 켜져 있을 때만 실제로 보낸다(mentionDigest.js).
startMentionDigestJob();
// 출근·퇴근 알림 — 알림을 켠 그룹웨어 범위에서 5분마다(groupwareWork.js).
startAttendanceReminderJob(io);
// 회의실·자원 예약 시작 전 알림(1분마다 — groupwareResources.js).
startBookingReminderJob(io);
startMailCheckJob(io);
// 자체 메일 서버 — 관리자가 켜고 회사 도메인을 넣었을 때만 받는 포트(기본 25)를 연다(localMailServer.js).
startLocalMailServer(io);
startDraftCleanupJob();
// DDNS(DuckDNS) 자동 갱신 — 관리자 콘솔 "DDNS" 탭에서 켰을 때만 5분마다 공인 IP를 알린다(ddns.js).
ddnsUpdater.start().catch(() => {});
startSecretExpiryJob(io);
startAnnouncementAutoUnpinJob(io);
startProjectDueReminderJob(io);
startScheduledMessageJob(io);
startTodoReminderJob(io);
// 나가는 웹훅·연동 앱으로 방의 일 보내기(실패하면 다시 — webhookDelivery.js).
startWebhookDeliveryJob();
// 메시지 리마인더 — 30초마다 울릴 때가 된 것을 "나와의 대화"에 올린다(reminders.js).
startReminderJob(io);
// 외부 캘린더(ICS 구독) — 5분마다 30분이 지난 구독을 다시 받는다(externalCalendars.js).
startExternalCalendarJob(io);

// 코드가 기대하는 스키마와 DB가 어긋난 채로 뜨면, 서버는 멀쩡해 보이는데 새 컬럼을 읽는
// 화면만 조용히 비어 보인다 — 뜨기 전에 확인해서 콘솔에 크게 알린다(막지는 않는다).
await checkPendingMigrations();
// 지난 실행 중에 "진행 중"으로 남은 화상회의 카드를 닫는다(통화 상태는 메모리에만 있어 재시작하면 사라진다 — callCards.js).
await closeStaleCallCards().catch((err) => console.error('[call] 화상회의 카드 정리 실패:', err?.message ?? err));
// 지난 실행 중에 끝내지 못한 녹화(녹화 중·마무리 중)와 회의록을 이어서 마무리한다(callRecording.js).
await resumeCallRecordings(io).catch((err) => console.error('[call] 녹화 이어서 마무리 실패:', err?.message ?? err));
// 팀에서 빠졌는데 그 팀 대화방에 남아 있는 멤버십을 뺀다(예전 규칙의 흔적 — teams.js sweepLeftoverTeamRoomMembers).
// 아직 소켓이 붙기 전이라 DB 정리와 안내 메시지만 남는다.
await sweepLeftoverTeamRoomMembers(io).catch((err) => console.error('[teams] 팀 밖 대화방 멤버십 정리 실패:', err?.message ?? err));
// 예전에 글자로만 적어 둔 부서를 조직도의 같은 이름 부서에 잇는다(없으면 맨 위에 만든다 — orgTree.js). 여러 번 돌아도 같다.
await backfillOrgTrees()
  .then((n) => n > 0 && console.log(`[orgTree] 예전 부서 글자 ${n}건을 조직도에 이었습니다.`))
  .catch((err) => console.error('[orgTree] 예전 부서 잇기 실패:', err?.message ?? err));
// 서버 전체 백업 — 관리자 콘솔 "백업" 탭에서 백업 암호를 정하면 매일 정한 시각에 백업한다(backup.js). 서버가 꺼져 있어 하루
// 넘게 놓쳤으면 조금 뒤 한 번 한다. 마이그레이션 확인 뒤에 둔다(설정 칼럼이 있어야 읽힌다).
backupScheduler.start().catch((err) => console.error('[backup] 예약 백업을 시작하지 못했습니다:', err?.message ?? err));

httpServer.listen(PORT, () => {
  const lanAddresses = Object.values(os.networkInterfaces())
    .flat()
    .filter((i) => i && i.family === 'IPv4' && !i.internal)
    .map((i) => i.address);

  console.log(`메신저 서버 실행 중 (HTTPS, 포트 ${PORT})`);
  console.log('같은 와이파이의 다른 기기에서 접속할 주소:');
  for (const addr of lanAddresses) console.log(`  https://${addr}:${PORT}`);
  if (EXTERNAL_ADDRESS) {
    console.log(`외부(LTE/5G)에서 접속할 주소: ${EXTERNAL_ADDRESS.url}`);
    console.log(`  공유기에서 외부 포트 ${EXTERNAL_ADDRESS.port}(TCP) → 이 PC의 포트 ${PORT}로 포워딩해야 합니다.`);
    console.log(`  초대 링크 안내 페이지를 밖에서도 열려면 TCP ${PAIRING_PORT}도 같은 번호로 포워딩하세요(밖에서는 안내 페이지·설치 파일만 열리고 페어링은 막힘).`);
    if (livekitMediaPorts) {
      const { udpStart, udpEnd, tcp } = livekitMediaPorts;
      console.log(`  화상회의도 쓰려면 UDP ${udpStart}-${udpEnd}와 TCP ${tcp}도 이 PC의 같은 포트로 포워딩하세요.`);
    }
  }
  console.log(`TLS 인증서(자체 서명): ${certPath}`);
  console.log('클라이언트 앱의 "서버 주소 변경"에서 페어링 코드로 이 인증서를 받아 연결할 수 있습니다.');
  console.log('새 기기를 연결하려면 이 콘솔에 "pair"를 입력하고 Enter 하세요(pm2 등으로 띄웠다면 같은 PC에서 "npm run pair").');
});

startPairingServer({ port: PAIRING_PORT, mainPort: PORT, getCertPem: () => tls.cert });

// 아이폰 등 앱이 없는 기기용 웹 앱 전용 HTTPS 포트(.env의 WEB_DOMAIN — 비어 있으면 아무것도 하지 않는다). 같은 app·socket.io·화상회의
// 신호 중계를 WEB_HTTPS_PORT에서 Let's Encrypt 인증서로 한 번 더 열고, 인증서를 자동으로 받고 갱신한다(webTls.js). 메인 포트(앱이
// 핀닝한 자체 서명 인증서)는 그대로이고, 이 기능의 문제(포트 충돌·발급 실패)는 로그·관리자 콘솔 상태로만 알린다 — 메인 서버는 계속 돈다.
startWebTls({
  app,
  io,
  fallbackTls: tls,
  attachUpgrade: (server) => attachLivekitUpgradeProxy(server, LIVEKIT_PORT),
  config: {
    domain: WEB_DOMAIN,
    httpsPort: WEB_HTTPS_PORT,
    httpPort: ACME_HTTP_PORT,
    email: ACME_EMAIL,
    staging: ACME_STAGING,
    error: WEB_TLS_CONFIG_ERROR,
  },
  // HSTS는 끈다 — 초대·팀 초대 링크가 요청 호스트로 만든 평문 주소(http://WEB_DOMAIN:PAIRING_PORT/invite/…)라, 켜면 웹 앱을 한 번
  // 연 브라우저에서 그 안내 페이지가 열리지 않는다. 그 링크들을 https 웹 주소로 옮긴 뒤에 true로 바꾼다(webTls.js startEnabled 참고).
  sendHsts: false,
  externalHost: EXTERNAL_ADDRESS?.host ?? null,
  mainPort: PORT,
  certsDir,
}).catch((err) => console.error('[web-tls] 웹 앱 전용 포트를 시작하지 못했습니다:', err));

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', (line) => {
  if (line.trim() !== 'pair') return;
  const { code, expiresInMs } = generatePairingCode();
  console.log(`[pairing] 새 기기 연결 코드: ${code} (유효시간 ${Math.round(expiresInMs / 1000)}초, 1회용)`);
});
