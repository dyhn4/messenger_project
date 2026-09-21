import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../data/stickers.dart';
import '../models/comment.dart';
import '../models/message.dart';
import '../models/project.dart' show Project;
import '../screens/home_screen.dart' show wideBreakpoint;
import '../screens/message_forward_screen.dart';
import '../screens/message_share_screen.dart';
import '../screens/project/project_forms.dart' show showNewTaskDialog;
import '../services/session.dart';
import 'app_toast.dart';

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

/// 메시지를 업무로 등록한다 — 제목은 메시지 첫 줄, 설명에는 전체 내용과 출처(보낸 사람·대화방·시각)가
/// 채워진 "새 업무" 창이 열리고, 프로젝트/담당자/마감일 등은 거기서 고른다. 정회원 이상만.
Future<void> registerMessageAsTask(
  BuildContext context, {
  required Session session,
  required Message message,
  required String senderDisplayName,
}) async {
  final body = copyableTextFor(message)?.trim() ?? '';
  final fileName = message.fileName;
  final firstLine = body
      .split('\n')
      .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
  var title = firstLine.trim();
  if (title.isEmpty) {
    title = fileName != null ? '[파일] $fileName' : '메시지에서 등록한 업무';
  }
  if (title.length > 200) title = title.substring(0, 200);

  final rooms = session.rooms.where((r) => r.id == message.roomId);
  final roomName = rooms.isEmpty
      ? null
      : rooms.first.displayName(session.userId ?? '');
  final t = message.createdAt.toLocal();
  final when =
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final description = [
    if (body.isNotEmpty) body,
    if (fileName != null) '첨부: $fileName',
    '— $senderDisplayName${roomName == null ? '' : ' · $roomName'} · $when 메시지에서 등록',
  ].join('\n\n');

  await openNewTaskFromChat(
    context,
    session,
    initialTitle: title,
    initialDescription: description,
  );
}

/// 대화 화면에서 "새 업무" 창을 연다 — 이 팀에서 참여 중인 프로젝트를 받아와 고르게 한다.
/// 등록되면 업무 번호와 함께 알려준다.
Future<void> openNewTaskFromChat(
  BuildContext context,
  Session session, {
  String? initialTitle,
  String? initialDescription,
}) async {
  final teamId = session.currentTeam?.id;
  if (teamId == null) return;
  final List<Project> projects;
  try {
    projects = await session.api!.fetchProjects(teamId);
  } catch (e) {
    if (context.mounted) showAppToast(context, '프로젝트를 불러오지 못했습니다: $e');
    return;
  }
  if (!context.mounted) return;
  if (projects.isEmpty) {
    showAppToast(context, '참여 중인 프로젝트가 없습니다. 프로젝트를 먼저 만들거나 참여하세요.');
    return;
  }
  final task = await showNewTaskDialog(
    context,
    session,
    projects: projects,
    initialTitle: initialTitle,
    initialDescription: initialDescription,
  );
  if (task != null && context.mounted) {
    showAppToast(context, '${task.key ?? '업무'}로 등록했습니다.');
  }
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
          if (!isSecretRoom && session.canUseProjects)
            ListTile(
              leading: const Icon(Icons.assignment_outlined),
              title: const Text('업무로 등록'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                registerMessageAsTask(
                  context,
                  session: session,
                  message: message,
                  senderDisplayName: senderDisplayName,
                );
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
    if (!isSecretRoom && session.canUseProjects)
      PopupMenuItem<void>(
        onTap: () => registerMessageAsTask(
          context,
          session: session,
          message: message,
          senderDisplayName: senderDisplayName,
        ),
        child: const Row(
          children: [
            Icon(Icons.assignment_outlined),
            SizedBox(width: 8),
            Text('업무로 등록'),
          ],
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
