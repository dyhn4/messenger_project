import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:window_manager/window_manager.dart';

import '../services/app_settings.dart';
import '../services/session.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/muted_scrollbar.dart';

const _appName = 'TangoTalk';

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
  late bool _downloadWithoutAsking =
      widget.session.settings.downloadWithoutAsking;
  late String _downloadFolder = widget.session.settings.downloadFolder;
  late bool _openFolderAfterDownload =
      widget.session.settings.openFolderAfterDownload;
  late ThemeMode _themeMode = widget.session.settings.themeMode;
  late MessagePreviewMode _messagePreviewMode =
      widget.session.settings.messagePreviewMode;
  late bool _alwaysOnTop = widget.session.settings.alwaysOnTop;
  late double _windowOpacity = widget.session.settings.windowOpacity;
  bool _saving = false;

  /// "저장하기"를 눌러 실제로 반영됐는지 — false인 채로 화면이 닫히면(취소/X/바깥 클릭)
  /// 반투명 슬라이더로 미리 봤던 값을 원래 저장된 값으로 되돌려야 한다(dispose 참고).
  bool _saved = false;
  final _scrollController = ScrollController();
  PackageInfo? _packageInfo;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _packageInfo = info);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    if (!_saved && Platform.isWindows) {
      // 저장하지 않고 닫힌 경우 — 슬라이더로 미리보기만 하던 불투명도를 원래 저장된
      // 값으로 되돌린다. dispose는 async를 기다릴 수 없어 그냥 던져둔다(fire-and-forget).
      windowManager.setOpacity(widget.session.settings.windowOpacity);
    }
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.getDirectoryPath(
      initialDirectory: _downloadFolder.isEmpty ? null : _downloadFolder,
    );
    if (path != null) setState(() => _downloadFolder = path);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    _saved = true; // dispose()가 반투명 미리보기를 되돌리지 않도록 먼저 표시해둔다.
    final settings = widget.session.settings;
    await settings.setLaunchAtStartup(_launchAtStartup);
    await settings.setDownloadWithoutAsking(_downloadWithoutAsking);
    await settings.setDownloadFolder(_downloadFolder);
    await settings.setOpenFolderAfterDownload(_openFolderAfterDownload);
    await settings.setThemeMode(_themeMode);
    await settings.setMessagePreviewMode(_messagePreviewMode);
    await settings.setAlwaysOnTop(_alwaysOnTop);
    await settings.setWindowOpacity(_windowOpacity);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return FloatingDialog(
      title: '환경설정',
      maxWidth: 460,
      maxHeight: 600,
      // 오른쪽 여백을 0으로 줘서, 스크롤 영역(아래 Expanded)이 실제 레이아웃 상으로 창 끝까지
      // 닿게 한다 — Positioned 오버플로 같은 "그리기만 넘치는" 트릭은 마우스 히트테스트가
      // Stack 자신의(넘치기 전) 크기에서 멈춰서 그 안의 스크롤바를 드래그할 수 없었다.
      // 실제로 폭을 넓히면 스크롤바도 그 폭 안에 정상적으로 포함되어 클릭/드래그가 먹는다.
      // 대신 오른쪽 여백이 필요한 부분(스크롤 내용, 하단 버튼)은 이 안에서 직접 챙긴다.
      padding: const EdgeInsets.fromLTRB(20, 20, 0, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: MutedScrollbar(
              controller: _scrollController,
              child: SingleChildScrollView(
                controller: _scrollController,
                // 스크롤바 두께(10) + 원래 창 오른쪽 여백(20)만큼을 내용 쪽에서 챙긴다.
                padding: const EdgeInsets.only(right: 34),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _SectionLabel('화면 테마'),
                    Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: RadioGroup<ThemeMode>(
                        groupValue: _themeMode,
                        onChanged: (v) =>
                            setState(() => _themeMode = v ?? ThemeMode.system),
                        child: const Column(
                          children: [
                            RadioListTile<ThemeMode>(
                              contentPadding: EdgeInsets.zero,
                              value: ThemeMode.system,
                              title: Text('시스템 설정을 따름'),
                            ),
                            RadioListTile<ThemeMode>(
                              contentPadding: EdgeInsets.zero,
                              value: ThemeMode.light,
                              title: Text('라이트 모드'),
                            ),
                            RadioListTile<ThemeMode>(
                              contentPadding: EdgeInsets.zero,
                              value: ThemeMode.dark,
                              title: Text('다크 모드'),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    const _SectionLabel('메시지 내용 미리보기'),
                    Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Row(
                        children: [
                          _PreviewModeOption(
                            selected:
                                _messagePreviewMode == MessagePreviewMode.all,
                            label: '모든 메시지',
                            onTap: () => setState(
                              () => _messagePreviewMode =
                                  MessagePreviewMode.all,
                            ),
                          ),
                          const SizedBox(width: 8),
                          _PreviewModeOption(
                            selected: _messagePreviewMode ==
                                MessagePreviewMode.publicTopicOnly,
                            label: '공개 토픽만',
                            onTap: () => setState(
                              () => _messagePreviewMode =
                                  MessagePreviewMode.publicTopicOnly,
                            ),
                          ),
                          const SizedBox(width: 8),
                          _PreviewModeOption(
                            selected:
                                _messagePreviewMode == MessagePreviewMode.none,
                            label: '미리보기 안함',
                            onTap: () => setState(
                              () => _messagePreviewMode =
                                  MessagePreviewMode.none,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (Platform.isWindows) ...[
                      const _SectionLabel('시작 시 자동 실행'),
                      Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: _launchAtStartup,
                          onChanged: (v) =>
                              setState(() => _launchAtStartup = v ?? false),
                          title: const Text('시스템 시작 시 $_appName 자동 실행'),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const _SectionLabel('항상 위로'),
                      Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: _alwaysOnTop,
                          onChanged: (v) =>
                              setState(() => _alwaysOnTop = v ?? false),
                          title: const Text('다른 창 위에 항상 띄워두기'),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const _SectionLabel('반투명'),
                      Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Slider(
                                // 완전히 0%로 내리면 창이 안 보여서 다시 잡기 어려우니
                                // 최소 20%는 남겨둔다.
                                value: _windowOpacity,
                                min: 0.2,
                                max: 1.0,
                                divisions: 16,
                                label: '${(_windowOpacity * 100).round()}%',
                                onChanged: (v) {
                                  setState(() => _windowOpacity = v);
                                  // 슬라이더를 끄는 동안 실제 창에도 바로 반영해서
                                  // 미리보기가 되게 한다 — 저장을 눌러야 그 값이
                                  // 확정/저장된다(dispose 참고: 취소하면 원래 값으로
                                  // 되돌아간다).
                                  windowManager.setOpacity(v);
                                },
                              ),
                            ),
                            SizedBox(
                              width: 44,
                              child: Text(
                                '${(_windowOpacity * 100).round()}%',
                                textAlign: TextAlign.end,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],
                    const _SectionLabel('파일 다운로드'),
                    Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: _downloadWithoutAsking,
                            onChanged: (v) => setState(
                              () => _downloadWithoutAsking = v ?? false,
                            ),
                            title: const Text(
                              '다운로드 시 저장 위치 물어보지 않고 아래 경로로 즉시 다운로드',
                            ),
                          ),
                          const SizedBox(height: 8),
                          InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: _pickFolder,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: Theme.of(context).dividerColor,
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.folder_outlined,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _downloadFolder.isEmpty
                                          ? '다운로드 폴더 선택'
                                          : _downloadFolder,
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
                          Text(
                            '다운로드 완료 시',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          RadioGroup<bool>(
                            groupValue: _openFolderAfterDownload,
                            onChanged: (v) => setState(
                              () => _openFolderAfterDownload = v ?? true,
                            ),
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
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    const _SectionLabel('버전 정보'),
                    Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _packageInfo == null
                                ? '확인 중...'
                                : '$_appName ${_packageInfo!.version}',
                            style: TextStyle(
                              color: Theme.of(context).hintColor,
                            ),
                          ),
                          if (widget.session.updateAvailableVersion != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '새 버전 ${widget.session.updateAvailableVersion} 사용 가능',
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          // FloatingDialog의 오른쪽 여백을 0으로 받았으니(위 참고), 스크롤바가 필요 없는
          // 버튼 줄은 여기서 직접 원래 여백(20)만큼 오른쪽을 띄워준다.
          Padding(
            padding: const EdgeInsets.only(right: 20),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('닫기'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('저장하기'),
                  ),
                ),
              ],
            ),
          ),
        ],
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
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }
}

/// "메시지 내용 미리보기" 설정의 선택지 한 칸 — 기존 RadioListTile 세로 목록과 달리 3개를
/// 가로로 나란히 두는 알약 모양 버튼(라디오 동작은 같지만, 짧은 라벨 3개를 한 줄에 비교하며
/// 고르기 좋아서 이 설정만 이 모양으로 뺐다).
class _PreviewModeOption extends StatelessWidget {
  final bool selected;
  final String label;
  final VoidCallback onTap;
  const _PreviewModeOption({
    required this.selected,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? color : Theme.of(context).dividerColor,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
                Icon(Icons.check_circle, size: 16, color: color),
                const SizedBox(width: 4),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? color : null,
                    fontWeight: selected ? FontWeight.w600 : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
