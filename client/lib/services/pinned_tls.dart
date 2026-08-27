import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as http_io;
import 'package:path_provider/path_provider.dart';
import 'package:web_socket/io_web_socket.dart';
import 'package:web_socket/web_socket.dart' as ws;

/// 서버가 자체 서명 인증서를 쓰기 때문에, 공인 CA 목록이 아니라 이 인증서 하나만
/// 신뢰하도록 설정한다(핀닝). 인증서 검증을 통째로 꺼버리는 방식(아무 인증서나 허용)은
/// 절대 쓰지 않는다 — 그러면 TLS를 붙이는 의미가 없다.
///
/// 신뢰할 인증서는 두 경로 중 하나에서 온다: 앱 빌드에 내장된 "assets/server_cert.pem"
/// (기존 방식), 또는 로그인 화면의 "서버 주소 변경"에서 페어링 코드로 받아와 로컬에 저장한
/// 인증서(우선순위가 더 높음 — [saveDynamicCert] 참고). 서버를 다른 PC로 옮겨 인증서가
/// 바뀌었을 때 앱을 재빌드하지 않고도 페어링으로 새 인증서를 받을 수 있게 하기 위함이다.
class PinnedTls {
  static SecurityContext? _context;
  static http.Client? _httpClient;

  static Future<File> _dynamicCertFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}pinned_server_cert.pem');
  }

  static Future<SecurityContext> _loadContext() async {
    final cached = _context;
    if (cached != null) return cached;
    final dynamicFile = await _dynamicCertFile();
    final bytes = await dynamicFile.exists()
        ? await dynamicFile.readAsBytes()
        : (await rootBundle.load(
            'assets/server_cert.pem',
          )).buffer.asUint8List();
    final context = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(bytes);
    _context = context;
    return context;
  }

  /// 페어링 코드로 서버에서 새로 받아온 인증서를 저장하고, 캐시된 SecurityContext/httpClient를
  /// 전부 초기화해서 이후 모든 연결(REST/소켓/이미지 로딩 포함)이 새 인증서를 즉시 쓰게 한다.
  static Future<void> saveDynamicCert(String pemContent) async {
    final file = await _dynamicCertFile();
    await file.writeAsString(pemContent);
    _context = null;
    _httpClient = null;
    HttpOverrides.global = _PinnedHttpOverrides(await _loadContext());
  }

  /// 서버 콘솔에 "pair"를 입력하면 나오는 4자리 코드로, 인증서를 빌드에 내장하지 않고도
  /// 평문 HTTP 부트스트랩(server/src/pairing.js)에서 받아와 [saveDynamicCert]로 고정(pin)한다.
  /// [address]는 메인 HTTPS 주소(예: https://192.168.0.62:3000) — 페어링 서버는 그 포트+1에서 대기한다.
  static Future<void> pairAndSaveCert(String address, String code) async {
    final uri = Uri.parse(address.trim());
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
      throw body['error'] as String? ?? '코드가 올바르지 않거나 만료되었습니다.';
    }
    await saveDynamicCert(body['cert'] as String);
  }

  /// REST 호출(ApiClient)에 쓸, 이 인증서만 신뢰하는 http.Client. 앱 전체에서 하나만
  /// 만들어 재사용한다(로그인/재로그인마다 새로 만들면 연결 풀이 계속 새로 생겨 낭비된다).
  static Future<http.Client> httpClient() async {
    final cached = _httpClient;
    if (cached != null) return cached;
    final context = await _loadContext();
    final client = http_io.IOClient(HttpClient(context: context));
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
    final context = await _loadContext();
    return (
      Uri uri, {
      Iterable<String>? protocols,
      Map<String, String>? headers,
    }) async {
      final ioSocket = await WebSocket.connect(
        uri.toString(),
        protocols: protocols,
        headers: headers,
        customClient: HttpClient(context: context),
      );
      return IOWebSocket.fromWebSocket(ioSocket);
    };
  }

  /// `NetworkImage`/`CachedNetworkImage`처럼 우리가 직접 만들지 않는 `HttpClient`를
  /// 내부적으로 새로 만들어 쓰는 코드들이 있다(둘 다 우리 ApiClient/ChatSocket과 무관하게
  /// 자기 나름의 dart:io HttpClient()를 새로 만든다) — 그런 곳까지 일일이 고쳐줄 수 없으니,
  /// 앱 전체의 `HttpClient()` 생성 자체를 가로채서 전부 이 인증서를 신뢰하도록 만든다.
  /// main()에서 runApp() 전에 반드시 await로 호출해야 한다.
  static Future<void> installGlobalHttpOverrides() async {
    final context = await _loadContext();
    HttpOverrides.global = _PinnedHttpOverrides(context);
  }
}

class _PinnedHttpOverrides extends HttpOverrides {
  final SecurityContext context;
  _PinnedHttpOverrides(this.context);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(this.context);
  }
}
