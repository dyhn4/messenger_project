// 웹 앱을 초대 링크의 웹 주소(https://웹주소/?invite=<코드>)로 열었을 때 그 초대 코드를 꺼낸다 — 네이티브에서는 늘 null.
// 아이폰 사용자는 설치형 앱이 없어 초대 안내 페이지의 웹 앱 링크로 들어오는데, 사내 와이파이 밖에서는 초대 코드를 함께 보내야
// 가입된다(server/src/auth.js). 웹 구현은 web_launch_invite_web.dart.
export 'web_launch_invite_stub.dart'
    if (dart.library.js_interop) 'web_launch_invite_web.dart';
