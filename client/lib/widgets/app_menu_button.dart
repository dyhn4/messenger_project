import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../screens/inquiry_inbox_screen.dart';
import '../screens/poll_create_dialog.dart';
import '../screens/scheduled_messages_screen.dart';
import '../services/session.dart';
import 'app_toast.dart';
import 'compact_menu.dart';

/// 상단 툴바의 "메뉴"(격자 아이콘) 드롭다운 — 둥근 색 아이콘 타일과 아래 라벨을 격자로 늘어놓은 모양이고
/// "생성"(메시지 예약 · 투표)과 "리스트"(파일 · 링크 · 문의함) 두 묶음으로 나뉜다.
/// desktop_home_screen.dart의 _TopBar와 room_list_screen.dart(안드로이드) AppBar가 같이 쓴다.
/// [onOpenFiles]는 플랫폼마다 다르다 — PC는 우측 패널을 토글하고, 안드로이드는 전체화면으로
/// 새로 연다. [onOpenLinks]("링크" — 주고받은 링크 모아보기)도 같다.
///
/// "투표"는 투표 만들기 창을 연다(맨 위 "대화방" 칸에서 방을 고른다).
class AppMenuButton extends StatelessWidget {
  final Session session;
  final VoidCallback onOpenFiles;
  final VoidCallback onOpenLinks;
  const AppMenuButton({
    super.key,
    required this.session,
    required this.onOpenFiles,
    required this.onOpenLinks,
  });

  /// 투표 만들기 — 방은 창 안에서 고른다. 만들어지면 그 방에 카드가 올라간다(서버가 message:new로 뿌린다).
  Future<void> _createPoll(BuildContext context) async {
    final created = await showPollCreator(context, session: session);
    if (created && context.mounted) showAppToast(context, '투표를 만들었습니다.');
  }

  @override
  Widget build(BuildContext context) {
    // 팝업이 닫힌 뒤에 창을 띄우므로, 팝업 안의 context가 아니라 버튼 자신의 context를 쓴다.
    final buttonContext = context;
    return PopupMenuButton<void>(
      icon: const Icon(Icons.apps),
      tooltip: '메뉴',
      position: PopupMenuPosition.under,
      offset: const Offset(0, 10),
      color: CompactMenu.color(context),
      shape: CompactMenu.shape,
      menuPadding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: _menuWidth),
      itemBuilder: (popupContext) {
        // 타일을 누르면 팝업부터 닫고 그 일을 한다.
        VoidCallback run(VoidCallback action) => () {
          Navigator.of(popupContext).pop();
          action();
        };
        return [
          PopupMenuItem<void>(
            // 항목 하나가 격자 전체다 — 타일마다 자기 탭을 갖고, 이 항목 자체는 눌리지 않는다.
            enabled: false,
            padding: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _SectionTitle('생성'),
                  Wrap(
                    children: [
                      _MenuTile(
                        key: const ValueKey('menu-schedule'),
                        label: '메시지 예약',
                        color: const Color(0xFF7048E8),
                        background: const Color(0xFFEDE3FF),
                        icon: const Icon(Icons.schedule_send_rounded),
                        onTap: run(
                          () => showScheduledMessages(buttonContext, session),
                        ),
                      ),
                      _MenuTile(
                        key: const ValueKey('menu-poll'),
                        label: '투표',
                        color: const Color(0xFFD6336C),
                        background: const Color(0xFFFFE0EC),
                        icon: const Icon(Icons.poll_rounded),
                        onTap: run(() => _createPoll(buttonContext)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const _SectionTitle('리스트'),
                  Wrap(
                    children: [
                      _MenuTile(
                        key: const ValueKey('menu-files'),
                        label: '파일',
                        color: const Color(0xFF1FAE85),
                        background: const Color(0xFFDCF5EB),
                        icon: const Icon(Icons.description_rounded),
                        onTap: run(onOpenFiles),
                      ),
                      _MenuTile(
                        key: const ValueKey('menu-links'),
                        label: '링크',
                        color: const Color(0xFF2F6FDB),
                        background: const Color(0xFFDDEBFF),
                        // 비스듬히 세운 사슬(잔디 메뉴의 링크 아이콘과 같은 방향).
                        icon: Transform.rotate(
                          angle: -math.pi / 4,
                          child: const Icon(Icons.link),
                        ),
                        onTap: run(onOpenLinks),
                      ),
                      _MenuTile(
                        key: const ValueKey('menu-inquiries'),
                        label: '문의함',
                        color: const Color(0xFFB86A00),
                        background: const Color(0xFFFFE7C2),
                        icon: const Icon(Icons.contact_support_rounded),
                        onTap: run(
                          () => showInquiryInboxScreen(buttonContext, session),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ];
      },
    );
  }
}

/// 드롭다운 폭 — 타일 4칸([_MenuTile._width])이 한 줄에 들어가는 폭(양옆 여백 12씩). 폭 360dp 화면에도 들어간다.
const double _menuWidth = 4 * _MenuTile._width + 24;

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 0, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).hintColor,
        ),
      ),
    );
  }
}

/// 둥근 색 아이콘 타일 + 아래 라벨. 밝은 테마는 옅은 [background] 위에 진한 [color] 아이콘이고,
/// 어두운 테마는 [color]를 옅게 깐 바탕 위에 같은 아이콘이다.
class _MenuTile extends StatelessWidget {
  static const double _width = 72;

  final String label;
  final Color color;
  final Color background;
  final Widget icon;
  final VoidCallback onTap;
  const _MenuTile({
    super.key,
    required this.label,
    required this.color,
    required this.background,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return SizedBox(
      width: _width,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: dark ? color.withValues(alpha: 0.22) : background,
                  borderRadius: BorderRadius.circular(14),
                ),
                alignment: Alignment.center,
                child: IconTheme(
                  data: IconThemeData(color: color, size: 24),
                  child: icon,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
