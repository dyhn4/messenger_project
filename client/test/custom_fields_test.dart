import 'dart:convert';

import 'package:client/models/project.dart';
import 'package:client/screens/project/task_config_manager.dart';
import 'package:client/screens/project/task_filter.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const progress = TaskFieldDef(
    id: 'pg',
    projectId: 'p1',
    name: '진행률',
    kind: 'progress',
  );
  const parts = TaskFieldDef(
    id: 'ms',
    projectId: 'p1',
    name: '참여 부서',
    kind: 'multiSelect',
    options: ['생산', '품질', '영업'],
  );

  test('진행률·다중 선택 값을 글자로 보여준다', () {
    expect(progress.display(70), '70%');
    expect(progress.display(null), isNull);
    expect(parts.display(['생산', '품질']), '생산, 품질');
    expect(parts.display(<String>[]), isNull);
    expect(parts.hasOptions, isTrue);
    expect(progress.hasOptions, isFalse);
  });

  test('필터: 다중 선택은 포함, 진행률은 범위', () {
    Task task(Map<String, dynamic> custom) => Task.fromJson({
      'id': '1',
      'projectId': 'p1',
      'title': 't',
      'status': 'todo',
      'priority': 'normal',
      'createdAt': 0,
      'customValues': custom,
    });
    const fields = [progress, parts];
    bool m(TaskFilter f, Task t) => f.matches(t, fields: fields);
    final t = task({
      'pg': 70,
      'ms': ['생산', '품질'],
    });

    expect(m(const TaskFilter(fieldValues: {'ms': '생산'}), t), isTrue);
    expect(m(const TaskFilter(fieldValues: {'ms': '영업'}), t), isFalse);
    expect(m(const TaskFilter(fieldValues: {'ms': '생산'}), task({})), isFalse);
    expect(
      m(const TaskFilter(fieldRanges: {'pg': FieldRange(min: 50)}), t),
      isTrue,
    );
    expect(
      m(const TaskFilter(fieldRanges: {'pg': FieldRange(min: 80)}), t),
      isFalse,
    );
  });

  testWidgets('필드 관리: 다중 선택 필드를 만든다', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Map<String, dynamic>? created;
    const json = {'content-type': 'application/json'};
    final client = MockClient((request) async {
      if (request.method == 'POST' &&
          request.url.path == '/api/projects/p1/task-fields') {
        created = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('{}', 200, headers: json);
      }
      return http.Response('[]', 200, headers: json);
    });
    final session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    session.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: client,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectFieldEditor(session: session, projectId: 'p1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('필드 추가'));
    await tester.pumpAndSettle();
    // 지원하는 종류가 전부 보인다.
    for (final label in ['텍스트', '숫자', '날짜', '단일 선택', '다중 선택', '진행률']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }

    await tester.enterText(find.widgetWithText(TextField, '필드 이름'), '참여 부서');
    await tester.tap(find.text('다중 선택'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '선택지 (쉼표로 구분)'),
      '생산, 품질',
    );
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    expect(created, {
      'name': '참여 부서',
      'kind': 'multiSelect',
      'options': ['생산', '품질'],
    });

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
