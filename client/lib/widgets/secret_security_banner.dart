import 'package:flutter/material.dart';

import '../models/room.dart';
import '../services/secret_peer_store.dart';
import '../services/session.dart';
import 'room_options_menu.dart' show showLeaveRoomDialog;
import 'secret_safety_number_dialog.dart';

/// 비밀 대화방 맨 위의 보안 안내 한 줄(필요할 때만) — 위에서부터 하나만 보인다:
///  1. 멈춤(빨강): 상대 기기의 보안 확인에 실패해 이 대화를 멈췄다(서버가 가로채려 했을 수 있다). 되돌리는 방법은
///     없고, 끝내고 새로 시작한 뒤 보안 코드를 비교해야 한다 — "비밀 대화 끝내기"로 바로 나가기 창을 연다. 이 기기에
///     고정해 둔 키로 확인이 안 돼 멈췄으면 "상대 기기 키 다시 받기"(확인 창을 거쳐 그 키를 지운다)도 보인다.
///  2. 상대 기기 바뀜(노랑): 예전에 보안 코드를 확인한 기기가 아닌 다른 기기와 맺어졌다 — 보안 코드를 다시 비교하게.
///  3. 예전 앱(회색): 상대가 맥락 서명(v2)을 보내지 않는 예전 앱이라 보안 확인이 일부만 된다 — 업데이트를 권한다.
/// 상태는 SecretSessionManager가 이 기기에 저장해 둔 값이다(Session.secretTrustOf) — 방을 열 때 읽어 온다.
class SecretSecurityBanner extends StatefulWidget {
  final Session session;
  final Room room;
  const SecretSecurityBanner({
    super.key,
    required this.session,
    required this.room,
  });

  @override
  State<SecretSecurityBanner> createState() => _SecretSecurityBannerState();
}

class _SecretSecurityBannerState extends State<SecretSecurityBanner> {
  @override
  void initState() {
    super.initState();
    widget.session.loadSecretTrust(widget.room.id);
  }

  @override
  void didUpdateWidget(SecretSecurityBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.room.id != widget.room.id) {
      widget.session.loadSecretTrust(widget.room.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final trust = widget.session.secretTrustOf(widget.room.id);
        if (trust == null) return const SizedBox.shrink();
        if (trust.blocked) return _blocked(context, trust);
        if (trust.showDeviceChangedNotice) return _deviceChanged(context);
        if (trust.showLegacyNotice) return _legacy(context);
        return const SizedBox.shrink();
      },
    );
  }

  Widget _bar(
    BuildContext context, {
    required Key key,
    required Color background,
    required Color foreground,
    required IconData icon,
    required List<Widget> body,
    List<Widget> actions = const [],
    VoidCallback? onClose,
  }) {
    final theme = Theme.of(context);
    return Material(
      key: key,
      color: background,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: theme.dividerColor)),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, 8, onClose == null ? 12 : 2, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(icon, size: 18, color: foreground),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DefaultTextStyle.merge(
                  style: TextStyle(fontSize: 13, color: foreground),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ...body,
                      if (actions.isNotEmpty)
                        Wrap(spacing: 4, children: actions),
                    ],
                  ),
                ),
              ),
              if (onClose != null)
                IconButton(
                  tooltip: '닫기',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  color: foreground,
                  onPressed: onClose,
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _blocked(BuildContext context, SecretRoomTrust trust) {
    final scheme = Theme.of(context).colorScheme;
    final fg = scheme.onErrorContainer;
    final reason = trust.security.blockedReason;
    final buttonStyle = TextButton.styleFrom(
      foregroundColor: fg,
      visualDensity: VisualDensity.compact,
    );
    return _bar(
      context,
      key: const ValueKey('secret-security-blocked'),
      background: scheme.errorContainer,
      foreground: fg,
      icon: Icons.gpp_bad_outlined,
      body: [
        const Text(
          '상대 기기의 보안 확인에 실패해 이 비밀 대화를 멈췄습니다.',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 2),
        const Text(
          '서버(또는 중간의 누군가)가 이 대화를 가로채려 했을 수 있어 메시지를 더 주고받지 않습니다. '
          '이 비밀 대화를 끝내고 새로 시작한 뒤, 상대와 직접 만나거나 전화로 "보안 코드"를 비교해 주세요.',
        ),
        // 이 기기에 고정해 둔 키로 확인이 안 돼 멈춘 경우 — 같은 상대 기기와 새로 시작해도 같은 키로 다시 멈춘다.
        // 상대가 앱을 다시 설치하는 등으로 같은 기기 id의 키가 바뀌었다면, 그 키를 지우는 것 말고는 다시 대화할
        // 길이 없다(버튼은 확인 창을 거친다).
        if (trust.canResetPeerKey) ...[
          const SizedBox(height: 2),
          const Text(
            '같은 상대 기기와 새로 시작해도 다시 멈춘다면, 상대가 앱을 다시 설치하는 등으로 기기 키가 바뀌었는지 상대에게 '
            '직접 확인한 뒤 "상대 기기 키 다시 받기"를 눌러 주세요.',
          ),
        ] else if (trust.peerKeyAlreadyReset) ...[
          const SizedBox(height: 2),
          const Text(
            '이 상대 기기의 키는 다시 받기로 했습니다. 이 대화를 끝내고 새 비밀 대화를 시작한 뒤 보안 코드를 꼭 비교해 주세요.',
            key: ValueKey('secret-security-key-reset-done'),
          ),
        ],
        if (reason != null) ...[
          const SizedBox(height: 2),
          Text(
            '원인: ${reason.description}',
            style: TextStyle(fontSize: 12, color: fg.withValues(alpha: 0.8)),
          ),
        ],
      ],
      actions: [
        TextButton(
          style: buttonStyle,
          onPressed: () =>
              showLeaveRoomDialog(context, widget.session, widget.room),
          child: const Text('비밀 대화 끝내기'),
        ),
        if (trust.canResetPeerKey)
          TextButton(
            key: const ValueKey('secret-security-reset-key'),
            style: buttonStyle,
            onPressed: () => confirmSecretPeerKeyReset(
              context,
              widget.session,
              widget.room,
              codeMismatch: false,
            ),
            child: const Text('상대 기기 키 다시 받기'),
          ),
      ],
    );
  }

  Widget _deviceChanged(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fg = dark ? Colors.amber.shade200 : Colors.brown.shade800;
    return _bar(
      context,
      key: const ValueKey('secret-security-device-changed'),
      background: dark ? const Color(0xFF3A3000) : Colors.amber.shade50,
      foreground: fg,
      icon: Icons.phonelink_lock_outlined,
      body: const [
        Text('상대의 기기가 바뀌었습니다. 예전에 확인한 보안 코드와 달라졌으니, 상대와 보안 코드를 다시 비교해 주세요.'),
      ],
      actions: [
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: fg,
            visualDensity: VisualDensity.compact,
          ),
          onPressed: () => showSecretSafetyNumberDialog(
            context,
            widget.session,
            widget.room,
          ),
          child: const Text('보안 코드 확인'),
        ),
      ],
      onClose: () =>
          widget.session.dismissSecretDeviceChangedNotice(widget.room.id),
    );
  }

  Widget _legacy(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _bar(
      context,
      key: const ValueKey('secret-security-legacy'),
      background: scheme.surfaceContainerHighest,
      foreground: scheme.onSurfaceVariant,
      icon: Icons.info_outline,
      body: const [
        Text(
          '상대가 예전 버전의 앱을 쓰고 있어 이 대화의 보안 확인이 일부만 이뤄집니다. 상대에게 앱을 업데이트해 달라고 알려 주세요.',
        ),
      ],
      onClose: () => widget.session.dismissSecretLegacyNotice(widget.room.id),
    );
  }
}
