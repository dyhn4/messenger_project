import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../screens/calendar/calendar_screen.dart' show openCalendarScreen;
import '../screens/groupware/groupware_screen.dart' show openGroupwareScreen;
import '../screens/project/project_dialog.dart' show showProjectDialog;
import '../screens/project/project_window.dart' show openProjectWindow;
import '../services/app_platform.dart';
import '../services/session.dart';
import 'side_panels.dart';

// ──────────────────────────────────────────────────────────────────────────
// "메뉴"(상단 격자 아이콘) 항목 등록 구조 — 새 항목을 달 때 읽을 것
//
// 메뉴 드롭다운(app_menu_button.dart)은 이 파일의 [menuEntries] 목록을 [MenuSection]별로 나눠 order 순으로
// 그릴 뿐이다. 새 기능을 메뉴에 달려면 아래 목록에 [MenuEntry] 한 줄을 더하면 끝이다:
//
//   MenuEntry(
//     key: 'todos',                                  // 타일의 ValueKey('menu-todos')가 된다
//     section: MenuSection.create,
//     label: '할 일',
//     icon: Icon(Icons.checklist_rounded),
//     color: Color(0xFF2B8A3E),                      // 아이콘 색(어두운 테마에서는 이 색을 옅게 깐 바탕)
//     order: 20,
//     onOpen: (context, session) => openSidePanel(context, session, 'todos'),  // 오른쪽 패널/모바일 전체 화면
//     // visible: (session) => session.canUseProjects,  // 조건부로 숨길 때(기본은 늘 보임)
//   ),
//
// - 패널로 여는 항목은 side_panels.dart의 [sidePanelSpecs]에 패널을 먼저 등록하고 위처럼 [openSidePanel]을 부른다.
// - 창·대화상자로 여는 항목은 onOpen 안에서 그 함수를 부르면 된다. [onOpen]이 받는 context는 메뉴 버튼 자신의 것이라
//   (팝업이 닫힌 뒤에 불린다) 홈 화면 아래다 — 대화상자·패널 열기에 그대로 써도 된다.
// - 타일 한 줄은 4칸, 넘치면 다음 줄로 내려간다. 같은 묶음에 항목이 없으면 그 묶음 제목도 안 보인다.
//
// 권장 order 값(10 간격이라 사이에 끼워 넣을 수 있다):
//   생성(create) — 메시지 예약 10 · 할 일 20 · 투표 30
//   리스트(list) — 파일 10 · 즐겨찾기 20 · 북마크 30 · 링크 40 · 내가 쓴 글 50 · 앨범 60 · (투표 목록 등은 70부터)
//   툴(tools)    — 캘린더 10 · 그룹웨어 15 · 프로젝트 20 · 문의함 30
// ──────────────────────────────────────────────────────────────────────────

/// 메뉴 묶음 — 드롭다운에 이 순서로 나온다.
enum MenuSection {
  create('생성'),
  list('리스트'),
  tools('툴');

  final String label;
  const MenuSection(this.label);
}

class MenuEntry {
  /// 타일의 `ValueKey('menu-$key')`가 된다. 목록 안에서 하나뿐이어야 한다.
  final String key;
  final MenuSection section;
  final String label;
  final Widget icon;

  /// 아이콘 색. 밝은 테마는 옅은 [background] 위에 이 색, 어두운 테마는 이 색을 옅게 깐 바탕 위에 같은 아이콘이다.
  final Color color;

  /// 밝은 테마의 타일 바탕. 안 주면 [color]를 흰색 위에 옅게 깐 색이다.
  final Color? background;

  /// 같은 묶음 안의 순서(작을수록 앞). 같으면 목록에 적은 순서.
  final int order;

  /// 이 사람에게 보일지(기본은 늘 보임). 예: 프로젝트는 `session.canUseProjects`.
  final bool Function(Session session) visible;

  /// 타일을 눌렀을 때. 메뉴 팝업이 먼저 닫힌 뒤 불리며, [context]는 메뉴 버튼의 것이다.
  final void Function(BuildContext context, Session session) onOpen;

  /// 타일 오른쪽 위에 빨간 숫자 뱃지로 보일 값(0이면 안 보임). 없으면 뱃지 없음.
  final int Function(Session session)? badge;

  const MenuEntry({
    required this.key,
    required this.section,
    required this.label,
    required this.icon,
    required this.color,
    required this.order,
    required this.onOpen,
    this.background,
    this.visible = _always,
    this.badge,
  });

  Color get tileBackground =>
      background ??
      Color.alphaBlend(color.withValues(alpha: 0.14), Colors.white);
}

bool _always(Session session) => true;

/// [section]에 보일 항목들을 order 순으로(같으면 등록 순서로).
List<MenuEntry> menuEntriesFor(MenuSection section, Session session) {
  final entries = [
    for (final e in menuEntries)
      if (e.section == section && e.visible(session)) e,
  ];
  // List.sort는 안정 정렬이 아니라서 등록 순서를 보조 키로 쓴다.
  final index = {for (final (i, e) in menuEntries.indexed) e: i};
  entries.sort((a, b) {
    final byOrder = a.order.compareTo(b.order);
    return byOrder != 0 ? byOrder : index[a]!.compareTo(index[b]!);
  });
  return entries;
}

/// 메뉴에 달린 항목들. 새 항목은 여기에 [MenuEntry]를 더한다(위 주석 참고).
final menuEntries = <MenuEntry>[
  // ── 생성 ──
  MenuEntry(
    key: 'schedule',
    section: MenuSection.create,
    label: '메시지 예약',
    icon: const Icon(Icons.schedule_send_rounded),
    color: const Color(0xFF7048E8),
    background: const Color(0xFFEDE3FF),
    order: 10,
    // 내 예약 메시지 목록 패널(상단의 "+ 메시지 예약"으로 만들기 창이 열린다) — PC는 오른쪽 패널, 모바일은 전체 화면.
    onOpen: (context, session) => openSidePanel(context, session, 'scheduled'),
  ),
  MenuEntry(
    key: 'todos',
    section: MenuSection.create,
    label: '할 일',
    icon: const Icon(Icons.checklist_rounded),
    color: const Color(0xFF2B8A3E),
    background: const Color(0xFFDDF3E1),
    order: 20,
    // 프로젝트 업무와는 별개인 대화방 할 일 — PC는 오른쪽 패널, 모바일은 전체 화면.
    onOpen: (context, session) => openSidePanel(context, session, 'todos'),
  ),
  MenuEntry(
    key: 'poll',
    section: MenuSection.create,
    label: '투표',
    icon: const Icon(Icons.poll_rounded),
    color: const Color(0xFFD6336C),
    background: const Color(0xFFFFE0EC),
    order: 30,
    // 투표 목록 패널(상단의 "투표 만들기"로 만들기 창이 열린다) — PC는 오른쪽 패널, 모바일은 전체 화면.
    onOpen: (context, session) => openSidePanel(context, session, 'polls'),
  ),
  MenuEntry(
    key: 'reminder',
    section: MenuSection.create,
    label: '리마인더',
    icon: const Icon(Icons.alarm_rounded),
    color: const Color(0xFFE8590C),
    background: const Color(0xFFFFE8D6),
    order: 40,
    // 내 리마인더 목록 패널(상단의 "+ 리마인더 생성"으로 만들기 창이 열린다) — PC는 오른쪽 패널, 모바일은 전체 화면.
    onOpen: (context, session) => openSidePanel(context, session, 'reminders'),
  ),

  // ── 리스트 ──
  MenuEntry(
    key: 'files',
    section: MenuSection.list,
    label: '파일',
    icon: const Icon(Icons.description_rounded),
    color: const Color(0xFF1FAE85),
    background: const Color(0xFFDCF5EB),
    order: 10,
    onOpen: (context, session) => openSidePanel(context, session, 'files'),
  ),
  MenuEntry(
    key: 'favorites',
    section: MenuSection.list,
    label: '즐겨찾기',
    icon: const Icon(Icons.star_rounded),
    color: const Color(0xFFE0A100),
    background: const Color(0xFFFFF1C2),
    order: 20,
    onOpen: (context, session) => openSidePanel(context, session, 'favorites'),
  ),
  MenuEntry(
    key: 'bookmarks',
    section: MenuSection.list,
    label: '북마크',
    icon: const Icon(Icons.bookmark_rounded),
    color: const Color(0xFFD9480F),
    background: const Color(0xFFFFE8D6),
    order: 30,
    onOpen: (context, session) => openSidePanel(context, session, 'bookmarks'),
  ),
  MenuEntry(
    key: 'links',
    section: MenuSection.list,
    label: '링크',
    // 비스듬히 세운 사슬(잔디 메뉴의 링크 아이콘과 같은 방향).
    icon: Transform.rotate(angle: -math.pi / 4, child: const Icon(Icons.link)),
    color: const Color(0xFF2F6FDB),
    background: const Color(0xFFDDEBFF),
    order: 40,
    onOpen: (context, session) => openSidePanel(context, session, 'links'),
  ),
  MenuEntry(
    key: 'myposts',
    section: MenuSection.list,
    label: '내가 쓴 글',
    icon: const Icon(Icons.edit_note_rounded),
    color: const Color(0xFF4263EB),
    background: const Color(0xFFDBE4FF),
    order: 50,
    onOpen: (context, session) => openSidePanel(context, session, 'myposts'),
  ),
  MenuEntry(
    key: 'albums',
    section: MenuSection.list,
    label: '앨범',
    icon: const Icon(Icons.photo_library_rounded),
    color: const Color(0xFF9C36B5),
    background: const Color(0xFFF3DCFA),
    order: 60,
    onOpen: (context, session) => openSidePanel(context, session, 'albums'),
  ),
  MenuEntry(
    key: 'inquiries',
    section: MenuSection.list,
    label: '문의함',
    icon: const Icon(Icons.contact_support_rounded),
    color: const Color(0xFFB86A00),
    background: const Color(0xFFFFE7C2),
    order: 70,
    // 받은 문의·보낸 문의 패널(상단의 "+ 팀장에게 문의하기"로 문의를 보낸다) — PC는 오른쪽 패널, 모바일은 전체 화면.
    onOpen: (context, session) => openSidePanel(context, session, 'inquiries'),
  ),

  // ── 툴 ──
  MenuEntry(
    key: 'calendar',
    section: MenuSection.tools,
    label: '캘린더',
    icon: const Icon(Icons.calendar_month_rounded),
    color: const Color(0xFFE03131),
    background: const Color(0xFFFFE3E3),
    order: 10,
    // PC는 사이드바+채팅 자리가 캘린더로 바뀌고(한 번 더 누르거나 방을 고르면 돌아온다), 모바일은 전체 화면.
    onOpen: (context, session) {
      final shell = HomeShellScope.maybeOf(context);
      if (shell != null) {
        shell.toggleCalendar();
      } else {
        openCalendarScreen(context, session);
      }
    },
  ),
  MenuEntry(
    key: 'groupware',
    section: MenuSection.tools,
    label: '그룹웨어',
    icon: const Icon(Icons.approval_rounded),
    color: const Color(0xFF5F3DC4),
    background: const Color(0xFFE5DBFF),
    order: 15,
    // 전자결재(휴가·지출·근태 수정)·연차·출퇴근 — 숫자는 내가 지금 결재할 문서 수(session.groupwarePending).
    badge: (session) => session.groupwarePending,
    onOpen: (context, session) => openGroupwareScreen(context, session),
  ),
  MenuEntry(
    key: 'project',
    section: MenuSection.tools,
    label: '프로젝트',
    icon: const Icon(Icons.track_changes),
    color: const Color(0xFF0C8599),
    background: const Color(0xFFD3F3F8),
    order: 20,
    // 안드로이드 앱에는 아직 프로젝트 화면이 없다(예전에도 모바일 앱바에는 프로젝트 버튼이 없었다).
    visible: (session) =>
        session.canUseProjects && !(AppPlatform.isAndroid || AppPlatform.isIOS),
    badge: (session) => session.projectUnread,
    // Windows는 독립된 OS 창(작업표시줄에 따로 뜨고 최소화/최대화/리사이즈가 된다)으로 열고, 그 외(안드로이드)는
    // 대화상자로 연다.
    onOpen: (context, session) => AppPlatform.isWindows
        ? openProjectWindow(session)
        : showProjectDialog(context, session),
  ),
];
