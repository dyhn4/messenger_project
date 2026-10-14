import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/inquiry.dart';
import '../models/room.dart';
import '../models/uploaded_attachment.dart';
import '../services/api_client.dart'
    show UploadCancelToken, UploadCancelledException;
import '../services/image_thumbnail.dart';
import '../services/session.dart';
import 'app_toast.dart';

/// "팀장에게 문의하기" — 팀장과의 1:1 대화방([room])에서 분류/제목/내용(+선택 첨부)을 받아 서버에 문의(티켓)를 만들고,
/// 팀장이 대화 목록에서도 바로 볼 수 있도록 같은 내용을 일반 메시지로도 그 방에 보낸다. 티켓 생성이 실패하면 메시지도 안
/// 보낸다(팀장이 못 찾는 "고아" 메시지가 남는 걸 막는다). 채팅 입력칸의 "문의하기"와 문의함 패널의 "문의하기"가 쓴다.
/// 만든 문의를 돌려준다(취소·실패면 null).
Future<Inquiry?> sendInquiryTo(
  BuildContext context,
  Session session,
  Room room,
) async {
  final result =
      await showDialog<(String, String, String, UploadedAttachment?)>(
        context: context,
        builder: (_) => InquiryComposeDialog(session: session, room: room),
      );
  if (result == null || !context.mounted) return null;
  final (category, title, content, attachment) = result;
  final text = '📩 문의 [$category] $title\n\n$content';
  try {
    final inquiry = await session.api!.createInquiry(
      room.id,
      category: category,
      title: title,
      content: content,
      fileUrl: attachment?.url,
      fileName: attachment?.fileName,
      fileSize: attachment?.size,
      mimeType: attachment?.mimeType,
      thumbnailUrl: attachment?.thumbnailUrl,
    );
    await session.chatSocket.send(
      roomId: room.id,
      type: attachment == null
          ? 'text'
          : (attachment.isImage ? 'image' : 'file'),
      text: text,
      fileUrl: attachment?.url,
      fileName: attachment?.fileName,
      fileSize: attachment?.size,
      mimeType: attachment?.mimeType,
      thumbnailUrl: attachment?.thumbnailUrl,
      inquiryId: inquiry.id,
    );
    if (context.mounted) showAppToast(context, '문의를 보냈습니다.');
    return inquiry;
  } catch (e) {
    if (context.mounted) showAppToast(context, '문의를 보내지 못했습니다: $e');
    return null;
  }
}

/// 문의에 붙이는 첨부 하나의 진행 상태 — 고르는 즉시 업로드가 시작되고, [result]가 채워지면 끝난 것.
class _InquiryAttachment {
  final bool isImage;
  final String displayName;
  final UploadCancelToken cancelToken = UploadCancelToken();
  UploadedAttachment? result;

  _InquiryAttachment({required this.isImage, required this.displayName});
}

/// "팀장에게 문의하기" 작성 대화상자 — 분류(고정 목록)/제목/내용과 첨부 하나(선택)를 입력받는다. [보내기]를 누르면
/// (분류, 제목, 내용, 첨부) 튜플을 돌려준다. 첨부는 [room]의 대화 컨트롤러로 올린다.
class InquiryComposeDialog extends StatefulWidget {
  final Session session;
  final Room room;
  const InquiryComposeDialog({
    super.key,
    required this.session,
    required this.room,
  });

  @override
  State<InquiryComposeDialog> createState() => _InquiryComposeDialogState();
}

class _InquiryComposeDialogState extends State<InquiryComposeDialog> {
  String _category = inquiryCategories.first;
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();

  /// 첨부 하나(선택) — 고르는 즉시 업로드가 시작된다. [_InquiryAttachment.result]가 채워지기 전엔 "보내기"를 못 누른다.
  _InquiryAttachment? _attachment;

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (picked == null) return;
    unawaited(_stageAndUpload(picked, true, picked.name));
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.pickFiles();
    final picked = result?.files.single;
    if (picked == null || (picked.path == null && picked.bytes == null)) {
      return;
    }
    unawaited(_stageAndUpload(picked.xFile, false, picked.name));
  }

  Future<void> _stageAndUpload(
    XFile file,
    bool isImage,
    String displayName,
  ) async {
    final bytes = await file.readAsBytes();
    final thumbBytes = isImage ? await generateThumbnail(bytes) : null;
    if (!mounted) return;

    final attachment = _InquiryAttachment(
      isImage: isImage,
      displayName: displayName,
    );
    setState(() => _attachment = attachment);

    try {
      final uploaded = await widget.session
          .controllerFor(widget.room)
          .uploadAttachment(
            file,
            isImage: isImage,
            originalBytes: bytes,
            thumbBytes: thumbBytes,
            cancelToken: attachment.cancelToken,
          );
      if (!mounted || _attachment != attachment) return;
      setState(() => attachment.result = uploaded);
    } on UploadCancelledException {
      // 조용히 무시 — X 버튼으로 이미 비워짐(_removeAttachment 참고).
    } catch (e) {
      if (!mounted) return;
      setState(() => _attachment = null);
      showAppToast(context, '첨부 업로드 실패: $e');
    }
  }

  void _removeAttachment() {
    final attachment = _attachment;
    if (attachment == null) return;
    if (attachment.result == null) attachment.cancelToken.cancel();
    setState(() => _attachment = null);
  }

  @override
  Widget build(BuildContext context) {
    final attachment = _attachment;
    final uploading = attachment != null && attachment.result == null;
    // 420은 PC 기준 값 — 좁은 화면(안드로이드)에서는 그대로 두면 대화상자 가용 폭을 넘어서
    // 자식(특히 첨부 미리보기 줄)이 밀려나거나 겹쳐 보일 수 있어 화면 폭에 맞춰 줄인다.
    final dialogWidth = math.min(420.0, MediaQuery.sizeOf(context).width - 64);
    return AlertDialog(
      title: const Text('팀장에게 문의하기'),
      content: SizedBox(
        width: dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _category,
                decoration: const InputDecoration(
                  labelText: '분류',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final c in inquiryCategories)
                    DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _category = v);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('inquiry-compose-title'),
                controller: _titleController,
                autofocus: true,
                maxLength: 100,
                decoration: const InputDecoration(
                  labelText: '제목',
                  border: OutlineInputBorder(),
                ),
              ),
              TextField(
                key: const ValueKey('inquiry-compose-content'),
                controller: _contentController,
                maxLines: 6,
                minLines: 3,
                maxLength: 2000,
                decoration: const InputDecoration(
                  labelText: '내용',
                  hintText: '문의 내용을 입력하세요',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 4),
              // 첨부는 하나만 붙일 수 있어서, 이미 하나 있으면 이 버튼들은 숨기지 않고
              // 그냥 비활성화만 한다 — 버튼이 통째로 사라지면(예전엔 if/else로 바꿔치기했다)
              // 미리보기 칸과 자리가 겹쳐서 파일명이 버튼을 가리는 것처럼 보였다.
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: attachment == null ? _pickImage : null,
                    icon: const Icon(Icons.image_outlined, size: 18),
                    label: const Text('이미지'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: attachment == null ? _pickFile : null,
                    icon: const Icon(Icons.attach_file, size: 18),
                    label: const Text('파일'),
                  ),
                ],
              ),
              if (attachment != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        attachment.isImage
                            ? Icons.image_outlined
                            : Icons.insert_drive_file_outlined,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          attachment.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      if (uploading) ...[
                        const SizedBox(width: 8),
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ],
                      IconButton(
                        iconSize: 18,
                        icon: const Icon(Icons.close),
                        onPressed: _removeAttachment,
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('inquiry-compose-send'),
          onPressed: uploading
              ? null
              : () {
                  final title = _titleController.text.trim();
                  final content = _contentController.text.trim();
                  if (title.isEmpty || content.isEmpty) return;
                  Navigator.of(
                    context,
                  ).pop((_category, title, content, attachment?.result));
                },
          child: const Text('보내기'),
        ),
      ],
    );
  }
}
