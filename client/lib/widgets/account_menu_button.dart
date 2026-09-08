import 'package:flutter/material.dart';

import '../screens/my_profile_dialog.dart';
import '../screens/settings_screen.dart';
import '../services/session.dart';
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
        PopupMenuItem<void>(
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'TeamTalk',
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
