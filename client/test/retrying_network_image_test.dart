// 못 불러온 그림을 어떻게 다시 받는지(retrying_network_image.dart) — 만료된 링크는 새 링크로, 연결 문제는 잠시 뒤 다시,
// 없는 파일·볼 수 없는 파일은 그대로 둔다.
import 'dart:async';
import 'dart:io';

import 'package:client/widgets/retrying_network_image.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

HttpExceptionWithStatus _status(int code) =>
    HttpExceptionWithStatus(code, 'Invalid statusCode: $code');

void main() {
  test('만료된 링크(401)는 새 링크를 받아 다시 받는다', () {
    expect(imageRetryActionFor(_status(401)), ImageRetryAction.resign);
  });

  test('연결 문제·서버 오류·잠시 막힘은 잠시 뒤 다시 받는다', () {
    for (final error in <Object>[
      const SocketException('Network is unreachable'),
      http.ClientException('Connection closed'),
      TimeoutException('timeout'),
      _status(500),
      _status(502),
      _status(503),
      _status(408),
      _status(429),
    ]) {
      expect(
        imageRetryActionFor(error),
        ImageRetryAction.later,
        reason: '$error',
      );
    }
  });

  test('없는 파일·볼 수 없는 파일·플러그인이 없는 환경은 다시 받지 않는다', () {
    for (final error in <Object>[
      _status(404),
      _status(403),
      _status(400),
      MissingPluginException('path_provider'),
    ]) {
      expect(
        imageRetryActionFor(error),
        ImageRetryAction.giveUp,
        reason: '$error',
      );
    }
  });

  test('다시 받는 간격은 2초·5초·15초·30초·1분, 그 뒤로 1분씩 — 8번까지', () {
    expect(
      [for (var i = 0; i < 8; i++) imageRetryDelay(i)!.inSeconds],
      [2, 5, 15, 30, 60, 60, 60, 60],
    );
    expect(imageRetryDelay(8), isNull, reason: '그 뒤로는 서버에 다시 연결될 때만');
  });
}
