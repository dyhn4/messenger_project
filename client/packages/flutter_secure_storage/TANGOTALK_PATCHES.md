# TangoTalk에서 고친 점 (flutter_secure_storage 9.2.4 기준)

pub.dev의 `flutter_secure_storage` 9.2.4를 그대로 복사한 뒤(예제 앱만 뺌) **Android 코드만** 고쳤다. 앱은
`client/pubspec.yaml`에서 이 사본을 path 의존성으로 쓴다. Dart API·저장 형식은 그대로라, 이전 버전 앱이 저장한 값을
그대로 읽는다. Windows 구현은 `../flutter_secure_storage_windows`(따로 고친 사본)를 쓴다.

원래 Android 구현은 값을 쓸 때 `SharedPreferences.Editor.apply()`를 썼다. `apply()`는 메모리의 값만 바로 바꾸고 디스크
쓰기는 나중으로 미룬다. 그 사이 앱이 죽거나 강제 종료되면 마지막 변경이 사라진다. 비밀 대화의 키 상태가 한 단계
되돌아가면 같은 메시지 키를 다시 쓰거나 대화가 어긋난다. 저장소 암호화 키를 처음 만들 때도 `apply()`라서, 그 키가
디스크에 닿기 전에 죽으면 그 키로 저장한 값을 다시 켠 뒤 읽을 수 없었다.

고친 점:

- `android/.../FlutterSecureStorage.java` — 쓰기·지우기·모두 지우기와 데이터 옮기기(재암호화·EncryptedSharedPreferences로
  옮기기)를 `commit()`으로 바꿨다(디스크에 쓴 뒤 돌아온다). 실패하면 예외를 던져 Dart 쪽 호출이 실패로 끝난다.
  플러그인은 원래 모든 호출을 자기 작업 스레드에서 돌려서, 여기서 기다려도 화면이 멈추지 않는다.
- `android/.../ciphers/StorageCipher18Implementation.java` — 새 저장소 암호화 키를 `commit()`으로 저장하고, 실패하면
  그 키를 쓰지 않는다(예외).
- `android/.../FlutterSecureStoragePlugin.java` — `FileNotFoundException`이 나면 로그만 남기고 응답하지 않아 Dart 쪽이
  영영 기다렸다. 이제 오류로 응답한다.

남은 점: `commit()`이 실패하면(저장 공간 부족·디스크 오류) SharedPreferences는 메모리에는 새 값을 이미 올려 두어, 그
실행 동안은 새 값이 읽히다가 다시 켜면 예전 값으로 돌아간다(Dart 쪽은 실패를 받는다). `resetOnError`를 켜면 쓰기 실패가 모든
키를 지우는 것으로 이어지므로 켜지 않는다(앱은 켜지 않는다).

플러그인을 새 버전으로 올릴 때는 새 버전이 같은 문제를 고쳤는지 보고, 아니면 이 고친 점을 다시 옮긴다.
