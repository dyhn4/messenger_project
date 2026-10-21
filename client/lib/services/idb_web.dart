import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// 웹의 IndexedDB를 Future로 쓰는 작은 도구 — 웹 앱의 이 기기 메시지 DB(message_db_web.dart)와 보내기 대기열의 첨부
/// (outbox_files_web.dart)가 쓴다. 웹 전용(이 파일은 웹에서만 import한다).

/// 이 브라우저에서 IndexedDB를 쓸 수 있는지(사생활 보호 창 등에서 막혀 있으면 window.indexedDB를 읽기만 해도 던진다).
web.IDBFactory? idbFactory() {
  try {
    return web.window.indexedDB;
  } catch (_) {
    return null;
  }
}

StateError _idbError(web.IDBRequest req, String what) {
  String? message;
  try {
    message = req.error?.message;
  } catch (_) {}
  return StateError('IndexedDB $what: ${message ?? 'error'}');
}

/// DB를 연다 — 처음이거나 [version]이 올라갔으면 [upgrade]로 저장소·색인을 만든다.
Future<web.IDBDatabase> idbOpen(
  String name,
  int version,
  void Function(web.IDBDatabase db, int oldVersion) upgrade,
) {
  final factory = idbFactory();
  if (factory == null) {
    return Future.error(StateError('IndexedDB를 쓸 수 없습니다.'));
  }
  final done = Completer<web.IDBDatabase>();
  final req = factory.open(name, version);
  req.onupgradeneeded = ((web.IDBVersionChangeEvent e) {
    upgrade(req.result as web.IDBDatabase, e.oldVersion);
  }).toJS;
  req.onsuccess = ((web.Event _) {
    if (!done.isCompleted) done.complete(req.result as web.IDBDatabase);
  }).toJS;
  req.onerror = ((web.Event _) {
    if (!done.isCompleted) done.completeError(_idbError(req, 'open'));
  }).toJS;
  return done.future;
}

/// DB를 지운다(로그아웃 — 다른 탭이 쥐고 있으면 그 탭이 닫을 때 지워진다).
Future<void> idbDeleteDatabase(String name) {
  final factory = idbFactory();
  if (factory == null) return Future.value();
  final done = Completer<void>();
  final req = factory.deleteDatabase(name);
  req.onsuccess = ((web.Event _) {
    if (!done.isCompleted) done.complete();
  }).toJS;
  req.onerror = ((web.Event _) {
    if (!done.isCompleted) done.complete(); // 못 지워도 로그아웃은 이어 간다.
  }).toJS;
  return done.future;
}

/// 요청 하나의 결과.
Future<JSAny?> idbRequest(web.IDBRequest req) {
  final done = Completer<JSAny?>();
  req.onsuccess = ((web.Event _) {
    if (!done.isCompleted) done.complete(req.result);
  }).toJS;
  req.onerror = ((web.Event _) {
    if (!done.isCompleted) done.completeError(_idbError(req, 'request'));
  }).toJS;
  return done.future;
}

/// 트랜잭션이 끝날 때까지(쓰기가 정말 저장됐을 때).
Future<void> idbDone(web.IDBTransaction tx) {
  final done = Completer<void>();
  tx.oncomplete = ((web.Event _) {
    if (!done.isCompleted) done.complete();
  }).toJS;
  tx.onerror = ((web.Event _) {
    if (!done.isCompleted) done.completeError(StateError('IndexedDB 쓰기 실패'));
  }).toJS;
  tx.onabort = ((web.Event _) {
    if (!done.isCompleted) done.completeError(StateError('IndexedDB 쓰기 취소'));
  }).toJS;
  return done.future;
}

/// 커서를 끝까지(또는 [onEach]가 false를 돌려줄 때까지) 돈다. [onEach]는 커서가 가리키는 칸에서 바로(같은 이벤트 안에서) 불려
/// 그 자리에서 cursor.delete()·update()를 해도 된다.
Future<void> idbEachCursor(
  web.IDBRequest req,
  bool Function(web.IDBCursorWithValue cursor) onEach,
) {
  final done = Completer<void>();
  req.onsuccess = ((web.Event _) {
    final cursor = req.result;
    if (cursor == null) {
      if (!done.isCompleted) done.complete();
      return;
    }
    final c = cursor as web.IDBCursorWithValue;
    bool more;
    try {
      more = onEach(c);
    } catch (e) {
      if (!done.isCompleted) done.completeError(e);
      return;
    }
    if (more) {
      c.continue_();
    } else if (!done.isCompleted) {
      done.complete();
    }
  }).toJS;
  req.onerror = ((web.Event _) {
    if (!done.isCompleted) done.completeError(_idbError(req, 'cursor'));
  }).toJS;
  return done.future;
}
