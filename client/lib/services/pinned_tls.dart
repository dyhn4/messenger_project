import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as http_io;
import 'package:web_socket/io_web_socket.dart';
import 'package:web_socket/web_socket.dart' as ws;

/// 서버가 자체 서명 인증서를 쓰기 때문에, 공인 CA 목록이 아니라 앱에 내장해둔 그 인증서
/// 하나만("assets/server_cert.pem") 신뢰하도록 설정한다(핀닝). 인증서 검증을 통째로
/// 꺼버리는 방식(아무 인증서나 허용)은 절대 쓰지 않는다 — 그러면 TLS를 붙이는 의미가 없다.
///
/// 서버가 인증서를 새로 만들면(certs/ 폴더가 삭제되거나 LAN IP가 바뀌어 재생성된 경우)
/// 이 앱도 새 server_cert.pem으로 다시 빌드해야 접속된다.
class PinnedTls {
  static SecurityContext? _context;
  static http.Client? _httpClient;

  static Future<SecurityContext> _loadContext() async {
    final cached = _context;
    if (cached != null) return cached;
    final bytes = await rootBundle.load('assets/server_cert.pem');
    final context = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(bytes.buffer.asUint8List());
    _context = context;
    return context;
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
  })> webSocketConnector() async {
    final context = await _loadContext();
    return (Uri uri, {Iterable<String>? protocols, Map<String, String>? headers}) async {
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
