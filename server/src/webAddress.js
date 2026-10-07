/**
 * 웹 앱의 정식 주소(https://WEB_DOMAIN[:포트]) — 그 도메인의 공인 인증서(Let's Encrypt)가 실제로 걸려 있을 때만 값이 있다.
 * 웹 전용 HTTPS 포트를 띄우는 쪽(인증서를 받고 갱신하는 모듈)이 인증서를 걸거나 내릴 때 setWebPublicUrl로 알리고, 초대 안내
 * 페이지(pairing.js)·/server-info가 아이폰 사용자에게 이 주소를 알려 줄 때 getWebPublicUrl로 읽는다. 인증서가 아직 없거나
 * 기능이 꺼져 있으면 null — 그때 주소를 알려 주면 브라우저가 "안전하지 않음" 경고를 띄우는 주소를 안내하게 된다.
 */
let webPublicUrl = null;

export function getWebPublicUrl() {
  return webPublicUrl;
}

export function setWebPublicUrl(url) {
  webPublicUrl = typeof url === 'string' && url ? url : null;
}
