/// 이 기기의 비밀 대화 저장소를 이 앱 하나만 쓰는지(PC·모바일 앱) — 그러면 방 줄(SecretSessionManager)만으로 차례가 지켜지고,
/// 읽어 둔 키 상태를 메모리에 들고 있어도 된다.
const bool secretStorageSharedAcrossInstances = false;

/// [op]를 그대로 돌린다(다른 실행과 함께 쓰는 저장소가 없다).
Future<T> runWithSecretRoomLock<T>(String name, Future<T> Function() op) =>
    op();
