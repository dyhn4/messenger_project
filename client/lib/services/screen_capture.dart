import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// 모든 모니터를 합친 가상 화면 전체를 찍은 결과. 픽셀은 파일([rawPath])에 위에서 아래로,
/// 픽셀당 4바이트(B,G,R,A — A는 255로 채움)로 그냥 이어 붙여 저장한다(헤더 없음).
class VirtualScreenCapture {
  /// 가상 화면의 왼쪽 위 좌표(실제 픽셀, 보조 모니터가 주 모니터 왼쪽/위에 있으면 음수).
  final int x;
  final int y;
  final int width;
  final int height;

  /// 주 모니터의 폭(실제 픽셀) — 안내 문구를 주 모니터 위쪽 가운데에 두는 데 쓴다.
  final int primaryWidth;
  final String rawPath;

  const VirtualScreenCapture({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.primaryWidth,
    required this.rawPath,
  });
}

/// 가상 화면의 위치·크기를 화면을 찍기 전에 미리(즉시) 알아낸다 — 오버레이 창을 화면 캡처와
/// 동시에 띄우기 시작하려면 창 크기를 캡처 결과를 기다리지 않고 알아야 해서 따로 뺐다.
VirtualScreenCapture virtualScreenGeometry(String rawPath) =>
    VirtualScreenCapture(
      x: GetSystemMetrics(SM_XVIRTUALSCREEN),
      y: GetSystemMetrics(SM_YVIRTUALSCREEN),
      width: GetSystemMetrics(SM_CXVIRTUALSCREEN),
      height: GetSystemMetrics(SM_CYVIRTUALSCREEN),
      primaryWidth: GetSystemMetrics(SM_CXSCREEN),
      rawPath: rawPath,
    );

/// 화면 전체(모든 모니터)를 GDI(BitBlt)로 찍어 [geo]가 가리키는 파일에 저장한다. 4K 두 대만
/// 돼도 픽셀이 수천만 개라 UI 스레드를 막지 않게 별도 isolate에서 돌린다. 다 쓴 뒤에야 그
/// 이름으로 나타나도록(임시 이름에 쓰고 이름을 바꾼다) 오버레이가 파일이 있는지만 보고
/// 기다려도 된다.
///
/// 좌표·크기는 [virtualScreenGeometry]가 이미 구해 둔 값을 그대로 쓴다 — isolate에서
/// GetSystemMetrics를 다시 부르면, 그 사이에 모니터가 붙거나 빠지거나 해상도가 바뀌었을 때
/// 오버레이가 아는 크기와 파일 크기가 어긋난다(오버레이는 그 크기를 그대로 믿고 읽으므로
/// 파일이 더 작으면 버퍼 밖을 읽어 앱이 그대로 죽는다).
///
/// 이 프로세스는 모니터별 DPI 인식 앱이라(Flutter Windows 러너 매니페스트) GetSystemMetrics가
/// 논리 좌표가 아니라 실제 픽셀을 돌려준다 — 그래서 여러 모니터의 배율이 달라도 그대로 맞는다.
Future<void> captureVirtualScreenTo(VirtualScreenCapture geo) {
  final (x, y, w, h, path) = (geo.x, geo.y, geo.width, geo.height, geo.rawPath);
  return Isolate.run(() => _captureSync(x, y, w, h, path));
}

void _captureSync(int x, int y, int w, int h, String path) {
  if (w <= 0 || h <= 0) throw StateError('화면 크기를 알 수 없습니다($w x $h).');

  final screenDc = GetDC(NULL);
  if (screenDc == NULL) throw StateError('화면 DC를 열지 못했습니다.');
  final memDc = CreateCompatibleDC(screenDc);
  final bitmap = memDc == NULL ? NULL : CreateCompatibleBitmap(screenDc, w, h);
  // 비트맵은 가상 화면 전체 크기라, 모니터가 많거나 해상도가 크면 GDI가 거절할 수 있다.
  if (memDc == NULL || bitmap == NULL) {
    if (memDc != NULL) DeleteDC(memDc);
    ReleaseDC(NULL, screenDc);
    throw StateError('화면 버퍼를 만들지 못했습니다($w x $h).');
  }

  final old = SelectObject(memDc, bitmap);
  // CAPTUREBLT — 투명(layered) 창(알림 토스트 등)까지 같이 찍는다.
  BitBlt(memDc, 0, 0, w, h, screenDc, x, y, SRCCOPY | CAPTUREBLT);
  // GetDIBits는 비트맵이 DC에 선택돼 있으면 안 된다(MSDN) — 먼저 빼놓고 읽는다.
  SelectObject(memDc, old);

  final bmi = calloc<BITMAPINFO>();
  bmi.ref.bmiHeader.biSize = sizeOf<BITMAPINFOHEADER>();
  bmi.ref.bmiHeader.biWidth = w;
  // 음수 높이 = 위에서 아래로(top-down) 저장 — 화면 위쪽 줄이 버퍼 맨 앞에 온다.
  bmi.ref.bmiHeader.biHeight = -h;
  bmi.ref.bmiHeader.biPlanes = 1;
  bmi.ref.bmiHeader.biBitCount = 32;
  bmi.ref.bmiHeader.biCompression = BI_RGB;

  final byteCount = w * h * 4;
  Pointer<Uint8>? buffer;
  try {
    buffer = calloc<Uint8>(byteCount);
    GetDIBits(memDc, bitmap, 0, h, buffer, bmi, DIB_RGB_COLORS);

    final pixels = Uint8List.fromList(buffer.asTypedList(byteCount));
    // GDI는 알파를 0으로 남겨두므로(BI_RGB 32bit) 그대로 그리면 투명하게 보인다 — 불투명하게.
    final asUint32 = pixels.buffer.asUint32List();
    for (var i = 0; i < asUint32.length; i++) {
      asUint32[i] |= 0xFF000000;
    }
    File('$path.tmp').writeAsBytesSync(pixels);
    File('$path.tmp').renameSync(path);
  } finally {
    if (buffer != null) calloc.free(buffer);
    calloc.free(bmi);
    DeleteObject(bitmap);
    DeleteDC(memDc);
    ReleaseDC(NULL, screenDc);
  }
}
