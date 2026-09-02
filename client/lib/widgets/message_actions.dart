import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../data/stickers.dart';
import '../models/comment.dart';
import '../models/message.dart';
import '../screens/home_screen.dart' show wideBreakpoint;
import '../screens/message_forward_screen.dart';
import '../screens/message_share_screen.dart';
import '../services/session.dart';

/// message_bubble.dart(실제 메시지)와 message_comments_card.dart(댓글)가 공용으로 쓰는
/// 액션들 — 롱프레스 액션 시트(모바일)와 "더보기" 메뉴(PC) 양쪽에서 호출한다. 댓글은
/// Message가 아니라 Comment라서, [messageFromComment]로 필드가 같은 합성 Message를 만들어
/// 그대로 재사용한다(공유/전달은 어차피 새 방에 새 메시지를 만드는 것뿐이라 원본이 진짜
/// 메시지인지 댓글인지는 상관없다).
Message messageFromComment(Comment comment) => Message(
  id: comment.id,
  roomId: comment.roomId,
  senderId: comment.senderId,
  senderName: comment.senderName,
  type: comment.type,
  text: comment.text,
  fileUrl: comment.fileUrl,
  fileName: comment.fileName,
  fileSize: comment.fileSize,
  mimeType: comment.mimeType,
  thumbnailUrl: comment.thumbnailUrl,
  createdAt: comment.createdAt,
);

/// 작성 후 허용 시간(edit_policy.dart)이 지나 수정/삭제를 못 할 때 뜨는 플로팅 알림창 —
/// 메시지/댓글 양쪽의 수정·삭제 4곳(message_bubble.dart, message_comments_card.dart)이
/// 공용으로 쓴다. [message]는 이미 완성된 안내 문구를 그대로 받는다(메시지/댓글, 수정/삭제
/// 조합마다 조사가 달라서 — "메시지를"/"댓글을" — 여기서 조립하지 않고 호출부가 넘긴다).
void showEditWindowExpiredDialog(BuildContext context, String message) {
  showDialog(
    context: context,
    builder: (dialogContext) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                  ),
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('확인'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 스티커는 이모지를, 텍스트/이미지·파일 캡션은 그 텍스트를 복사 대상으로 쓴다.
/// 복사할 게 없으면(예: 캡션 없는 이미지) null.
String? copyableTextFor(Message message) {
  if (message.type == MessageType.sticker) {
    return findStickerById(message.text ?? '')?.emoji;
  }
  return (message.text?.isNotEmpty ?? false) ? message.text : null;
}

Future<void> copyMessageText(BuildContext context, Message message) async {
  final text = copyableTextFor(message);
  if (text == null) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('복사할 내용이 없습니다.')));
    return;
  }
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('복사했습니다.')));
  }
}

void showSelectCopyDialog(BuildContext context, Message message) {
  final text = copyableTextFor(message);
  if (text == null) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('복사할 내용이 없습니다.')));
    return;
  }
  showDialog(
    context: context,
    builder: (_) => SelectCopyDialog(text: text),
  );
}

/// 넓은(PC) 화면에서는 FloatingDialog로 띄우고, 좁은(모바일) 화면에서는 전체화면으로
/// push한다 — home_screen.dart의 wideBreakpoint(700) 기준, 다른 "새 대화"류 화면들과 동일한 규칙.
void pushMessageShareScreen(
  BuildContext context, {
  required Session session,
  required Message message,
  required String senderDisplayName,
}) {
  final isWide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
  if (isWide) {
    showDialog(
      context: context,
      builder: (_) => MessageShareScreen(
        session: session,
        message: message,
        senderDisplayName: senderDisplayName,
        asDialog: true,
      ),
    );
    return;
  }
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => MessageShareScreen(
        session: session,
        message: message,
        senderDisplayName: senderDisplayName,
      ),
    ),
  );
}

void pushMessageForwardScreen(
  BuildContext context, {
  required Session session,
  required Message message,
  required String senderDisplayName,
}) {
  final isWide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
  if (isWide) {
    showDialog(
      context: context,
      builder: (_) => MessageForwardScreen(
        session: session,
        message: message,
        senderDisplayName: senderDisplayName,
        asDialog: true,
      ),
    );
    return;
  }
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => MessageForwardScreen(
        session: session,
        message: message,
        senderDisplayName: senderDisplayName,
      ),
    ),
  );
}

/// 롱프레스로 뜨는 하단 시트(모바일 전용 진입점) — 메시지 공유/댓글/복사/선택 복사/메시지
/// 전달. 공유·전달은 원본이 비밀 대화(E2EE)면 숨긴다 — 평문 메시지가 다른 방으로 새거나,
/// 암호화 없이 그 대화에 그대로 쌓이면 안 되기 때문(room_picker_screen.dart도 대상
/// 목록에서 비밀 대화를 뺀다). [onOpenThread]가 null이면(댓글 자신에는 댓글 스레드가
/// 없으므로) "댓글" 항목 자체를 안 보여준다.
void showMessageActionSheet(
  BuildContext context, {
  required Session session,
  required Message message,
  required String senderDisplayName,
  void Function(Message message)? onOpenThread,
}) {
  final sourceRoom = session.rooms.where((r) => r.id == message.roomId);
  final isSecretRoom = sourceRoom.isNotEmpty && sourceRoom.first.isSecret;

  showModalBottomSheet(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isSecretRoom)
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('메시지 공유'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                pushMessageShareScreen(
                  context,
                  session: session,
                  message: message,
                  senderDisplayName: senderDisplayName,
                );
              },
            ),
          if (onOpenThread != null)
            ListTile(
              leading: const Icon(Icons.mode_comment_outlined),
              title: const Text('댓글'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                onOpenThread(message);
              },
            ),
          ListTile(
            leading: const Icon(Icons.copy_outlined),
            title: const Text('복사'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              copyMessageText(context, message);
            },
          ),
          ListTile(
            leading: const Icon(Icons.text_fields),
            title: const Text('선택 복사'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              showSelectCopyDialog(context, message);
            },
          ),
          if (!isSecretRoom)
            ListTile(
              leading: const Icon(Icons.forward_outlined),
              title: const Text('메시지 전달'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                pushMessageForwardScreen(
                  context,
                  session: session,
                  message: message,
                  senderDisplayName: senderDisplayName,
                );
              },
            ),
        ],
      ),
    ),
  );
}

/// PC "더보기" 메뉴(PopupMenuButton)에 공유/복사/전달 항목을 채워 넣는다 — 비밀 대화면
/// (showMessageActionSheet와 동일한 이유로) 공유/전달만 뺀다. 수정/삭제 등 호출부 전용
/// 항목은 이 리스트 앞뒤에 이어 붙이면 된다.
List<PopupMenuEntry<void>> messageActionMenuItems(
  BuildContext context, {
  required Session session,
  required Message message,
  required String senderDisplayName,
}) {
  final sourceRoom = session.rooms.where((r) => r.id == message.roomId);
  final isSecretRoom = sourceRoom.isNotEmpty && sourceRoom.first.isSecret;

  return [
    if (!isSecretRoom)
      PopupMenuItem<void>(
        onTap: () => pushMessageShareScreen(
          context,
          session: session,
          message: message,
          senderDisplayName: senderDisplayName,
        ),
        child: const Row(
          children: [
            Icon(Icons.share_outlined),
            SizedBox(width: 8),
            Text('메시지 공유'),
          ],
        ),
      ),
    PopupMenuItem<void>(
      onTap: () => copyMessageText(context, message),
      child: const Row(
        children: [Icon(Icons.copy_outlined), SizedBox(width: 8), Text('복사')],
      ),
    ),
    if (!isSecretRoom)
      PopupMenuItem<void>(
        onTap: () => pushMessageForwardScreen(
          context,
          session: session,
          message: message,
          senderDisplayName: senderDisplayName,
        ),
        child: const Row(
          children: [
            Icon(Icons.forward_outlined),
            SizedBox(width: 8),
            Text('메시지 전달'),
          ],
        ),
      ),
  ];
}

/// "선택 복사" — 메시지 내용을 읽기 전용 텍스트 필드로 띄우고, 열리자마자 전체를 선택해서
/// 플랫폼 기본 선택 도구(복사 등 팝업 + 드래그 핸들)가 바로 뜨게 한다. 원하는 부분만 다시
/// 골라서 복사하고 싶으면 핸들을 드래그해서 선택 범위를 조절하면 된다.
class SelectCopyDialog extends StatefulWidget {
  final String text;
  const SelectCopyDialog({super.key, required this.text});

  @override
  State<SelectCopyDialog> createState() => _SelectCopyDialogState();
}

class _SelectCopyDialogState extends State<SelectCopyDialog> {
  late final _controller = TextEditingController(text: widget.text);
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // 포커스가 실제로 걸린 다음 프레임에 SelectAllTextIntent를(원인을 toolbar로) 실행해야
    // 선택 범위뿐 아니라 복사 팝업 툴바까지 같이 뜬다 — 생성자에서 controller.selection만
    // 미리 채워두면 텍스트는 선택된 것처럼 보여도 툴바는 안 뜬다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _focusNode.context;
        if (ctx == null) return;
        Actions.maybeInvoke<SelectAllTextIntent>(
          ctx,
          const SelectAllTextIntent(SelectionChangedCause.toolbar),
        );
      });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 120),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: _controller,
          focusNode: _focusNode,
          readOnly: true,
          maxLines: null,
          decoration: const InputDecoration(border: InputBorder.none),
        ),
      ),
    );
  }
}
