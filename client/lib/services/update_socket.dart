import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:socket_io_client/socket_io_client.dart' as socket_io;

import 'pinned_tls.dart';

/// 서버가 releases/version.json을 새로 배포하면 오는 브로드캐스트(update:available).
class UpdateAvailableEvent {
  final String version;
  final String? notes;
  const UpdateAvailableEvent({required this.version, this.notes});

  factory UpdateAvailableEvent.fromJson(Map<String, dynamic> json) =>
      UpdateAvailableEvent(
        version: json['version'] as String,
        notes: json['notes'] as String?,
      );
}

/// 앱이 켜져 있는 동안 새 클라이언트 버전이 배포되면 재시작 없이 바로 알기 위한 전용 소켓.
/// ChatSocket(chat_socket.dart)과 분리한 이유: 그쪽은 로그인 토큰이 있어야 연결되는데(서버
/// socket.js의 io.use가 JWT를 요구), 이 알림은 로그인 화면(로그인 전)에서도 떠야 해서 서버가
/// 일부러 인증 없는 별도 네임스페이스(/updates)로 내보낸다(server/src/version.js 참고) —
/// 여기서도 그 네임스페이스에 인증 없이 연결한다.
class UpdateSocket {
  socket_io.Socket? _socket;
  String? _connectedBaseUrl;
  final _controller = StreamController<UpdateAvailableEvent>.broadcast();

  Stream<UpdateAvailableEvent> get updates => _controller.stream;

  /// 이미 같은 baseUrl로 연결돼 있으면 아무 것도 안 한다 — session.dart가 앱 시작 시와
  /// "서버 주소 변경" 시 둘 다 이 함수를 부르므로, 중복 연결을 막는 멱등성이 필요하다.
  ///
  /// 웹은 붙지 않는다 — 이 알림은 PC·안드로이드 설치 파일(releases/version.json)의 새 버전이라 웹 앱과
  /// 상관없고(웹 앱은 서버가 내려주는 빌드를 새로고침하면 바뀐다), 받으면 설치할 수 없는 업데이트 알약이 뜬다.
  Future<void> connect(String baseUrl) async {
    if (kIsWeb) return;
    if (_connectedBaseUrl == baseUrl && (_socket?.connected ?? false)) return;
    _socket?.dispose();
    _connectedBaseUrl = baseUrl;

    final connector = await PinnedTls.webSocketConnector();
    final socket = socket_io.io(
      '$baseUrl/updates',
      socket_io.OptionBuilder()
          .setTransports(['websocket'])
          .setWebSocketConnector(connector)
          .disableAutoConnect()
          .enableForceNew()
          .build(),
    );

    socket.on('update:available', (data) {
      if (data is Map) {
        _controller.add(
          UpdateAvailableEvent.fromJson(Map<String, dynamic>.from(data)),
        );
      }
    });

    socket.connect();
    _socket = socket;
  }

  void dispose() {
    _socket?.dispose();
    unawaited(_controller.close());
  }
}
