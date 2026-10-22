{{flutter_js}}
{{flutter_build_config}}

// Flutter 기본 부트스트랩과 다른 점:
// - serviceWorkerSettings를 넘기지 않는다 — 넘기면(또는 이미 등록된 서비스 워커가 있으면) Flutter가 자기
//   flutter_service_worker.js로 같은 범위를 덮어써서, 알림·웹 푸시·앱 파일 보관을 맡는 우리 sw.js가 사라진다.
// - CanvasKit을 인터넷(gstatic)이 아니라 이 서버에서 받는다 — 사내망에서 인터넷 없이도 뜨게.
// - 첫 화면이 뜨면 이번에 받은 파일 목록을 sw.js에 넘겨 보관하게 한다 — 서버가 꺼져 있어도 다음에 열 수 있게. 처음 열 때는
//   서비스 워커가 아직 이 페이지를 맡기 전이라 그 사이에 받은 파일(main.dart.js·CanvasKit 등)을 스스로는 보관하지 못한다.
//   어떤 CanvasKit(브라우저마다 다름)·글꼴을 받았는지는 페이지만 안다.
_flutter.loader.load({
  config: {
    canvasKitBaseUrl: 'canvaskit/',
  },
});

(function keepAppFiles() {
  if (!('serviceWorker' in navigator) || !window.performance) return;
  let done = false;
  const send = () => {
    if (done) return;
    done = true;
    navigator.serviceWorker
      .register('sw.js')
      .then(() => navigator.serviceWorker.ready)
      .then((registration) => {
        const urls = [location.href, ...performance.getEntriesByType('resource').map((e) => e.name)];
        registration.active?.postMessage({ type: 'keep-app-files', urls });
      })
      .catch(() => {
        // 서비스 워커를 쓸 수 없는 환경(사설 인증서 등) — 보관만 못 할 뿐이다.
      });
  };
  window.addEventListener('flutter-first-frame', send, { once: true });
  // 첫 화면 알림을 못 받았어도(엔진이 바뀌는 등) 조금 뒤에 한 번.
  window.addEventListener('load', () => setTimeout(send, 15000), { once: true });
})();
