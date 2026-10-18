import 'package:flutter/material.dart';

import '../l10n/tr.dart';
import '../models/login_security.dart';
import '../services/session.dart';

/// 관리자 콘솔 "로그인 보안" 탭의 사내 디렉터리(LDAP) 칸 아래 "조직도 맞추기" — 디렉터리의 부서·상위자(manager)를 조직도에 맞춘다
/// (server/src/orgDirectorySync.js). 부서는 'attribute'(위 "부서 속성"의 글자를 맨 위 부서로 — 예전 방식) | 'ou'(그 사람 DN의 OU
/// 경로를 부서 트리로 — "시작 위치" 아래부터) | 'off'(맞추지 않음) 중 하나, 상위자는 켜면 [LdapSettings.managerAttr] 속성(AD는
/// manager — 상위자의 DN)으로 맞춘다.
///
/// 계정 단위 조직도일 때만 쓴다([LdapSettings.orgSyncAvailable] — 팀마다 조직도를 두면 누구의 부서를 바꿀지 몰라 서버가 거절한다).
/// 그때는 안내를 보이고 칸을 모두 막는다.
///
/// 저장은 탭의 [onPatch](PATCH /admin/login-security → 서버 값으로 탭 전체를 다시 채움)로 바꾼 칸만 보내고, 새 [ldap]이 오면 칸을
/// 그 값으로 되돌린다(SAML 칸과 같은 동작). "지금 디렉터리와 맞추기"는 확인 창을 거쳐 POST /admin/login-security/ldap-org-sync를
/// 부르고 결과(몇 명을 읽어 몇 명을 옮겼는지)나 서버가 준 까닭을 단추 아래에 남긴다("연결 시험" 결과와 같은 모양).
class AdminLdapOrgSyncSection extends StatefulWidget {
  final Session session;
  final LdapSettings ldap;

  /// 탭이 다른 저장을 하는 중인지 — 그동안은 단추를 막는다.
  final bool busy;
  final Future<void> Function(Map<String, dynamic> patch, String done) onPatch;

  const AdminLdapOrgSyncSection({
    super.key,
    required this.session,
    required this.ldap,
    required this.busy,
    required this.onPatch,
  });

  @override
  State<AdminLdapOrgSyncSection> createState() =>
      _AdminLdapOrgSyncSectionState();
}

/// 속성 이름 모양 — 서버 loginSecurityRules.js와 같다(영문으로 시작, 영문·숫자·-).
final _attrName = RegExp(r'^[A-Za-z][A-Za-z0-9-]*$');

/// OU 방식 설명에 보일 보기 DN(사람 하나) — 번역할 글이 아니라 값으로 끼운다.
const _sampleDn = 'CN=김철수,OU=1팀,OU=영업본부,OU=Users,DC=company,DC=local';

class _AdminLdapOrgSyncSectionState extends State<AdminLdapOrgSyncSection> {
  final _orgBaseDn = TextEditingController();
  final _managerAttr = TextEditingController();
  String _orgSource = 'attribute';
  bool _managerSync = false;

  // "지금 맞추기" — 도는 중인지, 마지막 결과(성공이면 숫자, 실패면 서버가 준 까닭).
  bool _syncing = false;
  String? _syncMessage;
  bool? _syncOk;

  @override
  void initState() {
    super.initState();
    _apply(widget.ldap);
    _orgBaseDn.addListener(_refresh);
    _managerAttr.addListener(_refresh);
  }

  @override
  void didUpdateWidget(covariant AdminLdapOrgSyncSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 서버에서 새 값이 왔다(불러오기·저장 성공·연결 시험) — 같은 객체면 탭이 다른 칸 때문에 다시 그린 것이라 그대로 둔다.
    if (!identical(oldWidget.ldap, widget.ldap)) _apply(widget.ldap);
  }

  @override
  void dispose() {
    _orgBaseDn.dispose();
    _managerAttr.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  void _apply(LdapSettings l) {
    _orgSource = _savedSource(l);
    _orgBaseDn.text = l.orgBaseDn;
    _managerSync = l.managerSync;
    _managerAttr.text = l.managerAttr;
  }

  /// 저장된 부서 방식 — 모르는 값(새 서버)이면 드롭다운이 깨지지 않게 예전 방식으로 본다(바꾼 것으로 치지 않도록 비교도 이 값으로).
  static String _savedSource(LdapSettings l) =>
      const ['attribute', 'ou', 'off'].contains(l.orgSource)
      ? l.orgSource
      : 'attribute';

  bool get _attrValid => _attrName.hasMatch(_managerAttr.text.trim());

  /// 저장된 값과 다른 칸만 — 서버 키 → 보낼 값(글은 앞뒤 빈칸을 뺀다. 시작 위치를 비우면 서버가 "모든 OU"(null)로 저장한다).
  Map<String, dynamic> get _changes {
    final l = widget.ldap;
    return {
      if (_orgSource != _savedSource(l)) 'ldapOrgSource': _orgSource,
      if (_orgBaseDn.text.trim() != l.orgBaseDn.trim())
        'ldapOrgBaseDn': _orgBaseDn.text.trim(),
      if (_managerSync != l.managerSync) 'ldapManagerSync': _managerSync,
      if (_managerAttr.text.trim() != l.managerAttr.trim())
        'ldapManagerAttr': _managerAttr.text.trim(),
    };
  }

  bool get _dirty => _changes.isNotEmpty;

  Future<void> _save() => widget.onPatch(_changes, tr('조직도 맞추기 설정을 저장했습니다.'));

  /// 지금 맞출 것이 있는지 — 저장된 값 기준(OU 경로로 부서를 맞추거나 상위자 맞추기가 켜져 있어야 한다. 부서 속성 글자 방식은 로그인할
  /// 때 그 사람 것만 바꾸므로 한꺼번에 맞출 것이 없다).
  bool get _hasWork => widget.ldap.orgSource == 'ou' || widget.ldap.managerSync;

  /// 확인 창 → POST /admin/login-security/ldap-org-sync → 결과를 단추 아래에.
  Future<void> _syncNow() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('지금 디렉터리와 맞출까요?')),
        content: Text(
          tr(
            '사내 디렉터리의 모든 사람을 읽어, TangoTalk 계정이 있는 사람의 부서·상위자를 디렉터리대로 바꿉니다. 계정이 없는 사람은 만들지 않습니다. 사람이 많으면 조금 걸립니다.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('취소')),
          ),
          FilledButton(
            key: const ValueKey('ldap-org-sync-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('맞추기')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _syncing = true;
      _syncMessage = null;
    });
    try {
      final r = await widget.session.api!.syncDirectoryOrg();
      if (!mounted) return;
      setState(() {
        _syncOk = true;
        _syncMessage = tr(
          '디렉터리 {scanned}명 중 계정 {linked}명 — 부서 옮김 {moved}명, 상위자 {managersSet}명, 새 부서 {departmentsCreated}개',
          {
            'scanned': r.scanned,
            'linked': r.linked,
            'moved': r.moved,
            'managersSet': r.managersSet,
            'departmentsCreated': r.departmentsCreated,
          },
        );
      });
    } catch (e) {
      // 서버의 까닭(예: "사내 디렉터리 로그인을 먼저 켜세요.")을 그대로 보인다 — ApiException.toString이 번역까지 한다.
      if (mounted) {
        setState(() {
          _syncOk = false;
          _syncMessage = e.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  /// 고른 부서 방식의 설명 한 줄.
  String _sourceHelp() => switch (_orgSource) {
    'ou' => tr(
      'OU 경로 방식은 {dn} 같은 사람을 시작 위치 아래의 "영업본부 > 1팀" 부서에 넣습니다. 없는 부서는 만듭니다.',
      {'dn': _sampleDn},
    ),
    'off' => tr('디렉터리로 부서를 바꾸지 않습니다. 부서는 조직도에서 직접 정합니다.'),
    _ => tr('위 "부서 속성"의 글자를 맨 위 부서로 씁니다(예전 방식 — 로그인할 때 맞춤).'),
  };

  /// "지금 맞추기" 옆 안내 — 못 누르는 까닭이 있으면 그것을, 없으면 저절로 맞추는 때를.
  String _syncHint() {
    final l = widget.ldap;
    if (!l.enabled) return tr('디렉터리 로그인을 켜야 맞출 수 있습니다.');
    if (_dirty) return tr('바꾼 값을 먼저 저장하세요.');
    if (!_hasWork) {
      return tr('OU 경로로 부서를 맞추거나 상위자 맞추기를 켜야 맞출 것이 있습니다.');
    }
    return tr('기다리지 않고 디렉터리의 모든 사람을 지금 한 번에 맞춥니다.');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final l = widget.ldap;
    final busy = widget.busy || _syncing;
    final available = l.orgSyncAvailable;
    final attrError = available && _managerSync && !_attrValid
        ? tr('속성 이름은 영문·숫자(예: displayName)로 넣으세요.')
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('조직도 맞추기'), style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                tr(
                  '사내 디렉터리의 부서(OU)와 상위자(manager)를 조직도에 그대로 옮깁니다. 디렉터리로 로그인할 때마다, 그리고 10분마다 저절로 맞춥니다.',
                ),
                style: theme.textTheme.bodySmall?.copyWith(color: hint),
              ),
            ],
          ),
        ),
        if (!available)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              tr(
                '조직도 맞추기는 부서·직책 관리 범위가 "계정 단위"일 때만 쓸 수 있습니다. 지금은 팀마다 조직도를 따로 두고 있습니다.',
              ),
              key: const ValueKey('ldap-org-unavailable'),
              style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
            ),
          ),
        Row(
          children: [
            Text(tr('부서 맞추기: ')),
            Expanded(
              child: DropdownButton<String>(
                key: const ValueKey('ldap-org-source'),
                isExpanded: true,
                value: _orgSource,
                items: [
                  DropdownMenuItem(
                    value: 'attribute',
                    child: Text(tr('부서 속성 글자(맨 위 부서로)')),
                  ),
                  DropdownMenuItem(
                    value: 'ou',
                    child: Text(tr('OU 경로를 부서 트리로')),
                  ),
                  DropdownMenuItem(value: 'off', child: Text(tr('맞추지 않음'))),
                ],
                onChanged: busy || !available
                    ? null
                    : (v) => setState(() => _orgSource = v ?? _orgSource),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            _sourceHelp(),
            style: TextStyle(fontSize: 12, color: hint),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: TextField(
            key: const ValueKey('ldap-org-base-dn'),
            controller: _orgBaseDn,
            // OU 방식에서만 쓰는 값 — 다른 방식이면 저장된 값은 그대로 두고 막아만 둔다.
            enabled: available && _orgSource == 'ou',
            decoration: InputDecoration(
              labelText: tr('부서 트리의 시작 위치'),
              hintText: 'OU=Users,DC=company,DC=local',
              helperText: tr('이 OU 바로 아래의 OU부터 부서가 됩니다. 비우면 모든 OU를 씁니다.'),
              helperMaxLines: 3,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        SwitchListTile(
          key: const ValueKey('ldap-manager-sync'),
          contentPadding: EdgeInsets.zero,
          title: Text(tr('상위자를 디렉터리의 manager 속성으로')),
          subtitle: Text(
            tr(
              'TangoTalk 계정이 있는 사람(디렉터리로 한 번이라도 로그인한 사람)만 상위자로 정할 수 있습니다. 서로가 서로의 상위자가 되는 경우는 건너뛰고, 디렉터리에 상위자가 비어 있으면 그대로 둡니다.',
            ),
            style: TextStyle(fontSize: 12, color: hint),
          ),
          value: _managerSync,
          onChanged: busy || !available
              ? null
              : (v) => setState(() => _managerSync = v),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: TextField(
            key: const ValueKey('ldap-manager-attr'),
            controller: _managerAttr,
            enabled: available && _managerSync,
            decoration: InputDecoration(
              labelText: tr('상위자 속성'),
              hintText: 'manager',
              helperText: tr('상위자의 DN이 든 속성입니다(Active Directory는 manager).'),
              helperMaxLines: 3,
              errorText: attrError,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            key: const ValueKey('ldap-org-save'),
            onPressed: busy || !available || !_dirty || attrError != null
                ? null
                : _save,
            child: Text(tr('조직도 맞추기 저장')),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton.icon(
              key: const ValueKey('ldap-org-sync-now'),
              icon: const Icon(Icons.sync, size: 18),
              label: Text(tr('지금 디렉터리와 맞추기')),
              onPressed: busy || !available || !l.enabled || !_hasWork || _dirty
                  ? null
                  : _syncNow,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _syncing
                  ? const Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : Text(
                      _syncHint(),
                      style: TextStyle(fontSize: 12, color: hint),
                    ),
            ),
          ],
        ),
        if (_syncMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _syncMessage!,
              key: const ValueKey('ldap-org-sync-result'),
              style: TextStyle(
                color: _syncOk == true ? Colors.green : theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}
