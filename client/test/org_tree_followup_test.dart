// 조직도 "부서" 탭 후속 — 겸직(표시·넣기·빼기), 끌어다 놓기(부서를 다른 부서 아래로·맨 위로, 자기 아래 부서에는 못 놓음, 사람의 주
// 부서 바꾸기), 엑셀 가져오기(미리 보기 오류면 "닫기"만, 괜찮으면 "가져오기"로 실제로 바꿈), 목록 ↔ 그림 바꾸기. 서버는 가짜 HTTP,
// 파일 고르기는 가짜 FilePickerPlatform.
import 'dart:convert';
import 'dart:typed_data';

import 'package:client/models/team.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/org_chart_diagram.dart';
import 'package:client/widgets/org_tree_view.dart';
import 'package:file_picker/file_picker.dart';
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object? body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> _dept(
  String id,
  String name, {
  String? parent,
  String? head,
  int order = 0,
}) => {
  'id': id,
  'parentId': parent,
  'name': name,
  'headId': head,
  'sortOrder': order,
};

Map<String, dynamic> _member(
  String id,
  String name, {
  String? dept,
  String? effective,
  String? position,
}) => {
  'id': id,
  'name': name,
  'username': id,
  'role': 'member',
  'avatarType': 'initial',
  'position': position,
  'departmentId': dept,
  'managerId': null,
  'effectiveManagerId': effective,
};

/// 대표실(boss) ─ 영업본부(kim) ─ 영업1팀(hong) / 영업2팀(choi, 겸직: hong "파트장")
///            └ 인사팀(부서장 없음)
Map<String, dynamic> _treeJson({bool canEdit = true}) => {
  'scope': 'server',
  'scopeKey': 'server',
  'teamId': null,
  'canEdit': canEdit,
  'departments': [
    _dept('ceo', '대표실', head: 'boss'),
    _dept('sales', '영업본부', parent: 'ceo', head: 'kim'),
    _dept('hr', '인사팀', parent: 'ceo', order: 1),
    _dept('s1', '영업1팀', parent: 'sales'),
    _dept('s2', '영업2팀', parent: 'sales', order: 1),
  ],
  'members': [
    _member('boss', '대표', dept: 'ceo'),
    _member('choi', '최영업', dept: 's2', effective: 'kim'),
    _member('hong', '홍길동', dept: 's1', effective: 'kim', position: '대리'),
    _member('kim', '김본부', dept: 'sales', effective: 'boss'),
  ],
  'concurrent': [
    {'userId': 'hong', 'departmentId': 's2', 'position': '파트장'},
  ],
};

class _Harness {
  final requests = <http.Request>[];
  late final Session session;

  /// 가져오기 미리 보기(dryRun)와 실제로 바꿀 때의 답.
  Object? previewBody;
  int previewStatus = 200;
  Object? applyBody;

  _Harness({bool canEdit = true}) {
    final tree = _treeJson(canEdit: canEdit);
    session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    session.serverUrl = 'https://test.local';
    session.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: MockClient((request) async {
        requests.add(request);
        final path = request.url.path;
        final key = '${request.method} $path';
        if (key == 'GET /api/org-tree') return _json(tree);
        if (key == 'POST /api/org-tree/import') {
          return request.url.queryParameters['dryRun'] == '1'
              ? _json(previewBody, status: previewStatus)
              : _json(applyBody);
        }
        if (request.method == 'POST' && path.endsWith('/concurrent')) {
          return _json({'ok': true}, status: 201);
        }
        if (request.method == 'POST' && path.endsWith('/place')) {
          return _json({'ok': true});
        }
        if (request.method == 'PUT' || request.method == 'DELETE') {
          return _json({'ok': true});
        }
        return _json({'error': 'no route'}, status: 404);
      }),
    );
    session.userId = 'hong';
    session.orgScope = 'account';
    final team = Team(id: 't1', name: '본사', createdAt: DateTime(2026));
    session.teams.add(team);
    session.currentTeam = team;
  }

  List<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();
  Map<String, dynamic> bodyOf(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;
}

/// 파일 고르기 창 대신 — 늘 같은 .xlsx 하나를 고른 것으로.
class _FakePicker extends FilePickerPlatform {
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
  }) async => FilePickerResult([
    PlatformFile(
      name: '조직도.xlsx',
      size: 3,
      bytes: Uint8List.fromList([1, 2, 3]),
    ),
  ]);
}

Future<List<String>> _pump(WidgetTester tester, _Harness h) async {
  tester.view.physicalSize = const Size(700, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final opened = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: OrgTreeView(
          session: h.session,
          onOpenMember: (user, _) => opened.add(user.id),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return opened;
}

Finder _key(String k) => find.byKey(ValueKey(k));

/// 영업본부·영업2팀까지 펼친다.
Future<void> _expandSales(WidgetTester tester) async {
  await tester.tap(_key('org-department-sales'));
  await tester.pumpAndSettle();
  await tester.tap(_key('org-department-s2'));
  await tester.pumpAndSettle();
}

/// 길게 눌러(터치 — 시험 기본 플랫폼은 안드로이드) [from]을 끌어 [to]에 놓는다. [to]는 끌기 시작한 뒤에 찾는다("맨 위로" 띠는 그때
/// 뜬다).
Future<void> _drag(WidgetTester tester, Finder from, Finder to) async {
  final gesture = await tester.startGesture(tester.getCenter(from));
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
  await gesture.moveBy(const Offset(0, 6));
  await tester.pump();
  await gesture.moveTo(tester.getCenter(to));
  await tester.pump();
  await gesture.moveBy(const Offset(1, 1));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('겸직 — 그 부서 사람들 다음에 "겸직" 표시·그 부서 직책, 주 부서 줄에는 겸직 부서', (
    tester,
  ) async {
    final h = _Harness(canEdit: false);
    final opened = await _pump(tester, h);
    await _expandSales(tester);
    expect(_key('concurrent-chip-hong-s2'), findsOneWidget);
    expect(find.text('파트장 · 주 부서 영업1팀'), findsOneWidget);
    await tester.tap(_key('org-department-s1'));
    await tester.pumpAndSettle();
    expect(find.text('대리 · 상위자 김본부 · 겸직: 영업2팀'), findsOneWidget);
    expect(
      _key('org-concurrent-menu-hong-s2'),
      findsNothing,
      reason: '고칠 수 없는 사람',
    );
    expect(_key('dept-drag-s1'), findsNothing);
    expect(_key('org-excel-menu'), findsNothing);
    // 겸직 줄을 눌러도 프로필.
    await tester.tap(_key('org-concurrent-hong-s2'));
    expect(opened, ['hong']);
  });

  testWidgets('겸직 추가 — 주 부서·이미 겸한 부서는 고를 수 없고, 직책과 함께 보낸다', (tester) async {
    final h = _Harness();
    await _pump(tester, h);
    await tester.tap(_key('org-department-sales'));
    await tester.pumpAndSettle();
    await tester.tap(_key('org-department-s1'));
    await tester.pumpAndSettle();
    await tester.tap(_key('org-member-menu-hong'));
    await tester.pumpAndSettle();
    await tester.tap(_key('concurrent-add-hong'));
    await tester.pumpAndSettle();
    expect(_key('org-pick-department-s1'), findsNothing, reason: '주 부서');
    expect(_key('org-pick-department-s2'), findsNothing, reason: '이미 겸직');
    expect(_key('org-pick-department-none'), findsNothing);
    await tester.tap(_key('org-pick-department-hr'));
    await tester.pumpAndSettle();
    await tester.enterText(_key('concurrent-position'), ' 채용 담당 ');
    await tester.tap(_key('concurrent-confirm'));
    await tester.pumpAndSettle();
    expect(
      h.bodyOf(
        h.called('POST', '/api/org-tree/members/hong/concurrent').single,
      ),
      {'departmentId': 'hr', 'position': '채용 담당'},
    );
  });

  testWidgets('겸직 빼기 — DELETE', (tester) async {
    final h = _Harness();
    await _pump(tester, h);
    await _expandSales(tester);
    await tester.tap(_key('org-concurrent-menu-hong-s2'));
    await tester.pumpAndSettle();
    await tester.tap(_key('concurrent-remove-hong-s2'));
    await tester.pumpAndSettle();
    expect(
      h.called('DELETE', '/api/org-tree/members/hong/concurrent/s2'),
      hasLength(1),
    );
  });

  testWidgets('끌어다 놓기 — 부서를 다른 부서 아래 맨 끝으로, "맨 위로" 띠로', (tester) async {
    final h = _Harness();
    await _pump(tester, h);
    await _drag(tester, _key('dept-drag-hr'), _key('dept-drop-sales'));
    expect(
      h.bodyOf(h.called('POST', '/api/org-tree/departments/hr/place').single),
      {'parentId': 'sales', 'index': 2},
      reason: '영업본부 아래 영업1팀·영업2팀 다음',
    );
    expect(_key('dept-drop-root'), findsNothing, reason: '끄는 동안만 뜬다');

    // 놓은 곳(영업본부)은 펼쳐 둔다 — 그 아래 영업1팀이 보인다.
    expect(_key('org-department-s1'), findsOneWidget);
    await _drag(tester, _key('dept-drag-s1'), _key('dept-drop-root'));
    expect(
      h.bodyOf(h.called('POST', '/api/org-tree/departments/s1/place').single),
      {'parentId': null, 'index': 1},
      reason: '맨 위 부서(대표실) 다음',
    );
  });

  testWidgets('끌어다 놓기 — 자기 아래 부서에는 놓지 못한다(보내지 않는다)', (tester) async {
    final h = _Harness();
    await _pump(tester, h);
    await tester.tap(_key('org-department-sales'));
    await tester.pumpAndSettle();
    await _drag(tester, _key('dept-drag-sales'), _key('dept-drop-s1'));
    await _drag(tester, _key('dept-drag-sales'), _key('dept-drop-sales'));
    expect(
      h.requests.where((r) => r.method != 'GET'),
      isEmpty,
      reason: '자기 아래·자기 자신',
    );
    // 같은 끌기로 다른 부서(인사팀)에는 놓인다.
    await _drag(tester, _key('dept-drag-sales'), _key('dept-drop-hr'));
    expect(
      h.bodyOf(
        h.called('POST', '/api/org-tree/departments/sales/place').single,
      ),
      {'parentId': 'hr', 'index': 0},
    );
  });

  testWidgets('끌어다 놓기 — 사람을 부서에 놓으면 주 부서가 바뀐다', (tester) async {
    final h = _Harness();
    await _pump(tester, h);
    await _drag(tester, _key('member-drag-boss'), _key('dept-drop-hr'));
    expect(h.bodyOf(h.called('PUT', '/api/org-tree/members/boss').single), {
      'departmentId': 'hr',
    });
    // 지금 부서에 다시 놓으면 보내지 않는다.
    await _drag(tester, _key('member-drag-boss'), _key('dept-drop-ceo'));
    expect(h.called('PUT', '/api/org-tree/members/boss'), hasLength(1));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  group('엑셀 가져오기', () {
    late FilePickerPlatform original;
    setUp(() {
      original = FilePickerPlatform.instance;
      FilePickerPlatform.instance = _FakePicker();
    });
    tearDown(() => FilePickerPlatform.instance = original);

    Future<void> openImport(WidgetTester tester) async {
      await tester.tap(_key('org-excel-menu'));
      await tester.pumpAndSettle();
      expect(_key('org-export'), findsOneWidget);
      await tester.tap(_key('org-import'));
      await tester.pumpAndSettle();
    }

    testWidgets('미리 보기에 오류가 있으면 줄마다 보이고 "닫기"만', (tester) async {
      final h = _Harness()
        ..previewStatus = 400
        ..previewBody = {
          'summary': {
            'createDepartments': 0,
            'headChanges': 0,
            'orderChanges': 0,
            'memberChanges': 0,
          },
          'errors': [
            {'sheet': '구성원', 'row': 3, 'message': '없는 상위자 아이디입니다.'},
          ],
          'applied': false,
        };
      await _pump(tester, h);
      await openImport(tester);
      final preview = h.called('POST', '/api/org-tree/import').single;
      expect(preview.url.queryParameters['dryRun'], '1');
      expect(preview.bodyBytes, [1, 2, 3]);
      expect(find.text('구성원 3번째 줄: 없는 상위자 아이디입니다.'), findsOneWidget);
      expect(_key('org-import-apply'), findsNothing);
      await tester.tap(_key('org-import-close'));
      await tester.pumpAndSettle();
      expect(h.called('POST', '/api/org-tree/import'), hasLength(1));
    });

    testWidgets('미리 보기가 괜찮으면 바뀌는 양을 보이고 "가져오기"로 실제로 바꾼다', (tester) async {
      final summary = {
        'createDepartments': 2,
        'headChanges': 1,
        'orderChanges': 0,
        'memberChanges': 3,
      };
      final h = _Harness()
        ..previewBody = {'summary': summary, 'errors': [], 'applied': false}
        ..applyBody = {
          'summary': summary,
          'errors': [],
          'applied': true,
          'skipped': [],
        };
      await _pump(tester, h);
      await openImport(tester);
      expect(find.text('만들 부서 2개'), findsOneWidget);
      expect(find.text('사람 3명'), findsOneWidget);
      await tester.tap(_key('org-import-apply'));
      await tester.pump();
      final calls = h.called('POST', '/api/org-tree/import');
      expect(calls, hasLength(2));
      expect(calls.last.url.queryParameters.containsKey('dryRun'), isFalse);
      expect(calls.last.bodyBytes, [1, 2, 3]);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });
  });

  testWidgets('목록 ↔ 그림 — 그림은 OrgChartDiagram', (tester) async {
    final h = _Harness(canEdit: false);
    await _pump(tester, h);
    expect(find.byType(OrgChartDiagram), findsNothing);
    await tester.tap(_key('org-view-toggle'));
    await tester.pumpAndSettle();
    expect(find.byType(OrgChartDiagram), findsOneWidget);
    expect(_key('org-department-ceo'), findsNothing);
    final diagram = tester.widget<OrgChartDiagram>(
      find.byType(OrgChartDiagram),
    );
    expect(diagram.onMoveDepartment, isNull, reason: '고칠 수 없는 사람');
    // 그림에서 부서를 누르면 목록으로 돌아와 그 부서까지 펼친다.
    diagram.onTapDepartment!(diagram.tree.department('s2')!);
    await tester.pumpAndSettle();
    expect(find.byType(OrgChartDiagram), findsNothing);
    expect(_key('org-department-s2'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });
}
