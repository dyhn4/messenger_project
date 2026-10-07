import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// 웹 앱은 같은 브라우저의 탭마다 같은 저장소(localStorage)·같은 기기 id를 쓴다 — 탭마다 키 상태를 메모리에 들고 있으면
/// 서로 어긋나서(한 탭이 나아간 래칫을 다른 탭이 모른 채 같은 번호로 보냄) 매번 저장소에서 읽고, 방 하나의 읽고 고쳐 쓰기를
/// 탭 사이에서도 한 줄로 세운다.
const bool secretStorageSharedAcrossInstances = true;

/// [name] 잠금을 얻은 뒤 [op]를 돌리고, 끝나면(실패해도) 놓는다 — 다른 탭이 같은 이름의 잠금을 들고 있으면 기다린다
/// (Web Locks — navigator.locks). 이 기능이 없거나 잠금을 쓸 수 없는 곳이면 잠금 없이 돌린다(탭 하나만 쓰면 그대로다).
Future<T> runWithSecretRoomLock<T>(String name, Future<T> Function() op) {
  final navigator = web.window.navigator;
  if (!navigator.has('locks')) return op();
  final done = Completer<T>();
  var started = false;
  Future<JSAny?> hold() async {
    started = true;
    try {
      done.complete(await op());
    } catch (e, st) {
      done.completeError(e, st);
    }
    return null;
  }

  // 잠금을 얻으면 불린다 — 돌려준 약속이 끝날 때까지 잠금을 들고 있는다.
  JSPromise<JSAny?> granted(JSAny? lock) => hold().toJS;
  unawaited(
    navigator.locks
        .request(name, granted.toJS)
        .toDart
        .then<void>(
          (_) {},
          onError: (Object e, StackTrace st) {
            if (done.isCompleted || started) return;
            // 잠금 요청이 거절됐다 — op는 돌지 않았으니 잠금 없이 돌린다.
            done.complete(Future<T>.sync(op));
          },
        ),
  );
  return done.future;
}
