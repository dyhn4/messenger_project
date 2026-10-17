// 아이폰 앱 아이콘(ios/Runner/Assets.xcassets/AppIcon.appiconset)을 웹 앱의 maskable 아이콘에서 만든다.
//
// 실행(client 폴더에서): dart run tool/make_ios_icons.dart [원본.png]
//
// - 원본 기본값은 web/icons/Icon-maskable-512.png — 바탕이 네 모서리까지 꽉 찬 그림이라 iOS가 모서리를 둥글게 잘라도 빈 곳이
//   없다(web/icons/Icon-512.png는 모서리가 이미 둥글고 투명해서 iOS에서는 검은 모서리가 생긴다).
// - maskable 아이콘은 안전 영역 때문에 말풍선이 작게 들어 있어서, 가운데를 잘라(CROP_RATIO) 일반 아이콘과 비슷한 크기로 키운다.
// - App Store는 알파 채널이 있는 아이콘을 받지 않아 RGB로 저장한다.
// - Contents.json에 적힌 크기(size × scale)마다 같은 파일 이름으로 덮어쓴다. 더 큰(1024px 이상) 원본이 생기면 인자로 넘긴다.
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;

/// 원본 한 변에서 가운데 몇 %를 잘라 쓸지 — maskable 안전 영역(80%)보다 조금 더 안쪽.
const cropRatio = 0.71;

void main(List<String> args) {
  final source = args.isNotEmpty
      ? args.first
      : 'web/icons/Icon-maskable-512.png';
  const setDir = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
  final decoded = img.decodePng(File(source).readAsBytesSync());
  if (decoded == null) {
    stderr.writeln('PNG를 읽지 못했습니다: $source');
    exit(1);
  }
  final side = (decoded.width * cropRatio).round();
  final cropped = img.copyCrop(
    decoded,
    x: (decoded.width - side) ~/ 2,
    y: (decoded.height - side) ~/ 2,
    width: side,
    height: side,
  );
  // 투명한 곳이 있으면 맨 위 왼쪽 바탕색으로 메운 뒤 알파를 뺀다.
  final background = cropped.getPixel(0, 0);
  final flat = img.Image(width: side, height: side, numChannels: 3)
    ..clear(
      img.ColorRgb8(
        background.r.toInt(),
        background.g.toInt(),
        background.b.toInt(),
      ),
    );
  img.compositeImage(flat, cropped);

  final contents =
      jsonDecode(File('$setDir/Contents.json').readAsStringSync())
          as Map<String, dynamic>;
  var written = 0;
  for (final entry
      in (contents['images'] as List).cast<Map<String, dynamic>>()) {
    final name = entry['filename'] as String?;
    if (name == null) continue;
    final points = double.parse((entry['size'] as String).split('x').first);
    final scale = double.parse((entry['scale'] as String).replaceAll('x', ''));
    final px = (points * scale).round();
    final resized = img.copyResize(
      flat,
      width: px,
      height: px,
      interpolation: img.Interpolation.cubic,
    );
    File('$setDir/$name').writeAsBytesSync(img.encodePng(resized));
    written++;
  }
  stdout.writeln('아이콘 $written개를 만들었습니다($source, 가운데 $side×${side}px).');
}
