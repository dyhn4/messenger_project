import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';

/// 끌어다 놓은 것 중 파일만 — 폴더를 같이 놓으면 그건 뺀다(올릴 수 없다). DropItem이 XFile이라
/// 그대로 넘기면 PC(경로)와 웹(브라우저가 준 바이트) 모두 같은 업로드 코드로 올라간다.
List<XFile> droppedFiles(DropDoneDetails details) => [
  for (final f in details.files)
    if (f is! DropItemDirectory) f,
];
