import 'dart:typed_data';

import 'package:client/services/image_thumbnail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('썸네일이 원본보다 작고 지정한 최대 변을 넘지 않는다', () async {
    final original = img.Image(width: 1600, height: 1200);
    img.fill(original, color: img.ColorRgb8(120, 180, 90));
    final originalBytes = Uint8List.fromList(
      img.encodeJpg(original, quality: 95),
    );

    final thumbBytes = await generateThumbnail(
      originalBytes,
      maxDimension: 480,
      quality: 70,
    );
    expect(thumbBytes, isNotNull);
    expect(thumbBytes!.length, lessThan(originalBytes.length));

    final decodedThumb = img.decodeImage(thumbBytes);
    expect(decodedThumb, isNotNull);
    expect(decodedThumb!.width, lessThanOrEqualTo(480));
    expect(decodedThumb.height, lessThanOrEqualTo(480));
    // 가로가 더 긴 원본이었으니 축소 후에도 가로가 더 길어야(비율 유지) 한다.
    expect(decodedThumb.width, greaterThanOrEqualTo(decodedThumb.height));
  });

  test('원본보다 작은 이미지는 축소하지 않고 재인코딩만 한다', () async {
    final small = img.Image(width: 100, height: 80);
    img.fill(small, color: img.ColorRgb8(10, 20, 30));
    final originalBytes = Uint8List.fromList(img.encodePng(small));

    final thumbBytes = await generateThumbnail(
      originalBytes,
      maxDimension: 480,
      quality: 70,
    );
    expect(thumbBytes, isNotNull);
    final decodedThumb = img.decodeImage(thumbBytes!);
    expect(decodedThumb!.width, 100);
    expect(decodedThumb.height, 80);
  });

  test('디코딩할 수 없는 바이트를 주면 예외 없이 null을 돌려준다', () async {
    final garbage = Uint8List.fromList([1, 2, 3, 4, 5]);
    final result = await generateThumbnail(garbage);
    expect(result, isNull);
  });
}
