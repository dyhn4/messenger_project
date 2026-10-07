import 'package:flutter/material.dart';

import '../models/room.dart';
import '../services/secret_peer_store.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import 'app_toast.dart';
import 'room_options_menu.dart' show CloseWhenRoomRemoved;

/// 비밀 대화의 "보안 코드 확인" 창을 연다(더보기 메뉴·방 안내의 버튼).
Future<void> showSecretSafetyNumberDialog(
  BuildContext context,
  Session session,
  Room room,
) => showDialog<void>(
  context: context,
  builder: (_) => SecretSafetyNumberDialog(session: session, room: room),
);

/// "상대 기기 키 다시 받기" 확인 창 — 진행하면 이 기기에 고정해 둔 상대 기기의 키를 지우고, 그 키로 맺은 비밀 대화를
/// 모두 멈춘다(Session.resetSecretPeerKey). 같은 기기 id의 키가 영영 맞지 않는 상대(앱을 다시 설치함 등)와 다시
/// 대화할 길은 이것뿐이지만, 지우고 나면 다음 새 대화에서 서버가 알려 주는 키를 처음 보는 것처럼 믿게 되므로 상대에게
/// 직접 확인했을 때만 진행하게 하고, 새 대화에서 보안 코드를 꼭 비교하라고 알린다. [codeMismatch]면 보안 코드 창의
/// "코드가 다릅니다"에서 연 것이다(멈추지 않은 대화). 지웠으면 true.
Future<bool> confirmSecretPeerKeyReset(
  BuildContext context,
  Session session,
  Room room, {
  required bool codeMismatch,
}) async {
  final overlay = Overlay.of(context, rootOverlay: true);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final scheme = Theme.of(dialogContext).colorScheme;
      return AlertDialog(
        key: const ValueKey('secret-key-reset-confirm'),
        scrollable: true,
        title: Text(codeMismatch ? '보안 코드가 다릅니다' : '상대 기기 키 다시 받기'),
        content: SizedBox(
          width: 360,
          child: Text(
            codeMismatch
                ? '보안 코드가 다르면 서버(또는 중간의 누군가)가 이 대화를 가로채고 있을 수 있습니다.\n\n'
                      '이 기기에 고정해 둔 상대 기기의 키를 지우고, 이 상대 기기와의 비밀 대화를 모두 멈춥니다. '
                      '그다음 이 대화를 끝내고 새 비밀 대화를 시작해 보안 코드를 다시 비교해 주세요. '
                      '상대도 자기 화면에서 "코드가 다릅니다"를 눌러야 합니다.'
                : '이 기기에 고정해 둔 상대 기기의 키를 지웁니다. 다음 비밀 대화에서는 서버가 알려 주는 키를 새로 '
                      '믿게 되므로, 상대가 앱을 다시 설치하는 등으로 기기 키가 바뀐 것을 상대에게 직접(만나서·전화로) '
                      '확인한 경우에만 진행하세요.\n\n'
                      '이 상대 기기와의 다른 비밀 대화도 모두 멈춥니다. 진행한 뒤 이 대화를 끝내고 새 비밀 대화를 '
                      '시작해, 상대와 보안 코드를 꼭 비교해 주세요.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const ValueKey('secret-key-reset-confirm-button'),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(codeMismatch ? '대화 멈추고 키 지우기' : '키 지우기'),
          ),
        ],
      );
    },
  );
  if (confirmed != true) return false;
  try {
    final done = await session.resetSecretPeerKey(room.id);
    showAppToastOnOverlay(
      overlay,
      done
          ? '상대 기기 키를 지웠습니다. 이 대화를 끝내고 새 비밀 대화를 시작한 뒤 보안 코드를 비교해 주세요.'
          : '지울 상대 기기 키가 없습니다.',
    );
    return done;
  } catch (e) {
    showAppToastOnOverlay(overlay, '상대 기기 키를 지우지 못했습니다: $e');
    return false;
  }
}

/// 이 기기와 상대 기기의 보안 코드(60자리 — 5자리 12묶음을 4묶음씩 3줄)를 보여 주고, 상대와 비교해 같으면
/// "확인함"으로 표시하게 한다. 같은 두 기기면 양쪽 화면에 같은 숫자가 나온다(secret_chat_crypto.dart
/// computeSafetyNumber) — 서버가 처음부터 상대 기기 키를 바꿔치기했다면 숫자가 달라서 사람이 알아챈다. 다르면
/// "코드가 다릅니다"로 그 키를 지우고 대화를 멈춘다 — 이 대화만 끝내면 새 대화도 같은(틀린) 고정 키를 쓰기 때문이다.
class SecretSafetyNumberDialog extends StatefulWidget {
  final Session session;
  final Room room;
  const SecretSafetyNumberDialog({
    super.key,
    required this.session,
    required this.room,
  });

  @override
  State<SecretSafetyNumberDialog> createState() =>
      _SecretSafetyNumberDialogState();
}

class _SecretSafetyNumberDialogState extends State<SecretSafetyNumberDialog>
    with CloseWhenRoomRemoved<SecretSafetyNumberDialog> {
  late Future<SecretSafetyInfo?> _info = _load();
  bool _saving = false;

  @override
  Session get roomSession => widget.session;

  @override
  String get watchedRoomId => widget.room.id;

  Future<SecretSafetyInfo?> _load() async {
    try {
      // 멈춤·"다시 받기" 여부도 함께 새로 읽는다 — 아래 버튼들이 그 상태를 본다.
      await widget.session.loadSecretTrust(widget.room.id);
      return await widget.session.secretSafetyInfo(widget.room.id);
    } catch (_) {
      return null;
    }
  }

  Future<void> _setVerified(bool verified) async {
    setState(() => _saving = true);
    try {
      await widget.session.setSecretPeerVerified(widget.room.id, verified);
      if (!mounted) return;
      setState(() => _info = _load());
    } catch (e) {
      if (mounted) showAppToast(context, '저장하지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 상대 이름 — 방 멤버에서 찾고(바뀐 이름 반영), 없으면 방 이름.
  String _peerName(SecretSafetyInfo info) {
    for (final m in widget.room.members) {
      if (m.id == info.peerUserId) return m.name;
    }
    return widget.room.displayName(widget.session.userId ?? '');
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.shield_outlined, color: Colors.green),
          SizedBox(width: 8),
          Text('보안 코드 확인'),
        ],
      ),
      content: SizedBox(
        width: 380,
        child: FutureBuilder<SecretSafetyInfo?>(
          future: _info,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final info = snapshot.data;
            if (info == null) {
              return const Text(
                '아직 상대 기기를 확인하지 못했습니다. 상대가 비밀 대화를 수락한 뒤(또는 서버에 연결된 뒤) 다시 열어 주세요.',
                key: ValueKey('secret-safety-unavailable'),
              );
            }
            return _content(context, info);
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
      ],
    );
  }

  Widget _content(BuildContext context, SecretSafetyInfo info) {
    final theme = Theme.of(context);
    final trust = widget.session.secretTrustOf(widget.room.id);
    final blocked = trust?.blocked == true;
    final codeStyle = TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w600,
      letterSpacing: 1.5,
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Consolas', 'Menlo', 'Courier New'],
      color: theme.colorScheme.onSurface,
    );
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_peerName(info)} 님과의 보안 코드',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 12),
          Container(
            key: const ValueKey('secret-safety-number'),
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                for (final row in info.rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    // 좁은 화면(휴대폰 대화상자)에서도 넘치지 않게 묶음마다 같은 폭을 나눠 주고, 모자라면 글자를 줄인다.
                    child: Row(
                      children: [
                        for (final group in row)
                          Expanded(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(group, style: codeStyle),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '상대와 직접 만나거나 전화로 이 60자리 숫자를 비교해 보세요. 양쪽 화면의 숫자가 모두 같으면, '
            '서버를 포함해 그 누구도 이 대화를 몰래 볼 수 없습니다. '
            // 다르면 이 대화만 끝내서는 안 된다 — 새 대화도 같은(틀린) 고정 키를 쓴다. 키를 지우는 길로 안내한다.
            '${blocked ? '' : '하나라도 다르면 아래 "코드가 다릅니다"를 눌러 주세요.'}',
          ),
          if (blocked) ...[
            const SizedBox(height: 8),
            Text(
              '이 비밀 대화는 상대 기기의 보안 확인에 실패해 멈춰 있습니다. 대화방 위의 안내를 따라 주세요.',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ],
          const SizedBox(height: 16),
          if (info.myKeyChanged)
            Text(
              '이 대화를 시작한 뒤 이 기기의 보안 키가 바뀌어, 상대 화면의 코드와 맞지 않습니다. 이 비밀 대화를 끝내고 새로 시작해 주세요.',
              style: TextStyle(color: theme.colorScheme.error),
            )
          else if (info.verified)
            Row(
              key: const ValueKey('secret-safety-verified'),
              children: [
                const Icon(Icons.verified_user, color: Colors.green, size: 20),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '보안 코드 확인함 (${formatPostDateTime(info.verifiedAt!)})',
                    style: const TextStyle(
                      color: Colors.green,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _saving ? null : () => _setVerified(false),
                  child: const Text('확인 표시 지우기'),
                ),
              ],
            )
          else if (!blocked)
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                key: const ValueKey('secret-safety-mark-verified'),
                onPressed: _saving ? null : () => _setVerified(true),
                icon: const Icon(Icons.verified_user_outlined),
                label: const Text('비교했고 같습니다 — 확인함으로 표시'),
              ),
            ),
          // 이 기기의 키가 바뀐 경우는 다른 게 당연해서(상대 화면은 예전 키로 계산) 상대 키를 지우는 길을 내지 않는다.
          if (!blocked &&
              !info.myKeyChanged &&
              trust?.canResetPeerKey == true) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const ValueKey('secret-safety-code-mismatch'),
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                onPressed: _saving ? null : _reportMismatch,
                icon: const Icon(Icons.report_outlined, size: 18),
                label: const Text('코드가 다릅니다'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// "코드가 다릅니다" — 확인하면 상대 기기 키를 지우고 그 키로 맺은 대화를 멈춘 뒤 창을 닫는다(방 안내가 할 일을 알린다).
  Future<void> _reportMismatch() async {
    final done = await confirmSecretPeerKeyReset(
      context,
      widget.session,
      widget.room,
      codeMismatch: true,
    );
    if (done && mounted) Navigator.of(context).pop();
  }
}
