import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:window_manager/window_manager.dart';

import '../services/app_platform.dart';
import '../services/app_settings.dart';
import '../services/download_storage.dart' show kAndroidDownloadSubfolder;
import '../services/notification_popup.dart'
    if (dart.library.js_interop) '../services/notification_popup_stub.dart';
import '../services/notification_popup_style.dart';
import '../services/session.dart';
import '../services/system_fonts.dart'
    if (dart.library.js_interop) '../services/system_fonts_stub.dart';
import '../widgets/app_toast.dart';
import '../widgets/filter_dropdown.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/muted_scrollbar.dart';
import '../widgets/update_dialog.dart';
import '../widgets/web_push_prompt.dart';
import 'project/project_window.dart';

const _appName = 'TangoTalk';

/// 화면 테마 카드의 선택 색(첨부 디자인의 초록).
const _accentGreen = Color(0xFF2BB673);

enum _Section { messenger, display, system }

String _sectionLabel(_Section s) => switch (s) {
  _Section.messenger => '메신저 설정',
  _Section.display => '화면 설정',
  _Section.system => '시스템 설정',
};

IconData _sectionIcon(_Section s) => switch (s) {
  _Section.messenger => Icons.chat_bubble_outline,
  _Section.display => Icons.desktop_windows_outlined,
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
  late bool _gatherTopics = widget.session.settings.gatherTopicsAcrossTeams;
  late bool _gatherGroupChats =
      widget.session.settings.gatherGroupChatsAcrossTeams;
  late bool _gatherDms = widget.session.settings.gatherDmsAcrossTeams;
  late MessagePreviewMode _messagePreviewMode =
      widget.session.settings.messagePreviewMode;
  late bool _sendWithShiftEnter = widget.session.settings.sendWithShiftEnter;
  late int _popupWidth = widget.session.settings.notifyPopupWidth;
  late int _popupHeight = widget.session.settings.notifyPopupHeight;
  late int _popupMaxCards = widget.session.settings.notifyPopupMaxCards;
  late bool _alwaysOnTop = widget.session.settings.alwaysOnTop;
  late double _windowOpacity = widget.session.settings.windowOpacity;
  late bool _autoLockOnSleep = widget.session.settings.autoLockOnSleep;
  late bool _flashTaskbarWhenFocused =
      widget.session.settings.flashTaskbarWhenFocused;
  late bool _flashWindowFrame = widget.session.settings.flashWindowFrame;
  late double _textScale = widget.session.settings.textScale;
  late String _fontFamily = widget.session.settings.fontFamily;

  /// "다른 기기 접속 중에도 휴대폰 알림 받기" — 다른 항목과 달리 서버(계정)에 저장되는 알림 설정이라 내 모든 기기에 같이
  /// 적용된다(server notification_settings.pushWhileOnline). 서버 값을 아직 못 받았으면 null(받는 중 표시).
  late bool? _pushWhileOnline =
      widget.session.notificationCenter.settings?.pushWhileOnline;
  bool _saving = false;

  /// "저장하기"를 눌러 실제로 반영됐는지 — false인 채로 화면이 닫히면(취소/X/바깥 클릭)
  /// 반투명 슬라이더로 미리 봤던 값을 원래 저장된 값으로 되돌려야 한다(dispose 참고).
  bool _saved = false;
  final _scrollController = ScrollController();
  PackageInfo? _packageInfo;

  /// 이 PC에 깔린 글꼴 이름 — WinAPI 열거(system_fonts.dart)는 몇백 개라도 수 밀리초 안에
  /// 끝나는 동기 호출이라, 비동기로 미루지 않고 그냥 바로 받는다.
  late final List<String>? _systemFonts = AppPlatform.isWindows
      ? listInstalledFontFamilies()
      : null;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _packageInfo = info);
    });
    final center = widget.session.notificationCenter;
    if (_pushWhileOnline == null) {
      // 알림 센터를 아직 안 열었으면 서버 알림 설정을 받아 온다(실패하면 그 항목만 안내 문구로 남는다).
      center.loadSettings().whenComplete(() {
        if (mounted && _pushWhileOnline == null) {
          setState(() => _pushWhileOnline = center.settings?.pushWhileOnline);
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    if (!_saved && AppPlatform.isWindows) {
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
    // 서버에 저장하는 값부터 — 실패하면 창을 닫지 않고 알린다(이 기기 설정은 아래에서 그대로 저장된다).
    final center = widget.session.notificationCenter;
    final push = _pushWhileOnline;
    if (push != null && push != center.settings?.pushWhileOnline) {
      try {
        await center.updateSettings(pushWhileOnline: push);
      } catch (e) {
        if (!mounted) return;
        setState(() => _saving = false);
        showAppToast(context, '휴대폰 알림 설정을 저장하지 못했습니다: $e');
        return;
      }
    }
    _saved = true; // dispose()가 반투명 미리보기를 되돌리지 않도록 먼저 표시해둔다.
    final settings = widget.session.settings;
    await settings.setLaunchAtStartup(_launchAtStartup);
    await settings.setDownloadWithoutAsking(_downloadWithoutAsking);
    await settings.setDownloadFolder(_downloadFolder);
    await settings.setOpenFolderAfterDownload(_openFolderAfterDownload);
    await settings.setThemeMode(_themeMode);
    await settings.setMessagePreviewMode(_messagePreviewMode);
    await settings.setTeamSwitchStyle(_teamSwitchStyle);
    await settings.setGatherAcrossTeams(
      topics: _gatherTopics,
      groupChats: _gatherGroupChats,
      dms: _gatherDms,
    );
    await settings.setSendWithShiftEnter(_sendWithShiftEnter);
    await settings.setNotificationPopupSize(
      width: _popupWidth,
      height: _popupHeight,
      maxCards: _popupMaxCards,
    );
    await settings.setAlwaysOnTop(_alwaysOnTop);
    await settings.setWindowOpacity(_windowOpacity);
    await settings.setAutoLockOnSleep(_autoLockOnSleep);
    await settings.setFlashTaskbarWhenFocused(_flashTaskbarWhenFocused);
    await settings.setFlashWindowFrame(_flashWindowFrame);
    await settings.setTextScale(_textScale);
    await settings.setFontFamily(_fontFamily);
    // "프로젝트" 창이 열려있으면 완전히 다른 엔진이라 위 setThemeMode만으론 안 바뀐다 —
    // 따로 알려준다(project_window.dart, Windows 전용이라 함수 안에서 자체적으로 걸러냄).
    if (AppPlatform.isWindows) unawaited(broadcastThemeChange(_themeMode));
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
    final items = switch (_section) {
      _Section.messenger => _messengerItems(context),
      _Section.display => _displayItems(context),
      _Section.system => _systemItems(context),
    };
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
    // 여러 팀에 속해 있으면 팀마다 들어가야 그 팀의 방이 보인다 — 종류별로 골라 지금 팀의 방 목록에 함께 모아 본다
    // (Session.showsInRoomList). 다른 팀의 방에는 팀 이름이 붙고, 누르면 그 팀으로 바뀌며 열린다.
    _Item(
      label: '여러 팀 방 모아보기',
      caption:
          '켠 종류는 내가 속한 다른 팀의 방도 지금 팀의 방 목록에 함께 보입니다. 다른 팀의 방에는 팀 이름이 붙고, '
          '누르면 그 팀으로 바뀌며 열립니다.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CheckRow(
            key: const ValueKey('settings-gather-topics'),
            value: _gatherTopics,
            label: '내가 속한 팀의 토픽방 모아보기',
            onChanged: (v) => setState(() => _gatherTopics = v),
          ),
          _CheckRow(
            key: const ValueKey('settings-gather-groups'),
            value: _gatherGroupChats,
            label: '내가 속한 팀의 그룹채팅방 모아보기',
            onChanged: (v) => setState(() => _gatherGroupChats = v),
          ),
          _CheckRow(
            key: const ValueKey('settings-gather-dms'),
            value: _gatherDms,
            label: '내가 속한 팀의 채팅방 모아보기',
            onChanged: (v) => setState(() => _gatherDms = v),
          ),
        ],
      ),
    ),
    _Item(
      label: '휴대폰 알림',
      caption:
          '켜 두면 PC 앱이 켜져 있어도, 접속해 있지 않은 휴대폰으로 푸시 알림이 갑니다. 끄면 어느 기기로든 접속해 있는 '
          '동안은 휴대폰 푸시를 보내지 않습니다. 이 설정은 계정에 저장돼 내 모든 기기에 같이 적용됩니다.',
      child: _pushWhileOnline == null
          ? Text(
              widget.session.notificationCenter.settingsError != null
                  ? '알림 설정을 불러오지 못했습니다. 잠시 후 다시 열어 주세요.'
                  : '알림 설정을 불러오는 중…',
              style: TextStyle(color: Theme.of(context).hintColor),
            )
          : _CheckRow(
              key: const ValueKey('settings-push-while-online'),
              value: _pushWhileOnline!,
              label: '다른 기기 접속 중에도 휴대폰 알림 받기',
              onChanged: (v) => setState(() => _pushWhileOnline = v),
            ),
    ),
    _Item(
      label: '메시지 내용 미리보기',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _PillOption(
                selected: _messagePreviewMode == MessagePreviewMode.all,
                label: '모든 메시지',
                onTap: () => setState(
                  () => _messagePreviewMode = MessagePreviewMode.all,
                ),
              ),
              const SizedBox(width: 8),
              _PillOption(
                selected:
                    _messagePreviewMode == MessagePreviewMode.publicTopicOnly,
                label: '공개 토픽만',
                onTap: () => setState(
                  () =>
                      _messagePreviewMode = MessagePreviewMode.publicTopicOnly,
                ),
              ),
              const SizedBox(width: 8),
              _PillOption(
                selected: _messagePreviewMode == MessagePreviewMode.none,
                label: '미리보기 안함',
                onTap: () => setState(
                  () => _messagePreviewMode = MessagePreviewMode.none,
                ),
              ),
            ],
          ),
          // 새 메시지가 오면 화면 오른쪽 아래에 뜨는 알림 창(notification_popup.dart)의 카드 크기와 한꺼번에 쌓이는
          // 개수 — 그 창은 PC에만 있다.
          if (AppPlatform.isWindows) ...[
            const SizedBox(height: 16),
            _popupSizeSection(context),
          ],
        ],
      ),
    ),
    // 키보드로 보내는 방식이라 PC 전용 — 모바일은 키보드의 "전송" 버튼으로 보낸다.
    if (AppPlatform.isWindows)
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

  /// "PC 알림 창" — 카드 가로·세로·최대 개수 스텝퍼와 미리 보기 단추. 값은 "저장하기"를 눌러야 반영된다.
  Widget _popupSizeSection(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('settings-notify-popup'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'PC 알림 창',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '새 메시지가 오면 화면 오른쪽 아래에 뜨는 알림 창의 크기와, 한꺼번에 쌓여 보이는 최대 개수입니다.',
          style: TextStyle(fontSize: 12, color: theme.hintColor),
        ),
        const SizedBox(height: 10),
        _NumberStepper(
          key: const ValueKey('settings-notify-popup-width'),
          label: '가로',
          value: _popupWidth,
          min: NotificationPopupStyle.minWidth,
          max: NotificationPopupStyle.maxWidth,
          step: NotificationPopupStyle.widthStep,
          defaultValue: NotificationPopupStyle.defaultWidth,
          unit: 'px',
          onChanged: (v) => setState(() => _popupWidth = v),
        ),
        const SizedBox(height: 8),
        _NumberStepper(
          key: const ValueKey('settings-notify-popup-height'),
          label: '세로',
          value: _popupHeight,
          min: NotificationPopupStyle.minHeight,
          max: NotificationPopupStyle.maxHeight,
          step: NotificationPopupStyle.heightStep,
          defaultValue: NotificationPopupStyle.defaultHeight,
          unit: 'px',
          onChanged: (v) => setState(() => _popupHeight = v),
        ),
        const SizedBox(height: 8),
        _NumberStepper(
          key: const ValueKey('settings-notify-popup-count'),
          label: '최대 개수',
          value: _popupMaxCards,
          min: NotificationPopupStyle.minCards,
          max: NotificationPopupStyle.maxCardsLimit,
          step: 1,
          defaultValue: NotificationPopupStyle.defaultMaxCards,
          unit: '개',
          onChanged: (v) => setState(() => _popupMaxCards = v),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const ValueKey('settings-notify-popup-preview'),
          onPressed: _previewPopup,
          icon: const Icon(Icons.visibility_outlined, size: 18),
          label: const Text('알림 창 미리 보기'),
        ),
      ],
    );
  }

  /// 아직 저장하지 않은 값으로 알림 창을 최대 개수만큼 띄워 본다(눌러도 아무 방도 열리지 않는다). 처음 한 번은 알림
  /// 창을 새로 만드느라 1초쯤 걸린다.
  Future<void> _previewPopup() async {
    final style = NotificationPopupStyle(
      themeMode: _themeMode,
      width: _popupWidth,
      height: _popupHeight,
      maxCards: _popupMaxCards,
    );
    for (var i = 1; i <= _popupMaxCards; i++) {
      final last = i == _popupMaxCards;
      final shown = await showNotificationPopup(
        key: 'settings-preview-$i',
        title: last ? '알림 창 미리 보기' : '미리 보기 $i',
        body:
            '가로 ${_popupWidth}px · 세로 ${_popupHeight}px · 최대 $_popupMaxCards개 — 새 메시지가 오면 이렇게 보입니다.',
        payload: '',
        style: style,
        force: true,
        sound: last,
      );
      if (!shown) {
        if (mounted) showAppToast(context, '알림 창을 띄우지 못했습니다.');
        return;
      }
    }
  }

  // ── 화면 설정 ──

  List<Widget> _displayItems(BuildContext context) => [
    _Item(
      label: '텍스트 크기',
      caption: '채팅 내용(메시지·댓글)과 방 이름의 글자 크기를 조절합니다.',
      child: _TextSizeStepper(
        scale: _textScale,
        onChanged: (v) => setState(() => _textScale = v),
      ),
    ),
    // 글꼴 이름(맑은 고딕 등)은 PC에 깔려 있는 시스템 글꼴을 그대로 쓰는 방식이라 — 안드로이드엔
    // 이 이름들이 없어서(그려도 기본 글꼴로만 보여 설정한 보람이 없다) 아예 숨긴다.
    if (AppPlatform.isWindows)
      _Item(
        label: '글꼴',
        caption: '새로 고른 글꼴은 저장한 뒤 적용됩니다.',
        child: _FontFilterButton(
          value: _fontFamily,
          options: _systemFonts,
          onSelected: (v) => setState(() => _fontFamily = v),
        ),
      ),
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
    if (AppPlatform.isWindows)
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
    if (AppPlatform.isWindows)
      _Item(
        label: '창 깜빡임',
        caption: '알림이 왔을 때 작업표시줄 버튼과 함께 메신저 창의 테두리도 깜빡일지 정합니다.',
        child: RadioGroup<bool>(
          groupValue: _flashWindowFrame,
          onChanged: (v) => setState(() => _flashWindowFrame = v ?? true),
          child: const Column(
            children: [
              RadioListTile<bool>(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: false,
                title: Text('깜빡이지 않음'),
              ),
              RadioListTile<bool>(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: true,
                title: Text('깜빡임 (기본값)'),
              ),
            ],
          ),
        ),
      ),
    if (AppPlatform.isWindows)
      _Item(
        label: '작업표시줄 깜빡임',
        caption:
            '메신저 창을 보고 있는 중에, 지금 보고 있는 방이 아닌 다른 방에 메시지가 오면 '
            '작업표시줄의 $_appName 버튼을 깜빡일지 정합니다.',
        child: RadioGroup<bool>(
          groupValue: _flashTaskbarWhenFocused,
          onChanged: (v) =>
              setState(() => _flashTaskbarWhenFocused = v ?? false),
          child: const Column(
            children: [
              RadioListTile<bool>(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: false,
                title: Text('깜빡이지 않음 (기본값)'),
              ),
              RadioListTile<bool>(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: true,
                title: Text('해당 채팅방을 열 때까지 계속 깜빡임'),
              ),
            ],
          ),
        ),
      ),
  ];

  // ── 시스템 설정 ──

  List<Widget> _systemItems(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return [
      if (AppPlatform.isWindows) ...[
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
      if (kIsWeb)
        _Item(
          label: '알림',
          child: WebNotificationSetting(session: widget.session),
        ),
      // 웹은 저장 위치를 브라우저가 정한다(받은 파일은 브라우저 다운로드로 내려간다).
      if (!kIsWeb)
        _Item(
          label: '파일 다운로드',
          // 안드로이드는 폴더를 고르지 않는다 — 폴더 선택 창에서 Download 자체를 고를 수
          // 없어서(안드로이드 11+ OS 제한) 늘 Download/TangoTalk에 바로 저장한다.
          child: AppPlatform.isAndroid
              ? const _AndroidDownloadFolder()
              : _desktopDownload(context),
        ),
      if (AppPlatform.isWindows)
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
            // 화면 위 알약(UpdateBanner)을 닫아도(이번 실행 동안만 숨김) 여기서는 계속
            // 알려주고, 버튼으로 바로 설치 대화상자를 다시 열 수 있게 한다.
            if (widget.session.updateAvailableVersion != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '새 버전 ${widget.session.updateAvailableVersion} 사용 가능',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.tonalIcon(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => UpdateDialog(
                          session: widget.session,
                          version: widget.session.updateAvailableVersion!,
                        ),
                      ),
                      icon: const Icon(Icons.system_update_outlined, size: 18),
                      label: const Text('업데이트'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        minimumSize: const Size(0, 32),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
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
    super.key,
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

/// "텍스트 크기" — 가운데 알약(지금 배율, 누르면 100%로 초기화)을 양옆의 −/+ 단추로 10%씩
/// 줄이거나 늘린다(80%~150%, app_settings.dart의 min/maxTextScale). 끝에 닿으면 그쪽 단추는
/// 꺼진다.
class _TextSizeStepper extends StatelessWidget {
  final double scale;
  final ValueChanged<double> onChanged;
  const _TextSizeStepper({required this.scale, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final percent = (scale * 100).round();
    final canDecrease = scale > minTextScale + 0.001;
    final canIncrease = scale < maxTextScale - 0.001;
    return Row(
      children: [
        Text('작게', style: TextStyle(color: theme.hintColor, fontSize: 12)),
        const SizedBox(width: 8),
        _StepButton(
          icon: Icons.remove,
          onPressed: canDecrease
              ? () => onChanged(((scale - textScaleStep) * 10).round() / 10)
              : null,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => onChanged(1.0),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: percent == 100 ? _accentGreen : theme.dividerColor,
                  width: percent == 100 ? 1.5 : 1,
                ),
              ),
              child: Center(
                child: Text(
                  '$percent% 기본 크기',
                  style: TextStyle(
                    fontWeight: percent == 100 ? FontWeight.w600 : null,
                    color: percent == 100 ? _accentGreen : null,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        _StepButton(
          icon: Icons.add,
          onPressed: canIncrease
              ? () => onChanged(((scale + textScaleStep) * 10).round() / 10)
              : null,
        ),
        const SizedBox(width: 8),
        Text('크게', style: TextStyle(color: theme.hintColor, fontSize: 12)),
      ],
    );
  }
}

/// 정해진 범위·간격으로 숫자 하나를 고르는 줄 — 왼쪽 이름, [−] 값 [+], 오른쪽 범위. 가운데 값을 누르면 기본값으로.
class _NumberStepper extends StatelessWidget {
  final String label;
  final int value;
  final int min;
  final int max;
  final int step;
  final int defaultValue;
  final String unit;
  final ValueChanged<int> onChanged;
  const _NumberStepper({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.defaultValue,
    required this.unit,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDefault = value == defaultValue;
    return Row(
      children: [
        SizedBox(width: 72, child: Text(label)),
        _StepButton(
          icon: Icons.remove,
          onPressed: value > min
              ? () => onChanged((value - step).clamp(min, max))
              : null,
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: '기본값($defaultValue$unit)으로',
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => onChanged(defaultValue),
            child: Container(
              width: 110,
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isDefault ? _accentGreen : theme.dividerColor,
                  width: isDefault ? 1.5 : 1,
                ),
              ),
              child: Center(
                child: Text(
                  '$value$unit${isDefault ? ' (기본)' : ''}',
                  style: TextStyle(
                    fontWeight: isDefault ? FontWeight.w600 : null,
                    color: isDefault ? _accentGreen : null,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        _StepButton(
          icon: Icons.add,
          onPressed: value < max
              ? () => onChanged((value + step).clamp(min, max))
              : null,
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            '$min~$max$unit',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: theme.hintColor),
          ),
        ),
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  const _StepButton({required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onPressed != null;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onPressed,
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.dividerColor),
        ),
        child: Icon(
          icon,
          size: 18,
          color: enabled ? null : theme.disabledColor,
        ),
      ),
    );
  }
}

/// "글꼴" — 이 PC에 깔린 수백 개 글꼴 중 하나를 검색해서 고른다(panel_filters.dart의 "참여
/// 대화방"·"모든 멤버" 필터와 같은 앵커 드롭다운 + 검색칸 + 목록 틀을 그대로 쓴다). [options]가
/// null이면(아직 받는 중) "시스템 기본"만 있는 목록으로 보여준다.
class _FontFilterButton extends StatelessWidget {
  final String value;
  final List<String>? options;
  final ValueChanged<String> onSelected;
  const _FontFilterButton({
    required this.value,
    required this.options,
    required this.onSelected,
  });

  // 글꼴 이름이 길면("Segoe UI Historic" 같은) 단추 밖으로 삐져나오는 대신 끝을 "..."로
  // 자르도록(FilterDropdownButton의 라벨에 이미 있는 ellipsis) 폭을 넉넉히 고정해 둔다 —
  // 안 그러면 단추가 내용 길이만큼 계속 넓어져서 잘릴 일이 없어진다.
  static const _buttonWidth = 240.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _buttonWidth,
      child: FilterDropdownButton(
        label: fontFamilyLabel(value),
        expand: true,
        panelBuilder: (close) => FilterPanelShell(
          width: 260,
          child: _FontFilterPanel(
            value: value,
            options: options,
            onSelected: (v) {
              onSelected(v);
              close();
            },
          ),
        ),
      ),
    );
  }
}

class _FontFilterPanel extends StatefulWidget {
  final String value;
  final List<String>? options;
  final ValueChanged<String> onSelected;
  const _FontFilterPanel({
    required this.value,
    required this.options,
    required this.onSelected,
  });

  @override
  State<_FontFilterPanel> createState() => _FontFilterPanelState();
}

class _FontFilterPanelState extends State<_FontFilterPanel> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final options = widget.options;
    final fonts = options == null
        ? const <String>[]
        : options
              .where((f) => f.toLowerCase().contains(_filter.toLowerCase()))
              .toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        filterSearchBox((v) => setState(() => _filter = v)),
        const Divider(height: 1),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              if (_filter.isEmpty)
                ListTile(
                  dense: true,
                  title: const Text('시스템 기본'),
                  trailing: widget.value.isEmpty
                      ? const Icon(Icons.check, size: 18)
                      : null,
                  onTap: () => widget.onSelected(''),
                ),
              if (options == null)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else
                for (final f in fonts)
                  ListTile(
                    dense: true,
                    title: Text(
                      f,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: f),
                    ),
                    trailing: widget.value == f
                        ? const Icon(Icons.check, size: 18)
                        : null,
                    onTap: () => widget.onSelected(f),
                  ),
            ],
          ),
        ),
      ],
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
