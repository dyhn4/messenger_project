/**
 * 서버가 보내는 메일의 제목·본문 — 계산만 하고 보내지는 않는다(보내기는 mailer.js). 받는 쪽 메일 앱이 HTML을 못 보여 줄 때를
 * 위해 늘 글(text)과 HTML을 같이 만든다. HTML에 들어가는 값은 모두 이스케이프한다 — 이름·방 이름·미리보기는 사람이 정한 글이다.
 */

export const MAIL_APP_NAME = 'TangoTalk';

const escapeHtml = (value) =>
  String(value ?? '').replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[ch]);

/** 제목 머리 — 메일함에서 어디서 온 메일인지 바로 보이게. */
const subjectOf = (text) => `[${MAIL_APP_NAME}] ${text}`;

const FOOTER = `이 메일은 ${MAIL_APP_NAME} 서버가 자동으로 보냈습니다. 답장해도 읽는 사람이 없습니다.`;

/** 문단들(빈 값은 건너뜀)로 글·HTML을 함께 만든다. [blocks]는 문자열이거나 { html, text }(HTML만 따로 꾸밀 때). */
function compose(subject, blocks) {
  const parts = blocks.filter((b) => b != null && b !== '');
  const text = [...parts.map((b) => (typeof b === 'string' ? b : b.text)), '', FOOTER].join('\n\n').trim();
  const body = parts
    .map((b) => (typeof b === 'string' ? `<p style="margin:0 0 14px">${escapeHtml(b).replace(/\n/g, '<br>')}</p>` : b.html))
    .join('');
  const html =
    '<!doctype html><html><body style="margin:0;padding:24px;background:#f4f4f6">' +
    '<div style="max-width:520px;margin:0 auto;background:#fff;border-radius:12px;padding:28px 24px;' +
    "font-family:'Malgun Gothic','Apple SD Gothic Neo',sans-serif;font-size:15px;line-height:1.6;color:#1f1f24\">" +
    `<div style="font-weight:700;font-size:18px;margin-bottom:18px">${escapeHtml(MAIL_APP_NAME)}</div>` +
    body +
    `<p style="margin:24px 0 0;font-size:12px;color:#8a8a93">${escapeHtml(FOOTER)}</p>` +
    '</div></body></html>';
  return { subject, text, html };
}

/** 눈에 띄는 큰 글(코드·아이디). */
const highlight = (label, value) => ({
  text: `${label}: ${value}`,
  html:
    `<p style="margin:0 0 6px;font-size:13px;color:#6b6b75">${escapeHtml(label)}</p>` +
    `<p style="margin:0 0 18px;font-size:28px;font-weight:700;letter-spacing:4px">${escapeHtml(value)}</p>`,
});

/** 누를 수 있는 주소 한 줄. 주소는 서버가 만든 값만 넣는다(http/https만). */
const linkLine = (label, url) => {
  if (!/^https?:\/\//.test(url ?? '')) return null;
  return {
    text: `${label}: ${url}`,
    html: `<p style="margin:0 0 10px">${escapeHtml(label)}<br><a href="${escapeHtml(url)}" style="color:#4c5bd4;word-break:break-all">${escapeHtml(url)}</a></p>`,
  };
};

const CODE_SUBJECT = {
  signup: '가입 이메일 확인 코드',
  verify: '이메일 확인 코드',
  change: '새 이메일 확인 코드',
  reset: '비밀번호 재설정 코드',
};

const CODE_INTRO = {
  signup: '회원가입을 마치려면 아래 확인 코드를 가입 화면에 넣으세요.',
  verify: '이 이메일이 본인 것인지 확인하려고 보낸 메일입니다. 아래 코드를 앱에 넣으세요.',
  change: '계정의 이메일을 이 주소로 바꾸려고 보낸 메일입니다. 아래 코드를 앱에 넣으세요.',
  reset: '비밀번호 재설정을 요청해서 보낸 메일입니다. 아래 코드를 비밀번호 찾기 화면에 넣으세요.',
};

/** 확인 코드 메일. [minutes]는 코드가 살아 있는 시간. */
export function emailCodeMail(purpose, code, { minutes = 10 } = {}) {
  return compose(subjectOf(CODE_SUBJECT[purpose] ?? '확인 코드'), [
    CODE_INTRO[purpose] ?? '아래 확인 코드를 앱에 넣으세요.',
    highlight('확인 코드', code),
    `${minutes}분 동안 쓸 수 있습니다. 코드는 다른 사람에게 알려 주지 마세요.`,
    purpose === 'reset'
      ? '직접 요청하지 않았다면 이 메일은 무시하세요 — 이 코드 없이는 비밀번호를 바꿀 수 없습니다. 같은 메일이 계속 오면 서버 운영자에게 알려 주세요.'
      : '직접 요청하지 않았다면 이 메일은 무시하세요.',
  ]);
}

/** 아이디 찾기 결과. */
export function findIdMail(username) {
  return compose(subjectOf('아이디 안내'), [
    '아이디 찾기를 요청해서 보낸 메일입니다.',
    highlight('아이디', username),
    '비밀번호가 생각나지 않으면 로그인 화면의 "비밀번호 찾기"를 이용하세요. 직접 요청하지 않았다면 이 메일은 무시하세요.',
  ]);
}

/** 이메일을 바꾼 뒤 예전 주소로 보내는 알림 — 남이 바꿨을 때 알아챌 수 있게. [newEmailMasked]는 일부만 보이는 새 주소. */
export function emailChangedMail(newEmailMasked) {
  return compose(subjectOf('계정 이메일이 바뀌었습니다'), [
    `계정의 이메일이 ${newEmailMasked} 로 바뀌었습니다. 이 주소로는 더 이상 아이디·비밀번호 찾기 메일이 가지 않습니다.`,
    '본인이 바꾸지 않았다면 바로 비밀번호를 바꾸고 서버 운영자에게 알려 주세요.',
  ]);
}

/**
 * 초대 메일. [teamName]이 있으면 팀 초대(가입하면 그 팀에 들어간다). 주소는 서버가 만든 초대 링크들 — [internalUrl](사내
 * 와이파이), [externalUrl](밖, 있을 때만), [webUrl](아이폰용 웹 앱 — 초대 코드가 붙은 주소, 있을 때만).
 */
export function inviteMail({ inviterName, teamName = null, internalUrl = null, externalUrl = null, webUrl = null, expiresText = null }) {
  const who = inviterName || '팀원';
  const what = teamName ? `${MAIL_APP_NAME}의 "${teamName}" 팀` : MAIL_APP_NAME;
  const both = internalUrl && externalUrl && internalUrl !== externalUrl;
  return compose(subjectOf(`${who}님이 ${teamName ? `"${teamName}" 팀에` : '메신저에'} 초대했습니다`), [
    `${who}님이 ${what}에 초대했습니다. 아래 링크를 열면 앱을 설치하고 이 서버에 연결해 가입할 수 있습니다.`,
    both ? linkLine('사내 와이파이에서', internalUrl) : linkLine('초대 링크', internalUrl ?? externalUrl),
    both ? linkLine('사내 와이파이 밖(LTE/5G)에서', externalUrl) : null,
    externalUrl ? '밖에서 열 때는 공용 와이파이(카페·공항·호텔 등) 말고 LTE/5G나 집 와이파이에서 여세요.' : null,
    linkLine('아이폰은 앱 대신 웹 앱을 씁니다 — Safari로 열어 가입하고 홈 화면에 추가하세요', webUrl),
    expiresText ? `이 링크는 ${expiresText}까지 쓸 수 있습니다.` : null,
    '초대받은 적이 없다면 이 메일은 무시하세요.',
  ]);
}

/**
 * 멘션 요약 메일. [items]는 최신순 { teamName, roomName, actorName, preview, createdAt, kind }(보일 만큼만), [total]은 안 읽은
 * 멘션 전체 수. [includePreview]가 거짓이면 미리보기를 넣지 않는다(서버 설정 — 메시지 내용이 서버 밖으로 나가지 않게).
 * [formatTime]은 시각을 글로(시험용).
 */
export function mentionDigestMail({ name, items, total, days, includePreview = false, formatTime = defaultTimeFormat }) {
  const lines = items.map((item) => {
    const where = [item.teamName, item.roomName].filter(Boolean).join(' · ') || '대화방';
    const who = item.actorName || '알 수 없는 사람';
    const all = item.kind === 'mention_all' ? ' (@all)' : '';
    const preview = includePreview && item.preview ? `\n  "${item.preview}"` : '';
    return { where, who, all, when: formatTime(item.createdAt), preview: includePreview ? item.preview : null, text: `• ${where} — ${who}${all}, ${formatTime(item.createdAt)}${preview}` };
  });
  const more = total - items.length;
  const list = {
    text: [...lines.map((l) => l.text), more > 0 ? `외 ${more}개` : null].filter(Boolean).join('\n'),
    html:
      '<ul style="margin:0 0 16px;padding-left:18px">' +
      lines
        .map(
          (l) =>
            `<li style="margin-bottom:8px"><b>${escapeHtml(l.where)}</b><br>` +
            `${escapeHtml(l.who)}${escapeHtml(l.all)} · <span style="color:#6b6b75">${escapeHtml(l.when)}</span>` +
            (l.preview ? `<br><span style="color:#44444c">“${escapeHtml(l.preview)}”</span>` : '') +
            '</li>',
        )
        .join('') +
      (more > 0 ? `<li style="color:#6b6b75">외 ${more}개</li>` : '') +
      '</ul>',
  };
  return compose(subjectOf(`읽지 않은 멘션 ${total}개`), [
    `${name || '회원'}님, ${days}일 넘게 ${MAIL_APP_NAME}에 접속하지 않으신 동안 읽지 않은 멘션이 ${total}개 쌓였습니다.`,
    list,
    '앱에 들어가 알림 센터에서 확인하세요. 이 메일을 그만 받으려면 앱의 알림 센터 → 알림 설정에서 "멘션 요약 메일 받기"를 끄세요.',
  ]);
}

/** 관리자 콘솔의 "시험 메일 보내기". */
export function testMail() {
  return compose(subjectOf('시험 메일'), [
    '메일 설정이 잘 되었습니다. 관리자 콘솔의 메일 탭에서 "메일 기능 사용"을 켜면 이메일 확인·메일로 아이디/비밀번호 찾기·초대 메일·멘션 요약 메일이 동작합니다.',
  ]);
}

const timeFormatter = new Intl.DateTimeFormat('ko-KR', {
  month: 'long',
  day: 'numeric',
  hour: 'numeric',
  minute: '2-digit',
});

function defaultTimeFormat(value) {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? '' : timeFormatter.format(date);
}
