import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/room_chat_controller.dart';

class ChatInputBar extends StatefulWidget {
  final RoomChatController controller;
  const ChatInputBar({super.key, required this.controller});

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  final _controller = TextEditingController();
  bool _sending = false;

  Future<void> _pickImage() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null) return;
    await _uploadAndSend(File(picked.path), isImage: true);
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.pickFiles();
    final path = result?.files.single.path;
    if (path == null) return;
    await _uploadAndSend(File(path), isImage: false);
  }

  Future<void> _uploadAndSend(File file, {required bool isImage}) async {
    setState(() => _sending = true);
    try {
      await widget.controller.sendFile(file, isImage: isImage);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('전송 실패: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _sendText() {
    widget.controller.sendText(_controller.text);
    _controller.clear();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.image_outlined),
              onPressed: _sending ? null : _pickImage,
              tooltip: '이미지 보내기',
            ),
            IconButton(
              icon: const Icon(Icons.attach_file),
              onPressed: _sending ? null : _pickFile,
              tooltip: '파일 보내기',
            ),
            Expanded(
              child: TextField(
                controller: _controller,
                decoration: const InputDecoration(hintText: '메시지 입력', border: OutlineInputBorder()),
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendText(),
              ),
            ),
            if (_sending)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              IconButton(icon: const Icon(Icons.send), onPressed: _sendText, tooltip: '보내기'),
          ],
        ),
      ),
    );
  }
}
