// 할 일 공유 폴더(UNC) 안전 검사(검토 S32) — 앱이 downloadPath·uploadPath를 건드리기 전에 서버 이름을 분류하는 규칙
// (todo_upload.dart). 흔한 NAS 공유(\\NAS\공유, \\192.168.x.x\share)는 확인 창을 거쳐 열고, 공인 IP·숫자로 꾸민 IP·WebDAV·
// 장치 경로는 거절하며, 점 있는 이름·한글 이름은 (서버가 운영자 허용 목록으로 받은 것일 수 있어) 경고를 더해 묻는지 본다.
// 분류는 서버(server/test/todoFolderPath.test.js folderHostKind)와 같아야 한다.
import 'package:client/services/todo_upload.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('folderUncHost — UNC면 서버 이름, 아니면 null', () {
    test('UNC 경로에서 서버 이름을 뽑는다', () {
      expect(folderUncHost(r'\\nas\공유\보고서'), 'nas');
      expect(folderUncHost(r'\\10.0.0.66\drop'), '10.0.0.66');
      expect(folderUncHost('//nas/공유'), 'nas');
      // 구분자를 섞어 써도 Windows는 UNC로 읽는다(서버와 같게).
      expect(folderUncHost(r'\/nas\공유'), 'nas');
    });
    test('로컬 드라이브·상대 경로·장치 경로는 null', () {
      expect(folderUncHost(r'C:\자료'), isNull);
      expect(folderUncHost('자료'), isNull);
      expect(folderUncHost(r'\\?\C:\Windows'), isNull);
      expect(folderUncHost(r'\\.\PhysicalDrive0'), isNull);
      expect(folderUncHost(r'\\'), isNull);
    });
  });

  group('folderHostKind — lan / named / blocked (서버와 같은 분류)', () {
    test('정식 표기의 사설/링크로컬/루프백 IP와 영문·숫자 단일 라벨은 lan', () {
      for (final h in [
        'nas',
        'NAS-01',
        'file_srv',
        '10.1.2.3',
        '172.16.0.1',
        '192.168.0.5',
        '169.254.1.1',
        '127.0.0.1',
        '[fe80::1]',
        '[fe80::1%4]',
        '[fd12:3456::1]',
        '[::1]',
        'fe80--1s4.ipv6-literal.net',
        // 숫자처럼 시작해도 주소로 읽히지 않는 이름.
        '2f',
        '1e5',
        '0xnas',
      ]) {
        expect(folderHostKind(h), FolderHostKind.lan, reason: h);
        expect(isLanOnlyFolderHost(h), isTrue, reason: h);
      }
    });
    test('점 있는 이름·한글 이름·유니코드 마침표가 든 이름은 named(사내 이름 모양이 아님)', () {
      for (final h in [
        'nas.corp.local',
        'files.evil.example',
        'nas.',
        '사내서버',
        'evil\u3002com', // 。 → IDN 변환에서 '.'
        'evil\uff0ecom', // ．
        'evil\uff61com', // ｡
        '\u212Aevin', // K(켈빈 기호) — 소문자로 바꾸면 ASCII k
      ]) {
        expect(folderHostKind(h), FolderHostKind.named, reason: h);
        expect(isLanOnlyFolderHost(h), isFalse, reason: h);
      }
    });
    test('공인 IP·숫자로 꾸민 IP·WebDAV 표기·빈 이름은 blocked', () {
      for (final h in [
        '8.8.8.8',
        '172.32.0.1', // 172.16~31만 사설
        '0.0.0.0',
        '134744072', // = 8.8.8.8 (점 없는 10진)
        '0x08080808', // = 8.8.8.8 (16진)
        '0X8080808',
        '010.8.8.8', // 앞자리 0 = 8진 → 8.8.8.8
        '10.0.0.010',
        '10.8', // 줄인 표기(10.0.0.8)
        '0x0a000001', // = 10.0.0.1이어도 정식 표기만
        '2130706433', // = 127.0.0.1
        '[2001:db8::1]', // 공인 IPv6
        '[fd::1]', // 00fd::1 — 고유 로컬이 아님
        '[::ffff:8.8.8.8]',
        '[evil.com]',
        '2001-db8--1.ipv6-literal.net',
        'evil.ipv6-literal.net',
        'fd00:evil',
        'nas@ssl',
        '',
      ]) {
        expect(folderHostKind(h), FolderHostKind.blocked, reason: h);
      }
    });
  });

  group('remoteFolderError — 열기 전 거절 판단', () {
    test('로컬 드라이브·사내망 UNC는 통과(null)', () {
      expect(remoteFolderError(r'C:\자료'), isNull);
      expect(remoteFolderError('D:/share/out'), isNull);
      expect(remoteFolderError(r'\\nas\공유\보고서'), isNull);
      expect(remoteFolderError(r'\\192.168.0.5\share'), isNull);
      expect(remoteFolderError(r'\/nas\공유'), isNull);
      expect(remoteFolderError(''), isNull); // 경로 없음은 호출부가 따로 처리
    });
    test('점 있는 이름·한글 이름은 거절하지 않는다(서버가 허용 목록으로 받은 것 — 확인 창이 경고)', () {
      expect(remoteFolderError(r'\\nas.corp.local\공유'), isNull);
      expect(remoteFolderError(r'\\corp.example.com\dfs\팀'), isNull);
      expect(remoteFolderError(r'\\사내서버\공유'), isNull);
    });
    test('공인 IP·숫자로 꾸민 IP는 서버 이름을 담은 까닭', () {
      expect(remoteFolderError(r'\\8.8.8.8\x'), contains('8.8.8.8'));
      expect(remoteFolderError(r'\\134744072\s'), contains('134744072'));
      expect(remoteFolderError(r'\\0x08080808\s'), isNotNull);
      expect(remoteFolderError(r'\\010.8.8.8\s'), contains('010.8.8.8'));
      expect(remoteFolderError(r'\\[2001:db8::1]\s'), isNotNull);
    });
    test('WebDAV·장치 경로·http(s)·드라이브 아님은 거절', () {
      expect(remoteFolderError(r'\\nas@SSL\DavWWWRoot\x'), isNotNull);
      expect(remoteFolderError(r'\\nas@8080\share'), isNotNull);
      expect(remoteFolderError(r'\\live.sysinternals.com\DavWWWRoot'), isNotNull);
      expect(remoteFolderError(r'\\nas\DavWWWRoot\x'), isNotNull);
      expect(remoteFolderError(r'\\?\C:\Windows'), isNotNull);
      expect(remoteFolderError(r'\\?\UNC\evil.example\x'), isNotNull);
      expect(remoteFolderError(r'\\.\PhysicalDrive0'), isNotNull);
      expect(remoteFolderError('http://evil.example/share'), isNotNull);
      expect(remoteFolderError(r'\\'), isNotNull);
      expect(remoteFolderError('자료'), isNotNull); // 상대 경로
      expect(remoteFolderError('/etc/passwd'), isNotNull);
    });
  });

  group('localFolderOrNull — 폴더 고르기 창의 시작 위치(UNC는 넘기지 않는다)', () {
    test('이 PC 드라이브 경로만 그대로', () {
      expect(localFolderOrNull(r'C:\자료'), r'C:\자료');
      expect(localFolderOrNull('D:/share/out'), 'D:/share/out');
    });
    test('UNC·장치 경로·형식 아님·빈 값은 null', () {
      expect(localFolderOrNull(r'\\nas\결과'), isNull);
      expect(localFolderOrNull(r'\\10.0.0.66\drop'), isNull);
      expect(localFolderOrNull(r'\\?\C:\Windows'), isNull);
      expect(localFolderOrNull('자료'), isNull);
      expect(localFolderOrNull(''), isNull);
      expect(localFolderOrNull(null), isNull);
    });
  });

  group('confirmRemoteFolderAccess — 서버 이름을 보여 주고 서버마다 한 번 묻는다', () {
    setUp(resetTrustedFolderHostsForTest);

    Future<BuildContext> pumpHost(WidgetTester tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      );
      return ctx;
    }

    testWidgets('사내 이름 — 서버 이름을 보이고, 계속하면 그 세션 동안 같은 서버는 다시 묻지 않는다', (
      tester,
    ) async {
      final ctx = await pumpHost(tester);
      final first = confirmRemoteFolderAccess(ctx, r'\\nas\공유');
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('공유 서버 "nas"'), findsOneWidget);
      expect(find.textContaining('사설 IP 주소가 아닙니다'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('folder-host-confirm')));
      await tester.pumpAndSettle();
      expect(await first, isTrue);

      // 같은 서버(대소문자 무시)는 묻지 않는다.
      expect(await confirmRemoteFolderAccess(ctx, r'\\NAS\다른 폴더'), isTrue);
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('점 있는 이름 — 경고를 더해 묻고, 취소는 기억하지 않는다', (tester) async {
      final ctx = await pumpHost(tester);
      final cancelled = confirmRemoteFolderAccess(ctx, r'\\nas.corp.local\공유');
      await tester.pumpAndSettle();
      expect(find.textContaining('공유 서버 "nas.corp.local"'), findsOneWidget);
      expect(find.textContaining('사설 IP 주소가 아닙니다'), findsOneWidget);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(await cancelled, isFalse);

      final again = confirmRemoteFolderAccess(ctx, r'\\nas.corp.local\공유');
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('folder-host-confirm')));
      await tester.pumpAndSettle();
      expect(await again, isTrue);
    });

    testWidgets('로컬 경로는 묻지 않고 true, 열면 안 되는 경로는 묻지 않고 false', (tester) async {
      final ctx = await pumpHost(tester);
      expect(await confirmRemoteFolderAccess(ctx, r'C:\자료'), isTrue);
      expect(await confirmRemoteFolderAccess(ctx, r'\\134744072\s'), isFalse);
      expect(await confirmRemoteFolderAccess(ctx, r'\\nas@SSL\x'), isFalse);
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}
