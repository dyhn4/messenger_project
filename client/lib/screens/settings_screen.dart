import 'package:flutter/material.dart';

import '../services/session.dart';

const _appVersion = '1.0.0';

class SettingsScreen extends StatelessWidget {
  final Session session;
  const SettingsScreen({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text(session.username ?? ''),
            subtitle: const Text('로그인 계정'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('오픈소스 라이선스'),
            subtitle: const Text('이 앱이 사용하는 오픈소스 패키지 및 라이선스 고지'),
            onTap: () {
              showLicensePage(
                context: context,
                applicationName: '메신저',
                applicationVersion: _appVersion,
              );
            },
          ),
        ],
      ),
    );
  }
}
