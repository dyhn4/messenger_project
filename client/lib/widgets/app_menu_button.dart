import 'package:flutter/material.dart';

import '../screens/inquiry_inbox_screen.dart';
import '../services/session.dart';

/// 상단 툴바의 "메뉴"(격자 아이콘) 팝업 — "파일"과 "문의함"을 모아둔다.
/// desktop_home_screen.dart의 _TopBar와 room_list_screen.dart(안드로이드) AppBar가 같이 쓴다.
/// [onOpenFiles]는 플랫폼마다 다르다 — PC는 우측 패널을 토글하고, 안드로이드는 전체화면으로
/// 새로 연다.
class AppMenuButton extends StatelessWidget {
  final Session session;
  final VoidCallback onOpenFiles;
  const AppMenuButton({
    super.key,
    required this.session,
    required this.onOpenFiles,
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
