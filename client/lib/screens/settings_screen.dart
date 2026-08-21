import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/session.dart';
import '../widgets/floating_dialog.dart';

const _appName = '메신저';

/// 삼선 메뉴 "설정"에서 여는 환경설정 플로팅 창. 로그인 계정 정보와 오픈소스 라이선스는
/// 삼선 메뉴 자체로 옮겼고, 여기서는 시작 시 자동 실행 / 파일 다운로드만 다룬다.
class SettingsScreen extends StatefulWidget {
  final Session session;
  const SettingsScreen({super.key, required this.session});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late bool _launchAtStartup = widget.session.settings.launchAtStartup;
  late bool _downloadWithoutAsking = widget.session.settings.downloadWithoutAsking;
  late String _downloadFolder = widget.session.settings.downloadFolder;
  late bool _openFolderAfterDownload = widget.session.settings.openFolderAfterDownload;
  bool _saving = false;

  Future<void> _pickFolder() async {
    final path = await FilePicker.getDirectoryPath(
      initialDirectory: _downloadFolder.isEmpty ? null : _downloadFolder,
    );
    if (path != null) setState(() => _downloadFolder = path);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final settings = widget.session.settings;
    await settings.setLaunchAtStartup(_launchAtStartup);
    await settings.setDownloadWithoutAsking(_downloadWithoutAsking);
    await settings.setDownloadFolder(_downloadFolder);
    await settings.setOpenFolderAfterDownload(_openFolderAfterDownload);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return FloatingDialog(
      title: '환경설정',
      maxWidth: 460,
      maxHeight: 600,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (Platform.isWindows) ...[
              const _SectionLabel('시작 시 자동 실행'),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _launchAtStartup,
                onChanged: (v) => setState(() => _launchAtStartup = v ?? false),
                title: const Text('시스템 시작 시 $_appName 자동 실행'),
              ),
              const SizedBox(height: 20),
            ],
            const _SectionLabel('파일 다운로드'),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _downloadWithoutAsking,
              onChanged: (v) => setState(() => _downloadWithoutAsking = v ?? false),
              title: const Text('다운로드 시 저장 위치 물어보지 않고 아래 경로로 즉시 다운로드'),
            ),
            const SizedBox(height: 8),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _pickFolder,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.folder_outlined, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _downloadFolder.isEmpty ? '다운로드 폴더 선택' : _downloadFolder,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text('다운로드 완료 시', style: Theme.of(context).textTheme.labelLarge),
            RadioGroup<bool>(
              groupValue: _openFolderAfterDownload,
              onChanged: (v) => setState(() => _openFolderAfterDownload = v ?? true),
              child: const Column(
                children: [
                  RadioListTile<bool>(
                    contentPadding: EdgeInsets.zero,
                    value: true,
                    title: Text('다운로드가 완료된 폴더 열기'),
                  ),
                  RadioListTile<bool>(
                    contentPadding: EdgeInsets.zero,
                    value: false,
                    title: Text('아무것도 하지 않기'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => Navigator.of(context).pop(),
                    child: const Text('닫기'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('저장하기'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
    );
  }
}
