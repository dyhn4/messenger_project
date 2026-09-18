import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../screens/admin_console_screen.dart';
import '../screens/invite_link_screen.dart';
import '../screens/my_profile_dialog.dart';
import '../screens/settings_screen.dart';
import '../services/session.dart';
import 'app_toast.dart';
import 'my_avatar.dart';

const _appVersion = '1.0.0';

/// 잔디식 우측 상단 삼선(햄버거) 메뉴: 계정 정보 + 설정 + 오픈소스 라이선스 + 로그아웃을
/// 아이콘 하나에 모아둔다.
class AccountMenuButton extends StatelessWidget {
  final Session session;
  const AccountMenuButton({super.key, required this.session});

  Future<void> _logout(BuildContext context) async {
    await session.logout();
    // 이 버튼이 push된 화면 위에 있을 수도 있으니, 로그인 화면이 보이도록
    // 루트까지 화면 스택을 걷어낸다.
    if (context.mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  /// 서버 설치 프로그램이 같이 깔아주는 "도움말"(README.html)을 기본 브라우저로 연다 — 그
  /// 파일은 서버 PC 로컬 디스크에만 있어서(server/certs.js 주석 참고), 앱이 서버와 다른
  /// PC에서 실행 중이어도 볼 수 있게 서버를 거쳐서 받는다(version.js의 GET /help).
  Future<void> _openHelp(BuildContext context) async {
    final base = session.serverUrl;
    if (base == null) return;
    final ok = await launchUrl(
      Uri.parse('$base/help'),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && context.mounted) {
      showAppToast(context, '도움말 문서를 열 수 없습니다.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<void>(
      icon: const Icon(Icons.menu),
      tooltip: '설정',
      position: PopupMenuPosition.under,
      offset: const Offset(0, 10),
      itemBuilder: (context) => [
        PopupMenuItem<void>(
          onTap: () => showDialog(
            context: context,
            builder: (_) => MyProfileDialog(session: session),
          ),
          child: Row(
            children: [
              MyAvatar(session: session, radius: 14),
              const SizedBox(width: 8),
              Text(
                session.name ?? session.username ?? '',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<void>(
          onTap: () => showDialog(
            context: context,
            builder: (_) => SettingsScreen(session: session),
          ),
          child: const Row(
            children: [
              Icon(Icons.settings_outlined),
              SizedBox(width: 8),
              Text('설정'),
            ],
          ),
        ),
        // 서버 운영자·계정 관리자·팀 소유자에게만 보인다(서버도 매 요청마다 다시 확인 —
        // invites.js의 canCreateInviteLink). 관리자 콘솔과 달리 팀 소유자도 만들 수 있어야
        // 해서 서버 운영자 전용인 "서버 관리"와는 다른 조건을 쓴다.
        if (session.canCreateInviteLink)
          PopupMenuItem<void>(
            onTap: () => showInviteLinkScreen(context, session),
            child: const Row(
              children: [
                Icon(Icons.add_link),
                SizedBox(width: 8),
                Text('초대 링크 생성'),
              ],
            ),
          ),
        // 팀 초대 링크 생성은 팀 설정(팀 정보 탭)으로 옮겼다 — 이미 어느 팀인지 정해진
        // 곳에서 만드는 게 더 자연스러워서(team_settings_dialog.dart).
        // 서버 운영자에게만 보이는 항목(서버도 매 요청마다 다시 확인한다 — admin.js).
        if (session.isServerAdmin)
          PopupMenuItem<void>(
            onTap: () => showAdminConsole(context, session),
            child: const Row(
              children: [
                Icon(Icons.admin_panel_settings_outlined),
                SizedBox(width: 8),
                Text('서버 관리'),
              ],
            ),
          ),
        // 서버 설치 시 같이 깔리는 "도움말" 바로가기(README.html)를 앱에서도 볼 수 있게 —
        // 서버 운영자만 쓸 일이 있어서 "서버 관리"와 같은 조건으로 묶는다.
        if (session.isServerAdmin)
          PopupMenuItem<void>(
            onTap: () => _openHelp(context),
            child: const Row(
              children: [
                Icon(Icons.help_outline),
                SizedBox(width: 8),
                Text('도움말'),
              ],
            ),
          ),
        PopupMenuItem<void>(
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'TangoTalk',
            applicationVersion: _appVersion,
          ),
          child: const Row(
            children: [
              Icon(Icons.description_outlined),
              SizedBox(width: 8),
              Text('오픈소스 라이선스'),
            ],
          ),
        ),
        PopupMenuItem<void>(
          onTap: () => _logout(context),
          child: const Row(
            children: [
              Icon(Icons.logout, color: Colors.redAccent),
              SizedBox(width: 8),
              Text('로그아웃', style: TextStyle(color: Colors.redAccent)),
            ],
          ),
        ),
      ],
    );
  }
}
