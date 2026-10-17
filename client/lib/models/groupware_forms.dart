// 그룹웨어 설문·업무일지 모델(서버 groupwareSurveys.js·groupwareReports.js, 규칙은 surveyRules.js·workReportRules.js).

DateTime? _time(Object? v) =>
    v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;

List<Map<String, dynamic>> _maps(Object? v) => [
  for (final e in (v as List? ?? const []))
    if (e is Map) e.cast<String, dynamic>(),
];

// ── 설문 ────────────────────────────────────────────────────────────────

/// 설문 문항의 종류 — 하나 고르기·여러 개 고르기·글·별점(1~5).
enum SurveyQuestionKind {
  single('single', '하나 고르기'),
  multiple('multiple', '여러 개 고르기'),
  text('text', '글'),
  rating('rating', '별점');

  final String wire;
  final String label;
  const SurveyQuestionKind(this.wire, this.label);

  static SurveyQuestionKind fromWire(String? v) => SurveyQuestionKind.values
      .firstWhere((k) => k.wire == v, orElse: () => SurveyQuestionKind.text);

  bool get hasOptions =>
      this == SurveyQuestionKind.single || this == SurveyQuestionKind.multiple;
}

class SurveyOption {
  final String? id;
  final String text;
  const SurveyOption({this.id, required this.text});

  factory SurveyOption.fromJson(Map<String, dynamic> j) =>
      SurveyOption(id: j['id'] as String?, text: j['text'] as String? ?? '');

  Map<String, dynamic> toJson() => {'id': ?id, 'text': text};
}

class SurveyQuestion {
  /// 서버가 붙이는 id('q…') — 새로 만드는 문항은 null.
  final String? id;
  final SurveyQuestionKind kind;
  final String title;
  final bool required;
  final List<SurveyOption> options;

  const SurveyQuestion({
    this.id,
    required this.kind,
    required this.title,
    this.required = true,
    this.options = const [],
  });

  factory SurveyQuestion.fromJson(Map<String, dynamic> j) => SurveyQuestion(
    id: j['id'] as String?,
    kind: SurveyQuestionKind.fromWire(j['kind'] as String?),
    title: j['title'] as String? ?? '',
    required: j['required'] as bool? ?? true,
    options: [for (final o in _maps(j['options'])) SurveyOption.fromJson(o)],
  );

  Map<String, dynamic> toJson() => {
    'id': ?id,
    'kind': kind.wire,
    'title': title,
    'required': required,
    if (kind.hasOptions) 'options': [for (final o in options) o.toJson()],
  };
}

/// 결과를 누가 보나.
enum SurveyResultVisibility {
  creator('creator', '만든 사람만'),
  respondents('respondents', '응답한 사람도'),
  all('all', '대상 모두');

  final String wire;
  final String label;
  const SurveyResultVisibility(this.wire, this.label);

  static SurveyResultVisibility fromWire(String? v) =>
      SurveyResultVisibility.values.firstWhere(
        (k) => k.wire == v,
        orElse: () => SurveyResultVisibility.creator,
      );
}

/// 설문 목록 한 줄(상세는 [SurveyDetail]).
class SurveySummary {
  final String id;
  final String title;
  final String? description;
  final String? creatorId;
  final String creatorName;
  final bool anonymous;
  final SurveyResultVisibility resultVisibility;

  /// 'all' | 'users'
  final String audience;
  final List<String> targetIds;
  final int questionCount;
  final DateTime? closesAt;
  final bool closed;
  final DateTime createdAt;
  final int responseCount;
  final int targetCount;
  final bool responded;

  /// 내가 아직 응답할 설문(대상이고 열려 있고 안 함).
  final bool pending;

  const SurveySummary({
    required this.id,
    required this.title,
    this.description,
    this.creatorId,
    required this.creatorName,
    this.anonymous = false,
    this.resultVisibility = SurveyResultVisibility.creator,
    this.audience = 'all',
    this.targetIds = const [],
    this.questionCount = 0,
    this.closesAt,
    this.closed = false,
    required this.createdAt,
    this.responseCount = 0,
    this.targetCount = 0,
    this.responded = false,
    this.pending = false,
  });

  factory SurveySummary.fromJson(Map<String, dynamic> j) => SurveySummary(
    id: j['id'] as String,
    title: j['title'] as String? ?? '',
    description: j['description'] as String?,
    creatorId: j['creatorId'] as String?,
    creatorName: j['creatorName'] as String? ?? '',
    anonymous: j['anonymous'] as bool? ?? false,
    resultVisibility: SurveyResultVisibility.fromWire(
      j['resultVisibility'] as String?,
    ),
    audience: j['audience'] as String? ?? 'all',
    targetIds: [
      for (final x in (j['targetIds'] as List? ?? const []))
        if (x is String) x,
    ],
    questionCount: (j['questionCount'] as num?)?.toInt() ?? 0,
    closesAt: _time(j['closesAt']),
    closed: j['closed'] as bool? ?? false,
    createdAt: _time(j['createdAt']) ?? DateTime.now(),
    responseCount: (j['responseCount'] as num?)?.toInt() ?? 0,
    targetCount: (j['targetCount'] as num?)?.toInt() ?? 0,
    responded: j['responded'] as bool? ?? false,
    pending: j['pending'] as bool? ?? false,
  );
}

/// 설문 하나 — 문항과 내 응답, 내가 할 수 있는 것.
class SurveyDetail {
  final SurveySummary summary;
  final List<SurveyQuestion> questions;

  /// { 문항 id: 보기 id | [보기 id] | 글 | 1~5 } — 아직 안 했으면 null.
  final Map<String, dynamic>? myAnswers;
  final bool canRespond;
  final bool canManage;
  final bool canViewResults;

  const SurveyDetail({
    required this.summary,
    required this.questions,
    this.myAnswers,
    this.canRespond = false,
    this.canManage = false,
    this.canViewResults = false,
  });

  factory SurveyDetail.fromJson(Map<String, dynamic> j) => SurveyDetail(
    summary: SurveySummary.fromJson(j),
    questions: [
      for (final q in _maps(j['questions'])) SurveyQuestion.fromJson(q),
    ],
    myAnswers: (j['myAnswers'] as Map?)?.cast<String, dynamic>(),
    canRespond: j['canRespond'] as bool? ?? false,
    canManage: j['canManage'] as bool? ?? false,
    canViewResults: j['canViewResults'] as bool? ?? false,
  );
}

/// 문항 하나의 결과.
class SurveyQuestionResult {
  final String id;
  final SurveyQuestionKind kind;
  final String title;
  final int answered;
  final List<({String id, String text, int count})> options;
  final double? average;
  final List<int> distribution;
  final List<({String? name, String text})> texts;

  const SurveyQuestionResult({
    required this.id,
    required this.kind,
    required this.title,
    required this.answered,
    this.options = const [],
    this.average,
    this.distribution = const [],
    this.texts = const [],
  });

  factory SurveyQuestionResult.fromJson(Map<String, dynamic> j) =>
      SurveyQuestionResult(
        id: j['id'] as String? ?? '',
        kind: SurveyQuestionKind.fromWire(j['kind'] as String?),
        title: j['title'] as String? ?? '',
        answered: (j['answered'] as num?)?.toInt() ?? 0,
        options: [
          for (final o in _maps(j['options']))
            (
              id: o['id'] as String? ?? '',
              text: o['text'] as String? ?? '',
              count: (o['count'] as num?)?.toInt() ?? 0,
            ),
        ],
        average: (j['average'] as num?)?.toDouble(),
        distribution: [
          for (final d in (j['distribution'] as List? ?? const []))
            if (d is num) d.toInt(),
        ],
        texts: [
          for (final t in _maps(j['texts']))
            (name: t['name'] as String?, text: t['text'] as String? ?? ''),
        ],
      );
}

class SurveyResults {
  final int responseCount;
  final int targetCount;
  final List<SurveyQuestionResult> questions;

  /// 응답한 사람(익명이면 null), 안 한 사람(관리할 수 있는 사람에게만 — 아니면 null).
  final List<({String userId, String name})>? respondents;
  final List<({String userId, String name})>? nonRespondents;

  const SurveyResults({
    required this.responseCount,
    required this.targetCount,
    required this.questions,
    this.respondents,
    this.nonRespondents,
  });

  static List<({String userId, String name})>? _people(Object? v) => v is List
      ? [
          for (final p in _maps(v))
            (
              userId: p['userId'] as String? ?? '',
              name: p['name'] as String? ?? '',
            ),
        ]
      : null;

  factory SurveyResults.fromJson(Map<String, dynamic> j) => SurveyResults(
    responseCount: (j['responseCount'] as num?)?.toInt() ?? 0,
    targetCount: (j['targetCount'] as num?)?.toInt() ?? 0,
    questions: [
      for (final q in _maps(j['questions'])) SurveyQuestionResult.fromJson(q),
    ],
    respondents: _people(j['respondents']),
    nonRespondents: _people(j['nonRespondents']),
  );
}

// ── 업무일지 ────────────────────────────────────────────────────────────

enum WorkReportKind {
  daily('daily', '일일'),
  weekly('weekly', '주간');

  final String wire;
  final String label;
  const WorkReportKind(this.wire, this.label);

  static WorkReportKind fromWire(String? v) =>
      v == 'weekly' ? WorkReportKind.weekly : WorkReportKind.daily;
}

class WorkReportComment {
  final String id;
  final String? userId;
  final String userName;
  final String text;
  final DateTime createdAt;

  const WorkReportComment({
    required this.id,
    this.userId,
    required this.userName,
    required this.text,
    required this.createdAt,
  });

  factory WorkReportComment.fromJson(Map<String, dynamic> j) =>
      WorkReportComment(
        id: j['id'] as String,
        userId: j['userId'] as String?,
        userName: j['userName'] as String? ?? '',
        text: j['text'] as String? ?? '',
        createdAt: _time(j['createdAt']) ?? DateTime.now(),
      );
}

/// 업무일지 하나.
class WorkReport {
  final String id;
  final String userId;
  final String userName;
  final WorkReportKind kind;

  /// 'YYYY-MM-DD' — 주간은 월요일~일요일.
  final String periodStart;
  final String periodEnd;
  final String? done;
  final String? plan;
  final String? issues;
  final DateTime? updatedAt;
  final int commentCount;

  /// 읽은 검토자(쓴 사람에게 "확인함").
  final List<({String userId, String name})> reads;

  /// 팀 현황에서만 — 내가 읽었는지.
  final bool readByMe;

  /// 상세에서만.
  final List<WorkReportComment> comments;
  final bool canEdit;

  const WorkReport({
    required this.id,
    required this.userId,
    required this.userName,
    required this.kind,
    required this.periodStart,
    required this.periodEnd,
    this.done,
    this.plan,
    this.issues,
    this.updatedAt,
    this.commentCount = 0,
    this.reads = const [],
    this.readByMe = false,
    this.comments = const [],
    this.canEdit = false,
  });

  factory WorkReport.fromJson(Map<String, dynamic> j) => WorkReport(
    id: j['id'] as String,
    userId: j['userId'] as String? ?? '',
    userName: j['userName'] as String? ?? '',
    kind: WorkReportKind.fromWire(j['kind'] as String?),
    periodStart: j['periodStart'] as String? ?? '',
    periodEnd: j['periodEnd'] as String? ?? '',
    done: j['done'] as String?,
    plan: j['plan'] as String?,
    issues: j['issues'] as String?,
    updatedAt: _time(j['updatedAt']) ?? _time(j['createdAt']),
    commentCount: (j['commentCount'] as num?)?.toInt() ?? 0,
    reads: [
      for (final r in _maps(j['reads']))
        (
          userId: r['userId'] as String? ?? '',
          name: r['name'] as String? ?? '',
        ),
    ],
    readByMe: j['readByMe'] as bool? ?? false,
    comments: [
      for (final c in _maps(j['comments'])) WorkReportComment.fromJson(c),
    ],
    canEdit: j['canEdit'] as bool? ?? false,
  );
}

/// 내 업무일지 화면 — 고른 기간의 내 보고와 받는 사람, 앞뒤 기간.
class MyWorkReportPage {
  final WorkReportKind kind;
  final String periodStart;
  final String periodEnd;
  final String currentPeriodStart;
  final String previousPeriodStart;
  final WorkReport? report;
  final List<({String userId, String name})> reviewers;

  const MyWorkReportPage({
    required this.kind,
    required this.periodStart,
    required this.periodEnd,
    required this.currentPeriodStart,
    required this.previousPeriodStart,
    this.report,
    this.reviewers = const [],
  });

  factory MyWorkReportPage.fromJson(Map<String, dynamic> j) => MyWorkReportPage(
    kind: WorkReportKind.fromWire(j['kind'] as String?),
    periodStart: j['periodStart'] as String? ?? '',
    periodEnd: j['periodEnd'] as String? ?? '',
    currentPeriodStart: j['currentPeriodStart'] as String? ?? '',
    previousPeriodStart: j['previousPeriodStart'] as String? ?? '',
    report: j['report'] is Map
        ? WorkReport.fromJson((j['report'] as Map).cast<String, dynamic>())
        : null,
    reviewers: [
      for (final r in _maps(j['reviewers']))
        (
          userId: r['userId'] as String? ?? '',
          name: r['name'] as String? ?? '',
        ),
    ],
  );
}

/// 팀 업무일지 현황 — 내가 검토하는 사람들의 이 기간 보고(안 쓴 사람이 위로).
class WorkReportTeam {
  final WorkReportKind kind;
  final String periodStart;
  final String periodEnd;

  /// 오늘·이번 주의 시작일(서버 한국 날짜) — "다음" 단추를 막는다.
  final String currentPeriodStart;
  final bool canReview;
  final int submittedCount;
  final List<({String userId, String name, WorkReport? report})> roster;

  const WorkReportTeam({
    required this.kind,
    required this.periodStart,
    required this.periodEnd,
    required this.currentPeriodStart,
    required this.canReview,
    required this.submittedCount,
    required this.roster,
  });

  factory WorkReportTeam.fromJson(Map<String, dynamic> j) => WorkReportTeam(
    kind: WorkReportKind.fromWire(j['kind'] as String?),
    periodStart: j['periodStart'] as String? ?? '',
    periodEnd: j['periodEnd'] as String? ?? '',
    currentPeriodStart: j['currentPeriodStart'] as String? ?? '',
    canReview: j['canReview'] as bool? ?? false,
    submittedCount: (j['submittedCount'] as num?)?.toInt() ?? 0,
    roster: [
      for (final r in _maps(j['roster']))
        (
          userId: r['userId'] as String? ?? '',
          name: r['name'] as String? ?? '',
          report: r['report'] is Map
              ? WorkReport.fromJson(
                  (r['report'] as Map).cast<String, dynamic>(),
                )
              : null,
        ),
    ],
  );
}

/// 'YYYY-MM-DD'를 하루씩 옮긴다(◀ ▶ — 주간은 7일).
String shiftPeriod(String key, WorkReportKind kind, int step) {
  final p = key.split('-').map(int.parse).toList();
  final d = DateTime(
    p[0],
    p[1],
    p[2] + (kind == WorkReportKind.weekly ? 7 : 1) * step,
  );
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// 기간 글 — 일일 "10/07(수)", 주간 "10/05~10/11".
String periodLabel(WorkReportKind kind, String start, String end) {
  String md(String k) {
    final p = k.split('-');
    return p.length == 3 ? '${int.parse(p[1])}/${int.parse(p[2])}' : k;
  }

  if (kind == WorkReportKind.weekly) return '${md(start)}~${md(end)}';
  final p = start.split('-').map(int.tryParse).toList();
  if (p.length != 3 || p.contains(null)) return start;
  const days = ['월', '화', '수', '목', '금', '토', '일'];
  final d = DateTime(p[0]!, p[1]!, p[2]!);
  return '${md(start)}(${days[d.weekday - 1]})';
}
