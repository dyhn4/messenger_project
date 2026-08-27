/// 메시지/댓글 수정·삭제 허용 시간. 서버(messages.js, comments.js의 EDIT_WINDOW_MS)와
/// 반드시 같은 값이어야 한다 — 여기서는 버튼을 누르자마자 바로 실패를 보여주기 위한
/// 클라이언트 쪽 사전 확인일 뿐이고, 최종 판단은 항상 서버가 한다(클라이언트 시계가 서버보다
/// 살짝 빠르면 여기선 통과해도 서버가 403으로 거부할 수 있는데, 그건 그때 가서 스낵바로 보여줌).
const editWindow = Duration(minutes: 5);

bool isWithinEditWindow(DateTime createdAt) =>
    DateTime.now().difference(createdAt) <= editWindow;
