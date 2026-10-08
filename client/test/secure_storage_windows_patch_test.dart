@TestOn('windows')
library;

// 고친 Windows 보안 저장소 사본(packages/flutter_secure_storage_windows)의 내부를 직접 본다.
// ignore_for_file: implementation_imports, depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_secure_storage_windows/src/flutter_secure_storage_windows_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win32/win32.dart';

/// 고친 Windows 보안 저장소(packages/flutter_secure_storage_windows/TANGOTALK_PATCHES.md) — 실제 DPAPI로 임시 폴더에
/// 저장한다. 파일을 그 자리에 덮어쓰지 않고 통째로 바꿔 끼우는지, 읽지 못한 파일을 지우지 않고 남기는지, 겹친 작업이
/// 서로의 변경을 덮어쓰지 않는지 본다.

/// 읽고 쓸 때마다 잠깐 기다리는 메모리 저장소 — 작업이 겹치면 늦게 끝난 쪽이 먼저 끝난 쪽을 덮어쓰게 된다.
class _SlowMapStorage extends MapStorage {
  Map<String, String> data = {};
  int saves = 0;

  @override
  Future<Map<String, String>> load(Map<String, String> options) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return Map.of(data);
  }

  @override
  Future<void> save(
    Map<String, String> data,
    Map<String, String> options,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    this.data = Map.of(data);
    saves++;
  }

  @override
  Future<void> clear(Map<String, String> options) async => data = {};
}

const _noBackwardCompatibility = {'useBackwardCompatibility': 'false'};

void main() {
  late Directory dir;
  late String filePath;
  late DpapiJsonFileMapStorage storage;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fss_patch_');
    filePath = '${dir.path}\\$encryptedJsonFileName';
    storage = DpapiJsonFileMapStorage(filePath: filePath);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('DPAPI로 암호화해 저장하고 그대로 읽는다 — 임시 파일은 남지 않고, 평문이 파일에 보이지 않는다', () async {
    await storage.save({'secret/r1/chain': '비밀 값', 'k': 'v'}, const {});
    expect(await storage.load(const {}), {'secret/r1/chain': '비밀 값', 'k': 'v'});
    expect(File('$filePath$temporaryFileSuffix$pid').existsSync(), isFalse);
    final raw = File(filePath).readAsBytesSync();
    expect(String.fromCharCodes(raw).contains('secret/r1/chain'), isFalse);

    // 다시 쓰면 통째로 바뀐다.
    await storage.save({'k': 'v2'}, const {});
    expect(await storage.load(const {}), {'k': 'v2'});
    expect(File('$filePath$temporaryFileSuffix$pid').existsSync(), isFalse);
  });

  test('쓰다 끊겨 남은 임시 파일은 읽지 않고(마지막으로 다 쓴 내용을 읽음), 다음 저장이 덮어써 치운다', () async {
    await storage.save({'k': '다 쓴 값'}, const {});
    // 새 내용을 임시 파일에 쓰다 끊긴 흉내 — 원래 파일은 그대로다.
    File('$filePath$temporaryFileSuffix$pid').writeAsBytesSync([1, 2, 3]);
    expect(await storage.load(const {}), {'k': '다 쓴 값'});
    await storage.save({'k': '새 값'}, const {});
    expect(await storage.load(const {}), {'k': '새 값'});
    expect(File('$filePath$temporaryFileSuffix$pid').existsSync(), isFalse);
  });

  test(
    '읽지 못한 파일(깨짐)은 지우지 않고 .unreadable로 옮겨 남긴다 — 그 뒤로는 빈 저장소로 읽고 새로 쓸 수 있다',
    () async {
      final broken = [9, 8, 7, 6, 5, 4, 3, 2, 1];
      File(filePath).writeAsBytesSync(broken);
      await expectLater(
        Future.sync(() => storage.load(const {})),
        throwsA(anything),
      );
      expect(File(filePath).existsSync(), isFalse);
      final kept = File('$filePath$unreadableFileSuffix');
      expect(kept.readAsBytesSync(), broken);

      expect(await storage.load(const {}), isEmpty);
      await storage.save({'k': 'v'}, const {});
      expect(await storage.load(const {}), {'k': 'v'});
      // 다음에 또 깨져도 처음 남긴 것(원래 키가 든 것)은 덮어쓰지 않고, 시각을 붙인 이름으로 따로 남긴다.
      File(filePath).writeAsBytesSync([4, 4, 4]);
      await expectLater(
        Future.sync(() => storage.load(const {})),
        throwsA(anything),
      );
      expect(kept.readAsBytesSync(), broken);
      final later = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('$unreadableFileSuffix-'))
          .toList();
      expect(later, hasLength(1));
      expect(later.single.readAsBytesSync(), [4, 4, 4]);
    },
  );

  test(
    '다른 프로그램이 파일을 잠깐 잡고 있어 읽지 못하면 빈 저장소로 보지 않는다 — 쓰기가 실패할 뿐 저장된 키는 그대로다',
    () async {
      await storage.save({'device': '신원키', 'secret/r1/chain': '체인'}, const {});
      final platform = createFlutterSecureStorageWindows(
        MethodChannelFlutterSecureStorage(),
        storage,
      );
      final holder = await File(filePath).open(mode: FileMode.append);
      await holder.lock(FileLock.exclusive);
      try {
        await expectLater(
          platform.write(
            key: 'k',
            value: 'v',
            options: _noBackwardCompatibility,
          ),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        await holder.unlock();
        await holder.close();
      }
      expect(await storage.load(const {}), {
        'device': '신원키',
        'secret/r1/chain': '체인',
      });
      await platform.write(
        key: 'k',
        value: 'v',
        options: _noBackwardCompatibility,
      );
      expect((await storage.load(const {}))['k'], 'v');
      expect((await storage.load(const {}))['device'], '신원키');
    },
  );

  test('복호화는 되지만 JSON 객체가 아닌 내용도 지우지 않고 옮겨 남긴다', () async {
    for (final plain in ['JSON이 아님', '["객체가 아님"]']) {
      // 앞 차례에 남긴 것을 치워 이번 것이 기본 이름으로 남게 한다.
      final previous = File('$filePath$unreadableFileSuffix');
      if (previous.existsSync()) previous.deleteSync();
      final encrypted = _dpapiProtect(utf8.encode(plain));
      File(filePath).writeAsBytesSync(encrypted);
      await expectLater(
        Future.sync(() => storage.load(const {})),
        throwsA(isA<FormatException>()),
        reason: plain,
      );
      expect(File(filePath).existsSync(), isFalse, reason: plain);
      expect(
        File('$filePath$unreadableFileSuffix').readAsBytesSync(),
        encrypted,
        reason: plain,
      );
    }
  });

  test('겹친 쓰기·지우기가 서로의 변경을 덮어쓰지 않는다 — 한 번에 하나씩 한다', () async {
    final slow = _SlowMapStorage();
    final platform = createFlutterSecureStorageWindows(
      MethodChannelFlutterSecureStorage(),
      slow,
    );
    await Future.wait([
      for (var i = 0; i < 20; i++)
        platform.write(
          key: 'k$i',
          value: 'v$i',
          options: _noBackwardCompatibility,
        ),
    ]);
    expect(slow.data.length, 20);
    await Future.wait([
      for (var i = 0; i < 10; i++)
        platform.delete(key: 'k$i', options: _noBackwardCompatibility),
      platform.write(key: 'new', value: 'x', options: _noBackwardCompatibility),
    ]);
    expect(slow.data.keys.toSet(), {
      for (var i = 10; i < 20; i++) 'k$i',
      'new',
    });
    expect(
      await platform.readAll(options: _noBackwardCompatibility),
      slow.data,
    );
  });

  test('한 작업이 실패해도 다음 작업은 그대로 한다', () async {
    final slow = _SlowMapStorage();
    final platform = createFlutterSecureStorageWindows(
      MethodChannelFlutterSecureStorage(),
      _FailingOnce(slow),
    );
    final failed = platform.write(
      key: 'a',
      value: '1',
      options: _noBackwardCompatibility,
    );
    final next = platform.write(
      key: 'b',
      value: '2',
      options: _noBackwardCompatibility,
    );
    await expectLater(failed, throwsA(isA<StateError>()));
    await next;
    expect(slow.data, {'b': '2'});
  });
}

/// 처음 한 번만 저장에 실패하는 저장소.
class _FailingOnce extends MapStorage {
  _FailingOnce(this.inner);
  final _SlowMapStorage inner;
  var _failed = false;

  @override
  FutureOr<Map<String, String>> load(Map<String, String> options) =>
      inner.load(options);

  @override
  FutureOr<void> save(Map<String, String> data, Map<String, String> options) {
    if (!_failed) {
      _failed = true;
      throw StateError('디스크 오류');
    }
    return inner.save(data, options);
  }

  @override
  FutureOr<void> clear(Map<String, String> options) => inner.clear(options);
}

/// [plain]을 이 Windows 사용자의 DPAPI로 암호화한다(저장소와 같은 방식).
List<int> _dpapiProtect(List<int> plain) => using((alloc) {
  final input = alloc<Uint8>(plain.length);
  input.asTypedList(plain.length).setAll(0, plain);
  final inBlob = alloc<CRYPT_INTEGER_BLOB>();
  inBlob.ref
    ..cbData = plain.length
    ..pbData = input;
  final outBlob = alloc<CRYPT_INTEGER_BLOB>();
  if (CryptProtectData(
        inBlob,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        0,
        outBlob,
      ) ==
      0) {
    throw WindowsException(GetLastError());
  }
  try {
    return List<int>.of(outBlob.ref.pbData.asTypedList(outBlob.ref.cbData));
  } finally {
    LocalFree(outBlob.ref.pbData);
  }
});
