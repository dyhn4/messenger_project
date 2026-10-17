import 'dart:convert';

import 'package:client/models/groupware.dart';
import 'package:client/models/groupware_forms.dart';
import 'package:client/screens/groupware/groupware_screen.dart'
    show GroupwareChanges;
import 'package:client/screens/groupware/survey_tab.dart';
import 'package:client/screens/groupware/work_report_tab.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/groupware_api.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 그룹웨어 설문·업무일지 탭(survey_tab.dart·work_report_tab.dart, 서버 groupwareSurveys.js·groupwareReports.js).

const _json = {'content-type': 'application/json'};

void main() {
  final now = DateTime.now().millisecondsSinceEpoch;
  late List<({String method, String path, Map<String, dynamic>? body})> calls;
  late Map<String, http.Response Function(http.Request r)> routes;

  http.Response ok(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: _json);

  GroupwareApi buildApi() {
    calls = [];
    final api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: MockClient((request) async {
        final body = request.body.isEmpty
            ? null
            : jsonDecode(request.body) as Map<String, dynamic>;
        if (request.method != 'GET') {
          calls.add((
            method: request.method,
            path: request.url.path,
            body: body,
          ));
        }
        final handler = routes['${request.method} ${request.url.path}'];
        return handler == null ? ok(<Object>[]) : handler(request);
      }),
    );
    return GroupwareApi(api, teamId: 't1');
  }

  final ctx = GroupwareContext.fromJson({
    'scope': 'team',
    'scopeKey': 't1',
    'isManager': false,
    'pendingForMe': 0,
  });

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    await tester.pumpAndSettle();
  }

  Session session() =>
      Session(notifications: NotificationService(), settings: AppSettings());

  Map<String, dynamic> surveyJson({
    bool responded = false,
    bool pending = true,
  }) => {
    'id': 's1',
    'title': '워크숍 장소',
    'creatorId': 'u9',
    'creatorName': '김팀장',
    'questionCount': 3,
    'createdAt': now,
    'responseCount': 3,
    'targetCount': 5,
    'responded': responded,
    'pending': pending,
  };

  final questions = [
    {
      'id': 'qaaaaaa1',
      'kind': 'single',
      'title': '어디가 좋을까요?',
      'required': true,
      'options': [
        {'id': 'oaaaaaa1', 'text': '강릉'},
        {'id': 'oaaaaaa2', 'text': '제주'},
      ],
    },
    {'id': 'qaaaaaa2', 'kind': 'rating', 'title': '기대 점수', 'required': true},
    {'id': 'qaaaaaa3', 'kind': 'text', 'title': '바라는 점', 'required': false},
  ];

  test('모델 — 문항 전송 모양, 기간 글·옮기기', () {
    const q = SurveyQuestion(
      kind: SurveyQuestionKind.multiple,
      title: '좋았던 점',
      required: false,
      options: [
        SurveyOption(text: '강의'),
        SurveyOption(text: '실습'),
      ],
    );
    expect(q.toJson(), {
      'kind': 'multiple',
      'title': '좋았던 점',
      'required': false,
      'options': [
        {'text': '강의'},
        {'text': '실습'},
      ],
    });
    expect(
      const SurveyQuestion(
        kind: SurveyQuestionKind.text,
        title: 't',
      ).toJson().containsKey('options'),
      isFalse,
    );
    expect(
      periodLabel(WorkReportKind.weekly, '2026-10-05', '2026-10-11'),
      '10/5~10/11',
    );
    expect(
      periodLabel(WorkReportKind.daily, '2026-10-07', '2026-10-07'),
      '10/7(수)',
    );
    expect(shiftPeriod('2026-10-05', WorkReportKind.weekly, -1), '2026-09-28');
    expect(shiftPeriod('2026-10-01', WorkReportKind.daily, -1), '2026-09-30');
  });

  testWidgets('설문 목록 → 열어서 답하고 보낸다(필수·별점·글)', (tester) async {
    var responded = false;
    routes = {
      'GET /api/groupware/surveys': (_) => ok({
        'items': [surveyJson(responded: responded, pending: !responded)],
        'pendingCount': responded ? 0 : 1,
      }),
      'GET /api/groupware/surveys/s1': (_) => ok({
        ...surveyJson(responded: responded, pending: !responded),
        'questions': questions,
        'myAnswers': null,
        'canRespond': true,
        'canManage': false,
        'canViewResults': false,
      }),
      'PUT /api/groupware/surveys/s1/response': (_) {
        responded = true;
        return ok({'ok': true, 'first': true});
      },
    };
    final api = buildApi();
    await pump(
      tester,
      SurveyTab(
        api: api,
        ctx: ctx,
        changes: GroupwareChanges(),
        session: session(),
      ),
    );
    expect(find.text('설문 · 응답할 설문 1'), findsOneWidget);
    expect(find.text('응답하기'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('survey-s1')));
    await tester.pumpAndSettle();
    // 필수 문항은 제목 끝에 ' *'.
    expect(find.text('1. 어디가 좋을까요? *'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('answer-qaaaaaa1-oaaaaaa2')));
    await tester.tap(find.byKey(const ValueKey('answer-qaaaaaa2-4')));
    await tester.enterText(
      find.byKey(const ValueKey('answer-qaaaaaa3')),
      ' 바다 ',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('survey-submit')));
    await tester.pumpAndSettle();
    expect(calls.single.body, {
      'teamId': 't1',
      'answers': {'qaaaaaa1': 'oaaaaaa2', 'qaaaaaa2': 4, 'qaaaaaa3': '바다'},
    });
    expect(find.text('응답 고치기'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('새 설문 — 문항·보기를 넣고 고른 사람에게 익명으로 보낸다', (tester) async {
    routes = {
      'GET /api/groupware/surveys': (_) =>
          ok({'items': <Object>[], 'pendingCount': 0}),
      'GET /api/groupware/candidates': (_) => ok([
        {'id': 'u1', 'name': '김가', 'username': 'a'},
        {'id': 'u2', 'name': '이나', 'username': 'b'},
      ]),
      'POST /api/groupware/surveys': (_) => ok(surveyJson(), 201),
    };
    final api = buildApi();
    await pump(
      tester,
      SurveyTab(
        api: api,
        ctx: ctx,
        changes: GroupwareChanges(),
        session: session(),
      ),
    );
    expect(find.text('아직 설문이 없습니다.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('survey-new')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('survey-title')), '점심 메뉴');
    await tester.enterText(
      find.byKey(const ValueKey('survey-q0-title')),
      '무엇을 먹을까요?',
    );
    await tester.enterText(find.byKey(const ValueKey('survey-q0-o0')), '국밥');
    await tester.enterText(find.byKey(const ValueKey('survey-q0-o1')), '파스타');
    await tester.tap(find.byKey(const ValueKey('survey-add-question')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('survey-q1-kind')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('글').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('survey-q1-title')),
      '기타 의견',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('survey-anonymous')));
    await tester.tap(find.byKey(const ValueKey('survey-anonymous')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('survey-targets')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('survey-target-u2')));
    await tester.tap(find.byKey(const ValueKey('survey-targets-done')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('survey-send')));
    await tester.pumpAndSettle();
    final body = calls
        .singleWhere((c) => c.path == '/api/groupware/surveys')
        .body!;
    expect(body['title'], '점심 메뉴');
    expect(body['anonymous'], true);
    expect(body['audience'], 'users');
    expect(body['targetIds'], ['u2']);
    expect(body['questions'], [
      {
        'kind': 'single',
        'title': '무엇을 먹을까요?',
        'required': true,
        'options': [
          {'text': '국밥'},
          {'text': '파스타'},
        ],
      },
      {'kind': 'text', 'title': '기타 의견', 'required': true},
    ]);
    expect(find.byType(SurveyEditorScreen), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('결과 — 보기 막대·별점 평균·글, 안 한 사람', (tester) async {
    routes = {
      'GET /api/groupware/surveys/s1/results': (_) => ok({
        'responseCount': 2,
        'targetCount': 3,
        'questions': [
          {
            'id': 'qaaaaaa1',
            'kind': 'single',
            'title': '어디가 좋을까요?',
            'answered': 2,
            'options': [
              {'id': 'oaaaaaa1', 'text': '강릉', 'count': 1},
              {'id': 'oaaaaaa2', 'text': '제주', 'count': 1},
            ],
          },
          {
            'id': 'qaaaaaa2',
            'kind': 'rating',
            'title': '기대 점수',
            'answered': 2,
            'average': 4.5,
            'distribution': [0, 0, 0, 1, 1],
          },
          {
            'id': 'qaaaaaa3',
            'kind': 'text',
            'title': '바라는 점',
            'answered': 1,
            'texts': [
              {'name': '김가', 'text': '바다'},
            ],
          },
        ],
        'respondents': [
          {'userId': 'u1', 'name': '김가'},
          {'userId': 'u2', 'name': '이나'},
        ],
        'nonRespondents': [
          {'userId': 'u3', 'name': '박다'},
        ],
      }),
    };
    final api = buildApi();
    final detail = SurveyDetail.fromJson({
      ...surveyJson(),
      'questions': questions,
      'canViewResults': true,
    });
    await pump(tester, SurveyResultsScreen(api: api, survey: detail));
    expect(find.text('응답 2명 / 대상 3명'), findsOneWidget);
    // 보기 둘(강릉·제주)과 별점 4점·5점 막대.
    expect(find.text('1명 (50%)'), findsNWidgets(4));
    expect(find.text('평균 4.5점'), findsOneWidget);
    expect(find.text('· 바다 — 김가'), findsOneWidget);
    expect(find.text('박다'), findsOneWidget);
  });

  testWidgets('내 업무일지 — 받는 사람, 쓰고 올리기, 주간은 일일 보고 불러오기', (tester) async {
    Map<String, dynamic>? saved;
    routes = {
      'GET /api/groupware/work-reports': (r) {
        final weekly = r.url.queryParameters['kind'] == 'weekly';
        return ok({
          'kind': weekly ? 'weekly' : 'daily',
          'periodStart': weekly ? '2026-10-05' : '2026-10-07',
          'periodEnd': weekly ? '2026-10-11' : '2026-10-07',
          'currentPeriodStart': weekly ? '2026-10-05' : '2026-10-07',
          'previousPeriodStart': weekly ? '2026-09-28' : '2026-10-06',
          'report': weekly || saved == null
              ? null
              : {
                  'id': 'r1',
                  'userId': 'me',
                  'userName': '나',
                  'kind': 'daily',
                  'periodStart': '2026-10-07',
                  'periodEnd': '2026-10-07',
                  'done': saved!['done'],
                  'plan': saved!['plan'],
                  'reads': [
                    {'userId': 'm', 'name': '김팀장'},
                  ],
                },
          'reviewers': [
            {'userId': 'm', 'name': '김팀장'},
          ],
        });
      },
      'GET /api/groupware/work-reports/r1': (_) => ok({
        'id': 'r1',
        'userId': 'me',
        'userName': '나',
        'kind': 'daily',
        'periodStart': '2026-10-07',
        'periodEnd': '2026-10-07',
        'done': saved?['done'],
        'comments': [
          {'id': 'c1', 'userName': '김팀장', 'text': '수고했어요', 'createdAt': now},
        ],
        'canEdit': true,
      }),
      'PUT /api/groupware/work-reports': (r) {
        saved = jsonDecode(r.body) as Map<String, dynamic>;
        return ok({
          'id': 'r1',
          'userId': 'me',
          'userName': '나',
          'kind': 'daily',
          'periodStart': '2026-10-07',
          'periodEnd': '2026-10-07',
        }, 201);
      },
      'GET /api/groupware/work-reports/mine': (_) => ok([
        {
          'id': 'd1',
          'userId': 'me',
          'userName': '나',
          'kind': 'daily',
          'periodStart': '2026-10-05',
          'periodEnd': '2026-10-05',
          'done': '기획안',
        },
        {
          'id': 'd2',
          'userId': 'me',
          'userName': '나',
          'kind': 'daily',
          'periodStart': '2026-10-06',
          'periodEnd': '2026-10-06',
          'done': '회의',
        },
      ]),
    };
    final api = buildApi();
    await pump(
      tester,
      WorkReportTab(
        api: api,
        ctx: ctx,
        changes: GroupwareChanges(),
        session: session(),
      ),
    );
    expect(find.text('받는 사람: 김팀장'), findsOneWidget);
    expect(find.text('10/7(수) · 오늘'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('report-done')), '시안 검토');
    await tester.enterText(find.byKey(const ValueKey('report-plan')), '회의 준비');
    await tester.tap(find.byKey(const ValueKey('report-save')));
    await tester.pumpAndSettle();
    expect(saved, {
      'teamId': 't1',
      'kind': 'daily',
      'periodStart': '2026-10-07',
      'done': '시안 검토',
      'plan': '회의 준비',
      'issues': '',
    });
    expect(find.text('확인: 김팀장'), findsOneWidget);
    expect(find.text('수고했어요'), findsOneWidget);
    expect(find.text('고치기'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));

    await tester.tap(find.text('주간'));
    await tester.pumpAndSettle();
    expect(find.text('10/5~10/11 · 이번 주'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('report-import-daily')));
    await tester.pumpAndSettle();
    final done = tester.widget<TextField>(
      find.byKey(const ValueKey('report-done')),
    );
    expect(done.controller!.text, '[10/5(월)] 기획안\n[10/6(화)] 회의');
  });

  testWidgets('팀 현황 — 안 쓴 사람이 위, 눌러서 읽고 댓글', (tester) async {
    routes = {
      'GET /api/groupware/work-reports': (_) => ok({
        'kind': 'daily',
        'periodStart': '2026-10-07',
        'periodEnd': '2026-10-07',
        'currentPeriodStart': '2026-10-07',
        'previousPeriodStart': '2026-10-06',
        'reviewers': <Object>[],
      }),
      'GET /api/groupware/work-reports/team': (_) => ok({
        'kind': 'daily',
        'periodStart': '2026-10-07',
        'periodEnd': '2026-10-07',
        'currentPeriodStart': '2026-10-07',
        'canReview': true,
        'submittedCount': 1,
        'roster': [
          {'userId': 'u2', 'name': '이나', 'report': null},
          {
            'userId': 'u1',
            'name': '김가',
            'report': {
              'id': 'r9',
              'userId': 'u1',
              'userName': '김가',
              'kind': 'daily',
              'periodStart': '2026-10-07',
              'periodEnd': '2026-10-07',
              'done': '배너 시안',
              'commentCount': 0,
              'readByMe': false,
            },
          },
        ],
      }),
      'GET /api/groupware/work-reports/r9': (_) => ok({
        'id': 'r9',
        'userId': 'u1',
        'userName': '김가',
        'kind': 'daily',
        'periodStart': '2026-10-07',
        'periodEnd': '2026-10-07',
        'done': '배너 시안',
        'comments': <Object>[],
      }),
      'POST /api/groupware/work-reports/r9/comments': (_) => ok({
        'id': 'c1',
        'userName': '나',
        'text': '좋아요',
        'createdAt': now,
      }, 201),
    };
    final api = buildApi();
    await pump(
      tester,
      WorkReportTab(
        api: api,
        ctx: ctx,
        changes: GroupwareChanges(),
        session: session(),
      ),
    );
    await tester.tap(find.text('팀 현황'));
    await tester.pumpAndSettle();
    expect(find.text('제출 1/2'), findsOneWidget);
    expect(find.text('아직 안 썼습니다'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('이나')).dy,
      lessThan(tester.getTopLeft(find.text('김가')).dy),
    );
    await tester.tap(find.byKey(const ValueKey('team-report-u1')));
    await tester.pumpAndSettle();
    expect(find.byType(WorkReportScreen), findsOneWidget);
    expect(find.text('배너 시안'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('report-comment-input')),
      '좋아요',
    );
    await tester.tap(find.byKey(const ValueKey('report-comment-send')));
    await tester.pumpAndSettle();
    expect(calls.single.body, {'teamId': 't1', 'text': '좋아요'});
  });
}
