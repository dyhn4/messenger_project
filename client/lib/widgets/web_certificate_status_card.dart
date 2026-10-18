import 'package:flutter/material.dart';

import '../models/web_certificate_status.dart';
import '../services/time_format.dart';
import '../l10n/tr.dart';

/// 관리자 콘솔 "DDNS" 탭의 웹 앱 주소(정식 인증서) 카드(admin_ddns_tab.dart) — 아이폰 사용자가 쓰는 웹 앱의 공인 인증서(Let's Encrypt)가
/// 지금 어떤지, 운영자가 다음에 무엇을 하면 되는지까지 쉬운 말로 보여 준다(서버 GET /api/admin/web-certificate).
///
/// [load]가 null을 주면(이 기능이 없는 예전 서버 — 404) 아무것도 그리지 않는다. 처음 불러오는 동안에도 자리를
/// 차지하지 않는다 — 예전 서버에서 카드 자리가 잠깐 생겼다 사라지며 아래 설정 항목들이 들썩이지 않게.
class WebCertificateStatusCard extends StatefulWidget {
  final Future<WebCertificateStatus?> Function() load;
  const WebCertificateStatusCard({super.key, required this.load});

  @override
  State<WebCertificateStatusCard> createState() =>
      _WebCertificateStatusCardState();
}

class _WebCertificateStatusCardState extends State<WebCertificateStatusCard> {
  WebCertificateStatus? _status;
  String? _error;
  bool _loaded = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _refresh() {
    setState(() => _loading = true);
    return _load();
  }

  Future<void> _load() async {
    try {
      final status = await widget.load();
      if (!mounted) return;
      setState(() {
        _status = status;
        _error = null;
        _loaded = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loaded = true;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    if (!_loaded || (status == null && _error == null)) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final (icon, color) = status == null
        ? (Icons.help_outline, hint)
        : _look(status, theme);
    final label = status == null ? tr('확인 못 함') : webCertificateLabel(status);
    final lines = status == null
        ? [
            tr('상태를 불러오지 못했습니다: {_error}', {'_error': _error}),
          ]
        : webCertificateLines(status);
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.fromLTRB(16, 6, 6, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    text: tr('웹 앱 주소(정식 인증서)'),
                    children: [
                      TextSpan(
                        text: '  ·  $label',
                        style: TextStyle(color: color),
                      ),
                    ],
                  ),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                tooltip: tr('다시 확인'),
                onPressed: _loading ? null : _refresh,
                icon: _loading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 10),
              child: Text(
                line,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: line.startsWith('※') ? hint : null,
                ),
              ),
            ),
        ],
      ),
    );
  }

  (IconData, Color) _look(WebCertificateStatus s, ThemeData theme) {
    if (s.isOff) return (Icons.public_off, theme.hintColor);
    return switch (s.status) {
      WebCertificateState.valid => (Icons.verified_user, Colors.green.shade700),
      WebCertificateState.expiring => (Icons.schedule, Colors.orange.shade800),
      WebCertificateState.error => (
        Icons.error_outline,
        theme.colorScheme.error,
      ),
      _ => (Icons.hourglass_top, theme.colorScheme.primary),
    };
  }
}

/// 카드 제목 옆에 붙는 짧은 상태. 시험용 인증서는 브라우저가 믿지 않으니 "사용 중"이라고만 하지 않는다.
String webCertificateLabel(WebCertificateStatus s) {
  if (s.isOff) return tr('꺼짐');
  return switch (s.status) {
    WebCertificateState.pending => tr('발급 중'),
    WebCertificateState.valid => s.staging ? tr('시험용 인증서 사용 중') : tr('사용 중'),
    WebCertificateState.expiring => tr('곧 만료'),
    WebCertificateState.error => tr('발급 실패'),
    _ => tr('확인 중'),
  };
}

/// 카드 본문 줄들. "※"로 시작하는 줄은 덧붙이는 설명이라 흐리게 그린다. [now]는 시험용(지금 시각).
List<String> webCertificateLines(WebCertificateStatus s, {DateTime? now}) {
  if (s.isOff) {
    return [
      tr(
        '아이폰은 앱 대신 웹 앱(Safari)을 씁니다. 웹 앱을 쓰고 홈 화면에 추가해 알림을 받으려면 브라우저가 믿는 정식 인증서가 필요합니다.',
      ),
      tr(
        '켜는 방법: 서버 PC 시작 메뉴의 "웹 앱 주소(정식 인증서)"에서 도메인(예: xxx.iptime.org)을 넣으세요. 서버가 Let\'s Encrypt 인증서를 받아 자동으로 갱신합니다.',
      ),
      tr(
        '※ 인증서를 받으려면 공유기 포트포워딩에서 80번이나 443번 포트를 이 서버 PC로 넘겨야 합니다(둘 다 넘겨 두면 통신사가 한쪽을 막아도 받을 수 있습니다).',
      ),
      tr('※ PC·안드로이드 앱의 연결 방식은 바뀌지 않습니다.'),
    ];
  }
  final domain = s.domain ?? tr('(도메인 없음)');
  final lines = <String>[];
  switch (s.status) {
    case WebCertificateState.valid:
      final expiresAt = s.expiresAt;
      lines.add(
        expiresAt == null
            ? tr('{domain} · 만료 전에 자동 갱신합니다.', {'domain': domain})
            : tr('{domain} · {p0}까지 유효 · 만료 전에 자동 갱신합니다.', {
                'domain': domain,
                'p0': formatDateTime(expiresAt),
              }),
      );
      if (!s.staging) {
        lines.add(tr('※ 초대 링크를 복사하면 아이폰용 웹 앱 주소 안내가 함께 붙습니다.'));
      }
    case WebCertificateState.expiring:
      final expiresAt = s.expiresAt;
      lines.add(
        expiresAt == null
            ? tr('{domain} · 인증서가 곧 만료됩니다. 서버가 자동 갱신을 시도하고 있습니다.', {
                'domain': domain,
              })
            : tr('{domain} · {p0}에 만료됩니다. 서버가 자동 갱신을 시도하고 있습니다.', {
                'domain': domain,
                'p0': formatDateTime(expiresAt),
              }),
      );
      if (s.lastError != null) {
        lines.add(tr('마지막 갱신 실패: {s.lastError}', {'s.lastError': s.lastError}));
      }
    case WebCertificateState.error:
      lines.add(
        tr('{domain} 인증서를 받지 못했습니다: {p0}', {
          'domain': domain,
          'p0': s.lastError ?? tr('원인을 알 수 없습니다.'),
        }),
      );
      final expiresAt = s.expiresAt;
      if (expiresAt != null && expiresAt.isAfter(now ?? DateTime.now())) {
        lines.add(
          tr('지금 걸려 있는 인증서는 {p0}까지 쓸 수 있습니다.', {
            'p0': formatDateTime(expiresAt),
          }),
        );
      }
    default:
      lines.add(tr('{domain} 인증서를 받는 중입니다.', {'domain': domain}));
      if (s.lastError != null) {
        lines.add(tr('마지막 오류: {s.lastError}', {'s.lastError': s.lastError}));
      }
  }
  // 서버는 공인 인증서가 실제로 걸려 있을 때만 이 주소를 준다 — 시험용 인증서는 브라우저가 믿지 않으니 안내하지 않는다.
  final webUrl = s.webUrl;
  if (webUrl != null && !s.staging) {
    lines.add(tr('아이폰 사용자에게 알려 줄 주소: {webUrl}', {'webUrl': webUrl}));
    // 웹 앱은 초대 코드를 받을 곳이 없어서 사내 와이파이 밖에서는 가입이 거절된다(server auth.js) — 운영자가 아이폰 사용자에게
    // 밖에서도 바로 가입된다고 안내하지 않게(초대 안내 페이지·복사하는 초대 글에도 같은 주의가 붙는다).
    lines.add(
      tr(
        '※ 웹 앱은 초대 코드를 쓸 수 없어서 아이폰 사용자의 첫 가입은 사내 와이파이에서 해야 합니다(가입한 뒤의 로그인은 어디서든 됩니다).',
      ),
    );
  }
  if (s.status != WebCertificateState.valid) {
    final last = s.lastAttemptAt;
    final next = s.nextAttemptAt;
    if (last != null) {
      lines.add(tr('마지막 시도: {p0}', {'p0': formatDateTime(last)}));
    }
    if (next != null) {
      lines.add(tr('다음 시도: {p0} (자동)', {'p0': formatDateTime(next)}));
    }
  }
  final failed =
      s.status == WebCertificateState.error ||
      (s.status == WebCertificateState.expiring && s.lastError != null);
  if (failed) {
    lines.add(
      s.rateLimited
          ? tr(
              '※ iptime.org처럼 여러 사람이 함께 쓰는 DDNS 도메인은 Let\'s Encrypt 발급 한도(7일에 새 인증서 50개)를 그 도메인 사용자 전체가 나눠 써서, 처음 발급이 막힐 수 있습니다. 서버가 다음 시도 때 자동으로 다시 받습니다(한 번 받은 뒤의 갱신은 이 한도에 걸리지 않습니다).',
            )
          : tr(
              '※ 공유기 포트포워딩에서 80번·443번 포트를 이 서버 PC로 넘겼는지, 다른 프로그램(IIS 등)이 그 포트를 쓰고 있지 않은지 확인하세요.',
            ),
    );
  }
  if (s.staging) {
    lines.add(
      tr(
        '※ 시험용 인증서(Let\'s Encrypt 스테이징)입니다 — 포트포워딩 확인용이라 브라우저가 믿지 않습니다. 확인이 끝나면 시험용 설정(ACME_STAGING)을 끄고 서버를 다시 시작한 뒤 아이폰 사용자에게 안내하세요.',
      ),
    );
  }
  // 서버가 그 확인 방식의 포트를 이 PC에서 열어 받을 준비가 됐는지다(공유기 포트포워딩까지 확인한 것은 아니다).
  if (s.http01 != null || s.tlsAlpn01 != null) {
    String mark(bool? ready) => ready == null
        ? tr('알 수 없음')
        : ready
        ? tr('준비됨')
        : tr('준비 안 됨');
    lines.add(
      tr(
        '※ 인증서 확인 방식: HTTP-01(외부 80번 포트) {p0} · TLS-ALPN-01(외부 443번 포트) {p1}',
        {'p0': mark(s.http01), 'p1': mark(s.tlsAlpn01)},
      ),
    );
  }
  return lines;
}
