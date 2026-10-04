/// 초대 링크를 "복사"할 때 붙여넣을 글. 서버에 외부(LTE/5G) 주소가 설정돼 있으면(서버 .env의
/// EXTERNAL_ADDRESS) 사내 와이파이용 주소와 밖에서 열 주소를 둘 다 적는다 — 받는 사람이 지금
/// 어디 있든 맞는 쪽을 누르면 된다(밖에서는 사내 주소가 안 열리고, 공유기에 따라 사내에서는
/// 외부 주소가 안 열린다). 외부 주소가 없으면 예전처럼 주소 하나만.
///
/// 밖에서 여는 안내 페이지와 설치 파일은 평문 HTTP라 공용 와이파이에서는 중간에서 바꿔치기될 수
/// 있어서, 외부 주소를 적을 때는 공용 와이파이에서 열지 말라는 안내를 같이 붙인다(서버 안내
/// 페이지에도 같은 주의가 뜬다 — server/src/pairing.js의 PUBLIC_WIFI_CAUTION).
library;

const kPublicWifiCaution =
    '※ 밖에서 열 때는 공용 와이파이(카페·공항·호텔 등) 말고 LTE/5G나 집 와이파이에서 여세요.';

String inviteShareText(String url, String? externalUrl) {
  if (externalUrl == null || externalUrl == url) {
    return externalUrl == null ? url : '$url\n$kPublicWifiCaution';
  }
  return '사내 와이파이에서: $url\n사내 와이파이 밖(LTE/5G)에서: $externalUrl\n$kPublicWifiCaution';
}
