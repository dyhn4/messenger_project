import 'package:flutter/material.dart';

import '../services/session.dart';
import 'compact_menu.dart';
import 'menu_entries.dart';
import '../l10n/tr.dart';

/// 상단 툴바의 "메뉴"(격자 아이콘) 드롭다운 — 둥근 색 아이콘 타일과 아래 라벨을 격자로 늘어놓은 모양이고
/// "생성"(메시지 예약 · 투표) · "리스트"(파일 · 즐겨찾기 · 링크) · "툴"(캘린더 · 프로젝트 · 문의함) 세 묶음으로 나뉜다.
/// 어떤 타일이 있는지는 menu_entries.dart의 [menuEntries] 등록 목록이 정한다 — 이 위젯은 그것을 묶음별·order순으로
/// 그릴 뿐이라 새 항목은 거기에 한 줄만 더하면 된다(권장 order 값과 사용법은 그 파일 맨 위 주석).
/// desktop_home_screen.dart의 _TopBar와 room_list_screen.dart(안드로이드) AppBar가 같이 쓴다.
///
/// 파일·즐겨찾기·링크 같은 "패널" 항목은 PC에서는 오른쪽 패널로 토글되고, 안드로이드에서는 전체 화면으로 열린다
/// (side_panels.dart의 [openSidePanel]). 캘린더도 PC는 사이드바+채팅 자리를 바꿔 보여주고 모바일은 전체 화면이다.
///
/// "투표"는 투표 만들기 창을 연다(맨 위 "대화방" 칸에서 방을 고른다). "즐겨찾기"는 메시지·파일·댓글·투표·대화방·멤버를
/// 종류별 탭으로 모아 보는 통합 즐겨찾기 패널(favorites_screen.dart)을 연다 — 예전 "투표 즐겨찾기" 화면도 그 탭으로 합쳤다.
class AppMenuButton extends StatelessWidget {
  final Session session;
  const AppMenuButton({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    // 팝업이 닫힌 뒤에 창을 띄우므로, 팝업 안의 context가 아니라 버튼 자신의 context를 쓴다
    // (버튼은 홈 화면 아래에 있어 오른쪽 패널·캘린더 전환 같은 홈 화면의 일을 부를 수 있다).
    final buttonContext = context;
    return PopupMenuButton<void>(
      icon: const Icon(Icons.apps),
      tooltip: tr('메뉴'),
      position: PopupMenuPosition.under,
      offset: const Offset(0, 10),
      color: CompactMenu.color(context),
      shape: CompactMenu.shape,
      menuPadding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: _menuWidth),
      itemBuilder: (popupContext) {
        // 타일을 누르면 팝업부터 닫고 그 일을 한다.
        VoidCallback run(MenuEntry entry) => () {
          Navigator.of(popupContext).pop();
          entry.onOpen(buttonContext, session);
        };
        final sections = <Widget>[];
        for (final section in MenuSection.values) {
          final entries = menuEntriesFor(section, session);
          if (entries.isEmpty) continue;
          if (sections.isNotEmpty) sections.add(const SizedBox(height: 8));
          sections.add(_SectionTitle(section.label));
          sections.add(
            Wrap(
              children: [
                for (final entry in entries)
                  _MenuTile(
                    key: ValueKey('menu-${entry.key}'),
                    session: session,
                    entry: entry,
                    onTap: run(entry),
                  ),
              ],
            ),
          );
        }
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
                children: sections,
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

/// 둥근 색 아이콘 타일 + 아래 라벨. 밝은 테마는 옅은 배경 위에 진한 아이콘이고,
/// 어두운 테마는 아이콘 색을 옅게 깐 바탕 위에 같은 아이콘이다.
class _MenuTile extends StatelessWidget {
  static const double _width = 72;

  final Session session;
  final MenuEntry entry;
  final VoidCallback onTap;
  const _MenuTile({
    super.key,
    required this.session,
    required this.entry,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final badge = entry.badge;
    Widget icon = Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: dark
            ? entry.color.withValues(alpha: 0.22)
            : entry.tileBackground,
        borderRadius: BorderRadius.circular(14),
      ),
      alignment: Alignment.center,
      child: IconTheme(
        data: IconThemeData(color: entry.color, size: 24),
        child: entry.icon,
      ),
    );
    if (badge != null) {
      // 안 읽은 알림 개수 같은 것 — 세션이 바뀔 때마다 다시 그린다.
      icon = ListenableBuilder(
        listenable: session,
        builder: (context, child) {
          final count = badge(session);
          return Badge(
            isLabelVisible: count > 0,
            backgroundColor: Colors.redAccent,
            label: Text('$count'),
            child: child,
          );
        },
        child: icon,
      );
    }
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
              icon,
              const SizedBox(height: 6),
              Text(
                entry.label,
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
