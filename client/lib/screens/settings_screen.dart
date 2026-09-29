import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:window_manager/window_manager.dart';

import '../services/app_settings.dart';
import '../services/download_storage.dart' show kAndroidDownloadSubfolder;
import '../services/session.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/muted_scrollbar.dart';
import 'project/project_window.dart';

const _appName = 'TangoTalk';

/// 화면 테마 카드의 선택 색(첨부 디자인의 초록).
const _accentGreen = Color(0xFF2BB673);

enum _Section { messenger, system }

String _sectionLabel(_Section s) => switch (s) {
  _Section.messenger => '메신저 설정',
  _Section.system => '시스템 설정',
};

IconData _sectionIcon(_Section s) => switch (s) {
  _Section.messenger => Icons.chat_bubble_outline,
  _Section.system => Icons.settings_outlined,
};

/// 삼선 메뉴 "설정"에서 여는 환경설정 플로팅 창 — "프로젝트 설정"처럼 왼쪽 사이드바(메신저 설정 /
/// 시스템 설정)에서 고르고 오른쪽에 그 항목들을 보여준다(좁은 화면은 위쪽 탭). 바꾼 값은
/// "저장하기"를 눌러야 반영된다(반투명 슬라이더만 끄는 동안 미리 보여주고, 저장 안 하고 닫으면
/// 되돌린다).
class SettingsScreen extends StatefulWidget {
  final Session session;
  const SettingsScreen({super.key, required this.session});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  _Section _section = _Section.messenger;

  late bool _launchAtStartup = widget.session.settings.launchAtStartup;
  late bool _downloadWithoutAsking =
      widget.session.settings.downloadWithoutAsking;
  late String _downloadFolder = widget.session.settings.downloadFolder;
  late bool _openFolderAfterDownload =
      widget.session.settings.openFolderAfterDownload;
  late ThemeMode _themeMode = widget.session.settings.themeMode;
  late TeamSwitchStyle _teamSwitchStyle =
      widget.session.settings.teamSwitchStyle;
  late MessagePreviewMode _messagePreviewMode =
      widget.session.settings.messagePreviewMode;
  late bool _sendWithShiftEnter = widget.session.settings.sendWithShiftEnter;
  late bool _alwaysOnTop = widget.session.settings.alwaysOnTop;
  late double _windowOpacity = widget.session.settings.windowOpacity;
  late bool _autoLockOnSleep = widget.session.settings.autoLockOnSleep;
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
    await settings.setTeamSwitchStyle(_teamSwitchStyle);
    await settings.setSendWithShiftEnter(_sendWithShiftEnter);
    await settings.setAlwaysOnTop(_alwaysOnTop);
    await settings.setWindowOpacity(_windowOpacity);
    await settings.setAutoLockOnSleep(_autoLockOnSleep);
    // "프로젝트" 창이 열려있으면 완전히 다른 엔진이라 위 setThemeMode만으론 안 바뀐다 —
    // 따로 알려준다(project_window.dart, Windows 전용이라 함수 안에서 자체적으로 걸러냄).
    if (Platform.isWindows) unawaited(broadcastThemeChange(_themeMode));
    if (mounted) Navigator.of(context).pop();
  }

  void _select(_Section s) {
    if (_section == s) return;
    setState(() => _section = s);
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    return FloatingDialog(
      title: '환경설정',
      maxWidth: 820,
      maxHeight: 640,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 좁으면(모바일) 사이드바 대신 위쪽 탭으로 고른다.
          final wide = constraints.maxWidth >= 560;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(width: 180, child: _buildNav(context)),
                          const SizedBox(width: 16),
                          Expanded(child: _buildPane(context)),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildTabs(context),
                          const SizedBox(height: 12),
                          Expanded(child: _buildPane(context)),
                        ],
                      ),
              ),
              const SizedBox(height: 16),
              Row(
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
            ],
          );
        },
      ),
    );
  }

  Widget _buildNav(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final s in _Section.values)
            _NavItem(
              icon: _sectionIcon(s),
              label: _sectionLabel(s),
              selected: _section == s,
              onTap: () => _select(s),
            ),
        ],
      ),
    );
  }

  Widget _buildTabs(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Row(
      children: [
        for (final s in _Section.values)
          Expanded(
            child: InkWell(
              onTap: () => _select(s),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: _section == s ? primary : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: Center(
                  child: Text(
                    _sectionLabel(s),
                    style: TextStyle(
                      color: _section == s ? primary : null,
                      fontWeight: _section == s ? FontWeight.bold : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 오른쪽 내용 — 테두리 있는 칸에 제목 + 항목들(스크롤).
  Widget _buildPane(BuildContext context) {
    final theme = Theme.of(context);
    final items = _section == _Section.messenger
        ? _messengerItems(context)
        : _systemItems(context);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Text(
              _sectionLabel(_section),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: MutedScrollbar(
              controller: _scrollController,
              child: SingleChildScrollView(
                controller: _scrollController,
                // 오른쪽은 스크롤바 두께만큼 더 띄운다.
                padding: const EdgeInsets.fromLTRB(20, 16, 28, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < items.length; i++) ...[
                      if (i > 0) const _ItemDivider(),
                      items[i],
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 메신저 설정 ──

  List<Widget> _messengerItems(BuildContext context) => [
    _Item(
      label: '팀 전환 방식',
      child: Row(
        children: [
          _PillOption(
            selected: _teamSwitchStyle == TeamSwitchStyle.dropdown,
            label: '드롭다운',
            onTap: () =>
                setState(() => _teamSwitchStyle = TeamSwitchStyle.dropdown),
          ),
          const SizedBox(width: 8),
          _PillOption(
            selected: _teamSwitchStyle == TeamSwitchStyle.tabs,
            label: '탭(전체 보기)',
            onTap: () =>
                setState(() => _teamSwitchStyle = TeamSwitchStyle.tabs),
          ),
        ],
      ),
    ),
    _Item(
      label: '메시지 내용 미리보기',
      child: Row(
        children: [
          _PillOption(
            selected: _messagePreviewMode == MessagePreviewMode.all,
            label: '모든 메시지',
            onTap: () =>
                setState(() => _messagePreviewMode = MessagePreviewMode.all),
          ),
          const SizedBox(width: 8),
          _PillOption(
            selected: _messagePreviewMode == MessagePreviewMode.publicTopicOnly,
            label: '공개 토픽만',
            onTap: () => setState(
              () => _messagePreviewMode = MessagePreviewMode.publicTopicOnly,
            ),
          ),
          const SizedBox(width: 8),
          _PillOption(
            selected: _messagePreviewMode == MessagePreviewMode.none,
            label: '미리보기 안함',
            onTap: () =>
                setState(() => _messagePreviewMode = MessagePreviewMode.none),
          ),
        ],
      ),
    ),
    // 키보드로 보내는 방식이라 PC 전용 — 모바일은 키보드의 "전송" 버튼으로 보낸다.
    if (Platform.isWindows)
      _Item(
        label: '메시지 전송 옵션 설정',
        child: Row(
          children: [
            Expanded(
              child: _SendOptionCard(
                title: 'Enter로 전송',
                subtitle: 'Shift + Enter로 줄바꿈',
                selected: !_sendWithShiftEnter,
                onTap: () => setState(() => _sendWithShiftEnter = false),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _SendOptionCard(
                title: 'Shift + Enter로 전송',
                subtitle: 'Enter로 줄바꿈',
                selected: _sendWithShiftEnter,
                onTap: () => setState(() => _sendWithShiftEnter = true),
              ),
            ),
          ],
        ),
      ),
  ];

  // ── 시스템 설정 ──

  List<Widget> _systemItems(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return [
      if (Platform.isWindows) ...[
        _Item(
          label: '시작 시 자동 실행',
          child: _CheckRow(
            value: _launchAtStartup,
            label: '시스템 시작 시 $_appName 자동 실행',
            onChanged: (v) => setState(() => _launchAtStartup = v),
          ),
        ),
        _Item(
          label: '항상 위로',
          child: _CheckRow(
            value: _alwaysOnTop,
            label: '다른 창 위에 항상 띄워두기',
            onChanged: (v) => setState(() => _alwaysOnTop = v),
          ),
        ),
      ],
      _Item(
        label: '화면 테마',
        caption: '본인이 선호하는 컬러 테마를 설정할 수 있습니다.',
        child: Row(
          children: [
            Expanded(
              child: _ThemeCard(
                label: '화이트 (기본)',
                selected: _themeMode != ThemeMode.dark,
                onTap: () => setState(() => _themeMode = ThemeMode.light),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ThemeCard(
                label: '다크',
                selected: _themeMode == ThemeMode.dark,
                onTap: () => setState(() => _themeMode = ThemeMode.dark),
              ),
            ),
          ],
        ),
      ),
      if (Platform.isWindows)
        _Item(
          label: '반투명',
          child: Row(
            children: [
              Expanded(
                child: Slider(
                  // 완전히 0%로 내리면 창이 안 보여서 다시 잡기 어려우니 최소 20%는 남겨둔다.
                  value: _windowOpacity,
                  min: 0.2,
                  max: 1.0,
                  divisions: 16,
                  label: '${(_windowOpacity * 100).round()}%',
                  onChanged: (v) {
                    setState(() => _windowOpacity = v);
                    // 슬라이더를 끄는 동안 실제 창에도 바로 반영해서 미리보기가 되게 한다 —
                    // 저장을 눌러야 그 값이 확정/저장된다(dispose 참고: 취소하면 원래 값으로
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
      _Item(
        label: '파일 다운로드',
        // 안드로이드는 폴더를 고르지 않는다 — 폴더 선택 창에서 Download 자체를 고를 수
        // 없어서(안드로이드 11+ OS 제한) 늘 Download/TangoTalk에 바로 저장한다.
        child: Platform.isAndroid
            ? const _AndroidDownloadFolder()
            : _desktopDownload(context),
      ),
      if (Platform.isWindows)
        _Item(
          label: '자동 잠금',
          caption:
              'PC가 절전 모드에 들어가거나 화면이 꺼지면 메신저를 잠급니다. 다시 열 때 로그인 '
              '비밀번호를 입력해야 잠금이 풀립니다.',
          child: _CheckRow(
            value: _autoLockOnSleep,
            label: '절전모드 시 $_appName 자동 잠금',
            onChanged: (v) => setState(() => _autoLockOnSleep = v),
          ),
        ),
      _Item(
        label: '버전 정보',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _packageInfo == null
                  ? '확인 중...'
                  : '$_appName ${_packageInfo!.version}',
              style: TextStyle(color: hint),
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
    ];
  }

  Widget _desktopDownload(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CheckRow(
          value: _downloadWithoutAsking,
          label: '다운로드 시 저장 위치 물어보지 않고 아래 경로로 즉시 다운로드',
          onChanged: (v) => setState(() => _downloadWithoutAsking = v),
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
        const SizedBox(height: 16),
        Text('다운로드 완료 시', style: Theme.of(context).textTheme.labelLarge),
        RadioGroup<bool>(
          groupValue: _openFolderAfterDownload,
          onChanged: (v) =>
              setState(() => _openFolderAfterDownload = v ?? true),
          child: const Column(
            children: [
              RadioListTile<bool>(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: true,
                title: Text('다운로드가 완료된 폴더 열기'),
              ),
              RadioListTile<bool>(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: false,
                title: Text('아무것도 하지 않기'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 왼쪽 사이드바의 한 칸(프로젝트 설정의 사이드바와 같은 모양).
class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Material(
        color: selected ? color.withValues(alpha: 0.10) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                Icon(icon, size: 18, color: selected ? color : theme.hintColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? color : null,
                      fontWeight: selected ? FontWeight.bold : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 설정 항목 하나 — 굵은 제목 + 내용(+ 아래 작은 설명).
class _Item extends StatelessWidget {
  final String label;
  final Widget child;
  final String? caption;
  const _Item({required this.label, required this.child, this.caption});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 10),
        child,
        if (caption != null) ...[
          const SizedBox(height: 8),
          Text(
            caption!,
            style: TextStyle(fontSize: 12, color: theme.hintColor),
          ),
        ],
      ],
    );
  }
}

/// 항목 사이 구분선.
class _ItemDivider extends StatelessWidget {
  const _ItemDivider();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 16),
    child: Divider(height: 1),
  );
}

/// 체크박스 + 글 한 줄(글을 눌러도 켜고 끈다).
class _CheckRow extends StatelessWidget {
  final bool value;
  final String label;
  final ValueChanged<bool> onChanged;
  const _CheckRow({
    required this.value,
    required this.label,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => onChanged(!value),
      child: Row(
        children: [
          Checkbox(value: value, onChanged: (v) => onChanged(v ?? false)),
          const SizedBox(width: 4),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }
}

/// "메시지 전송 옵션 설정"의 선택 카드 — 제목(굵게) + 설명, 오른쪽에 체크 원.
class _SendOptionCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  const _SendOptionCard({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strong = theme.colorScheme.onSurface;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? strong : theme.dividerColor,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: theme.hintColor),
                  ),
                ],
              ),
            ),
            Icon(
              selected ? Icons.check_circle : Icons.circle_outlined,
              size: 22,
              color: selected ? strong : theme.dividerColor,
            ),
          ],
        ),
      ),
    );
  }
}

/// "화면 테마"의 선택 카드 — 왼쪽에 라디오, 고르면 초록 테두리.
class _ThemeCard extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ThemeCard({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? _accentGreen : theme.dividerColor,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 20,
              color: selected ? _accentGreen : theme.hintColor,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(label)),
          ],
        ),
      ),
    );
  }
}

/// 짧은 선택지 여러 개를 한 줄에 나란히 두는 알약 모양 버튼(팀 전환 방식·메시지 미리보기).
class _PillOption extends StatelessWidget {
  final bool selected;
  final String label;
  final VoidCallback onTap;
  const _PillOption({
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

/// 안드로이드의 다운로드 위치 안내 — 바꿀 수 없는 고정 폴더라 누를 곳 없이 보여주기만 한다.
class _AndroidDownloadFolder extends StatelessWidget {
  const _AndroidDownloadFolder();

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Row(
            children: [
              Icon(Icons.folder_outlined, size: 18),
              SizedBox(width: 8),
              Expanded(child: Text('Download/$kAndroidDownloadSubfolder')),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '다운로드한 파일은 휴대폰의 이 폴더에 바로 저장됩니다. 같은 이름의 파일이 있으면 '
          '"이름 (1)"처럼 번호가 붙습니다.',
          style: TextStyle(fontSize: 12, color: hint),
        ),
      ],
    );
  }
}
