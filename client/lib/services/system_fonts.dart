import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// EnumFontFamiliesEx 콜백이 채워 넣을 곳 — Pointer.fromFunction은 클로저를 못 받고(정적
/// 함수만 가능) 매번 새 Pointer를 만들 수도 없어서, [listInstalledFontFamilies] 호출 동안만
/// 잠깐 여기(top-level)에 연결해 둔다. 이 패키지는 싱글 스레드 UI 아이솔레이트에서만 쓰고
/// 재진입(호출 도중 또 호출)도 없어서 전역 변수로도 안전하다.
Set<String>? _collecting;

/// Windows에 설치된 글꼴 이름(패밀리당 하나) — 환경설정 > 화면 설정 > 글꼴에서 고를 목록으로
/// 쓴다. 세로쓰기 전용 글꼴(이름이 '@'로 시작)은 가로쓰기 UI에 안 맞아서 뺀다. Windows가
/// 아니거나 실패하면(아주 드묾) 빈 목록 — 호출부는 "시스템 기본"만 보여주면 된다.
List<String> listInstalledFontFamilies() {
  if (!Platform.isWindows) return const [];
  final hdc = GetDC(0);
  if (hdc == 0) return const [];
  final names = <String>{};
  final logfont = calloc<LOGFONT>();
  try {
    // lfFaceName을 비워 두고 lfCharSet=DEFAULT_CHARSET을 주면, 글꼴 하나하나(굵게·기울임
    // 등 스타일별)가 아니라 패밀리(예: "맑은 고딕")당 한 번씩만 불린다(문자셋이 여럿인
    // 패밀리는 그 수만큼 더 불릴 수 있어 Set으로 중복을 거른다).
    logfont.ref
      ..lfCharSet = DEFAULT_CHARSET
      ..lfFaceName = '';
    _collecting = names;
    EnumFontFamiliesEx(
      hdc,
      logfont,
      Pointer.fromFunction<FONTENUMPROC>(_enumFontFamProc, 0),
      0,
      0,
    );
  } finally {
    _collecting = null;
    calloc.free(logfont);
    ReleaseDC(0, hdc);
  }
  final list = names.where((n) => n.isNotEmpty && !n.startsWith('@')).toList()
    ..sort();
  return list;
}

int _enumFontFamProc(
  Pointer<LOGFONT> lpelfe,
  Pointer<TEXTMETRIC> lpntme,
  int fontType,
  int lParam,
) {
  _collecting?.add(lpelfe.ref.lfFaceName);
  return 1; // 0이 아닌 값을 돌려줘야 계속 열거한다(전부 모은다).
}
