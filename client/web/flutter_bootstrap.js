{{flutter_js}}
{{flutter_build_config}}

// Flutter 기본 부트스트랩과 다른 점:
// - serviceWorkerSettings를 넘기지 않는다 — 넘기면(또는 이미 등록된 서비스 워커가 있으면) Flutter가 자기
//   flutter_service_worker.js로 같은 범위를 덮어써서, 알림·웹 푸시를 맡는 우리 sw.js가 사라진다.
// - CanvasKit을 인터넷(gstatic)이 아니라 이 서버에서 받는다 — 사내망에서 인터넷 없이도 뜨게.
_flutter.loader.load({
  config: {
    canvasKitBaseUrl: 'canvaskit/',
  },
});
