import 'dart:async';

import 'package:client/services/secret_key_store.dart';
import 'package:client/services/secret_ratchet.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// 비밀 대화 저장소 줄(SecretKeyStore._serial) — Windows 저장소는 쓸 때마다 파일 하나를 통째로 다시 써서, 두 작업이 겹치면
/// 늦게 끝난 쪽이 먼저 끝난 쪽의 변경을 덮어쓴다(래칫 상태가 되돌아가 같은 키를 다시 쓰거나 대화가 어긋난다). 줄은 앞
/// 작업이 끝나야 다음 작업을 시작한다. 저장소 호출 하나가 멈춰 버리면 그 작업이 시작하고 30초 뒤부터, 그 호출이 끝날
/// 때까지 뒤 작업은 저장소를 건드리지 않고 실패한다(앱이 영영 기다리지도, 멈춘 쓰기와 섞이지도 않게). 시간은 줄을 선 때가
/// 아니라 작업이 시작한 때부터 잰다 — 줄이 길 때 앞 작업이 끝나기 전에 뒤 작업이 실패하지 않게. 줄은 앱 전체에 하나
/// (static)라 가짜 시계 테스트는 이 파일에 하나만 둔다.

class _MemoryStorage extends Fake implements FlutterSecureStorage {
  final Map<String, String> data = {};

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => data[key];

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => data.remove(key);
}

/// 쓰기마다 [delay]만큼 걸리는 저장소 — 저장소 줄이 앞 작업이 끝나기 전에 뒤 작업을 시작하는지 본다. [hangKey]에 쓰면
/// [hang]이 끝날 때까지 끝나지 않는다(멈춰 버린 저장소 호출).
class _SlowStorage extends _MemoryStorage {
  _SlowStorage(this.delay);
  final Duration delay;
  String? hangKey;
  Completer<void>? hang;
  int _active = 0;
  int maxConcurrent = 0;
  int completed = 0;

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key == hangKey) {
      await hang!.future;
      return super.write(key: key, value: value);
    }
    _active++;
    if (_active > maxConcurrent) maxConcurrent = _active;
    await Future<void>.delayed(delay);
    await super.write(key: key, value: value);
    _active--;
    completed++;
  }
}

SecretSkippedKey _skipped(String chain, int n) =>
    SecretSkippedKey(chain, n, List.filled(32, n + 1));

void main() {
  // 저장소 줄의 시간 초과는 30초라 가짜 시계(testWidgets)로 잰다.
  testWidgets(
    '저장소 줄 — 줄이 길어 앞 작업들을 30초 넘게 기다려도 앞 작업이 끝나기 전에는 시작하지 않고, 멈춰 버린 작업이 있으면 시작하고 30초 뒤부터 그 작업이 끝날 때까지 뒤 작업은 저장소를 건드리지 않고 실패한다',
    (tester) async {
      final slow = _SlowStorage(const Duration(seconds: 20));
      final slowStore = SecretKeyStore(storage: slow);
      for (var i = 0; i < 3; i++) {
        unawaited(slowStore.saveV1SkippedKeys('r', [_skipped('e0', i)]));
      }
      for (var t = 0; t < 70; t++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(slow.maxConcurrent, 1, reason: '앞 작업이 끝나기 전에 뒤 작업이 시작했다');
      expect(slow.completed, 3);

      // 멈춰 버린 저장소 호출 — 시작하고 30초 안에는 다음 작업이 기다린다.
      final hang = Completer<void>();
      slow
        ..hang = hang
        ..hangKey = 'secret/hang/skipped';
      unawaited(slowStore.saveV1SkippedKeys('hang', [_skipped('e0', 9)]));
      Object? afterError;
      var afterDone = false;
      unawaited(
        slowStore
            .saveV1SkippedKeys('after', [_skipped('e0', 10)])
            .then<void>(
              (_) => afterDone = true,
              onError: (Object e) => afterError = e,
            ),
      );
      for (var t = 0; t < 29; t++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(afterDone, isFalse);
      expect(afterError, isNull);
      // 30초가 지나면 기다리던 작업은 저장소를 건드리지 않고 실패한다 — 멈춘 쓰기가 뒤늦게 끝나며 덮어쓸 수 있다.
      for (var t = 0; t < 5; t++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(afterDone, isFalse);
      expect(afterError, isA<SecretStorageBusyException>());
      expect(slow.data.containsKey('secret/after/skipped'), isFalse);
      // 멈춘 동안 새로 줄을 선 작업도 바로 실패한다.
      Object? duringError;
      unawaited(
        slowStore
            .saveV1SkippedKeys('during', [_skipped('e0', 11)])
            .then<void>((_) {}, onError: (Object e) => duringError = e),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(duringError, isA<SecretStorageBusyException>());
      expect(slow.data.containsKey('secret/during/skipped'), isFalse);

      // 멈췄던 호출이 끝나면 다시 저장소를 쓴다.
      hang.complete();
      await tester.pump(const Duration(seconds: 1));
      expect(slow.data.containsKey('secret/hang/skipped'), isTrue);
      unawaited(slowStore.saveV1SkippedKeys('again', [_skipped('e0', 12)]));
      for (var t = 0; t < 25; t++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(slow.data.containsKey('secret/again/skipped'), isTrue);
      slowStore.dispose();
    },
  );
}
