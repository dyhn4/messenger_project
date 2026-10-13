import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/invite_share.dart';
import 'app_toast.dart';

/// 초대 링크(설치 초대·팀 초대 공용) 하나의 내용 — 초대 링크 창의 목록 자리에 대신 보인다(InviteLinkScreen,
/// TeamInviteLinkScreen). "사내 와이파이에서"·"사내 와이파이 밖(LTE/5G)에서" 주소를 따로 복사할 수 있게 해서, 목록의
/// "링크 복사"(두 주소와 주의 문구를 한 번에 — inviteShareText) 대신 필요한 주소 하나만 보낼 수 있다.
///
/// 취소·만료된 링크([isOpen]이 false)는 주소를 보여주기만 하고 복사 버튼은 두지 않는다 — 그 링크로는 더 이상 설치·연결도
/// 안 된다. 인원이 다 찬 링크([isFull])는 이미 가입한 사람이 다른 기기를 연결하는 데 아직 쓰이므로(server/src/pairing.js)
/// 복사는 두되 새로 가입할 수는 없다고 알린다.
class InviteLinkDetail extends StatelessWidget {
  final String title;

  /// 제목 아래 회색 글줄들(상태·가입 인원·만든 사람·만료 시각 등).
  final List<String> infoLines;
  final String? url;
  final String? externalUrl;
  final bool isOpen;
  final bool isFull;
  final VoidCallback onBack;

  const InviteLinkDetail({
    super.key,
    required this.title,
    required this.infoLines,
    required this.url,
    required this.externalUrl,
    required this.isOpen,
    required this.isFull,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('목록'),
          ),
          const SizedBox(height: 4),
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          for (final line in infoLines)
            Text(line, style: theme.textTheme.bodySmall?.copyWith(color: hint)),
          if (!isOpen)
            _Notice(text: '취소되었거나 만료된 링크라 이 주소로는 더 이상 설치·연결할 수 없습니다.')
          else if (isFull)
            _Notice(
              text:
                  '가입 인원이 다 찼습니다. 사내 와이파이 밖에서는 이 링크로 새로 가입할 수 없고, '
                  '이미 가입한 사람이 다른 기기를 연결하는 데만 쓸 수 있습니다.',
            ),
          const SizedBox(height: 16),
          _AddressField(
            label: '사내 와이파이에서',
            address: url,
            missingText: '주소를 알 수 없습니다.',
            copyTooltip: '사내 와이파이 주소 복사',
            copiedMessage: '사내 와이파이 주소를 복사했습니다.',
            canCopy: isOpen,
          ),
          const SizedBox(height: 16),
          _AddressField(
            label: '사내 와이파이 밖(LTE/5G)에서',
            address: externalUrl,
            missingText: '서버에 외부 접속 주소가 설정되어 있지 않아 밖에서 열 주소가 없습니다.',
            copyTooltip: '외부 주소 복사',
            copiedMessage: '사내 와이파이 밖(LTE/5G) 주소를 복사했습니다.',
            canCopy: isOpen,
          ),
          if (externalUrl != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                kPublicWifiCaution,
                style: theme.textTheme.bodySmall?.copyWith(color: hint),
              ),
            ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  final String text;
  const _Notice({required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
      ),
    );
  }
}

class _AddressField extends StatelessWidget {
  final String label;
  final String? address;
  final String missingText;
  final String copyTooltip;
  final String copiedMessage;
  final bool canCopy;

  const _AddressField({
    required this.label,
    required this.address,
    required this.missingText,
    required this.copyTooltip,
    required this.copiedMessage,
    required this.canCopy,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final address = this.address;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        if (address == null)
          Text(
            missingText,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          )
        else
          Container(
            padding: const EdgeInsets.only(left: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: SelectableText(
                      address,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: canCopy ? null : theme.hintColor,
                      ),
                    ),
                  ),
                ),
                if (canCopy)
                  IconButton(
                    tooltip: copyTooltip,
                    icon: const Icon(Icons.copy_outlined, size: 20),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: address));
                      if (context.mounted) showAppToast(context, copiedMessage);
                    },
                  )
                else
                  const SizedBox(width: 12),
              ],
            ),
          ),
      ],
    );
  }
}
