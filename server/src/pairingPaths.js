/**
 * 평문 페어링 서버(pairing.js)의 DB 없이 테스트할 수 있는 규칙들 — 사내망 밖에서 열 수 있는 경로, 초대 링크로 내려주는 설치
 * 파일, 마지막 오류 처리. pairing.js는 DB 모듈을 불러오므로 여기에 따로 둔다(test/pairingExternal.test.js,
 * test/pairingDownload.test.js).
 */

/**
 * 초대 링크로 내려주는 설치 파일 — 플랫폼 → { file: releases 폴더의 파일 이름, downloadName: 받는 사람이 보는 이름 }.
 * 객체 대신 Map이라 'constructor'·'toString' 같은 이름이 Object의 기본 속성으로 잡히지 않는다(예전엔 그런 플랫폼 이름으로
 * 처리 중 예외가 나서 오류 화면이 그대로 나갔다).
 */
const INSTALLERS = new Map([
  ['windows', { file: 'client-windows-setup.exe', downloadName: 'TangoTalk-Setup.exe' }],
  ['android', { file: 'client-android.apk', downloadName: 'TangoTalk.apk' }],
]);

/** [platform]의 설치 파일 정보, 모르는 플랫폼이면 null. */
export function installerFor(platform) {
  return (typeof platform === 'string' && INSTALLERS.get(platform)) || null;
}

/**
 * 사내망 밖(LTE/5G)에서 열 수 있는 경로 — 초대 링크 안내 페이지, 그 페이지의 설치 파일 다운로드(위 INSTALLERS의 플랫폼만),
 * 도움말(/guide/)뿐이다. 인증서를 평문으로 내려주는 /pair와 코드 발급(/admin/generate)은 밖에서 막는다(밖에서는 메인 HTTPS
 * 포트로 페어링한다).
 */
const EXTERNAL_PATHS = new RegExp(
  `^\\/(invite|team-invite)\\/[^/]+(\\/download\\/(${[...INSTALLERS.keys()].join('|')}))?\\/?$|^\\/guide(\\/|$)`,
);

export const allowedFromOutside = (path) => EXTERNAL_PATHS.test(path);

/** 로그에 남길 경로 — 초대 토큰은 가린다(콘솔 기록을 남에게 보여 줄 때 링크가 같이 새지 않게). */
export function pathForLog(path) {
  return String(path ?? '').replace(/^\/(invite|team-invite)\/[^/]+/, '/$1/<토큰>');
}

/**
 * 평문 페어링 서버의 마지막 오류 처리 — 이 포트는 사내망 밖에도 열리므로, 처리 중 예외가 나도 Express 기본 오류 화면을 보내지
 * 않는다(NODE_ENV가 production이 아니면 서버의 절대 경로가 담긴 스택 추적을 그대로 보낸다). NODE_ENV와 상관없이 짧은 JSON만
 * 주고, 자세한 내용은 서버 콘솔에만 남긴다. 잘못된 주소(%가 깨진 경로 등 — Express가 400을 붙인다) 같은 4xx는 그 상태 코드로
 * 답한다. 응답을 이미 보내기 시작했으면(설치 파일을 내려주다 끊긴 경우) 더 쓸 수 없으니 Express에 넘겨 연결만 정리하게 한다.
 */
export function pairingErrorHandler(err, req, res, next) {
  if (res.headersSent) return next(err);
  const status = Number.isInteger(err?.status) && err.status >= 400 && err.status < 500 ? err.status : 500;
  if (status >= 500) console.error(`[pairing] 요청 처리 오류 ${req.method} ${pathForLog(req.path)}:`, err);
  const error = status >= 500 ? '서버 오류가 발생했습니다.' : status === 404 ? '찾을 수 없습니다.' : '요청을 처리할 수 없습니다.';
  return res.status(status).json({ error });
}
