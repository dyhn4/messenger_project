import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;
import 'package:pasteboard/pasteboard.dart';
import 'package:win32/win32.dart'
    show
        CF_DIB,
        CloseClipboard,
        EmptyClipboard,
        GMEM_MOVEABLE,
        GlobalAlloc,
        GlobalFree,
        GlobalLock,
        GlobalUnlock,
        OpenClipboard,
        RegisterClipboardFormat,
        SetClipboardData,
        TEXT;

import 'app_platform.dart';
import 'win32_window.dart';

/// 이 기기에서 이미지를 클립보드에 복사할 수 있는지 — 안드로이드는 pasteboard가 FileProvider(앱에 아직 없음)를
/// 요구해서 빼고, 리눅스는 pasteboard가 쓰기를 지원하지 않는다.
bool get canCopyImageToClipboard =>
    AppPlatform.isWindows || AppPlatform.isMacOS || AppPlatform.isIOS;

/// [bytes](원본 이미지 파일 내용)를 클립보드에 이미지로 올린다. 실패하면 예외.
///
/// Windows는 pasteboard 대신 직접 쓴다 — 그 플러그인은 클립보드에 넘긴 비트맵을 곧바로 지워버리고 투명한 부분이
/// 검게 나온다. 여기서는 흰 바탕에 합성한 CF_DIB(어느 프로그램이나 붙여넣을 수 있다)에, 원본이 PNG면 "PNG" 형식도
/// 함께 올린다(워드·브라우저 등은 이걸로 투명도까지 붙여넣는다).
Future<void> copyImageToClipboard(Future<Uint8List> bytes) async {
  final data = await bytes;
  if (!AppPlatform.isWindows) return Pasteboard.writeImage(data);
  final dib = await Isolate.run(() => _encodeDib(data));
  if (dib == null) throw const FormatException('이미지 형식을 읽을 수 없습니다.');
  await _writeWindowsClipboard(dib, png: _isPng(data) ? data : null);
}

bool _isPng(Uint8List data) =>
    data.length > 8 &&
    data[0] == 0x89 &&
    data[1] == 0x50 &&
    data[2] == 0x4E &&
    data[3] == 0x47;

/// 이미지를 CF_DIB(BITMAPINFOHEADER + 아래에서 위로 쌓은 32비트 BGRA 픽셀)로 바꾼다. 투명한 부분은 흰 바탕에
/// 합성한다 — CF_DIB의 알파는 프로그램마다 제각각으로 읽어서(무시하면 검게 나온다) 불투명하게 넘긴다.
Uint8List? _encodeDib(Uint8List data) {
  final decoded = img.decodeImage(data);
  if (decoded == null) return null;
  // 휴대폰 사진은 EXIF 방향대로 돌려서 — 채팅 미리보기에 보이는 모양 그대로 복사되게.
  final image = img
      .bakeOrientation(decoded)
      .convert(format: img.Format.uint8, numChannels: 4);
  final w = image.width;
  final h = image.height;
  final rgba = image.getBytes(order: img.ChannelOrder.rgba);
  final out = Uint8List(40 + w * h * 4);
  ByteData.sublistView(out)
    ..setUint32(0, 40, Endian.little) // biSize
    ..setInt32(4, w, Endian.little) // biWidth
    ..setInt32(8, h, Endian.little) // biHeight(양수 = 아래에서 위로)
    ..setUint16(12, 1, Endian.little) // biPlanes
    ..setUint16(14, 32, Endian.little) // biBitCount
    ..setUint32(16, 0, Endian.little) // biCompression = BI_RGB
    ..setUint32(20, w * h * 4, Endian.little); // biSizeImage
  var o = 40;
  for (var y = h - 1; y >= 0; y--) {
    var i = y * w * 4;
    for (var x = 0; x < w; x++, i += 4, o += 4) {
      final a = rgba[i + 3];
      final white = 255 * (255 - a);
      out[o] = (rgba[i + 2] * a + white) ~/ 255;
      out[o + 1] = (rgba[i + 1] * a + white) ~/ 255;
      out[o + 2] = (rgba[i] * a + white) ~/ 255;
      out[o + 3] = 255;
    }
  }
  return out;
}

Future<void> _writeWindowsClipboard(Uint8List dib, {Uint8List? png}) async {
  // 다른 프로그램이 잠깐 클립보드를 열고 있을 수 있어 몇 번 다시 해 본다.
  final owner = findMainWindow();
  var opened = false;
  for (var i = 0; i < 10 && !opened; i++) {
    if (i > 0) await Future.delayed(const Duration(milliseconds: 30));
    opened = OpenClipboard(owner) != 0;
  }
  if (!opened) throw StateError('다른 프로그램이 클립보드를 쓰고 있습니다.');
  try {
    EmptyClipboard();
    if (!_setClipboardBytes(CF_DIB, dib)) {
      throw StateError('클립보드에 이미지를 올리지 못했습니다.');
    }
    if (png != null) {
      final name = TEXT('PNG');
      try {
        final format = RegisterClipboardFormat(name);
        // PNG는 덤이다 — 못 올려도 CF_DIB로 붙여넣을 수 있다.
        if (format != 0) _setClipboardBytes(format, png);
      } finally {
        calloc.free(name);
      }
    }
  } finally {
    CloseClipboard();
  }
}

/// [bytes]를 전역 메모리에 담아 클립보드에 넘긴다 — 넘긴 뒤로는 시스템 것이라 풀지 않는다(실패했을 때만 푼다).
bool _setClipboardBytes(int format, Uint8List bytes) {
  final mem = GlobalAlloc(GMEM_MOVEABLE, bytes.length);
  if (mem == nullptr) return false;
  final dst = GlobalLock(mem);
  if (dst == nullptr) {
    GlobalFree(mem);
    return false;
  }
  dst.cast<Uint8>().asTypedList(bytes.length).setAll(0, bytes);
  GlobalUnlock(mem);
  if (SetClipboardData(format, mem.address) == 0) {
    GlobalFree(mem);
    return false;
  }
  return true;
}
