// 비밀 대화 방 하나의 키 상태를 읽고 고쳐 쓰는 일을 같은 저장소를 쓰는 다른 실행(웹 앱의 다른 탭)과도 한 줄로 세운다 —
// PC·모바일 앱은 저장소를 이 앱 하나만 써서 그대로 돌리고, 웹 앱은 탭마다 같은 저장소(localStorage)를 써서 Web Locks로
// 탭 사이에서도 차례로 돌린다(secret_session_manager.dart).
export 'secret_room_lock_stub.dart'
    if (dart.library.js_interop) 'secret_room_lock_web.dart';
