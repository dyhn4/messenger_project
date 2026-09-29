import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../screens/inquiry_inbox_screen.dart';
import '../services/session.dart';

/// 상단 툴바의 "메뉴"(격자 아이콘) 팝업 — "파일", "링크", "문의함"을 모아둔다.
/// desktop_home_screen.dart의 _TopBar와 room_list_screen.dart(안드로이드) AppBar가 같이 쓴다.
/// [onOpenFiles]는 플랫폼마다 다르다 — PC는 우측 패널을 토글하고, 안드로이드는 전체화면으로
/// 새로 연다. [onOpenLinks]("링크" — 주고받은 링크 모아보기)도 같다.
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

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<void>(
      icon: const Icon(Icons.apps),
      tooltip: '메뉴',
      position: PopupMenuPosition.under,
      offset: const Offset(0, 10),
      itemBuilder: (context) => [
        PopupMenuItem(
          onTap: onOpenFiles,
          child: const Row(
            children: [_FileTypeIcon(), SizedBox(width: 8), Text('파일')],
          ),
        ),
        PopupMenuItem(
          onTap: onOpenLinks,
          child: const Row(
            children: [_LinkTypeIcon(), SizedBox(width: 8), Text('링크')],
          ),
        ),
        PopupMenuItem(
          onTap: () => showInquiryInboxScreen(context, session),
          child: const Row(
            children: [_InquiryTypeIcon(), SizedBox(width: 8), Text('문의함')],
          ),
        ),
      ],
    );
  }
}

/// "파일" 항목 앞에 붙는 색깔 있는 아이콘 — 민트색 둥근 배경 위에 진한 민트색 문서 아이콘.
class _FileTypeIcon extends StatelessWidget {
  const _FileTypeIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: const Color(0xFFDCF5EB),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: const Icon(
        Icons.description_rounded,
        size: 16,
        color: Color(0xFF1FAE85),
      ),
    );
  }
}

/// "링크" 항목 앞에 붙는 색깔 있는 아이콘 — 하늘색 둥근 배경 위에 진한 파란색 사슬(비스듬히
/// 세운 링크 모양 — 잔디 메뉴의 링크 아이콘과 같은 방향).
class _LinkTypeIcon extends StatelessWidget {
  const _LinkTypeIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: const Color(0xFFDDEBFF),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Transform.rotate(
        angle: -math.pi / 4,
        child: const Icon(Icons.link, size: 20, color: Color(0xFF2F6FDB)),
      ),
    );
  }
}

/// "문의함" 항목 앞에 붙는 색깔 있는 아이콘 — 주황색 둥근 배경 위에 진한 주황색 문의 아이콘.
class _InquiryTypeIcon extends StatelessWidget {
  const _InquiryTypeIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: const Color(0xFFFFE7C2),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: const Icon(
        Icons.contact_support_rounded,
        size: 16,
        color: Color(0xFFB86A00),
      ),
    );
  }
}
