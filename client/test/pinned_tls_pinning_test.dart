import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:client/services/pinned_tls.dart';

/// 공개키 핀닝(PinnedTls) — 127.0.0.1에 진짜 TLS 서버를 띄워 붙어 본다.
///
/// test/fixtures/pinning/의 인증서는 server/node_modules의 selfsigned로 만들었다(server certs.js와 같은 설정):
///  - a_cert.pem(+key1.pem): 원래 인증서 — localhost·127.0.0.1
///  - b_same_key_cert.pem: key1로 다시 만든 인증서 — 127.0.0.1은 빠지고 new.example.org만(외부 주소를 더해 다시 만든 경우)
///  - c_other_key_cert.pem(+key2.pem): 다른 키, 이름·주소는 a와 같음(다른 서버나 바꿔치기한 서버)
///  - d_forged_chain.pem(+d_forged_key.pem): 발급자 이름만 messenger-server인 가짜 인증서 뒤에 a를 붙인 체인
///    (a의 신뢰를 빌려 보려는 경우)
void main() {
  String fixture(String name) => 'test/fixtures/pinning/$name';
  List<int> bytes(String name) => File(fixture(name)).readAsBytesSync();

  Future<HttpServer> serve(String chain, String key) async {
    final context = SecurityContext()
      ..useCertificateChain(fixture(chain))
      ..usePrivateKey(fixture(key));
    final server = await HttpServer.bindSecure('127.0.0.1', 0, context);
    server.listen((req) => req.response
      ..write('ok')
      ..close());
    return server;
  }

  Future<int> get(HttpClient client, HttpServer server) async {
    try {
      final req = await client
          .getUrl(Uri.parse('https://127.0.0.1:${server.port}/'))
          .timeout(const Duration(seconds: 10));
      final res = await req.close().timeout(const Duration(seconds: 10));
      await res.drain<void>();
      return res.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  test('저장한 인증서 그대로인 서버에는 붙는다', () async {
    final server = await serve('a_cert.pem', 'key1.pem');
    addTearDown(() => server.close(force: true));
    expect(await get(PinnedTls.pinnedHttpClientFor(bytes('a_cert.pem')), server), 200);
  });

  test('같은 키로 다시 만든 인증서(주소 목록이 달라 이 주소가 없어도)에는 그대로 붙는다', () async {
    final server = await serve('b_same_key_cert.pem', 'key1.pem');
    addTearDown(() => server.close(force: true));
    expect(await get(PinnedTls.pinnedHttpClientFor(bytes('a_cert.pem')), server), 200);
  });

  test('새 인증서로 다시 페어링한 앱도 예전 인증서를 쓰는 서버에 붙는다(키가 같으므로)', () async {
    final server = await serve('a_cert.pem', 'key1.pem');
    addTearDown(() => server.close(force: true));
    expect(await get(PinnedTls.pinnedHttpClientFor(bytes('b_same_key_cert.pem')), server), 200);
  });

  test('키가 다른 서버는 이름·주소가 같아도 거절한다', () async {
    final server = await serve('c_other_key_cert.pem', 'key2.pem');
    addTearDown(() => server.close(force: true));
    await expectLater(
      get(PinnedTls.pinnedHttpClientFor(bytes('a_cert.pem')), server),
      throwsA(isA<HandshakeException>()),
    );
  });

  test('다른 키의 인증서 뒤에 우리 인증서를 붙인 체인도 거절한다', () async {
    final server = await serve('d_forged_chain.pem', 'd_forged_key.pem');
    addTearDown(() => server.close(force: true));
    await expectLater(
      get(PinnedTls.pinnedHttpClientFor(bytes('a_cert.pem')), server),
      throwsA(isA<HandshakeException>()),
    );
  });

  test('인증서에서 공개키를 꺼낸다 — 같은 키면 같고, 다른 키면 다르다', () {
    List<int> der(String name) {
      final pem = File(fixture(name)).readAsStringSync();
      final body = pem
          .split(RegExp(r'\r?\n'))
          .where((l) => l.isNotEmpty && !l.startsWith('-----'))
          .join();
      return Uri.parse('data:;base64,$body').data!.contentAsBytes();
    }

    final a = PinnedTls.subjectPublicKeyInfo(der('a_cert.pem'));
    final b = PinnedTls.subjectPublicKeyInfo(der('b_same_key_cert.pem'));
    final c = PinnedTls.subjectPublicKeyInfo(der('c_other_key_cert.pem'));
    expect(a, isNotNull);
    expect(a![0], 0x30); // SEQUENCE
    expect(b, a);
    expect(c, isNot(a));
    expect(PinnedTls.subjectPublicKeyInfo([0x30, 0x03, 0x02, 0x01]), isNull);
    expect(PinnedTls.subjectPublicKeyInfo(const []), isNull);
  });

  test('인증서를 읽지 못한 핀은 만들지 않는다(아무 인증서나 받는 상태가 되지 않게)', () {
    expect(
      () => PinnedTls.pinnedHttpClientFor('not a pem'.codeUnits),
      throwsA(isA<FormatException>()),
    );
  });
}
