import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/room.dart';
import '../services/api_client.dart' show ApiException;
import '../services/session.dart';
import '../widgets/room_avatar.dart' show SelfRoomAvatar;
import 'invite_members_screen.dart';
import '../l10n/tr.dart';

/// "채팅 시작하기" — 멤버 초대하기와 같은 모양(멤버 검색·직책·검색 조건 초기화, 왼쪽 팀 멤버, 오른쪽
/// 선택된 멤버)에서 대화할 사람을 고른다. 1명이면 1:1 채팅, 2명 이상이면 그룹채팅(이름·아이콘은
/// 기본값)을 만들고, 1명일 때는 비밀 대화도 시작할 수 있다. 목록 맨 위의 "나와의 대화"는 고르지
/// 않고 누르면 바로 연다. 만들거나 연 방을 돌려주며 닫힌다 — 여는 건 부른 쪽(start_chat_dialog.dart)이
/// 한다. 준회원은 대화를 시작할 수 없어서(서버도 막는다) 나와의 대화만 열 수 있다.
class NewChatScreen extends StatefulWidget {
  final Session session;
  final bool asDialog;
  const NewChatScreen({
    super.key,
    required this.session,
    this.asDialog = false,
  });

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

/// 지금 보내고 있는 요청 — 그동안은 다른 버튼과 닫기를 막는다.
enum _Busy { self, chat, secret }

class _NewChatScreenState extends State<NewChatScreen> {
  _Busy? _busy;
  String? _error;

  Session get _session => widget.session;

  /// 방을 만들거나 받아 오는 요청을 보내고, 되면 그 방을 돌려주며 닫는다. 실패하면 버튼 줄 옆에
  /// 이유를 보여준다(서버가 준 안내는 그대로).
  Future<void> _run(
    _Busy kind,
    Future<Room> Function() request,
    String failure,
  ) async {
    if (_busy != null) return;
    setState(() {
      _busy = kind;
      _error = null;
    });
    try {
      final room = await request();
      if (!mounted) return;
      // 닫히는 동안에도 버튼은 잠가 둔다(새로운 토픽 생성하기와 같다).
      Navigator.of(context).pop(room);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = null;
        _error = e is ApiException ? trServer(e.message) : failure;
      });
    }
  }

  void _openSelf() => _run(
    _Busy.self,
    () => _session.openSelfChat(),
    tr('나와의 대화를 열지 못했습니다. 잠시 후 다시 시도하세요.'),
  );

  /// 1명이면 1:1 채팅(이미 있으면 그 방), 2명 이상이면 이름 없는 그룹채팅 — 이름은 멤버 이름으로
  /// 보이고, 아이콘은 멤버 사진이다(바꾸려면 채팅 정보 변경).
  void _start(List<AppUser> selected) => _run(
    _Busy.chat,
    () => selected.length == 1
        ? _session.startDm(selected.single.id)
        : _session.createGroup(memberIds: [for (final u in selected) u.id]),
    tr('채팅을 시작하지 못했습니다. 잠시 후 다시 시도하세요.'),
  );

  /// 비밀 대화는 1:1 전용 — member_profile_dialog.dart처럼 별도 방을 새로 만들거나 진행 중인 방을 연다.
  void _startSecret(List<AppUser> selected) => _run(
    _Busy.secret,
    () => _session.startSecretChat(selected.single.id),
    tr('비밀 대화를 시작하지 못했습니다. 잠시 후 다시 시도하세요.'),
  );

  @override
  Widget build(BuildContext context) {
    final canStart = _session.canCreateRooms;
    // 요청이 가는 동안은 Esc·뒤로 가기·바깥 누르기로 닫히지 않게 한다 — 닫혀 버리면 방은 만들어지는데
    // 열리지 않는다.
    return PopScope(
      canPop: _busy == null,
      child: MemberPickerFrame(
        title: tr('채팅 시작하기'),
        asDialog: widget.asDialog,
        child: MemberPicker(
          session: _session,
          excludeIds: {?_session.userId},
          showSelectAll: false,
          enabled: canStart,
          pinnedRow: _SelfChatRow(
            session: _session,
            busy: _busy == _Busy.self,
            onTap: _busy == null ? _openSelf : null,
          ),
          emptySelectedText: tr('대화할 멤버를 선택하세요.'),
          noMembersText: tr('대화할 수 있는 멤버가 없습니다.'),
          footer: _buildFooter(context, canStart),
          actionsBuilder: (context, selected, wide) =>
              _buildActions(selected, wide: wide, canStart: canStart),
        ),
      ),
    );
  }

  /// 버튼 줄 옆의 한 줄 — 오류가 있으면 오류, 준회원이면 못 쓰는 이유, 아니면 몇 명을 고르면 무엇이
  /// 만들어지는지.
  Widget _buildFooter(BuildContext context, bool canStart) {
    final theme = Theme.of(context);
    final error = _error;
    final (icon, text, color) = error != null
        ? (Icons.error_outline, error, theme.colorScheme.error)
        : !canStart
        ? (
            Icons.lock_outline,
            tr('준회원은 대화를 시작할 수 없어요. 나와의 대화만 열 수 있어요.'),
            theme.colorScheme.error,
          )
        : (
            Icons.info_outline,
            // 휴대폰 폭(360)에서도 한 줄에 들게 짧게 — 길면 끝의 '요.'만 다음 줄로 넘어갔다.
            tr('1명은 1:1 채팅, 2명 이상은 그룹채팅으로 만들어요.'),
            theme.hintColor,
          );
    return Row(
      key: const ValueKey('start-chat-footer'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 새로운 토픽 생성하기의 안내 줄(보기 방식은 만든 뒤에 바꿀 수 없습니다)과 같은 크기.
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 14, color: color),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 12, color: color)),
        ),
      ],
    );
  }

  /// 취소 / 비밀 대화 시작(정확히 1명일 때만) / 채팅 시작. 좁은 화면은 한 줄을 나눠 채운다(휴대폰
  /// 폭에서 세 버튼이 넘치지 않게).
  Widget _buildActions(
    List<AppUser> selected, {
    required bool wide,
    required bool canStart,
  }) {
    final idle = _busy == null;
    // 비밀 대화는 초록(채팅 목록의 초록 이름·자물쇠와 짝)으로 구분한다. 꺼져 있을 때는 테마 기본색.
    final dark = Theme.of(context).brightness == Brightness.dark;
    final green = dark ? Colors.green.shade300 : Colors.green.shade700;
    final secretButton = OutlinedButton.icon(
      key: const ValueKey('start-chat-secret'),
      style: OutlinedButton.styleFrom(
        foregroundColor: green,
        side: selected.length == 1 && canStart
            ? BorderSide(color: green.withValues(alpha: 0.8))
            : null,
        padding: wide ? null : const EdgeInsets.symmetric(horizontal: 8),
      ),
      onPressed: canStart && selected.length == 1 && idle
          ? () => _startSecret(selected)
          : null,
      icon: _busy == _Busy.secret
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.lock_outline, size: 18),
      label: _OneLine(tr('비밀 대화 시작')),
    );
    final startButton = FilledButton(
      key: const ValueKey('start-chat-submit'),
      style: wide
          ? null
          : FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
      onPressed: canStart && selected.isNotEmpty && idle
          ? () => _start(selected)
          : null,
      child: _busy == _Busy.chat
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : _OneLine(tr('채팅 시작')),
    );
    final cancel = TextButton(
      onPressed: idle ? () => Navigator.of(context).pop() : null,
      child: Text(tr('취소')),
    );
    if (wide) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          cancel,
          const SizedBox(width: 8),
          secretButton,
          const SizedBox(width: 8),
          startButton,
        ],
      );
    }
    return Row(
      children: [
        cancel,
        const SizedBox(width: 8),
        Expanded(child: secretButton),
        const SizedBox(width: 8),
        Expanded(child: startButton),
      ],
    );
  }
}

/// 버튼 글자 — 아주 좁은 폭에서는 줄바꿈 대신 조금 줄여서 한 줄에 둔다.
class _OneLine extends StatelessWidget {
  final String text;
  const _OneLine(this.text);

  @override
  Widget build(BuildContext context) =>
      FittedBox(fit: BoxFit.scaleDown, child: Text(text, maxLines: 1));
}

/// 팀 멤버 목록 맨 위에 늘 고정된 "나와의 대화" 줄 — 고르는 줄이 아니라 누르면 바로 연다. 사진은
/// 아래 멤버 줄의 사진과 줄을 맞춘다(체크박스 자리를 비워 둔다).
class _SelfChatRow extends StatelessWidget {
  final Session session;
  final bool busy;
  final VoidCallback? onTap;
  const _SelfChatRow({
    required this.session,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: const ValueKey('start-chat-self'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
          child: Row(
            children: [
              // 멤버 줄의 체크박스와 같은 크기의 빈 자리(밀도·터치 영역에 따라 크기가 달라서 보이지
              // 않는 체크박스로 잰다).
              const ExcludeSemantics(
                child: IgnorePointer(
                  child: Opacity(
                    opacity: 0,
                    child: Checkbox(value: false, onChanged: null),
                  ),
                ),
              ),
              SelfRoomAvatar(session: session, size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      selfRoomName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      tr('나만 보는 메모 공간 · 바로 열기'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: theme.hintColor),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(Icons.chevron_right, size: 20, color: theme.hintColor),
            ],
          ),
        ),
      ),
    );
  }
}
