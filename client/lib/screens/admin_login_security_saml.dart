import 'package:flutter/material.dart';

import '../l10n/tr.dart';
import '../models/login_security.dart';
import '../services/session.dart';
import '../widgets/app_toast.dart';
import '../widgets/integration_widgets.dart';

/// 관리자 콘솔 "로그인 보안" 탭의 SAML 2.0 칸 — OIDC를 못 쓰는 IdP(ADFS·Okta·OneLogin·Keycloak 등)로 로그인
/// (server/src/saml.js·samlRules.js). 값을 고친 뒤 "SAML 설정 저장"으로 바꾼 값만 보내고, 저장된 값이 갖춰져야 켤 수 있다(빠지면
/// 서버가 거절한다 — Google·Microsoft와 같다). "IdP 메타데이터로 채우기"는 붙여 넣은 XML을 서버가 읽어 칸만 채운다(저장은 따로).
///
/// 저장·켜기는 탭의 [onPatch](PATCH /admin/login-security → 서버 값으로 탭 전체를 다시 채움)로 하고, 새 [saml]이 오면 칸을 그 값으로
/// 되돌린다(저장 안 한 다른 칸도 서버 값으로 — 탭의 다른 칸과 같은 동작).
class AdminSamlSection extends StatefulWidget {
  final Session session;
  final SamlSettings saml;

  /// 탭이 다른 저장을 하는 중인지 — 그동안은 단추를 막는다.
  final bool busy;
  final Future<void> Function(Map<String, dynamic> patch, String done) onPatch;

  const AdminSamlSection({
    super.key,
    required this.session,
    required this.saml,
    required this.busy,
    required this.onPatch,
  });

  @override
  State<AdminSamlSection> createState() => _AdminSamlSectionState();
}

class _AdminSamlSectionState extends State<AdminSamlSection> {
  final _label = TextEditingController();
  final _entryPoint = TextEditingController();
  final _issuer = TextEditingController();
  final _cert = TextEditingController();
  final _logoutUrl = TextEditingController();
  final _emailAttr = TextEditingController();
  final _nameAttr = TextEditingController();
  final _groupsAttr = TextEditingController();

  List<TextEditingController> get _all => [
    _label,
    _entryPoint,
    _issuer,
    _cert,
    _logoutUrl,
    _emailAttr,
    _nameAttr,
    _groupsAttr,
  ];

  @override
  void initState() {
    super.initState();
    _apply(widget.saml);
    for (final c in _all) {
      c.addListener(_refresh);
    }
  }

  @override
  void didUpdateWidget(covariant AdminSamlSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 서버에서 새 값이 왔다(불러오기·저장 성공) — 같은 객체면 탭이 다른 칸 때문에 다시 그린 것이라 그대로 둔다.
    if (!identical(oldWidget.saml, widget.saml)) _apply(widget.saml);
  }

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  void _refresh() => setState(() {});

  void _apply(SamlSettings s) {
    _label.text = s.label;
    _entryPoint.text = s.entryPoint;
    _issuer.text = s.idpIssuer;
    _cert.text = s.idpCert;
    _logoutUrl.text = s.logoutUrl;
    _emailAttr.text = s.emailAttr;
    _nameAttr.text = s.nameAttr;
    _groupsAttr.text = s.groupsAttr;
  }

  /// 저장된 값과 다른 칸만 — 서버 키 → 보낼 값(앞뒤 빈칸은 뺀다. 인증서는 서버가 PEM 모양을 다시 맞추므로 trim만 비교).
  Map<String, String> get _changes {
    final s = widget.saml;
    final out = <String, String>{};
    void diff(String key, TextEditingController c, String saved) {
      final v = c.text.trim();
      if (v != saved.trim()) out[key] = v;
    }

    diff('samlLabel', _label, s.label);
    diff('samlEntryPoint', _entryPoint, s.entryPoint);
    diff('samlIdpIssuer', _issuer, s.idpIssuer);
    diff('samlIdpCert', _cert, s.idpCert);
    diff('samlLogoutUrl', _logoutUrl, s.logoutUrl);
    diff('samlEmailAttr', _emailAttr, s.emailAttr);
    diff('samlNameAttr', _nameAttr, s.nameAttr);
    diff('samlGroupsAttr', _groupsAttr, s.groupsAttr);
    return out;
  }

  bool get _dirty => _changes.isNotEmpty;

  Future<void> _save() => widget.onPatch(_changes, tr('SAML 설정을 저장했습니다.'));

  /// 메타데이터 XML을 붙여 넣는 창 — 서버가 읽은 값으로 칸만 채운다(저장은 "SAML 설정 저장"으로).
  Future<void> _fillFromMetadata() async {
    final fill = await showDialog<SamlMetadataFill>(
      context: context,
      builder: (_) => _SamlMetadataDialog(session: widget.session),
    );
    if (fill == null || !mounted) return;
    setState(() {
      if (fill.idpIssuer != null) _issuer.text = fill.idpIssuer!;
      if (fill.entryPoint.isNotEmpty) _entryPoint.text = fill.entryPoint;
      if (fill.logoutUrl != null) _logoutUrl.text = fill.logoutUrl!;
      if (fill.idpCert.isNotEmpty) _cert.text = fill.idpCert;
    });
    showAppToast(context, tr('메타데이터의 값으로 채웠습니다. 확인하고 저장하세요.'));
  }

  Widget _field(
    TextEditingController c,
    String label, {
    String? hint,
    String? helper,
    int maxLines = 1,
    required Key key,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      key: key,
      controller: c,
      maxLines: maxLines,
      minLines: maxLines > 1 ? 3 : null,
      style: maxLines > 1
          ? const TextStyle(fontFamily: 'monospace', fontSize: 12)
          : null,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        helperMaxLines: 3,
        border: const OutlineInputBorder(),
        isDense: true,
        alignLabelWithHint: maxLines > 1,
      ),
    ),
  );

  /// "IdP에 넣을 값" 한 줄 — 이름과 복사 칸.
  Widget _spValue(String label, String value, String key) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 2),
        CopyableSecretField(value: value, fieldKey: ValueKey(key)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final s = widget.saml;
    final sp = s.sp;
    final busy = widget.busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('SAML 2.0 (OIDC를 못 쓰는 IdP — ADFS·Okta·OneLogin·Keycloak 등)'),
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                tr(
                  '회사의 IdP에 이 서버를 앱(SP)으로 등록하고 IdP의 로그인 주소·entityID·서명 인증서를 넣으면 로그인 화면에 단추가 생깁니다. 새 계정 만들기·등급·다시 확인 주기는 위 회사 계정 설정을 따릅니다.',
                ),
                style: theme.textTheme.bodySmall?.copyWith(color: hint),
              ),
            ],
          ),
        ),
        // ── IdP에 넣을 값(이 서버 — SP) ──
        Container(
          key: const ValueKey('saml-sp-info'),
          padding: const EdgeInsets.all(10),
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            border: Border.all(color: theme.dividerColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: sp == null
              ? Text(
                  tr(
                    '서버의 웹 앱 주소(정식 인증서 — WEB_DOMAIN)가 없어 SAML 로그인을 켤 수 없습니다. "DDNS" 탭의 웹 앱 주소를 먼저 설정하세요.',
                  ),
                  style: TextStyle(
                    color: theme.colorScheme.error,
                    fontSize: 12,
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(tr('IdP에 넣을 값'), style: theme.textTheme.labelLarge),
                    const SizedBox(height: 6),
                    _spValue(
                      'entityID(Audience)',
                      sp.entityId,
                      'saml-sp-entity-id',
                    ),
                    _spValue('ACS URL(POST)', sp.acsUrl, 'saml-sp-acs'),
                    _spValue('SLO URL', sp.sloUrl, 'saml-sp-slo'),
                    _spValue(
                      tr('메타데이터 URL'),
                      sp.metadataUrl,
                      'saml-sp-metadata',
                    ),
                    Text(
                      tr(
                        '메타데이터 URL을 받는 IdP는 그 주소 하나만 넣으면 됩니다. NameID는 persistent나 이메일 형식으로 보내게 하세요(transient는 받지 않습니다). 어설션(Assertion)에는 꼭 서명해야 합니다.',
                      ),
                      style: TextStyle(fontSize: 12, color: hint),
                    ),
                  ],
                ),
        ),
        SwitchListTile(
          key: const ValueKey('saml-enabled'),
          contentPadding: EdgeInsets.zero,
          title: Text(tr('SAML 회사 계정 로그인')),
          subtitle: _dirty
              ? Text(
                  tr('바꾼 값을 먼저 저장하세요.'),
                  style: TextStyle(fontSize: 12, color: hint),
                )
              : null,
          value: s.enabled,
          onChanged: busy || _dirty || sp == null
              ? null
              : (v) => widget.onPatch({
                  'samlEnabled': v,
                }, v ? tr('SAML 로그인을 켰습니다.') : tr('SAML 로그인을 껐습니다.')),
        ),
        if (!s.enabled && s.problem != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              s.problem!,
              key: const ValueKey('saml-problem'),
              style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const ValueKey('saml-metadata-fill'),
            icon: const Icon(Icons.download_outlined, size: 18),
            label: Text(tr('IdP 메타데이터로 채우기')),
            onPressed: busy ? null : _fillFromMetadata,
          ),
        ),
        const SizedBox(height: 10),
        _field(
          _label,
          tr('IdP 이름'),
          hint: tr('예: Okta'),
          helper: tr(
            '로그인 화면의 단추에 "{name} 로그인"으로 보입니다(40자까지 — 이름만 넣으세요). 비우면 "회사 계정(SAML)".',
            {'name': 'Okta'},
          ),
          key: const ValueKey('saml-label'),
        ),
        _field(
          _entryPoint,
          tr('IdP 로그인 주소(SSO URL)'),
          hint: 'https://idp.company.com/sso/saml',
          key: const ValueKey('saml-entry-point'),
        ),
        _field(
          _issuer,
          tr('IdP entityID(발급자)'),
          hint: 'http://www.okta.com/exk…',
          key: const ValueKey('saml-idp-issuer'),
        ),
        _field(
          _cert,
          tr('IdP 서명 인증서(PEM)'),
          hint: '-----BEGIN CERTIFICATE-----\n…\n-----END CERTIFICATE-----',
          helper: tr('인증서를 바꾸는 중이면 둘을 이어 붙여 넣어도 됩니다.'),
          maxLines: 6,
          key: const ValueKey('saml-idp-cert'),
        ),
        _field(
          _logoutUrl,
          tr('IdP 로그아웃 주소(SLO, 선택)'),
          hint: 'https://idp.company.com/slo/saml',
          key: const ValueKey('saml-logout-url'),
        ),
        Text(tr('속성 이름'), style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: _field(
                _emailAttr,
                tr('이메일'),
                key: const ValueKey('saml-email-attr'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _field(
                _nameAttr,
                tr('이름'),
                key: const ValueKey('saml-name-attr'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _field(
                _groupsAttr,
                tr('그룹'),
                key: const ValueKey('saml-groups-attr'),
              ),
            ),
          ],
        ),
        Text(
          tr(
            'IdP가 보내는 속성(Attribute) 이름입니다. 이메일 속성이 없으면 이메일 모양의 NameID를 씁니다. 그룹은 아래 "디렉터리 그룹 규칙"에 씁니다.',
          ),
          style: TextStyle(fontSize: 12, color: hint),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            key: const ValueKey('saml-save'),
            onPressed: busy || !_dirty ? null : _save,
            child: Text(tr('SAML 설정 저장')),
          ),
        ),
      ],
    );
  }
}

/// IdP 메타데이터 XML 붙여 넣기 창 — 서버가 읽어(POST /admin/login-security/saml-metadata) 채울 값을 돌려준다. 못 읽으면 창 안에 까닭.
class _SamlMetadataDialog extends StatefulWidget {
  final Session session;
  const _SamlMetadataDialog({required this.session});

  @override
  State<_SamlMetadataDialog> createState() => _SamlMetadataDialogState();
}

class _SamlMetadataDialogState extends State<_SamlMetadataDialog> {
  final _xml = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _xml.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final fill = await widget.session.api!.parseSamlMetadata(_xml.text);
      if (mounted) Navigator.of(context).pop(fill);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(tr('IdP 메타데이터로 채우기')),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr(
                'IdP에서 받은 메타데이터 XML(<EntityDescriptor …>) 전체를 붙여 넣으세요. 로그인·로그아웃 주소, entityID, 서명 인증서를 채웁니다(저장은 따로 합니다).',
              ),
              style: TextStyle(fontSize: 12, color: theme.hintColor),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('saml-metadata-xml'),
              controller: _xml,
              minLines: 8,
              maxLines: 14,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '<?xml version="1.0"?>\n<EntityDescriptor …>',
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('saml-metadata-read'),
          onPressed: _busy || _xml.text.trim().isEmpty ? null : _read,
          child: Text(tr('읽어서 채우기')),
        ),
      ],
    );
  }
}
