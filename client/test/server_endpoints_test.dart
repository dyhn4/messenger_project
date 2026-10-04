import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:client/services/server_endpoints.dart';

void main() {
  const internal = 'https://192.168.0.10:3000';
  const internal2 = 'https://10.0.0.5:3000';
  const external = 'https://xxx.iptime.org:3000';

  group('normalizeServerUrl', () {
    test('비었으면 null, 끝 슬래시는 뗀다', () {
      expect(normalizeServerUrl(null), isNull);
      expect(normalizeServerUrl('  '), isNull);
      expect(normalizeServerUrl('$external/'), external);
    });
  });

  group('endpointCandidates', () {
    test('외부 주소가 없으면 연결해둔 주소뿐(전환 안 함)', () {
      expect(endpointCandidates(primary: internal), [internal]);
    });

    test('사내 주소로 연결해뒀으면 사내 → 외부', () {
      expect(
        endpointCandidates(
          primary: internal,
          external: external,
          internals: [internal2],
        ),
        [internal, external],
      );
    });

    test('밖에서 외부 주소로 페어링했으면 서버가 알려준 사내 주소들 → 외부', () {
      expect(
        endpointCandidates(
          primary: external,
          external: external,
          internals: [internal, internal2],
        ),
        [internal, internal2, external],
      );
    });
  });

  group('endpointProbeOrder', () {
    test('기본은 후보 순서 그대로(사내 먼저) — 사내로 돌아오면 사내 주소로 되돌아간다', () {
      expect(endpointProbeOrder([internal, external], current: external), [
        internal,
        external,
      ]);
    });

    test('앱을 켤 때는 지난번 주소부터 본다', () {
      expect(
        endpointProbeOrder(
          [internal, external],
          current: external,
          currentFirst: true,
        ),
        [external, internal],
      );
    });

    test('지난번 주소가 지금 후보에 없으면 무시한다', () {
      expect(
        endpointProbeOrder(
          [internal, external],
          current: 'https://old.example.com:3000',
          currentFirst: true,
        ),
        [internal, external],
      );
    });
  });

  group('findReachableEndpoint', () {
    test('순서상 앞에서 연결되는 주소를 고른다', () async {
      final picked = await findReachableEndpoint([
        internal,
        external,
      ], (url) async => true);
      expect(picked, internal);
    });

    test('사내망 밖이면 외부 주소', () async {
      final picked = await findReachableEndpoint([
        internal,
        internal2,
        external,
      ], (url) async => url == external);
      expect(picked, external);
    });

    test('모든 주소를 동시에 확인한다(사내 IP마다 하나씩 기다리지 않게)', () async {
      final started = <String>[];
      final gate = Completer<void>();
      final future = findReachableEndpoint([internal, internal2, external], (
        url,
      ) async {
        started.add(url);
        await gate.future;
        return url == external;
      });
      await Future<void>.delayed(Duration.zero);
      expect(started, [internal, internal2, external]);
      gate.complete();
      expect(await future, external);
    });

    test('다 안 되면(오프라인) null', () async {
      expect(
        await findReachableEndpoint([internal, external], (_) async => false),
        isNull,
      );
    });
  });
}
