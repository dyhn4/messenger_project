import 'dart:io';

import 'package:client/services/download_storage.dart';
import 'package:flutter_test/flutter_test.dart';

// 받은 첨부를 누르면 바로 열지, 실행될 수 있는 형식이라 열지 않을지(download_storage.dart의
// isRiskyToOpen·openLocalFile), 웹 새 탭으로 열어도 되는 형식인지(webViewableMimeType).
void main() {
  group('isRiskyToOpen', () {
    test('열기만 해도 실행되거나 위험한 형식', () {
      for (final name in [
        'setup.exe',
        'RUN.BAT',
        'x.cmd',
        'x.com',
        'x.scr',
        'x.pif',
        'x.cpl',
        'x.msi',
        'x.msix',
        'x.appx',
        'x.lnk',
        'x.url',
        'x.website',
        'x.scf',
        'x.hta',
        'x.js',
        'x.jse',
        'x.vbs',
        'x.vbe',
        'x.wsf',
        'x.ps1',
        'x.reg',
        'x.inf',
        'x.chm',
        'x.jar',
        'x.jnlp',
        'x.application',
        'x.appref-ms',
        'x.settingcontent-ms',
        'x.library-ms',
        'x.searchConnector-ms',
        'x.rdp',
        'x.msc',
        'x.cer',
        'x.html',
        'x.HTM',
        'x.mht',
        'x.svg',
        'x.xml',
        'x.xsl',
        'x.iso',
        'x.img',
        'x.vhd',
        'x.vhdx',
        'x.apk',
        'x.docm',
        'x.xlsm',
        'x.xll',
        'x.sh',
        'x.py',
      ]) {
        expect(isRiskyToOpen(name), isTrue, reason: name);
      }
    });

    test('매크로·원격 데이터를 담는 드문 오피스 형식, 재생 목록, 개발 도구 프로젝트', () {
      for (final name in [
        // 원노트(첨부를 품어 실행시킨다)·엑셀 쿼리와 연결(원격 데이터)·SYLK(DDE)
        'invoice.one',
        'x.onepkg',
        'report.iqy',
        'x.dqy',
        'x.rqy',
        'x.oqy',
        'x.odc',
        'x.slk',
        // 매크로를 담는 서식 파일·쇼·바이너리 통합 문서·퍼블리셔·백업, OLE 개체를 품는 RTF
        'x.dot',
        'x.xlt',
        'x.xlsb',
        'x.pot',
        'x.pps',
        'x.ppsx',
        'x.pub',
        'x.wbk',
        'x.rtf',
        // 재생 목록(원격 주소를 불러온다)
        'x.m3u',
        'x.wax',
        'x.wvx',
        'x.wmx',
        'x.wpl',
        // 열기만 해도 빌드 명령이 도는 프로젝트
        'x.sln',
        'x.csproj',
        'x.vcxproj',
        'x.props',
        'x.targets',
        // 연락처·인증서 묶음
        'x.contact',
        'x.wab',
        'x.p7b',
      ]) {
        expect(isRiskyToOpen(name), isTrue, reason: name);
      }
    });

    test('확장자를 숨기거나 흐리는 수법도 걸러 낸다', () {
      expect(isRiskyToOpen('invoice.pdf.exe'), isTrue);
      // Windows는 끝의 점·공백을 떼고 연다.
      expect(isRiskyToOpen('x.exe.'), isTrue);
      expect(isRiskyToOpen('x.exe . '), isTrue);
      // 화면에는 "photoexe.png"처럼 보인다.
      expect(isRiskyToOpen('photo\u202Egnp.exe'), isTrue);
      expect(isRiskyToOpen('report.txt:evil.exe'), isTrue);
      // 확장자 자리의 COM 개체 번호(HTA 문서로 열린다).
      expect(
        isRiskyToOpen('x.txt.{3050f4d8-98b5-11cf-bb82-00aa00bdce0b}'),
        isTrue,
      );
      // 저장된 경로를 그대로 넣어도 된다.
      expect(isRiskyToOpen(r'C:\Users\me\Downloads\x.exe'), isTrue);
      expect(
        isRiskyToOpen('/storage/emulated/0/Download/TangoTalk/x.apk'),
        isTrue,
      );
    });

    // 옛 오피스 형식(doc·xls·ppt)도 연다 — 매크로는 저장할 때 붙인 "인터넷에서 받은 파일" 표시로
    // 오피스가 막는다(markFromInternet).
    test('흔한 문서·사진·영상·압축 파일은 그대로 연다', () {
      for (final name in [
        'report.pdf',
        'photo.PNG',
        'a.jpg',
        'notes.txt',
        'sheet.xlsx',
        'doc.docx',
        'slides.pptx',
        'old.doc',
        'old.xls',
        'old.ppt',
        'report.hwp',
        // 바로 가기는 글 파일로 저장한다(savedFileName) — 열면 안에 적힌 주소가 보인다.
        'x.url.txt',
        'data.csv',
        'archive.zip',
        'clip.mp4',
        'song.mp3',
        'README',
        'x.exe.txt',
        '.gitignore',
        r'C:\Users\me\Downloads\report.pdf',
      ]) {
        expect(isRiskyToOpen(name), isFalse, reason: name);
      }
    });
  });

  group('riskyFileNotice', () {
    final sep = Platform.pathSeparator;

    test('위험한 형식만 안내가 있다', () {
      expect(riskyFileNotice('${sep}dl${sep}x.exe'), isNotNull);
      expect(riskyFileNotice('${sep}dl${sep}x.pdf'), isNull);
      expect(riskyFileNotice('${sep}dl${sep}README'), isNull);
    });

    test('PC는 탐색기가 그 파일을 보여 주니 까닭만 알린다', () {
      expect(
        riskyFileNotice(r'C:\Users\me\Downloads\x.hta'),
        '실행될 수 있는 파일이라 바로 열지 않았습니다. 내용을 확인한 뒤 직접 여세요.',
      );
    }, skip: !Platform.isWindows);
  });

  group('explorerSelectArgs', () {
    test('파일 경로는 늘 /select와 함께 넘긴다 — 그냥 넘기면 탐색기가 그 파일을 실행한다', () {
      expect(explorerSelectArgs(r'C:\dl\x.exe'), ['/select,', r'C:\dl\x.exe']);
      expect(explorerSelectArgs(r'C:\my files\x.exe'), [
        '/select,',
        r'C:\my files\x.exe',
      ]);
      expect(explorerSelectArgs('C:/dl/x.exe'), ['/select,', r'C:\dl\x.exe']);
    });

    test('쉼표가 든 경로는 골라 보이지 않고 그 폴더만 연다', () {
      expect(explorerSelectArgs(r'C:\dl\a,b.exe'), [r'C:\dl']);
    }, skip: !Platform.isWindows);
  });

  group('webViewableMimeType', () {
    test('브라우저가 스크립트 없이 보여 주는 형식만 새 탭으로', () {
      expect(webViewableMimeType('a.png'), 'image/png');
      expect(webViewableMimeType('a.JPG'), 'image/jpeg');
      expect(webViewableMimeType('a.jpeg'), 'image/jpeg');
      expect(webViewableMimeType('a.webp'), 'image/webp');
      expect(webViewableMimeType('a.pdf'), 'application/pdf');
      expect(webViewableMimeType('a.mp4'), 'video/mp4');
      expect(webViewableMimeType('a.m4a'), 'audio/mp4');
      // 글 파일은 내용과 상관없이 text/plain — 안에 HTML이 있어도 글자로 보인다.
      expect(webViewableMimeType('a.txt'), 'text/plain;charset=utf-8');
      expect(webViewableMimeType('a.json'), 'text/plain;charset=utf-8');
    });

    test('svg·html·xml·모르는 형식은 내려받는다', () {
      for (final name in [
        'a.svg',
        'a.svgz',
        'a.html',
        'a.htm',
        'a.xhtml',
        'a.xml',
        'a.mht',
        'a.docx',
        'a.exe',
        'README',
        'a.png.svg',
        'a.svg.',
        'a.png:x.html',
      ]) {
        expect(webViewableMimeType(name), isNull, reason: name);
      }
    });
  });
}
