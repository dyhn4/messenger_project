import 'groupware_finance.dart';

/// 급여 부가 기능·지출 관리 도구 모델(server/src/payrollReports.js·financeTools.js) — 한 해 집계·연말정산 어림, 퇴직금, 4대보험 신고,
/// 지출 관리 설정(회계 계정·영수증 보관·CODEF 연동), 현금영수증·전자세금계산서.

int _int(Object? v) => (v as num?)?.toInt() ?? 0;
int? _intOrNull(Object? v) => (v as num?)?.toInt();
DateTime? _time(Object? v) =>
    v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;
List<Map<String, dynamic>> _maps(Object? v) => [
  for (final e in (v as List? ?? const []))
    if (e is Map) e.cast<String, dynamic>(),
];
Map<String, dynamic> _map(Object? v) =>
    (v as Map?)?.cast<String, dynamic>() ?? const {};
Map<String, int> _intMap(Object? v) => {
  for (final e in _map(v).entries) e.key: _int(e.value),
};

// ── 한 해 집계·연말정산 ──

/// 한 사람의 한 해 합계(server payrollReportRules.js yearTotals).
class PayrollYearTotals {
  final int months;
  final int gross;
  final int taxFree;
  final int taxable;
  final int pension;
  final int health;
  final int longTermCare;
  final int employment;
  final int incomeTax;
  final int localTax;
  final int settlement;
  final int net;
  const PayrollYearTotals({
    this.months = 0,
    this.gross = 0,
    this.taxFree = 0,
    this.taxable = 0,
    this.pension = 0,
    this.health = 0,
    this.longTermCare = 0,
    this.employment = 0,
    this.incomeTax = 0,
    this.localTax = 0,
    this.settlement = 0,
    this.net = 0,
  });

  factory PayrollYearTotals.fromJson(Map<String, dynamic> j) =>
      PayrollYearTotals(
        months: _int(j['months']),
        gross: _int(j['gross']),
        taxFree: _int(j['taxFree']),
        taxable: _int(j['taxable']),
        pension: _int(j['pension']),
        health: _int(j['health']),
        longTermCare: _int(j['longTermCare']),
        employment: _int(j['employment']),
        incomeTax: _int(j['incomeTax']),
        localTax: _int(j['localTax']),
        settlement: _int(j['settlement']),
        net: _int(j['net']),
      );
}

/// 연말정산 어림(server incomeTaxRules.js yearEndEstimate) — [diffIncomeTax]가 양수면 추징, 음수면 환급.
class YearEndEstimate {
  final int earnedIncome;
  final int taxBase;
  final int computedTax;
  final int earnedCredit;
  final int childCredit;
  final int standardCredit;

  /// 공제 자료의 세액공제 합계(산출세액 안에서 쓴 것).
  final int claimCredit;

  /// 공제 자료가 있을 때 공제마다의 금액 — 소득공제(extraPersonal·card·subscription·other·rentLoan·mortgage)와 세액공제
  /// (pensionAccount·political·hometown·marriage·births·other·insurance·medical·education·donation·monthlyRent). 고른 쪽에서 쓰지 못한 것은 0.
  final Map<String, int> claimDeductions;
  final Map<String, int> claimCredits;
  final bool useStandard;
  final int decidedTax;
  final int decidedLocalTax;
  final int withheldIncomeTax;
  final int withheldLocalTax;
  final int diffIncomeTax;
  final int diffLocalTax;
  const YearEndEstimate({
    this.earnedIncome = 0,
    this.taxBase = 0,
    this.computedTax = 0,
    this.earnedCredit = 0,
    this.childCredit = 0,
    this.standardCredit = 0,
    this.claimCredit = 0,
    this.claimDeductions = const {},
    this.claimCredits = const {},
    this.useStandard = false,
    this.decidedTax = 0,
    this.decidedLocalTax = 0,
    this.withheldIncomeTax = 0,
    this.withheldLocalTax = 0,
    this.diffIncomeTax = 0,
    this.diffLocalTax = 0,
  });

  factory YearEndEstimate.fromJson(Map<String, dynamic> j) => YearEndEstimate(
    earnedIncome: _int(j['earnedIncome']),
    taxBase: _int(j['taxBase']),
    computedTax: _int(j['computedTax']),
    earnedCredit: _int(j['earnedCredit']),
    childCredit: _int(j['childCredit']),
    standardCredit: _int(j['standardCredit']),
    claimCredit: _int(j['claimCredit']),
    claimDeductions: _intMap(_map(j['claim'])['deductions']),
    claimCredits: _intMap(_map(j['claim'])['credits']),
    useStandard: j['useStandard'] == true,
    decidedTax: _int(j['decidedTax']),
    decidedLocalTax: _int(j['decidedLocalTax']),
    withheldIncomeTax: _int(j['withheldIncomeTax']),
    withheldLocalTax: _int(j['withheldLocalTax']),
    diffIncomeTax: _int(j['diffIncomeTax']),
    diffLocalTax: _int(j['diffLocalTax']),
  );
}

class PayrollYearPerson {
  final String userId;
  final String name;
  final String? employeeNo;
  final TaxProfile profile;
  final PayrollYearTotals totals;
  final YearEndEstimate estimate;

  /// 연말정산 공제 자료를 냈는지·확인했는지.
  final YearEndClaimStatus claim;
  const PayrollYearPerson({
    required this.userId,
    required this.name,
    this.employeeNo,
    this.profile = const TaxProfile(),
    this.totals = const PayrollYearTotals(),
    this.estimate = const YearEndEstimate(),
    this.claim = const YearEndClaimStatus(),
  });

  factory PayrollYearPerson.fromJson(Map<String, dynamic> j) =>
      PayrollYearPerson(
        userId: j['userId'] as String? ?? '',
        name: j['name'] as String? ?? '',
        employeeNo: j['employeeNo'] as String?,
        profile: TaxProfile.fromJson(_map(j['profile'])),
        totals: PayrollYearTotals.fromJson(_map(j['totals'])),
        estimate: YearEndEstimate.fromJson(_map(j['estimate'])),
        claim: YearEndClaimStatus.fromJson(_map(j['claim'])),
      );
}

class PayrollYearSummary {
  final int year;
  final List<PayrollYearPerson> people;

  /// 정산분을 넣을 수 있는 작성 중인 대장들.
  final List<({String id, String title, String payMonth})> draftRuns;
  const PayrollYearSummary({
    required this.year,
    this.people = const [],
    this.draftRuns = const [],
  });

  factory PayrollYearSummary.fromJson(Map<String, dynamic> j) =>
      PayrollYearSummary(
        year: _int(j['year']),
        people: [
          for (final m in _maps(j['people'])) PayrollYearPerson.fromJson(m),
        ],
        draftRuns: [
          for (final m in _maps(j['draftRuns']))
            (
              id: m['id'] as String,
              title: m['title'] as String? ?? '',
              payMonth: m['payMonth'] as String? ?? '',
            ),
        ],
      );
}

// ── 퇴직금 ──

/// 퇴직금 계산 결과(server severanceRules.js calculateSeverance).
class SeveranceResult {
  final String userId;
  final String name;
  final String hireDate;
  final String lastDay;
  final String retireDate;
  final int serviceDays;
  final int serviceYears;
  final bool eligible;
  final String periodFrom;
  final String periodTo;
  final int periodDays;
  final List<
    ({String payMonth, int gross, int days, int monthDays, int amount})
  >
  wageBreakdown;
  final int wages;
  final int bonusAdd;
  final int leaveAdd;
  final double averageDailyWage;
  final int ordinaryDailyWage;
  final bool usedOrdinary;
  final double dailyWage;
  final int amount;
  final int serviceDeduction;
  final int convertedPay;
  final int convertedDeduction;
  final int taxBase;
  final int incomeTax;
  final int localTax;
  final int net;
  const SeveranceResult({
    required this.userId,
    required this.name,
    required this.hireDate,
    required this.lastDay,
    required this.retireDate,
    required this.serviceDays,
    required this.serviceYears,
    required this.eligible,
    required this.periodFrom,
    required this.periodTo,
    required this.periodDays,
    this.wageBreakdown = const [],
    required this.wages,
    this.bonusAdd = 0,
    this.leaveAdd = 0,
    required this.averageDailyWage,
    this.ordinaryDailyWage = 0,
    this.usedOrdinary = false,
    required this.dailyWage,
    required this.amount,
    this.serviceDeduction = 0,
    this.convertedPay = 0,
    this.convertedDeduction = 0,
    this.taxBase = 0,
    required this.incomeTax,
    required this.localTax,
    required this.net,
  });

  factory SeveranceResult.fromJson(Map<String, dynamic> j) {
    final period = _map(j['period']);
    return SeveranceResult(
      userId: j['userId'] as String? ?? '',
      name: j['name'] as String? ?? '',
      hireDate: j['hireDate'] as String? ?? '',
      lastDay: j['lastDay'] as String? ?? '',
      retireDate: j['retireDate'] as String? ?? '',
      serviceDays: _int(j['serviceDays']),
      serviceYears: _int(j['serviceYears']),
      eligible: j['eligible'] == true,
      periodFrom: period['from'] as String? ?? '',
      periodTo: period['to'] as String? ?? '',
      periodDays: _int(period['days']),
      wageBreakdown: [
        for (final m in _maps(j['wageBreakdown']))
          (
            payMonth: m['payMonth'] as String? ?? '',
            gross: _int(m['gross']),
            days: _int(m['days']),
            monthDays: _int(m['monthDays']),
            amount: _int(m['amount']),
          ),
      ],
      wages: _int(j['wages']),
      bonusAdd: _int(j['bonusAdd']),
      leaveAdd: _int(j['leaveAdd']),
      averageDailyWage: (j['averageDailyWage'] as num?)?.toDouble() ?? 0,
      ordinaryDailyWage: _int(j['ordinaryDailyWage']),
      usedOrdinary: j['usedOrdinary'] == true,
      dailyWage: (j['dailyWage'] as num?)?.toDouble() ?? 0,
      amount: _int(j['amount']),
      serviceDeduction: _int(j['serviceDeduction']),
      convertedPay: _int(j['convertedPay']),
      convertedDeduction: _int(j['convertedDeduction']),
      taxBase: _int(j['taxBase']),
      incomeTax: _int(j['incomeTax']),
      localTax: _int(j['localTax']),
      net: _int(j['net']),
    );
  }
}

// ── 4대보험 취득·상실 신고 ──

class InsuranceReport {
  final String id;
  final String? userId;
  final String userName;

  /// 'acquire'(취득 — 입사) | 'lose'(상실 — 퇴사).
  final String kind;
  final String eventDate;
  final String deadline;
  final String? reasonCode;
  final int? monthlyPay;
  final num? weeklyHours;
  final String? jobName;

  /// EDI 일괄 신고 양식에 옮길 부호(직종 부호·국민연금/건강보험 취득·상실 부호).
  final String? jobCode;
  final String? pensionCode;
  final String? healthCode;
  final String? memo;
  final DateTime? filedAt;
  final String? filedByName;
  const InsuranceReport({
    required this.id,
    this.userId,
    required this.userName,
    required this.kind,
    required this.eventDate,
    required this.deadline,
    this.reasonCode,
    this.monthlyPay,
    this.weeklyHours,
    this.jobName,
    this.jobCode,
    this.pensionCode,
    this.healthCode,
    this.memo,
    this.filedAt,
    this.filedByName,
  });

  bool get acquire => kind == 'acquire';

  factory InsuranceReport.fromJson(Map<String, dynamic> j) => InsuranceReport(
    id: j['id'] as String,
    userId: j['userId'] as String?,
    userName: j['userName'] as String? ?? '',
    kind: j['kind'] as String? ?? 'acquire',
    eventDate: j['eventDate'] as String? ?? '',
    deadline: j['deadline'] as String? ?? '',
    reasonCode: j['reasonCode'] as String?,
    monthlyPay: _intOrNull(j['monthlyPay']),
    weeklyHours: j['weeklyHours'] as num?,
    jobName: j['jobName'] as String?,
    jobCode: j['jobCode'] as String?,
    pensionCode: j['pensionCode'] as String?,
    healthCode: j['healthCode'] as String?,
    memo: j['memo'] as String?,
    filedAt: _time(j['filedAt']),
    filedByName: j['filedByName'] as String?,
  );
}

class InsuranceReportList {
  final List<InsuranceReport> items;

  /// 입사일로 짐작한 취득 신고할 사람.
  final List<({String userId, String name, String eventDate})> suggestions;
  final List<({String code, String label})> lossReasons;
  final String today;
  const InsuranceReportList({
    this.items = const [],
    this.suggestions = const [],
    this.lossReasons = const [],
    this.today = '',
  });

  factory InsuranceReportList.fromJson(Map<String, dynamic> j) =>
      InsuranceReportList(
        items: [for (final m in _maps(j['items'])) InsuranceReport.fromJson(m)],
        suggestions: [
          for (final m in _maps(j['suggestions']))
            (
              userId: m['userId'] as String? ?? '',
              name: m['name'] as String? ?? '',
              eventDate: m['eventDate'] as String? ?? '',
            ),
        ],
        lossReasons: [
          for (final m in _maps(j['lossReasons']))
            (
              code: m['code'] as String? ?? '',
              label: m['label'] as String? ?? '',
            ),
        ],
        today: j['today'] as String? ?? '',
      );
}

// ── 지출 관리 설정 ──

/// 회계 계정 하나(코드·이름).
class LedgerAccount {
  final String code;
  final String name;
  const LedgerAccount(this.code, this.name);

  factory LedgerAccount.fromJson(Object? v) {
    final m = _map(v);
    return LedgerAccount(
      m['code'] as String? ?? '',
      m['name'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {'code': code, 'name': name};

  String get label => code.isEmpty ? name : '$code $name';
}

/// 회계 전표의 계정 — 지출 분류마다, 그리고 대변·급여 계정([named] 키: fallback·cardPayable·expensePayable·salary·withholding·payment).
class LedgerAccounts {
  final Map<String, LedgerAccount> categories;
  final Map<String, LedgerAccount> named;
  const LedgerAccounts({this.categories = const {}, this.named = const {}});

  static const namedKeys = [
    'fallback',
    'cardPayable',
    'expensePayable',
    'salary',
    'withholding',
    'payment',
  ];

  factory LedgerAccounts.fromJson(Map<String, dynamic> j) => LedgerAccounts(
    categories: {
      for (final e in _map(j['categories']).entries)
        e.key: LedgerAccount.fromJson(e.value),
    },
    named: {
      for (final k in namedKeys)
        if (j[k] is Map) k: LedgerAccount.fromJson(j[k]),
    },
  );

  Map<String, dynamic> toJson() => {
    'categories': {for (final e in categories.entries) e.key: e.value.toJson()},
    for (final e in named.entries) e.key: e.value.toJson(),
  };
}

/// CODEF(카드사·홈택스 연동) 상태.
class CodefStatus {
  /// server/.env에 CODEF 키가 있어 켜졌는지.
  final bool enabled;
  final String env;

  /// 카드사 아이디·비밀번호로 계정을 연결할 수 있는지(공개 키까지 있음).
  final bool canConnect;

  /// 홈택스에서 가져올 수 있는 종류('cash_receipt'·'tax_invoice' — 상품 주소가 있는 것).
  final List<String> hometaxKinds;
  final bool cardConnected;
  final bool hometaxConnected;
  final bool autoSync;
  final DateTime? lastSyncAt;
  final Map<String, dynamic>? lastResult;

  /// 카드사 → CODEF 기관 코드.
  final Map<String, String> organizations;

  /// 상품 주소(card·cashReceipt·taxInvoice — 비어 있으면 그 종류는 꺼짐)와 .env로 더한 응답 칸 이름이 있는지.
  final Map<String, String?> paths;
  final bool fieldOverrides;
  const CodefStatus({
    this.enabled = false,
    this.env = 'production',
    this.canConnect = false,
    this.hometaxKinds = const [],
    this.cardConnected = false,
    this.hometaxConnected = false,
    this.autoSync = false,
    this.lastSyncAt,
    this.lastResult,
    this.organizations = const {},
    this.paths = const {},
    this.fieldOverrides = false,
  });

  factory CodefStatus.fromJson(Map<String, dynamic> j) => CodefStatus(
    enabled: j['enabled'] == true,
    env: j['env'] as String? ?? 'production',
    canConnect: j['canConnect'] == true,
    hometaxKinds: (j['hometaxKinds'] as List? ?? const []).cast<String>(),
    cardConnected: j['cardConnected'] == true,
    hometaxConnected: j['hometaxConnected'] == true,
    autoSync: j['autoSync'] == true,
    lastSyncAt: _time(j['lastSyncAt']),
    lastResult: (j['lastResult'] as Map?)?.cast<String, dynamic>(),
    organizations: {
      for (final e in _map(j['organizations']).entries) e.key: '${e.value}',
    },
    paths: {
      for (final e in _map(j['paths']).entries) e.key: e.value as String?,
    },
    fieldOverrides: j['fieldOverrides'] == true,
  );
}

class FinanceSettings {
  final LedgerAccounts accounts;
  final LedgerAccounts defaults;
  final List<String> categories;

  /// 'generic' | 'douzone'.
  final String voucherFormat;

  /// 0이면 기한 없음.
  final int receiptRetentionYears;

  /// 'corporate'(3월 31일) | 'individual'(5월 31일).
  final String receiptFiling;
  final bool receiptPurge;
  final CodefStatus codef;
  const FinanceSettings({
    this.accounts = const LedgerAccounts(),
    this.defaults = const LedgerAccounts(),
    this.categories = const [],
    this.voucherFormat = 'generic',
    this.receiptRetentionYears = 5,
    this.receiptFiling = 'corporate',
    this.receiptPurge = false,
    this.codef = const CodefStatus(),
  });

  factory FinanceSettings.fromJson(Map<String, dynamic> j) => FinanceSettings(
    accounts: LedgerAccounts.fromJson(_map(j['accounts'])),
    defaults: LedgerAccounts.fromJson(_map(j['defaultAccounts'])),
    categories: (j['categories'] as List? ?? const []).cast<String>(),
    voucherFormat: j['voucherFormat'] as String? ?? 'generic',
    receiptRetentionYears: _intOrNull(j['receiptRetentionYears']) ?? 5,
    receiptFiling: j['receiptFiling'] as String? ?? 'corporate',
    receiptPurge: j['receiptPurge'] == true,
    codef: CodefStatus.fromJson(_map(j['codef'])),
  );
}

/// 영수증 보관 현황.
class ReceiptRetentionSummary {
  final int retentionYears;
  final String filing;
  final bool purge;
  final int count;
  final int bytes;
  final int expired;
  final int purged;
  final List<({int year, int count, int bytes, String? keepUntil, int expired})>
  years;
  const ReceiptRetentionSummary({
    this.retentionYears = 5,
    this.filing = 'corporate',
    this.purge = false,
    this.count = 0,
    this.bytes = 0,
    this.expired = 0,
    this.purged = 0,
    this.years = const [],
  });

  factory ReceiptRetentionSummary.fromJson(Map<String, dynamic> j) =>
      ReceiptRetentionSummary(
        retentionYears: _intOrNull(j['retentionYears']) ?? 5,
        filing: j['filing'] as String? ?? 'corporate',
        purge: j['purge'] == true,
        count: _int(j['count']),
        bytes: _int(j['bytes']),
        expired: _int(j['expired']),
        purged: _int(j['purged']),
        years: [
          for (final m in _maps(j['years']))
            (
              year: _int(m['year']),
              count: _int(m['count']),
              bytes: _int(m['bytes']),
              keepUntil: m['keepUntil'] as String?,
              expired: _int(m['expired']),
            ),
        ],
      );
}

// ── 현금영수증·전자세금계산서 ──

class TaxDocument {
  final String id;

  /// 'cash_receipt' | 'tax_invoice'.
  final String kind;

  /// 'purchase' | 'sale'.
  final String direction;
  final String issuedOn;
  final String? approvalNo;
  final String? supplierName;
  final String? supplierBizNo;
  final String? buyerName;
  final int? supplyAmount;
  final int? taxAmount;
  final int totalAmount;
  final String? itemName;
  final String? category;
  final String? memo;
  final String source;
  const TaxDocument({
    required this.id,
    required this.kind,
    this.direction = 'purchase',
    required this.issuedOn,
    this.approvalNo,
    this.supplierName,
    this.supplierBizNo,
    this.buyerName,
    this.supplyAmount,
    this.taxAmount,
    required this.totalAmount,
    this.itemName,
    this.category,
    this.memo,
    this.source = 'excel',
  });

  bool get invoice => kind == 'tax_invoice';

  factory TaxDocument.fromJson(Map<String, dynamic> j) => TaxDocument(
    id: j['id'] as String,
    kind: j['kind'] as String? ?? 'cash_receipt',
    direction: j['direction'] as String? ?? 'purchase',
    issuedOn: j['issuedOn'] as String? ?? '',
    approvalNo: j['approvalNo'] as String?,
    supplierName: j['supplierName'] as String?,
    supplierBizNo: j['supplierBizNo'] as String?,
    buyerName: j['buyerName'] as String?,
    supplyAmount: _intOrNull(j['supplyAmount']),
    taxAmount: _intOrNull(j['taxAmount']),
    totalAmount: _int(j['totalAmount']),
    itemName: j['itemName'] as String?,
    category: j['category'] as String?,
    memo: j['memo'] as String?,
    source: j['source'] as String? ?? 'excel',
  );
}

class TaxDocumentPage {
  final String month;
  final List<TaxDocument> items;
  final int count;
  final int supply;
  final int tax;
  final int total;
  const TaxDocumentPage({
    required this.month,
    this.items = const [],
    this.count = 0,
    this.supply = 0,
    this.tax = 0,
    this.total = 0,
  });

  factory TaxDocumentPage.fromJson(Map<String, dynamic> j) {
    final t = _map(j['totals']);
    return TaxDocumentPage(
      month: j['month'] as String? ?? '',
      items: [for (final m in _maps(j['items'])) TaxDocument.fromJson(m)],
      count: _int(t['count']),
      supply: _int(t['supply']),
      tax: _int(t['tax']),
      total: _int(t['total']),
    );
  }
}

class TaxDocImportResult {
  final String kind;
  final int read;
  final int fresh;
  final int duplicates;
  final int inserted;
  final List<({int line, String message})> errors;
  final String? from;
  final String? to;
  final int total;
  final bool applied;
  const TaxDocImportResult({
    required this.kind,
    this.read = 0,
    this.fresh = 0,
    this.duplicates = 0,
    this.inserted = 0,
    this.errors = const [],
    this.from,
    this.to,
    this.total = 0,
    this.applied = false,
  });

  factory TaxDocImportResult.fromJson(Map<String, dynamic> j) =>
      TaxDocImportResult(
        kind: j['kind'] as String? ?? 'cash_receipt',
        read: _int(j['read']),
        fresh: _int(j['fresh']),
        duplicates: _int(j['duplicates']),
        inserted: _int(j['inserted']),
        errors: [
          for (final m in _maps(j['errors']))
            (line: _int(m['line']), message: m['message'] as String? ?? ''),
        ],
        from: j['from'] as String?,
        to: j['to'] as String?,
        total: _int(j['total']),
        applied: j['applied'] == true,
      );
}

// ── 연말정산 공제 자료 ──

/// 공제 자료를 냈는지·담당자가 확인했는지(금액 없이).
class YearEndClaimStatus {
  final bool exists;
  final DateTime? submittedAt;
  final DateTime? confirmedAt;
  final String? confirmedByName;
  final String? updatedByName;
  final DateTime? updatedAt;
  const YearEndClaimStatus({
    this.exists = false,
    this.submittedAt,
    this.confirmedAt,
    this.confirmedByName,
    this.updatedByName,
    this.updatedAt,
  });

  bool get confirmed => confirmedAt != null;

  factory YearEndClaimStatus.fromJson(Map<String, dynamic> j) =>
      YearEndClaimStatus(
        exists: j['exists'] == true,
        submittedAt: _time(j['submittedAt']),
        confirmedAt: _time(j['confirmedAt']),
        confirmedByName: j['confirmedByName'] as String?,
        updatedByName: j['updatedByName'] as String?,
        updatedAt: _time(j['updatedAt']),
      );
}

/// 연말정산 공제 자료(server yearEndClaimRules.js parseYearEndClaim) — 홈택스 간소화 자료의 항목별 합계(원). 서버가 보낸 모양을 그대로 들고,
/// 칸마다 읽는다(화면이 같은 모양으로 다시 보낸다).
class YearEndClaim {
  final Map<String, dynamic> json;
  const YearEndClaim([this.json = const {}]);

  /// 묶음마다의 칸(server GROUPS와 같다). births·extraPersonal은 사람 수.
  static const groups = {
    'card': ['credit', 'debitCash', 'culture', 'sports', 'market', 'transit'],
    'insurance': ['general', 'disabled'],
    'medical': ['general', 'special', 'premature', 'infertility'],
    'donation': ['political', 'hometown', 'special', 'general', 'religious'],
    'pension': ['savings', 'retirement'],
    'housing': ['rentLoan', 'subscription', 'mortgage'],
    'births': ['first', 'second', 'third'],
    'extraPersonal': ['elderly', 'disabled'],
  };
  static const countGroups = {'births', 'extraPersonal'};
  static const educationKinds = [
    'self',
    'preschool',
    'school',
    'college',
    'disabled',
  ];
  static const mortgageLimits = [6000000, 8000000, 18000000, 20000000];

  int value(String group, String field) => _int(_map(json[group])[field]);
  int top(String key) => _int(json[key]);
  bool get marriage => json['marriage'] == true;
  bool get woman => _map(json['extraPersonal'])['woman'] == true;
  bool get singleParent => _map(json['extraPersonal'])['singleParent'] == true;
  int get mortgageLimit =>
      _intOrNull(_map(json['housing'])['mortgageLimit']) ?? 18000000;
  String? get memo => json['memo'] as String?;
  List<({String kind, int amount})> get education => [
    for (final m in _maps(json['education']))
      (kind: m['kind'] as String? ?? 'self', amount: _int(m['amount'])),
  ];
}

/// 한 사람·한 해의 공제 자료와 상태.
class YearEndClaimDetail {
  final YearEndClaimStatus status;
  final YearEndClaim? claim;
  const YearEndClaimDetail({
    this.status = const YearEndClaimStatus(),
    this.claim,
  });

  factory YearEndClaimDetail.fromJson(Map<String, dynamic> j) =>
      YearEndClaimDetail(
        status: YearEndClaimStatus.fromJson(j),
        claim: j['claim'] is Map ? YearEndClaim(_map(j['claim'])) : null,
      );
}

/// 내 연말정산(받는 사람) — 내 공제 자료와, 그해 내 명세서로 계산한 어림.
class MyYearEnd {
  final int year;
  final YearEndClaimDetail detail;
  final bool canEdit;
  final TaxProfile profile;
  final PayrollYearTotals totals;
  final YearEndEstimate estimate;
  const MyYearEnd({
    required this.year,
    this.detail = const YearEndClaimDetail(),
    this.canEdit = false,
    this.profile = const TaxProfile(),
    this.totals = const PayrollYearTotals(),
    this.estimate = const YearEndEstimate(),
  });

  factory MyYearEnd.fromJson(Map<String, dynamic> j) => MyYearEnd(
    year: _int(j['year']),
    detail: YearEndClaimDetail.fromJson(j),
    canEdit: j['canEdit'] == true,
    profile: TaxProfile.fromJson(_map(j['profile'])),
    totals: PayrollYearTotals.fromJson(_map(j['totals'])),
    estimate: YearEndEstimate.fromJson(_map(j['estimate'])),
  );
}

// ── 내보내기 양식(급여 이체·4대보험 신고 파일) ──

class ExportColumn {
  final String field;
  final String header;

  /// field가 'fixed'일 때 모든 줄에 넣는 값.
  final String? value;
  const ExportColumn(this.field, {this.header = '', this.value});

  factory ExportColumn.fromJson(Map<String, dynamic> j) => ExportColumn(
    j['field'] as String? ?? 'blank',
    header: j['header'] as String? ?? '',
    value: j['value'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'field': field,
    'header': header,
    if (field == 'fixed') 'value': value ?? '',
  };
}

/// 내보내기 양식(server exportTemplateRules.js) — [kind] 'transfer' | 'acquire' | 'lose'.
class ExportTemplate {
  final String? id;
  final String kind;
  final String name;
  final bool builtin;

  /// 첫 줄에 머리 글을 넣는지.
  final bool header;

  /// 'dash' | 'compact' | 'dot'.
  final String dateFormat;
  final bool rrnDash;

  /// 'xlsx' | 'csv'.
  final String fileType;
  final List<ExportColumn> columns;
  const ExportTemplate({
    this.id,
    required this.kind,
    required this.name,
    this.builtin = false,
    this.header = true,
    this.dateFormat = 'dash',
    this.rrnDash = true,
    this.fileType = 'xlsx',
    this.columns = const [],
  });

  bool get wantsRrn => columns.any((c) => c.field == 'rrn');

  factory ExportTemplate.fromJson(Map<String, dynamic> j) => ExportTemplate(
    id: j['id'] as String?,
    kind: j['kind'] as String? ?? 'transfer',
    name: j['name'] as String? ?? '',
    builtin: j['builtin'] == true,
    header: j['header'] != false,
    dateFormat: j['dateFormat'] as String? ?? 'dash',
    rrnDash: j['rrnDash'] != false,
    fileType: j['fileType'] as String? ?? 'xlsx',
    columns: [for (final m in _maps(j['columns'])) ExportColumn.fromJson(m)],
  );

  Map<String, dynamic> toJson() => {
    'id': ?id,
    'kind': kind,
    'name': name,
    'header': header,
    'dateFormat': dateFormat,
    'rrnDash': rrnDash,
    'fileType': fileType,
    'columns': [for (final c in columns) c.toJson()],
  };

  ExportTemplate copyWith({
    String? name,
    bool? header,
    String? dateFormat,
    bool? rrnDash,
    String? fileType,
    List<ExportColumn>? columns,
  }) => ExportTemplate(
    id: id,
    kind: kind,
    name: name ?? this.name,
    header: header ?? this.header,
    dateFormat: dateFormat ?? this.dateFormat,
    rrnDash: rrnDash ?? this.rrnDash,
    fileType: fileType ?? this.fileType,
    columns: columns ?? this.columns,
  );
}

class ExportTemplateSet {
  /// 담당자가 만든 양식.
  final List<ExportTemplate> templates;
  final List<ExportTemplate> builtins;

  /// 종류마다 고를 수 있는 칸.
  final Map<String, List<String>> fields;
  const ExportTemplateSet({
    this.templates = const [],
    this.builtins = const [],
    this.fields = const {},
  });

  /// [kind]의 양식 — 기본 양식 먼저.
  List<ExportTemplate> forKind(String kind) => [
    ...builtins.where((t) => t.kind == kind),
    ...templates.where((t) => t.kind == kind),
  ];

  factory ExportTemplateSet.fromJson(Map<String, dynamic> j) =>
      ExportTemplateSet(
        templates: [
          for (final m in _maps(j['templates'])) ExportTemplate.fromJson(m),
        ],
        builtins: [
          for (final m in _maps(j['builtins'])) ExportTemplate.fromJson(m),
        ],
        fields: {
          for (final e in _map(j['fields']).entries)
            e.key: (e.value as List? ?? const []).cast<String>(),
        },
      );
}

/// 급여 이체 미리 보기 — 이체할 사람 수·합계, 빠진 사람.
class TransferPreview {
  final int count;
  final int total;
  final List<({String userName, String reason})> missing;
  const TransferPreview({
    this.count = 0,
    this.total = 0,
    this.missing = const [],
  });

  factory TransferPreview.fromJson(Map<String, dynamic> j) => TransferPreview(
    count: _int(j['count']),
    total: _int(j['total']),
    missing: [
      for (final m in _maps(j['missing']))
        (
          userName: m['userName'] as String? ?? '',
          reason: m['reason'] as String? ?? '',
        ),
    ],
  );
}

// ── CODEF 연동 점검 ──

/// 응답 칸 하나를 어느 이름으로 읽었는지.
class CodefFieldCheck {
  final List<String> names;

  /// 읽은 이름 → 줄 수.
  final Map<String, int> matched;
  final int missing;
  final bool required;
  const CodefFieldCheck({
    this.names = const [],
    this.matched = const {},
    this.missing = 0,
    this.required = false,
  });

  factory CodefFieldCheck.fromJson(Map<String, dynamic> j) => CodefFieldCheck(
    names: (j['names'] as List? ?? const []).cast<String>(),
    matched: _intMap(j['matched']),
    missing: _int(j['missing']),
    required: j['required'] == true,
  );
}

/// 연동 점검 결과(server financeTools.js /codef/probe) — 값 없이 응답 코드·줄 수·칸 이름.
class CodefProbeResult {
  final String target;
  final String? organization;
  final String? path;
  final String from;
  final String to;
  final bool ok;
  final String? code;
  final String? message;
  final int count;
  final int parsed;
  final int skipped;
  final List<({String error, int count})> errors;
  final List<String> keys;
  final Map<String, CodefFieldCheck> fields;
  const CodefProbeResult({
    required this.target,
    this.organization,
    this.path,
    this.from = '',
    this.to = '',
    this.ok = false,
    this.code,
    this.message,
    this.count = 0,
    this.parsed = 0,
    this.skipped = 0,
    this.errors = const [],
    this.keys = const [],
    this.fields = const {},
  });

  factory CodefProbeResult.fromJson(Map<String, dynamic> j) => CodefProbeResult(
    target: j['target'] as String? ?? 'card',
    organization: j['organization'] as String?,
    path: j['path'] as String?,
    from: j['from'] as String? ?? '',
    to: j['to'] as String? ?? '',
    ok: j['ok'] == true,
    code: j['code'] as String?,
    message: j['message'] as String?,
    count: _int(j['count']),
    parsed: _int(j['parsed']),
    skipped: _int(j['skipped']),
    errors: [
      for (final m in _maps(j['errors']))
        (error: m['error'] as String? ?? '', count: _int(m['count'])),
    ],
    keys: (j['keys'] as List? ?? const []).cast<String>(),
    fields: {
      for (final e in _map(j['fields']).entries)
        e.key: CodefFieldCheck.fromJson(_map(e.value)),
    },
  );
}
