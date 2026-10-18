import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as http_io;
import 'package:path_provider/path_provider.dart';
import 'package:web_socket/io_web_socket.dart';
import 'package:web_socket/web_socket.dart' as ws;

import 'app_platform.dart';
import '../l10n/tr.dart';

/// 서버가 자체 서명 인증서를 쓰기 때문에, 공인 CA 목록이 아니라 이 서버의 **공개키** 하나만
/// 신뢰하도록 설정한다(핀닝). 인증서 검증을 통째로 꺼버리는 방식(아무 인증서나 허용)은
/// 절대 쓰지 않는다 — 그러면 TLS를 붙이는 의미가 없다.
///
/// 신뢰할 인증서는 두 경로 중 하나에서 온다: 앱 빌드에 내장된 "assets/server_cert.pem"
/// (기존 방식), 또는 로그인 화면의 "서버 주소 변경"에서 페어링 코드로 받아와 로컬에 저장한
/// 인증서(우선순위가 더 높음 — [saveDynamicCert] 참고). 서버를 다른 PC로 옮겨 인증서가
/// 바뀌었을 때 앱을 재빌드하지 않고도 페어링으로 새 인증서를 받을 수 있게 하기 위함이다.
///
/// 그 인증서를 신뢰 목록에 넣는 것에 더해, 검증에 실패한 인증서라도 **저장한 인증서와 공개키가 같으면** 받는다
/// ([pinnedCertificateCallback]). 서버는 외부 주소를 더할 때 같은 키로 인증서만 다시 만들어서(server certs.js) 주소
/// 목록이나 발급 시각이 달라져도 공개키는 그대로다 — 그래서 외부 주소 추가·사내 IP 변경 뒤에도 다시 페어링할
/// 필요가 없다. 공개키가 같다는 건 그 개인키를 가진 서버라는 뜻이라(TLS 연결 과정에서 서버가 그 개인키로 서명한다)
/// 주소 검사를 건너뛰어도 바꿔치기를 막는 힘은 같다 — 대신 서버마다 키가 달라야 한다(키 파일을 다른 서버로 복사하지 않기).
///
/// 웹 빌드는 TLS를 브라우저가 맡아서 앱이 인증서를 고를 수 없다 — 그래서 웹에서는 핀닝 없이
/// 브라우저 기본 연결을 쓰고, 서버는 브라우저가 신뢰하는 공인 인증서를 써야 한다.
class PinnedTls {
  static _Pin? _pin;
  static http.Client? _httpClient;

  static Future<File> _dynamicCertFile() async {
    final dir = await getApplicationSupportDirectory();
    return File(
      '${dir.path}${AppPlatform.pathSeparator}pinned_server_cert.pem',
    );
  }

  static Future<_Pin> _loadPin() async {
    final cached = _pin;
    if (cached != null) return cached;
    final dynamicFile = await _dynamicCertFile();
    final bytes = await dynamicFile.exists()
        ? await dynamicFile.readAsBytes()
        : (await rootBundle.load(
            'assets/server_cert.pem',
          )).buffer.asUint8List();
    return _pin = _Pin.fromPem(bytes);
  }

  /// 페어링 코드로 서버에서 새로 받아온 인증서를 저장하고, 캐시된 핀/httpClient를
  /// 전부 초기화해서 이후 모든 연결(REST/소켓/이미지 로딩 포함)이 새 인증서를 즉시 쓰게 한다.
  static Future<void> saveDynamicCert(String pemContent) async {
    final file = await _dynamicCertFile();
    await file.writeAsString(pemContent);
    _pin = null;
    _httpClient = null;
    HttpOverrides.global = _PinnedHttpOverrides(await _loadPin());
  }

  /// [pinnedPem](PEM 인증서 하나 이상)의 공개키로만 연결하는 HttpClient — 앱 전체가 쓰는 것과 같은 설정이다(시험용).
  @visibleForTesting
  static HttpClient pinnedHttpClientFor(List<int> pinnedPem) =>
      _Pin.fromPem(pinnedPem).httpClient();

  /// 검증에 실패한 서버 인증서를 받을지 정하는 badCertificateCallback — [cert]의 공개키(SPKI)가 [pinnedSpkis] 중
  /// 하나와 같을 때만 받는다. BoringSSL은 검증 오류마다 그 오류가 난 인증서로 이 콜백을 부르고 하나라도 거절하면
  /// 연결을 끊는다. 서버가 내민 인증서(체인의 첫 장)는 그 공개키에 맞는 개인키로 연결을 서명해야 하니, 다른 키의
  /// 인증서로 우리 인증서의 신뢰를 빌리려 하면(체인 뒤에 우리 인증서를 붙여도) 첫 장에서 난 오류가 거절된다.
  @visibleForTesting
  static bool Function(X509Certificate cert, String host, int port)
  pinnedCertificateCallback(List<List<int>> pinnedSpkis) {
    return (cert, _, _) {
      final spki = subjectPublicKeyInfo(cert.der);
      return spki != null && pinnedSpkis.any((p) => _bytesEqual(p, spki));
    };
  }

  /// 인증서(DER)에서 공개키 부분(SubjectPublicKeyInfo — 태그·길이 포함 DER)을 꺼낸다. 형식이 이상하면 null.
  /// Certificate ::= SEQUENCE { tbsCertificate SEQUENCE { [0] version(생략 가능), serialNumber, signature,
  /// issuer, validity, subject, subjectPublicKeyInfo, ... }, ... } (RFC 5280).
  @visibleForTesting
  static List<int>? subjectPublicKeyInfo(List<int> der) {
    final cert = _DerElement.read(der, 0);
    if (cert == null || cert.tag != 0x30) return null;
    final tbs = _DerElement.read(der, cert.contentStart);
    if (tbs == null || tbs.tag != 0x30) return null;
    var offset = tbs.contentStart;
    var element = _DerElement.read(der, offset);
    if (element != null && element.tag == 0xA0) {
      offset = element.end;
      element = _DerElement.read(der, offset);
    }
    // serialNumber, signature, issuer, validity, subject를 건너뛴다.
    for (var i = 0; i < 5; i++) {
      if (element == null || element.end > tbs.end) return null;
      offset = element.end;
      element = _DerElement.read(der, offset);
    }
    if (element == null || element.tag != 0x30 || element.end > tbs.end) {
      return null;
    }
    return der.sublist(offset, element.end);
  }

  /// 서버 콘솔에 "pair"를 입력하면 나오는 4자리 코드(또는 초대 토큰)로, 인증서를 빌드에 내장하지
  /// 않고도 서버에서 받아와 [saveDynamicCert]로 고정(pin)한다. [address]는 메인 HTTPS 주소(예:
  /// https://192.168.0.62:3000).
  ///
  /// 서버 주소가 도메인 이름(예: xxx.iptime.org)이면 먼저 그 이름의 443 포트에서 **보통의 인증서 검증**을 거쳐
  /// 받는다([pairOverPublicTls]) — 웹 앱 주소를 설정한 서버는 그 포트에 공인 인증서(Let's Encrypt)로 같은 /pair를
  /// 연다. 공인 인증 기관이 확인해 준 연결로 받은 인증서(메인 포트의 자체 서명 인증서)는 중간에서 바꿔치기될 수
  /// 없다 — 아래 기존 경로는 인증서를 모르는 채로 붙기 때문에, 중간에서 TLS를 대신 맺은 쪽이 자기 인증서를 본문에도
  /// 실어 보내면 막을 수 없다. 그 포트가 없거나(기능을 안 켠 서버·예전 서버·포트를 안 연 공유기) 인증서가 맞지 않으면
  /// 기존 경로로 넘어가고, 서버가 코드를 거절했으면 그 문구를 그대로 보여 준다(기존 경로로 다시 물어도 같은 답이고
  /// 틀린 횟수만 늘어난다). IP 주소에는 공인 인증서가 없으니 기존 경로 그대로다.
  ///
  /// 기존 경로([_pairOverMainPort]): 먼저 메인 HTTPS 포트의 /pair로 받는다 — 공유기에 이 포트만 열려 있는 사내망
  /// 밖(LTE/5G)에서도 되게 하려는 것이다([_pairOverHttps]). 그 경로가 없는 예전 서버이거나 연결이 안 되면, 사내망의
  /// 평문 페어링 서버(메인 포트+1, server/src/pairing.js)로 받는다.
  static Future<void> pairAndSaveCert(String address, String code) async {
    final pem = await pairingCertificate(
      Uri.parse(address.trim()),
      code,
      overPublicTls: pairOverPublicTls,
      overMainPort: _pairOverMainPort,
    );
    await saveDynamicCert(pem);
  }

  /// 페어링으로 고정할 인증서를 어느 경로로 받을지 정한다 — 실제로 받는 부분은 넘겨받아서 네트워크 없이 시험할 수
  /// 있게 했다. [overPublicTls]는 받으면 PEM, 연결·TLS 문제로 못 받으면 null(→ [overMainPort]로 넘어간다), 서버가 코드를
  /// 거절하면 그 문구로 예외(그대로 올려 보낸다).
  @visibleForTesting
  static Future<String> pairingCertificate(
    Uri address,
    String code, {
    required Future<String?> Function(Uri uri) overPublicTls,
    required Future<String> Function(Uri address, String code) overMainPort,
  }) async {
    final publicUri = publicTlsPairingUri(address, code);
    if (publicUri != null) {
      final pem = await overPublicTls(publicUri);
      if (pem != null) return pem;
    }
    return overMainPort(address, code);
  }

  /// 공인 인증서로 검증하며 페어링할 주소 — 서버 주소가 도메인 이름일 때만 `https://<그 이름>/pair/<코드>`(443 포트,
  /// 서버의 웹 앱 전용 HTTPS 포트). IP 주소나 점 없는 이름(localhost, PC 이름)이면 null — 공인 인증서는 공개
  /// 도메인에만 나오므로 물어봐야 시간만 쓴다.
  @visibleForTesting
  static Uri? publicTlsPairingUri(Uri address, String code) {
    final host = address.host;
    if (!host.contains('.') || InternetAddress.tryParse(host) != null) {
      return null;
    }
    return Uri(scheme: 'https', host: host, pathSegments: ['pair', code]);
  }

  /// [uri]에서 운영체제가 믿는 공인 인증 기관 목록으로 **보통의 인증서 검증**을 거쳐 인증서를 받는다. 앱 전체의
  /// HttpClient는 [installGlobalHttpOverrides]가 이 서버의 자체 서명 인증서 하나만 믿게 바꿔 두어서(그대로 만들면 공인
  /// 인증서를 거절한다) 이 연결 하나만 그 설정을 비켜 간다. 리다이렉트는 따라가지 않는다 — 검증한 바로 그 도메인의
  /// 답만 믿는다.
  ///
  /// 받으면 PEM, 서버가 코드를 거절하면 그 문구로 예외([publicPairingResult]), 그 밖에는 전부 null(기존 경로로
  /// 넘어간다) — 포트가 닫혔거나, 공인 인증서가 아니거나 이름이 다르거나, 다른 웹 서버가 답했거나, 예상 못 한 오류라도
  /// 이 경로 때문에 지금까지 되던 페어링이 막히면 안 된다. [trustedRoots]는 시험용이다.
  @visibleForTesting
  static Future<String?> pairOverPublicTls(
    Uri uri, {
    SecurityContext? trustedRoots,
  }) async {
    final client = HttpOverrides.runWithHttpOverrides(
      () => HttpClient(
        context: trustedRoots ?? SecurityContext(withTrustedRoots: true),
      ),
      _SystemTrustHttpOverrides(),
    )..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 8));
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 10));
      return publicPairingResult(response.statusCode, text);
    } on String {
      rethrow; // 서버가 코드를 거절했다(publicPairingResult).
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 공인 인증서로 검증한 연결에서 받은 /pair 응답을 읽는다 — 200이면 실린 인증서(PEM). 서버가 코드를 거절했으면 그
  /// 문구로 예외 — 서버의 /pair가 코드를 거절할 때 쓰는 404(틀림·만료)와 429(시도가 너무 많음)에 `{error}`가 실린 경우만이다.
  /// 그 밖(그 도메인의 다른 웹 서버·예전 서버의 HTML 404, 리다이렉트, 다른 4xx, 서버 오류 등)은 null이라 기존 경로로
  /// 넘어간다 — 이 경로가 엉뚱한 답을 "거절"로 읽어 지금까지 되던 페어링을 막으면 안 된다.
  @visibleForTesting
  static String? publicPairingResult(int status, String body) {
    final Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      return null;
    }
    if (json is! Map) return null;
    if (status == 200) {
      final cert = json['cert'];
      return cert is String && cert.contains('-----BEGIN CERTIFICATE-----')
          ? cert
          : null;
    }
    final error = json['error'];
    if ((status == 404 || status == 429) &&
        error is String &&
        error.isNotEmpty) {
      throw error;
    }
    return null;
  }

  /// 지금까지의 페어링 경로 — 메인 HTTPS 포트([_pairOverHttps]), 안 되면 사내망의 평문 페어링 서버(메인 포트+1).
  static Future<String> _pairOverMainPort(Uri uri, String code) async {
    final pem = await _pairOverHttps(uri, code);
    if (pem != null) return pem;
    final pairingPort = (uri.hasPort ? uri.port : 443) + 1;
    final pairingUri = Uri(
      scheme: 'http',
      host: uri.host,
      port: pairingPort,
      path: '/pair/$code',
    );
    final res = await http.get(pairingUri).timeout(const Duration(seconds: 10));
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw body['error'] as String? ?? tr('코드가 올바르지 않거나 만료되었습니다.');
    }
    return body['cert'] as String;
  }

  /// 메인 HTTPS 포트에서 인증서를 받는다. 아직 이 서버 인증서를 모르는 상태(그래서 페어링하는
  /// 것)라 인증서 검증 없이 연결하되, 응답에 실린 인증서가 **실제 TLS 연결에 쓰인 인증서와
  /// 같은지** 대조해서 다르면 거부한다 — 평문 HTTP로 받던 기존 방식보다 중간에서 바꿔치기하기
  /// 어렵다. 코드가 틀렸으면 서버의 에러 문구로 예외, 이 경로가 없는 예전 서버이거나 연결이
  /// 안 되면 null(평문 페어링 서버로 넘어간다).
  static Future<String?> _pairOverHttps(Uri address, String code) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..badCertificateCallback = (_, _, _) => true;
    try {
      final request = await client.getUrl(
        address.replace(path: '/pair/$code', query: null),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final text = await response.transform(utf8.decoder).join();
      final Map<String, dynamic> body;
      try {
        body = jsonDecode(text) as Map<String, dynamic>;
      } on FormatException {
        return null; // 예전 서버(이 경로 없음 — Express 기본 404 페이지).
      }
      if (response.statusCode != 200) {
        throw body['error'] as String? ?? tr('코드가 올바르지 않거나 만료되었습니다.');
      }
      final pem = body['cert'] as String;
      final presented = response.certificate?.der;
      if (presented == null || !_sameCertificate(pem, presented)) {
        throw tr('서버 인증서가 일치하지 않습니다. 네트워크를 바꿔 다시 시도하거나 관리자에게 문의하세요.');
      }
      return pem;
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    } on HandshakeException {
      return null;
    } on HttpException {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 페어링 응답에 실린 인증서가 그 TLS 연결에 실제로 쓰인 인증서와 똑같은지 — 서버는 같은 파일을 둘 다에 쓰므로
  /// 공개키만이 아니라 인증서 전체를 비교한다(더 엄격한 쪽).
  static bool _sameCertificate(String pem, List<int> der) {
    final ders = _pemCertificates(utf8.encode(pem));
    return ders.length == 1 && _bytesEqual(ders.single, der);
  }

  /// REST 호출(ApiClient)에 쓸, 이 서버의 공개키만 신뢰하는 http.Client. 앱 전체에서 하나만
  /// 만들어 재사용한다(로그인/재로그인마다 새로 만들면 연결 풀이 계속 새로 생겨 낭비된다).
  static Future<http.Client> httpClient() async {
    final cached = _httpClient;
    if (cached != null) return cached;
    if (kIsWeb) return _httpClient = http.Client();
    final pin = await _loadPin();
    final client = http_io.IOClient(pin.httpClient());
    _httpClient = client;
    return client;
  }

  /// socket_io_client의 OptionBuilder.setWebSocketConnector에 넘길 커넥터.
  static Future<
    Future<ws.WebSocket> Function(
      Uri uri, {
      Iterable<String>? protocols,
      Map<String, String>? headers,
    })
  >
  webSocketConnector() async {
    if (kIsWeb) {
      // 브라우저 WebSocket은 헤더를 붙일 수 없다(토큰은 socket.io auth로 보내서 상관없다).
      return (
        Uri uri, {
        Iterable<String>? protocols,
        Map<String, String>? headers,
      }) => ws.WebSocket.connect(uri, protocols: protocols);
    }
    final pin = await _loadPin();
    return (
      Uri uri, {
      Iterable<String>? protocols,
      Map<String, String>? headers,
    }) async {
      final ioSocket = await WebSocket.connect(
        uri.toString(),
        protocols: protocols,
        headers: headers,
        customClient: pin.httpClient(),
      );
      return IOWebSocket.fromWebSocket(ioSocket);
    };
  }

  /// `NetworkImage`/`CachedNetworkImage`처럼 우리가 직접 만들지 않는 `HttpClient`를
  /// 내부적으로 새로 만들어 쓰는 코드들이 있다(둘 다 우리 ApiClient/ChatSocket과 무관하게
  /// 자기 나름의 dart:io HttpClient()를 새로 만든다) — 그런 곳까지 일일이 고쳐줄 수 없으니,
  /// 앱 전체의 `HttpClient()` 생성 자체를 가로채서 전부 이 서버의 공개키만 신뢰하도록 만든다.
  /// main()에서 runApp() 전에 반드시 await로 호출해야 한다.
  static Future<void> installGlobalHttpOverrides() async {
    if (kIsWeb) return;
    HttpOverrides.global = _PinnedHttpOverrides(await _loadPin());
  }
}

/// 핀닝할 인증서들 — 신뢰 목록에 넣을 SecurityContext와, 검증에 실패한 인증서를 받을지 볼 공개키들.
class _Pin {
  final SecurityContext context;
  final List<List<int>> spkis;
  _Pin(this.context, this.spkis);

  factory _Pin.fromPem(List<int> pem) {
    final spkis = _pemCertificates(
      pem,
    ).map(PinnedTls.subjectPublicKeyInfo).whereType<List<int>>().toList();
    if (spkis.isEmpty) throw FormatException(tr('핀닝할 서버 인증서를 읽지 못했습니다.'));
    final context = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(pem);
    return _Pin(context, spkis);
  }

  late final bool Function(X509Certificate, String, int) callback =
      PinnedTls.pinnedCertificateCallback(spkis);

  /// 이 핀으로 연결하는 HttpClient. 앱 전체 설정([_PinnedHttpOverrides])을 거치지 않고 만든 뒤 콜백을 단다.
  HttpClient httpClient() => HttpOverrides.runWithHttpOverrides(
    () => HttpClient(context: context),
    _SystemTrustHttpOverrides(),
  )..badCertificateCallback = callback;
}

class _PinnedHttpOverrides extends HttpOverrides {
  final _Pin pin;
  _PinnedHttpOverrides(this.pin);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(pin.context)
      ..badCertificateCallback = pin.callback;
  }
}

/// PEM 글에 든 인증서들(DER). BEGIN/END CERTIFICATE 사이만 읽는다.
List<List<int>> _pemCertificates(List<int> pem) {
  final text = utf8.decode(pem, allowMalformed: true);
  return RegExp(
        r'-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----',
      )
      .allMatches(text)
      .map((m) {
        try {
          return base64Decode(m.group(1)!.replaceAll(RegExp(r'\s'), ''));
        } on FormatException {
          return null;
        }
      })
      .whereType<List<int>>()
      .toList();
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// DER 요소 하나의 위치 — 태그 한 바이트, 길이(짧은·긴 형식), 내용. 인증서에서 공개키를 꺼내는 데만 쓴다.
class _DerElement {
  final int tag;
  final int contentStart;
  final int end;
  _DerElement(this.tag, this.contentStart, this.end);

  static _DerElement? read(List<int> der, int offset) {
    if (offset + 2 > der.length) return null;
    final tag = der[offset];
    final lengthByte = der[offset + 1];
    var pos = offset + 2;
    int length;
    if (lengthByte < 0x80) {
      length = lengthByte;
    } else {
      final count = lengthByte & 0x7f;
      if (count == 0 || count > 4 || pos + count > der.length) return null;
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | der[pos++];
      }
    }
    final end = pos + length;
    if (end > der.length) return null;
    return _DerElement(tag, pos, end);
  }
}

/// 아무것도 바꾸지 않는 설정 — [PinnedTls.pairOverPublicTls]가 이 안에서 만든 HttpClient는 앱 전체에 걸어 둔
/// [_PinnedHttpOverrides](넘겨준 SecurityContext를 무시하고 이 서버의 자체 서명 인증서 하나만 믿게 바꾼다)를 거치지
/// 않고, 넘겨준 SecurityContext(공인 인증 기관 목록)를 그대로 쓴다.
class _SystemTrustHttpOverrides extends HttpOverrides {}
