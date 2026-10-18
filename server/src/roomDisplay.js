import express, { Router } from 'express';
import { clientIpKey, RateLimiter } from './authGuard.js';
import { findResourceByDisplayToken, listBookingsInRange, reserveResource } from './db/queries/resources.js';
import { broadcastResources } from './groupwareResources.js';
import { displayState, quickBookRange } from './resourcePolicy.js';
import { bookingDto, conflictText } from './resourceRules.js';

/**
 * 회의실 앞 태블릿 화면 — 로그인 없이 자원마다의 비밀 주소(`/room-display/<열쇠>` — 관리자가 켜고 바꿀 수 있음, groupwareResources.js)로 연다.
 * 지금 쓰는지·언제까지·오늘 남은 예약을 크게 보여 주고 30초마다 새로 받는다. 관리자가 허락했으면(displayQuickBook) 비어 있을 때 15·30·60분을
 * 바로 잡는다("현장 예약" — 잡은 사람 없음). 승인이 필요한 자원은 바로 잡지 못한다. 일정에 붙은 비공개 일정은 제목을 숨긴다. 바깥 스크립트·글꼴
 * 없이 이 서버의 /room-display.js만(oauth.js 승인 페이지와 같은 CSP). index.js가 로그인 묶음보다 먼저 건다.
 */

const DAY_MS = 86_400_000;
const viewLimiter = new RateLimiter({ max: 120, windowMs: 60_000 });
const bookLimiter = new RateLimiter({ max: 10, windowMs: 10 * 60_000 });

const escapeHtml = (s) =>
  String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

/** 태블릿 화면 페이지(틀만 — 내용은 스크립트가 /state로 받아 채운다). */
function page(res, token) {
  res
    .status(200)
    .set({
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
      'content-security-policy':
        "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self'; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      'referrer-policy': 'no-referrer',
    })
    .send(`<!doctype html>
<html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>회의실</title>
<style>
html,body{height:100%;margin:0}
body{font-family:system-ui,-apple-system,"Segoe UI","Malgun Gothic",sans-serif;background:#1b5e20;color:#fff;display:flex;flex-direction:column;transition:background .4s}
body.busy{background:#b71c1c} body.pending{background:#e65100} body.off{background:#424242}
header{padding:28px 36px 0} #name{font-size:44px;font-weight:700} #where{font-size:20px;opacity:.85;margin-top:4px}
main{flex:1;display:flex;flex-direction:column;justify-content:center;padding:0 36px}
#status{font-size:72px;font-weight:800} #detail{font-size:28px;margin-top:10px;opacity:.95}
#quick{margin-top:28px;display:flex;gap:14px;flex-wrap:wrap} #quick button{font-size:26px;padding:16px 26px;border:0;border-radius:14px;background:rgba(255,255,255,.92);color:#1b5e20;font-weight:700}
#msg{font-size:20px;margin-top:12px;min-height:26px}
footer{background:rgba(0,0,0,.22);padding:18px 36px 22px} footer h2{font-size:18px;margin:0 0 10px;opacity:.8;font-weight:600}
#list{list-style:none;margin:0;padding:0} #list li{font-size:22px;padding:6px 0;display:flex;gap:18px} #list .t{min-width:150px;font-variant-numeric:tabular-nums}
#clock{position:fixed;top:24px;right:36px;font-size:34px;font-variant-numeric:tabular-nums;opacity:.9}
</style></head>
<body data-token="${escapeHtml(token)}">
<div id="clock"></div>
<header><div id="name">…</div><div id="where"></div></header>
<main><div id="status">불러오는 중…</div><div id="detail"></div><div id="quick"></div><div id="msg"></div></main>
<footer><h2>오늘 남은 예약 · Today</h2><ul id="list"></ul></footer>
<script src="/room-display.js"></script></body></html>`);
}

/** 태블릿 화면의 스크립트 — 30초마다 상태를 받아 그리고, 바로 예약 단추를 누르면 잡는다. 한국어·영어를 함께 적는다. */
export const ROOM_DISPLAY_JS = `(function(){
var token=document.body.getAttribute('data-token');var base='/room-display/'+encodeURIComponent(token);
function $(id){return document.getElementById(id);}
function hm(ms){var d=new Date(ms);return ('0'+d.getHours()).slice(-2)+':'+('0'+d.getMinutes()).slice(-2);}
function tick(){$('clock').textContent=hm(Date.now());}
function render(s){
  $('name').textContent=s.name;$('where').textContent=[s.location,s.capacity?('최대 '+s.capacity+'명 · up to '+s.capacity):null].filter(Boolean).join(' · ');
  document.body.className=!s.enabled?'off':s.current?(s.current.status==='pending'?'pending':'busy'):'';
  if(!s.enabled){$('status').textContent='쓰지 않음 · Unavailable';$('detail').textContent='';}
  else if(s.current){$('status').textContent=(s.current.status==='pending'?'승인 대기 · Pending':'사용 중 · In use');
    $('detail').textContent=s.current.title+' — '+s.current.userName+' · '+hm(s.current.start)+'~'+hm(s.busyUntil||s.current.end);}
  else{$('status').textContent='비어 있음 · Available';$('detail').textContent=s.freeUntil?(hm(s.freeUntil)+'까지 · until '+hm(s.freeUntil)):'오늘은 예약이 없습니다 · Free for the rest of today';}
  var q=$('quick');q.innerHTML='';
  if(s.quickBook&&s.enabled&&!s.current){[15,30,60].forEach(function(m){if(s.freeUntil&&Date.now()+m*60000>s.freeUntil)return;
    var b=document.createElement('button');b.textContent=m+'분 쓰기 · '+m+' min';b.onclick=function(){book(m);};q.appendChild(b);});}
  var l=$('list');l.innerHTML='';
  if(!s.upcoming.length){var li=document.createElement('li');li.textContent='없음 · None';l.appendChild(li);}
  s.upcoming.forEach(function(b){var li=document.createElement('li');var t=document.createElement('span');t.className='t';t.textContent=hm(b.start)+'~'+hm(b.end);
    var n=document.createElement('span');n.textContent=b.title+' — '+b.userName+(b.status==='pending'?' (승인 대기)':'');li.appendChild(t);li.appendChild(n);l.appendChild(li);});
}
function load(){fetch(base+'/state',{cache:'no-store'}).then(function(r){if(!r.ok)throw r;return r.json();}).then(function(s){$('msg').textContent='';render(s);})
  .catch(function(){$('status').textContent='연결할 수 없습니다 · Offline';});}
function book(m){$('msg').textContent='잡는 중… · Booking…';fetch(base+'/quick',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({minutes:m})})
  .then(function(r){return r.json().then(function(j){return {ok:r.ok,j:j};});}).then(function(x){$('msg').textContent=x.ok?'잡았습니다 · Booked':(x.j.error||'잡지 못했습니다');load();})
  .catch(function(){$('msg').textContent='잡지 못했습니다 · Failed';});}
tick();setInterval(tick,10000);load();setInterval(load,30000);
})();`;

/** 열쇠로 자원을 찾는다(없으면 404로 응답하고 null). */
async function resourceOf(req, res) {
  const token = typeof req.params.token === 'string' && /^[A-Za-z0-9_-]{16,64}$/.test(req.params.token) ? req.params.token : null;
  const resource = token ? await findResourceByDisplayToken(token) : null;
  if (!resource) {
    res.status(404).set('cache-control', 'no-store').json({ error: '화면을 찾을 수 없습니다. 관리자에게 새 주소를 받으세요.' });
    return null;
  }
  return resource;
}

/** 지금 상태 — 오늘·내일 예약(일정에 붙은 비공개 일정은 제목을 숨김). */
async function stateOf(resource, now = Date.now()) {
  const rows = await listBookingsInRange({ scopeKey: resource.scopeKey, fromMs: now - DAY_MS, toMs: now + 2 * DAY_MS, resourceId: resource.id });
  const view = displayState(rows, now);
  // 보는 사람이 없는 화면 — 빈 id로(잡은 사람 칸이 비어도 "내 예약"으로 보지 않게 — 비공개 일정 제목은 늘 가린다).
  const dto = (b) => (b ? bookingDto(b, { viewerId: '' }) : null);
  return {
    name: resource.name,
    location: resource.location ?? null,
    capacity: resource.capacity ?? null,
    enabled: resource.enabled,
    now,
    current: dto(view.current),
    upcoming: view.upcoming.map(dto),
    freeUntil: view.freeUntil,
    busyUntil: view.busyUntil,
    // 바로 예약 — 관리자가 허락했고, 승인이 필요 없는 자원만.
    quickBook: !!resource.displayQuickBook && !resource.requiresApproval,
  };
}

export function createRoomDisplayRouter(io) {
  const router = Router();
  const json = express.json({ limit: '2kb' });
  const limited = (limiter) => (req, res, next) => {
    const wait = limiter.hit(clientIpKey(req));
    if (wait > 0) return res.status(429).set('Retry-After', String(Math.ceil(wait / 1000))).json({ error: '잠시 뒤 다시 하세요.' });
    next();
  };

  router.get('/room-display.js', (req, res) => {
    res.set({ 'content-type': 'text/javascript; charset=utf-8', 'cache-control': 'no-cache' }).send(ROOM_DISPLAY_JS);
  });

  router.get('/room-display/:token', limited(viewLimiter), async (req, res) => {
    const resource = await resourceOf(req, res);
    if (resource) page(res, req.params.token);
  });

  router.get('/room-display/:token/state', limited(viewLimiter), async (req, res) => {
    const resource = await resourceOf(req, res);
    if (resource) res.set('cache-control', 'no-store').json(await stateOf(resource));
  });

  /** 태블릿에서 바로 예약 `{ minutes: 15 | 30 | 60 }` — 지금부터, 비어 있을 때. 잡은 사람 없는 "현장 예약". */
  router.post('/room-display/:token/quick', limited(bookLimiter), json, async (req, res) => {
    const resource = await resourceOf(req, res);
    if (!resource) return;
    if (!resource.displayQuickBook || resource.requiresApproval || !resource.enabled) {
      return res.status(403).json({ error: '이 회의실은 태블릿에서 바로 예약할 수 없습니다.' });
    }
    const now = Date.now();
    const state = await stateOf(resource, now);
    const range = quickBookRange({ minutes: Number(req.body?.minutes), now, freeUntil: state.freeUntil, current: state.current });
    if (range.error) return res.status(409).json({ error: range.error });
    const result = await reserveResource({
      resourceId: resource.id,
      values: {
        userId: null,
        userName: '현장 예약',
        teamId: null,
        title: '현장 예약',
        startAt: new Date(range.startMs),
        endAt: new Date(range.endMs),
        eventId: null,
        status: 'confirmed',
      },
    });
    if (result.missing) return res.status(409).json({ error: '지금은 예약할 수 없는 회의실입니다.' });
    if (result.conflict) return res.status(409).json({ error: conflictText(result.conflict) });
    await broadcastResources(io, resource.scopeKey);
    res.status(201).json({ ok: true });
  });

  return router;
}
