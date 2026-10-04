/**
 * 사내망 밖(LTE/5G)에서 평문 페어링 서버(pairing.js)로 열 수 있는 경로 — 초대 링크 안내 페이지,
 * 그 페이지의 설치 파일 다운로드, 도움말(/guide/)뿐이다. 인증서를 평문으로 내려주는 /pair와
 * 코드 발급(/admin/generate)은 밖에서 막는다(밖에서는 메인 HTTPS 포트로 페어링한다).
 * DB 없이 테스트할 수 있게 pairing.js와 따로 둔다.
 */
const EXTERNAL_PATHS = /^\/(invite|team-invite)\/[^/]+(\/download\/[a-z]+)?\/?$|^\/guide(\/|$)/;

export const allowedFromOutside = (path) => EXTERNAL_PATHS.test(path);
