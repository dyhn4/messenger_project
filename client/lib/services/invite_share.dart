/// 초대 링크를 "복사"할 때 붙여넣을 글. 서버에 외부(LTE/5G) 주소가 설정돼 있으면(서버 .env의
/// EXTERNAL_ADDRESS) 사내 와이파이용 주소와 밖에서 열 주소를 둘 다 적는다 — 받는 사람이 지금
/// 어디 있든 맞는 쪽을 누르면 된다(밖에서는 사내 주소가 안 열리고, 공유기에 따라 사내에서는
/// 외부 주소가 안 열린다). 외부 주소가 없으면 예전처럼 주소 하나만.
///
/// 밖에서 여는 안내 페이지와 설치 파일은 평문 HTTP라 공용 와이파이에서는 중간에서 바꿔치기될 수
/// 있어서, 외부 주소를 적을 때는 공용 와이파이에서 열지 말라는 안내를 같이 붙인다(서버 안내
/// 페이지에도 같은 주의가 뜬다 — server/src/pairing.js의 PUBLIC_WIFI_CAUTION).
///
/// 서버에 아이폰용 웹 앱 주소가 있으면(공인 인증서가 걸린 https 주소 — 아이폰에는 설치형 앱이 없어 Safari로 웹 앱을
/// 쓴다) 맨 끝에 아이폰 안내 줄과 가입 주의 줄을 붙인다(서버 안내 페이지의 iphoneWebSection과 같은 내용). 공용 와이파이
/// 주의보다 뒤에 두는 건, 그 주의는 평문 HTTP인 초대 안내 페이지 이야기라 공인 인증서로 열리는 웹 앱 주소까지 묶여 읽히지
/// 않게 하려는 것이다.
library;

const kPublicWifiCaution =
    '※ 밖에서 열 때는 공용 와이파이(카페·공항·호텔 등) 말고 LTE/5G나 집 와이파이에서 여세요.';

/// 아이폰 안내 줄 바로 다음에 붙는 가입 안내. 사내 와이파이 밖에서는 초대 링크의 코드를 함께 보내야 가입되는데(server
/// auth.js), 웹 앱은 그 코드를 주소의 `?invite=`로 받는다(web_launch_invite.dart) — 그래서 이 글의 웹 앱 주소에는 코드가 붙어
/// 있고, 이 주소로 처음 열어야 밖에서도 가입된다.
const kIphoneSignupCaution =
    '※ 처음 가입할 때는 꼭 위 주소로 여세요(초대 코드가 들어 있어 사내 와이파이 밖에서도 가입됩니다). 가입한 뒤에는 홈 화면의 웹 앱으로 로그인합니다.';

/// 초대 코드로 볼 수 있는 모양인지 — 서버가 만드는 코드는 16진수 24자(server/src/invites.js·teamInvites.js)지만, 웹 앱 주소에서
/// 꺼낸 값을 그대로 서버에 보내기 전에 터무니없는 값(긴 글·기호)만 거른다.
bool isPlausibleInviteToken(String value) =>
    RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(value);

/// 웹 앱 주소에 초대 코드를 붙인 주소(`https://웹주소/?invite=<코드>`) — 이 주소로 연 웹 앱이 그 코드로 가입한다. 코드가 없으면
/// 웹 앱 주소 그대로.
String webAppInviteUrl(String webUrl, String? inviteToken) {
  if (inviteToken == null || !isPlausibleInviteToken(inviteToken)) {
    return webUrl;
  }
  final base = webUrl.endsWith('/') ? webUrl : '$webUrl/';
  return '$base?invite=${Uri.encodeQueryComponent(inviteToken)}';
}

/// 아이폰 사용자용 안내 줄. 주소와 "을" 사이를 띄우는 건, 메신저들이 글 속 주소를 링크로 바꿀 때 뒤에 붙은
/// 글자까지 주소로 삼아 열리지 않는 링크가 되지 않게 하려는 것이다.
String iphoneWebAppLine(String webUrl, {String? inviteToken}) =>
    '아이폰은 앱 대신 웹 앱을 씁니다: ${webAppInviteUrl(webUrl, inviteToken)} 을 Safari로 열어 가입하고 홈 화면에 추가하세요.';

/// 서버가 알려 준 아이폰용 웹 앱 주소(GET /server-info의 webUrl — 서버에 공인 인증서가 실제로 걸려 있을 때만 값이
/// 있다). 앱이 서버 정보를 받을 때마다 ApiClient가 [rememberWebAppUrl]로 고쳐 적는다 — 초대 링크 화면들은 링크
/// 주소만 넘기므로, 그 화면들을 거치지 않고도 복사하는 글에 아이폰 안내가 붙게 하려는 것이다. 못 받았으면(예전
/// 서버·기능 꺼짐·오프라인) null — 그때는 안내 줄을 빼면 그만이다.
String? get knownWebAppUrl => _knownWebAppUrl;
String? _knownWebAppUrl;

void rememberWebAppUrl(String? url) => _knownWebAppUrl = url;

/// [webUrl]을 안 넘기면 서버에서 받아 둔 주소([knownWebAppUrl])를 쓴다. [inviteToken]은 이 초대 링크의 코드 — 아이폰용 웹 앱
/// 주소에 붙여, 그 주소로 연 웹 앱이 밖에서도 가입할 수 있게 한다.
String inviteShareText(
  String url,
  String? externalUrl, {
  String? webUrl,
  String? inviteToken,
}) {
  final text = _linkText(url, externalUrl);
  final web = webUrl ?? _knownWebAppUrl;
  return web == null
      ? text
      : '$text\n${iphoneWebAppLine(web, inviteToken: inviteToken)}\n$kIphoneSignupCaution';
}

String _linkText(String url, String? externalUrl) {
  if (externalUrl == null || externalUrl == url) {
    return externalUrl == null ? url : '$url\n$kPublicWifiCaution';
  }
  return '사내 와이파이에서: $url\n사내 와이파이 밖(LTE/5G)에서: $externalUrl\n$kPublicWifiCaution';
}
