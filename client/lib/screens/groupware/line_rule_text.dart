import '../../models/groupware.dart';
import '../../l10n/tr.dart';

/// 결재선 규칙([ApprovalLineRule])을 읽는 글로 — 관리 탭의 규칙 목록(line_rules_section.dart)과 신청 창 결재선 아래의 "규칙: …" 안내
/// (approval_forms.dart)가 같이 쓴다. 예: "지출 · 100만 원 이상 → 직책 본부장 이상까지 + 결재 재무팀장 · 참조 인사팀",
/// "휴가 → 상위자 1명까지". 글 조각은 모두 tr(…)로 옮기고, 조각 사이는 기호(·, →, +)로만 잇는다.

/// 규칙에 고를 수 있는 결재 종류(서버 approvalLineRules.js RULE_KINDS와 같은 순서) — 'any'는 모든 결재.
const lineRuleKinds = [
  'any',
  'leave',
  'expense',
  'attendance',
  'draft',
  'trip',
  'purchase',
  'overtime',
  'form',
];

/// 결재 종류 이름 — 'any'는 "모든 결재", 'form'은 "관리자가 만든 양식"(양식 이름은 [lineRuleKindText]가 붙인다).
String lineRuleKindLabel(String kind) => switch (kind) {
  'any' => tr('모든 결재'),
  'form' => tr('관리자가 만든 양식'),
  _ => ApprovalKind.fromWire(kind).label,
};

/// 규칙이 걸리는 문서 — 한 양식만 정했으면 그 양식 이름(이름을 모르면 "관리자가 만든 양식 1개").
String lineRuleKindText(ApprovalLineRule rule, {String? templateName}) {
  if (rule.kind == 'form' && rule.templateId != null) {
    final name = templateName ?? rule.templateName;
    return name == null || name.isEmpty
        ? tr('관리자가 만든 양식 1개')
        : tr('"{name}" 양식', {'name': name});
  }
  return lineRuleKindLabel(rule.kind);
}

/// 세 자리마다 쉼표(1500 → "1,500").
String _grouped(int n) {
  final digits = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// 금액을 짧게 — 억·만 원 단위로 떨어지면 "1억 원"·"100만 원"·"1,500만 원", 아니면 "1,234,567원"(wonText).
String shortWonText(int amount) {
  // 억·만은 한국어 단위라 다른 언어에서는 그대로 다 적는다.
  if (!AppLocale.isKorean) return wonText(amount);
  if (amount >= 100000000 && amount % 100000000 == 0) {
    return tr('{n}억 원', {'n': _grouped(amount ~/ 100000000)});
  }
  if (amount >= 10000 && amount % 10000 == 0) {
    return tr('{n}만 원', {'n': _grouped(amount ~/ 10000)});
  }
  return wonText(amount);
}

/// 어디까지 채우는지 — "상위자 1명까지" | "상위자 없이"(0명) | "직책 본부장 이상까지".
String lineRuleReachText(ApprovalLineRule rule) {
  if (rule.mode == 'position') {
    return tr('직책 {position} 이상까지', {'position': rule.positionLabel ?? ''});
  }
  final levels = rule.levels ?? 0;
  return levels == 0 ? tr('상위자 없이') : tr('상위자 {n}명까지', {'n': levels});
}

/// 규칙 한 줄 — "{종류} · {금액} 이상 → {어디까지} + 결재 {사람들} · 참조 {사람들}". [nameOf]는 사람 id → 이름(모르면 "(알 수 없음)").
String lineRuleSentence(
  ApprovalLineRule rule, {
  String Function(String id)? nameOf,
  String? templateName,
}) {
  String names(List<String> ids) =>
      ids.map((id) => nameOf?.call(id) ?? tr('(알 수 없음)')).join(', ');
  final head = [
    lineRuleKindText(rule, templateName: templateName),
    if (rule.minAmount != null)
      tr('{amount} 이상', {'amount': shortWonText(rule.minAmount!)}),
  ].join(' · ');
  final extras = [
    if (rule.extraApproverIds.isNotEmpty)
      tr('결재 {names}', {'names': names(rule.extraApproverIds)}),
    if (rule.ccIds.isNotEmpty) tr('참조 {names}', {'names': names(rule.ccIds)}),
  ].join(' · ');
  final reach = lineRuleReachText(rule);
  return extras.isEmpty ? '$head → $reach' : '$head → $reach + $extras';
}
