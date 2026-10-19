import 'dart:async';
import 'dart:io' show HandshakeException, SocketException;

import 'package:http/http.dart' as http;

import 'api_client.dart' show ApiException, ApiTimeoutException;

/// [error]가 연결 문제(서버에 닿지 않음·응답 없음·서버가 잠시 못 받음)인지 — 그러면 다시 하면 될 수 있다(보내기 대기열이 기다렸다
/// 다시 한다). 서버가 받아서 거절한 것(권한·수정 가능 시간·길이 등 — 4xx)은 false.
bool isConnectionError(Object error) {
  if (error is ApiTimeoutException) return true;
  if (error is ApiException) {
    final status = error.statusCode;
    return status != null && (status == 502 || status == 503 || status == 504);
  }
  return error is http.ClientException ||
      error is SocketException ||
      error is HandshakeException ||
      error is TimeoutException;
}
