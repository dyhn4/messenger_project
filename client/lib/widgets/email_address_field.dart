import 'package:flutter/material.dart';
import '../l10n/tr.dart';

final emailDomainCustomOption = tr('직접 입력');
final emailDomainPresets = [
  'naver.com',
  'gmail.com',
  'daum.net',
  'nate.com',
  'kakao.com',
  emailDomainCustomOption,
];

/// 회원가입 폼과 같은 이메일 입력 형식(로컬 파트 + '@' + 프리셋 도메인 드롭다운/직접
/// 입력) — 아이디 찾기/비밀번호 찾기에서도 같은 모양을 쓰기 위해 공용으로 뺐다. 완성된
/// 이메일 문자열은 바뀔 때마다 [onChanged]로 전달된다.
class EmailAddressField extends StatefulWidget {
  final ValueChanged<String> onChanged;
  const EmailAddressField({super.key, required this.onChanged});

  @override
  State<EmailAddressField> createState() => _EmailAddressFieldState();
}

class _EmailAddressFieldState extends State<EmailAddressField> {
  final _local = TextEditingController();
  final _domainCustom = TextEditingController();
  String _domainChoice = emailDomainPresets.first;

  @override
  void initState() {
    super.initState();
    _local.addListener(_notify);
    _domainCustom.addListener(_notify);
  }

  void _notify() {
    final domain = _domainChoice == emailDomainCustomOption
        ? _domainCustom.text.trim()
        : _domainChoice;
    widget.onChanged('${_local.text.trim()}@$domain');
  }

  @override
  void dispose() {
    _local.dispose();
    _domainCustom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: _local,
            decoration: InputDecoration(
              hintText: tr('이메일 주소'),
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.emailAddress,
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 14, left: 8, right: 8),
          child: Text('@', style: TextStyle(fontSize: 16)),
        ),
        Expanded(
          child: _domainChoice == emailDomainCustomOption
              ? TextField(
                  controller: _domainCustom,
                  decoration: InputDecoration(
                    hintText: tr('도메인 입력'),
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.emailAddress,
                )
              : DropdownButtonFormField<String>(
                  initialValue: _domainChoice,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                  ),
                  items: emailDomainPresets
                      .map(
                        (d) => DropdownMenuItem(
                          value: d,
                          child: Text(d, overflow: TextOverflow.ellipsis),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    setState(() => _domainChoice = v!);
                    _notify();
                  },
                ),
        ),
      ],
    );
  }
}
