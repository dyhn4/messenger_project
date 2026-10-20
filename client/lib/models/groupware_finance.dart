import '../l10n/tr.dart';

/// 그룹웨어 급여명세서·법인카드·영수증 읽기 모델(server/src/payroll.js·corporateCards.js).

int _int(Object? v) => (v as num?)?.toInt() ?? 0;
int? _intOrNull(Object? v) => (v as num?)?.toInt();
DateTime? _time(Object? v) =>
    v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;
List<Map<String, dynamic>> _maps(Object? v) => [
  for (final e in (v as List? ?? const []))
    if (e is Map) e.cast<String, dynamic>(),
];

/// 원 단위 금액 — 음수(승인 취소·환수)도 "-12,300원"으로.
String signedWonText(int amount) {
  final digits = amount.abs().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return tr('{buffer}원', {'buffer': '${amount < 0 ? '-' : ''}$buffer'});
}

/// 분 → "10시간 30분"(0이면 "0시간").
String payrollHoursText(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? tr('{h}시간', {'h': h}) : tr('{h}시간 {m}분', {'h': h, 'm': m});
}

// ── 급여명세서 ──

/// 지급·공제 항목 하나 — [basis]는 계산 방법(연장근로수당의 "10시간 × 12,000원 × 1.5" 등), [taxFree]는 비과세 지급 항목.
class PayrollItem {
  final String name;
  final int amount;
  final String? basis;
  final bool taxFree;
  const PayrollItem({
    required this.name,
    required this.amount,
    this.basis,
    this.taxFree = false,
  });

  factory PayrollItem.fromJson(Map<String, dynamic> json) => PayrollItem(
    name: json['name'] as String? ?? '',
    amount: _int(json['amount']),
    basis: json['basis'] as String?,
    taxFree: json['taxFree'] == true,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'amount': amount,
    if (basis != null && basis!.trim().isNotEmpty) 'basis': basis!.trim(),
    if (taxFree) 'taxFree': true,
  };

  PayrollItem copyWith({
    String? name,
    int? amount,
    String? basis,
    bool? taxFree,
  }) => PayrollItem(
    name: name ?? this.name,
    amount: amount ?? this.amount,
    basis: basis ?? this.basis,
    taxFree: taxFree ?? this.taxFree,
  );
}

List<PayrollItem> _items(Object? v) => [
  for (final m in _maps(v)) PayrollItem.fromJson(m),
];

/// 근무 시간 요약(명세서의 "근무 내역" — 출근일수·실근로·연장·야간·휴일, 분).
class PayrollWork {
  final int? workDays;
  final int? workMinutes;
  final int? overtimeMinutes;
  final int? nightMinutes;
  final int? holidayMinutes;
  const PayrollWork({
    this.workDays,
    this.workMinutes,
    this.overtimeMinutes,
    this.nightMinutes,
    this.holidayMinutes,
  });

  static PayrollWork? fromJson(Object? v) {
    if (v is! Map) return null;
    final m = v.cast<String, dynamic>();
    return PayrollWork(
      workDays: _intOrNull(m['workDays']),
      workMinutes: _intOrNull(m['workMinutes']),
      overtimeMinutes: _intOrNull(m['overtimeMinutes']),
      nightMinutes: _intOrNull(m['nightMinutes']),
      holidayMinutes: _intOrNull(m['holidayMinutes']),
    );
  }

  Map<String, dynamic> toJson() => {
    'workDays': ?workDays,
    'workMinutes': ?workMinutes,
    'overtimeMinutes': ?overtimeMinutes,
    'nightMinutes': ?nightMinutes,
    'holidayMinutes': ?holidayMinutes,
  };

  bool get isEmpty =>
      workDays == null &&
      workMinutes == null &&
      overtimeMinutes == null &&
      nightMinutes == null &&
      holidayMinutes == null;
}

/// 보낸 뒤 고친 기록 하나 — 언제·누가·왜, 그때(정정 전)의 합계(담당자에게는 그때의 항목까지).
class PayslipCorrection {
  final int revision;
  final DateTime? correctedAt;
  final String? correctedByName;
  final String? reason;
  final int gross;
  final int deductionTotal;
  final int net;
  final List<PayrollItem>? earnings;
  final List<PayrollItem>? deductions;
  const PayslipCorrection({
    required this.revision,
    this.correctedAt,
    this.correctedByName,
    this.reason,
    required this.gross,
    required this.deductionTotal,
    required this.net,
    this.earnings,
    this.deductions,
  });

  factory PayslipCorrection.fromJson(Map<String, dynamic> json) =>
      PayslipCorrection(
        revision: _int(json['revision']),
        correctedAt: _time(json['correctedAt']),
        correctedByName: json['correctedByName'] as String?,
        reason: json['reason'] as String?,
        gross: _int(json['gross']),
        deductionTotal: _int(json['deductionTotal']),
        net: _int(json['net']),
        earnings: json['earnings'] == null ? null : _items(json['earnings']),
        deductions: json['deductions'] == null
            ? null
            : _items(json['deductions']),
      );
}

/// 급여 대장(한 달 정기 급여·상여 등).
class PayrollRun {
  final String id;
  final String title;

  /// 'YYYY-MM'.
  final String payMonth;

  /// 'YYYY-MM-DD'.
  final String payDate;
  final String? note;

  /// 'draft'(작성 중) | 'published'(보냄).
  final String status;
  final String createdByName;
  final DateTime? publishedAt;
  final String? publishedByName;
  final int slipCount;
  final int viewedCount;
  const PayrollRun({
    required this.id,
    required this.title,
    required this.payMonth,
    required this.payDate,
    this.note,
    required this.status,
    this.createdByName = '',
    this.publishedAt,
    this.publishedByName,
    this.slipCount = 0,
    this.viewedCount = 0,
  });

  bool get published => status == 'published';

  factory PayrollRun.fromJson(Map<String, dynamic> json) => PayrollRun(
    id: json['id'] as String,
    title: json['title'] as String? ?? '',
    payMonth: json['payMonth'] as String? ?? '',
    payDate: json['payDate'] as String? ?? '',
    note: json['note'] as String?,
    status: json['status'] as String? ?? 'draft',
    createdByName: json['createdByName'] as String? ?? '',
    publishedAt: _time(json['publishedAt']),
    publishedByName: json['publishedByName'] as String?,
    slipCount: _int(json['slipCount']),
    viewedCount: _int(json['viewedCount']),
  );
}

/// 급여명세서 하나. 목록(내 명세서)에서는 항목 없이 합계만 온다([earnings]가 빈 목록).
class Payslip {
  final String id;
  final String runId;
  final String userId;
  final String userName;
  final String? username;
  final String? employeeNo;
  final String? department;
  final String? position;
  final int revision;
  final DateTime? correctedAt;
  final DateTime? viewedAt;
  final int gross;
  final int taxable;
  final int taxFree;
  final int deductionTotal;
  final int net;
  final List<PayrollItem> earnings;
  final List<PayrollItem> deductions;
  final PayrollWork? work;
  final String? memo;
  final List<PayslipCorrection> corrections;

  /// 명세서를 연 곳에서 같이 오는 대장·회사 이름(받는 사람 화면).
  final PayrollRun? run;
  final String? companyName;

  /// 서버가 내용을 풀지 못했다(암호화 키가 바뀌는 등) — 고쳐 저장하면 새로 쓴다.
  final bool unreadable;
  const Payslip({
    required this.id,
    required this.runId,
    required this.userId,
    required this.userName,
    this.username,
    this.employeeNo,
    this.department,
    this.position,
    this.revision = 1,
    this.correctedAt,
    this.viewedAt,
    required this.gross,
    this.taxable = 0,
    this.taxFree = 0,
    required this.deductionTotal,
    required this.net,
    this.earnings = const [],
    this.deductions = const [],
    this.work,
    this.memo,
    this.corrections = const [],
    this.run,
    this.companyName,
    this.unreadable = false,
  });

  factory Payslip.fromJson(Map<String, dynamic> json) => Payslip(
    id: json['id'] as String,
    runId: json['runId'] as String? ?? '',
    userId: json['userId'] as String? ?? '',
    userName: json['userName'] as String? ?? '',
    username: json['username'] as String?,
    employeeNo: json['employeeNo'] as String?,
    department: json['department'] as String?,
    position: json['position'] as String?,
    revision: _intOrNull(json['revision']) ?? 1,
    correctedAt: _time(json['correctedAt']),
    viewedAt: _time(json['viewedAt']),
    gross: _int(json['gross']),
    taxable: _int(json['taxable']),
    taxFree: _int(json['taxFree']),
    deductionTotal: _int(json['deductionTotal']),
    net: _int(json['net']),
    earnings: _items(json['earnings']),
    deductions: _items(json['deductions']),
    work: PayrollWork.fromJson(json['work']),
    memo: json['memo'] as String?,
    corrections: [
      for (final m in _maps(json['corrections'])) PayslipCorrection.fromJson(m),
    ],
    run: json['run'] is Map
        ? PayrollRun.fromJson((json['run'] as Map).cast<String, dynamic>())
        : null,
    companyName: json['companyName'] as String?,
    unreadable: json['unreadable'] == true,
  );
}

/// 대장 하나와 명세서들(담당자 화면).
class PayrollRunDetail {
  final PayrollRun run;
  final List<Payslip> payslips;
  final int gross;
  final int deductionTotal;
  final int net;

  /// 아직 이 대장에 없는 구성원(더하기 고르기).
  final List<({String id, String name, String username})> addable;
  final String? companyName;
  const PayrollRunDetail({
    required this.run,
    required this.payslips,
    required this.gross,
    required this.deductionTotal,
    required this.net,
    this.addable = const [],
    this.companyName,
  });

  factory PayrollRunDetail.fromJson(Map<String, dynamic> json) {
    final totals =
        (json['totals'] as Map?)?.cast<String, dynamic>() ?? const {};
    return PayrollRunDetail(
      run: PayrollRun.fromJson(json),
      payslips: [for (final m in _maps(json['payslips'])) Payslip.fromJson(m)],
      gross: _int(totals['gross']),
      deductionTotal: _int(totals['deductionTotal']),
      net: _int(totals['net']),
      addable: [
        for (final m in _maps(json['addable']))
          (
            id: m['id'] as String,
            name: m['name'] as String? ?? '',
            username: m['username'] as String? ?? '',
          ),
      ],
      companyName: json['companyName'] as String?,
    );
  }
}

/// 급여 설정 — 담당자·회사 이름·새 명세서의 항목 틀·4대보험 요율(%)·사번.
class PayrollSettings {
  final List<String> staffIds;
  final String? companyName;
  final List<PayrollItem> templateEarnings;
  final List<PayrollItem> templateDeductions;

  /// pension·health·longTermCare·employment·localTax(%), pensionMin·pensionMax(원).
  final Map<String, num> insurance;
  final Map<String, String> employeeNos;

  /// 담당자를 바꿀 수 있는지(그룹웨어 관리자만).
  final bool canEditStaff;
  final List<({String id, String name, String username})> people;

  /// 사람마다의 원천징수 정보(없는 사람은 본인 1명·100%).
  final Map<String, TaxProfile> taxProfiles;

  /// 사람마다의 급여 계좌(급여 이체 파일).
  final Map<String, BankAccount> bankAccounts;

  /// 고를 수 있는 은행(금융결제원 코드).
  final List<({String code, String name})> banks;

  /// 받는 사람이 명세서를 열 때 비밀번호를 다시 묻는지.
  final bool requireReauth;
  const PayrollSettings({
    this.staffIds = const [],
    this.companyName,
    this.templateEarnings = const [],
    this.templateDeductions = const [],
    this.insurance = const {},
    this.employeeNos = const {},
    this.canEditStaff = false,
    this.people = const [],
    this.taxProfiles = const {},
    this.bankAccounts = const {},
    this.banks = const [],
    this.requireReauth = false,
  });

  factory PayrollSettings.fromJson(Map<String, dynamic> json) {
    final template =
        (json['template'] as Map?)?.cast<String, dynamic>() ?? const {};
    return PayrollSettings(
      staffIds: (json['staffIds'] as List? ?? const []).cast<String>(),
      companyName: json['companyName'] as String?,
      templateEarnings: _items(template['earnings']),
      templateDeductions: _items(template['deductions']),
      insurance: {
        for (final e
            in ((json['insurance'] as Map?)?.cast<String, dynamic>() ??
                    const {})
                .entries)
          if (e.value is num) e.key: e.value as num,
      },
      employeeNos: {
        for (final e
            in ((json['employeeNos'] as Map?)?.cast<String, dynamic>() ??
                    const {})
                .entries)
          e.key: '${e.value}',
      },
      canEditStaff: json['canEditStaff'] == true,
      people: [
        for (final m in _maps(json['people']))
          (
            id: m['id'] as String,
            name: m['name'] as String? ?? '',
            username: m['username'] as String? ?? '',
          ),
      ],
      taxProfiles: {
        for (final e
            in ((json['taxProfiles'] as Map?)?.cast<String, dynamic>() ??
                    const {})
                .entries)
          if (e.value is Map)
            e.key: TaxProfile.fromJson(
              (e.value as Map).cast<String, dynamic>(),
            ),
      },
      bankAccounts: {
        for (final e
            in ((json['bankAccounts'] as Map?)?.cast<String, dynamic>() ??
                    const {})
                .entries)
          if (e.value is Map)
            e.key: BankAccount.fromJson(
              (e.value as Map).cast<String, dynamic>(),
            ),
      },
      banks: [
        for (final m in _maps(json['banks']))
          (code: m['code'] as String? ?? '', name: m['name'] as String? ?? ''),
      ],
      requireReauth: json['requireReauth'] == true,
    );
  }
}

/// 원천징수 정보 — 공제대상가족(본인 포함)·그중 8~20세 자녀·원천징수 비율(80·100·120%), [auto]가 false면 소득세를 직접 넣는다.
class TaxProfile {
  final int dependents;
  final int children;
  final int ratio;
  final bool auto;
  const TaxProfile({
    this.dependents = 1,
    this.children = 0,
    this.ratio = 100,
    this.auto = true,
  });

  factory TaxProfile.fromJson(Map<String, dynamic> json) => TaxProfile(
    dependents: _intOrNull(json['dependents']) ?? 1,
    children: _int(json['children']),
    ratio: _intOrNull(json['ratio']) ?? 100,
    auto: json['auto'] != false,
  );

  Map<String, dynamic> toJson() => {
    'dependents': dependents,
    'children': children,
    'ratio': ratio,
    if (!auto) 'auto': false,
  };

  bool get isDefault =>
      dependents == 1 && children == 0 && ratio == 100 && auto;
}

/// 급여 계좌(은행 코드·계좌번호·예금주).
class BankAccount {
  final String bankCode;
  final String number;
  final String? holder;
  const BankAccount({
    required this.bankCode,
    required this.number,
    this.holder,
  });

  factory BankAccount.fromJson(Map<String, dynamic> json) => BankAccount(
    bankCode: json['bankCode'] as String? ?? '',
    number: json['number'] as String? ?? '',
    holder: json['holder'] as String?,
  );
}

/// 급여대장 엑셀 가져오기의 결과(미리 보기·적용).
class PayrollImportResult {
  final int updated;
  final int added;
  final List<({int row, String label})> unmatched;
  final List<({int row, String message})> errors;
  final List<String> earningColumns;
  final List<String> deductionColumns;
  final bool applied;
  const PayrollImportResult({
    required this.updated,
    required this.added,
    this.unmatched = const [],
    this.errors = const [],
    this.earningColumns = const [],
    this.deductionColumns = const [],
    this.applied = false,
  });

  factory PayrollImportResult.fromJson(Map<String, dynamic> json) {
    final columns =
        (json['columns'] as Map?)?.cast<String, dynamic>() ?? const {};
    return PayrollImportResult(
      updated: _int(json['updated']),
      added: _int(json['added']),
      unmatched: [
        for (final m in _maps(json['unmatched']))
          (row: _int(m['row']), label: m['label'] as String? ?? ''),
      ],
      errors: [
        for (final m in _maps(json['errors']))
          (row: _int(m['row']), message: m['message'] as String? ?? ''),
      ],
      earningColumns: (columns['earnings'] as List? ?? const []).cast<String>(),
      deductionColumns: (columns['deductions'] as List? ?? const [])
          .cast<String>(),
      applied: json['applied'] == true,
    );
  }
}

// ── 법인카드 ──

/// 카드사(서버 cardRules.js CARD_ISSUERS와 같다).
const cardIssuers = [
  '신한',
  '삼성',
  'KB국민',
  '현대',
  '롯데',
  '하나',
  '우리',
  'BC',
  'NH농협',
  'IBK기업',
  '씨티',
  '기타',
];

class CorporateCard {
  final String id;
  final String name;
  final String issuer;
  final String last4;
  final List<({String id, String? name})> holders;
  final int? monthlyLimit;
  final String? memo;
  final bool enabled;

  /// 고른 달의 사용 합계(관리자 목록).
  final int? used;

  /// 카드사·홈택스 연동(CODEF)의 기관 코드 — 직접 넣은 것([codefOrganization])과 실제로 쓰는 것([codefOrg] — 없으면 카드사 이름으로).
  final String? codefOrganization;
  final String? codefOrg;
  const CorporateCard({
    required this.id,
    required this.name,
    required this.issuer,
    required this.last4,
    this.holders = const [],
    this.monthlyLimit,
    this.memo,
    this.enabled = true,
    this.used,
    this.codefOrganization,
    this.codefOrg,
  });

  List<String> get holderIds => [for (final h in holders) h.id];

  /// "영업 카드 (신한 5678)".
  String get label => '$name ($issuer $last4)';

  factory CorporateCard.fromJson(Map<String, dynamic> json) => CorporateCard(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    issuer: json['issuer'] as String? ?? '기타',
    last4: json['last4'] as String? ?? '',
    holders: [
      for (final m in _maps(json['holders']))
        (id: m['id'] as String, name: m['name'] as String?),
    ],
    monthlyLimit: _intOrNull(json['monthlyLimit']),
    memo: json['memo'] as String?,
    enabled: json['enabled'] != false,
    used: _intOrNull(json['used']),
    codefOrganization: json['codefOrganization'] as String?,
    codefOrg: json['codefOrg'] as String?,
  );
}

/// 사용 건 상태.
enum CardTxStatus {
  open('미정산'),
  claiming('결재 중'),
  settled('정산됨'),
  excluded('제외');

  final String _labelKo;
  const CardTxStatus(this._labelKo);
  String get label => tr(_labelKo);

  static CardTxStatus fromWire(String? v) => switch (v) {
    'claiming' => claiming,
    'settled' => settled,
    'excluded' => excluded,
    _ => open,
  };
}

/// 영수증 첨부 하나(서명 링크).
class ReceiptFile {
  final String? fileUrl;
  final String? fileName;
  final int? fileSize;
  final String? mimeType;

  /// 보관 기한이 지나 서버가 원본을 지운 때(링크 없음).
  final DateTime? purgedAt;
  const ReceiptFile({
    this.fileUrl,
    this.fileName,
    this.fileSize,
    this.mimeType,
    this.purgedAt,
  });

  factory ReceiptFile.fromJson(Map<String, dynamic> json) => ReceiptFile(
    fileUrl: json['fileUrl'] as String?,
    fileName: json['fileName'] as String?,
    fileSize: _intOrNull(json['fileSize']),
    mimeType: json['mimeType'] as String?,
    purgedAt: _time(json['purgedAt']),
  );

  Map<String, dynamic> toJson() => {
    'fileUrl': fileUrl,
    'fileName': fileName,
    'fileSize': fileSize,
    'mimeType': mimeType,
  };

  bool get isImage =>
      (mimeType ?? '').startsWith('image/') ||
      RegExp(
        r'\.(jpe?g|png|webp|gif|heic)$',
        caseSensitive: false,
      ).hasMatch(fileName ?? '');
}

/// 읽은 영수증(서버 receiptOcrRules.js normalizeReceipt) — 모르는 값은 null.
class ReceiptData {
  final String? merchant;
  final String? bizNo;

  /// 'YYYY-MM-DD'.
  final String? date;

  /// 'HH:MM'.
  final String? time;
  final int? total;
  final int? vat;
  final String? cardLast4;
  final String? approvalNo;
  final List<({String name, int? qty, int? amount})> items;
  const ReceiptData({
    this.merchant,
    this.bizNo,
    this.date,
    this.time,
    this.total,
    this.vat,
    this.cardLast4,
    this.approvalNo,
    this.items = const [],
  });

  static ReceiptData? fromJson(Object? v) {
    if (v is! Map) return null;
    final m = v.cast<String, dynamic>();
    return ReceiptData(
      merchant: m['merchant'] as String?,
      bizNo: m['bizNo'] as String?,
      date: m['date'] as String?,
      time: m['time'] as String?,
      total: _intOrNull(m['total']),
      vat: _intOrNull(m['vat']),
      cardLast4: m['cardLast4'] as String?,
      approvalNo: m['approvalNo'] as String?,
      items: [
        for (final i in _maps(m['items']))
          (
            name: i['name'] as String? ?? '',
            qty: _intOrNull(i['qty']),
            amount: _intOrNull(i['amount']),
          ),
      ],
    );
  }

  /// "스타벅스 · 2026-10-18 · 5,600원".
  String get summary =>
      [?merchant, ?date, if (total != null) signedWonText(total!)].join(' · ');
}

/// 법인카드 사용 건.
class CardTransaction {
  final String id;
  final String cardId;
  final String cardName;
  final String issuer;
  final String last4;
  final DateTime usedAt;

  /// 한국 날짜 'YYYY-MM-DD'.
  final String usedOn;
  final String merchant;
  final String? merchantBizNo;
  final int amount;
  final String? approvalNo;

  /// 'excel' | 'api' | 'manual'.
  final String source;
  final String? userId;
  final String? userName;
  final String? memo;
  final String? category;
  final List<ReceiptFile> receipts;
  final ReceiptData? receiptScan;

  /// 읽은 영수증과 어긋나는 점 — 'amount' | 'date' | 'card'.
  final List<String> mismatches;
  final CardTxStatus status;
  final ({String id, String? docNumber, String? title, String status})? expense;
  final DateTime? excludedAt;
  final String? excludedReason;
  final String? excludedByName;
  final bool canEdit;
  final bool canClaim;
  final bool unassigned;
  const CardTransaction({
    required this.id,
    required this.cardId,
    required this.cardName,
    required this.issuer,
    required this.last4,
    required this.usedAt,
    required this.usedOn,
    required this.merchant,
    this.merchantBizNo,
    required this.amount,
    this.approvalNo,
    this.source = 'excel',
    this.userId,
    this.userName,
    this.memo,
    this.category,
    this.receipts = const [],
    this.receiptScan,
    this.mismatches = const [],
    this.status = CardTxStatus.open,
    this.expense,
    this.excludedAt,
    this.excludedReason,
    this.excludedByName,
    this.canEdit = false,
    this.canClaim = false,
    this.unassigned = false,
  });

  factory CardTransaction.fromJson(Map<String, dynamic> json) {
    final expense = json['expense'] is Map
        ? (json['expense'] as Map).cast<String, dynamic>()
        : null;
    return CardTransaction(
      id: json['id'] as String,
      cardId: json['cardId'] as String? ?? '',
      cardName: json['cardName'] as String? ?? '',
      issuer: json['issuer'] as String? ?? '',
      last4: json['last4'] as String? ?? '',
      usedAt: _time(json['usedAt']) ?? DateTime.now(),
      usedOn: json['usedOn'] as String? ?? '',
      merchant: json['merchant'] as String? ?? '',
      merchantBizNo: json['merchantBizNo'] as String?,
      amount: _int(json['amount']),
      approvalNo: json['approvalNo'] as String?,
      source: json['source'] as String? ?? 'excel',
      userId: json['userId'] as String?,
      userName: json['userName'] as String?,
      memo: json['memo'] as String?,
      category: json['category'] as String?,
      receipts: [
        for (final m in _maps(json['receipts'])) ReceiptFile.fromJson(m),
      ],
      receiptScan: ReceiptData.fromJson(json['receiptScan']),
      mismatches: (json['mismatches'] as List? ?? const []).cast<String>(),
      status: CardTxStatus.fromWire(json['status'] as String?),
      expense: expense == null
          ? null
          : (
              id: expense['id'] as String,
              docNumber: expense['docNumber'] as String?,
              title: expense['title'] as String?,
              status: expense['status'] as String? ?? '',
            ),
      excludedAt: _time(json['excludedAt']),
      excludedReason: json['excludedReason'] as String?,
      excludedByName: json['excludedByName'] as String?,
      canEdit: json['canEdit'] == true,
      canClaim: json['canClaim'] == true,
      unassigned: json['unassigned'] == true,
    );
  }

  /// 어긋남 안내 글(없으면 null).
  String? get mismatchText {
    if (mismatches.isEmpty) return null;
    final parts = [
      if (mismatches.contains('amount'))
        tr('금액({won})', {
          'won': receiptScan?.total == null
              ? '?'
              : signedWonText(receiptScan!.total!),
        }),
      if (mismatches.contains('date'))
        tr('날짜({date})', {'date': receiptScan?.date ?? '?'}),
      if (mismatches.contains('card'))
        tr('카드(끝 {last4})', {'last4': receiptScan?.cardLast4 ?? '?'}),
    ];
    return tr('영수증과 다릅니다: {parts}', {'parts': parts.join(', ')});
  }
}

/// 사용 건 목록과 합계.
class CardTransactionPage {
  final String? month;
  final bool mine;
  final List<CardTransaction> items;
  final int total;
  final int openTotal;
  final int claimingTotal;
  final int settledTotal;
  final int excludedTotal;
  final int openCount;
  const CardTransactionPage({
    this.month,
    this.mine = true,
    required this.items,
    this.total = 0,
    this.openTotal = 0,
    this.claimingTotal = 0,
    this.settledTotal = 0,
    this.excludedTotal = 0,
    this.openCount = 0,
  });

  factory CardTransactionPage.fromJson(Map<String, dynamic> json) {
    final t = (json['totals'] as Map?)?.cast<String, dynamic>() ?? const {};
    return CardTransactionPage(
      month: json['month'] as String?,
      mine: json['mine'] != false,
      items: [
        for (final m in _maps(json['items'])) CardTransaction.fromJson(m),
      ],
      total: _int(t['all']),
      openTotal: _int(t['open']),
      claimingTotal: _int(t['claiming']),
      settledTotal: _int(t['settled']),
      excludedTotal: _int(t['excluded']),
      openCount: _int(t['openCount']),
    );
  }
}

/// 이용내역 가져오기의 결과(미리 보기·적용).
class CardImportResult {
  final int read;
  final int fresh;
  final int duplicates;
  final List<({int line, String message})> errors;
  final String? from;
  final String? to;
  final int total;
  final int inserted;
  final int paired;
  final bool applied;
  const CardImportResult({
    required this.read,
    required this.fresh,
    required this.duplicates,
    this.errors = const [],
    this.from,
    this.to,
    this.total = 0,
    this.inserted = 0,
    this.paired = 0,
    this.applied = false,
  });

  factory CardImportResult.fromJson(Map<String, dynamic> json) =>
      CardImportResult(
        read: _int(json['read']),
        fresh: _int(json['fresh']),
        duplicates: _int(json['duplicates']),
        errors: [
          for (final m in _maps(json['errors']))
            (line: _int(m['line']), message: m['message'] as String? ?? ''),
        ],
        from: json['from'] as String?,
        to: json['to'] as String?,
        total: _int(json['total']),
        inserted: _int(json['inserted']),
        paired: _int(json['paired']),
        applied: json['applied'] == true,
      );
}

/// 법인카드 연동 키(값은 만들 때 한 번만 [token]으로 온다).
class CardFeedKey {
  final bool exists;
  final String? hint;
  final String? createdByName;
  final DateTime? createdAt;
  final DateTime? lastUsedAt;
  final String? token;
  const CardFeedKey({
    required this.exists,
    this.hint,
    this.createdByName,
    this.createdAt,
    this.lastUsedAt,
    this.token,
  });

  factory CardFeedKey.fromJson(Map<String, dynamic> json) => CardFeedKey(
    exists: json['exists'] == true,
    hint: json['hint'] as String?,
    createdByName: json['createdByName'] as String?,
    createdAt: _time(json['createdAt']),
    lastUsedAt: _time(json['lastUsedAt']),
    token: json['token'] as String?,
  );
}

/// 영수증 읽기 결과 — 읽은 값, 짐작한 지출 분류, 맞을 법한 내 미정산 사용 건(점수 순).
class ReceiptScanResult {
  final ReceiptData receipt;

  /// 아무것도 못 읽었다(영수증이 아니거나 흐림).
  final bool empty;
  final String? category;
  final List<({CardTransaction transaction, int score, List<String> reasons})>
  matches;

  /// 사용 건에서 읽었으면 바뀐 그 건(어긋남 표시).
  final CardTransaction? transaction;
  const ReceiptScanResult({
    required this.receipt,
    this.empty = false,
    this.category,
    this.matches = const [],
    this.transaction,
  });

  factory ReceiptScanResult.fromJson(Map<String, dynamic> json) =>
      ReceiptScanResult(
        receipt: ReceiptData.fromJson(json['receipt']) ?? const ReceiptData(),
        empty: json['empty'] == true,
        category: json['category'] as String?,
        matches: [
          for (final m in _maps(json['matches']))
            if (m['transaction'] is Map)
              (
                transaction: CardTransaction.fromJson(
                  (m['transaction'] as Map).cast<String, dynamic>(),
                ),
                score: _int(m['score']),
                reasons: (m['reasons'] as List? ?? const []).cast<String>(),
              ),
        ],
        transaction: json['transaction'] is Map
            ? CardTransaction.fromJson(
                (json['transaction'] as Map).cast<String, dynamic>(),
              )
            : null,
      );
}

/// 지출 결재에 적힌 그때의 카드 사용 건(payload.cardTransactions — 결재 상세·인쇄).
class ClaimedCardTransaction {
  final String id;
  final String cardName;
  final String issuer;
  final String last4;
  final DateTime? usedAt;
  final String merchant;
  final String? merchantBizNo;
  final int amount;
  final String? approvalNo;
  final String? memo;
  final List<ReceiptFile> receipts;
  const ClaimedCardTransaction({
    required this.id,
    required this.cardName,
    required this.issuer,
    required this.last4,
    this.usedAt,
    required this.merchant,
    this.merchantBizNo,
    required this.amount,
    this.approvalNo,
    this.memo,
    this.receipts = const [],
  });

  factory ClaimedCardTransaction.fromJson(Map<String, dynamic> json) =>
      ClaimedCardTransaction(
        id: json['id'] as String? ?? '',
        cardName: json['cardName'] as String? ?? '',
        issuer: json['issuer'] as String? ?? '',
        last4: json['last4'] as String? ?? '',
        usedAt: _time(json['usedAt']),
        merchant: json['merchant'] as String? ?? '',
        merchantBizNo: json['merchantBizNo'] as String?,
        amount: _int(json['amount']),
        approvalNo: json['approvalNo'] as String?,
        memo: json['memo'] as String?,
        receipts: [
          for (final m in _maps(json['receipts'])) ReceiptFile.fromJson(m),
        ],
      );

  /// 결재 payload에서 꺼낸다(없으면 빈 목록).
  static List<ClaimedCardTransaction> listOf(Map<String, dynamic> payload) => [
    for (final m in _maps(payload['cardTransactions']))
      ClaimedCardTransaction.fromJson(m),
  ];
}
