import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../screens/admin_console_screen.dart';
import '../screens/invite_link_screen.dart';
import '../screens/my_profile_dialog.dart';
import '../screens/settings_screen.dart';
import '../services/session.dart';
import 'app_toast.dart';
import 'compact_menu.dart';
import 'my_avatar.dart';
import 'user_status_dialogs.dart';
import '../l10n/tr.dart';

const _appVersion = '1.0.0';

/// 초보자용 "도움말"(server/guide/)을 평문 페어링 서버(메인 포트+1 — 초대 링크 안내 페이지가
/// 있는 곳, server/src/pairing.js)에서 여는 주소. 메인 서버는 자체 서명 인증서라 브라우저가
/// "안전하지 않음" 경고부터 띄우는데, 처음 쓰는 사람에게 그 화면을 보여주면 안 돼서다.
/// 페어링 서버 포트 계산은 pinned_tls.dart의 pairAndSaveCert와 같다.
@visibleForTesting
Uri plainGuideUri(String serverUrl) {
  final uri = Uri.parse(serverUrl);
  return Uri(
    scheme: 'http',
    host: uri.host,
    port: (uri.hasPort ? uri.port : 443) + 1,
    path: '/guide/',
  );
}

Future<bool> _launchExternal(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// 평문 페어링 서버가 도움말을 서빙하는지 짧게 확인한다(구버전 서버는 없을 수 있음).
Future<bool> _probePlainGuide(Uri uri) async {
  try {
    final res = await http.head(uri).timeout(const Duration(seconds: 2));
    return res.statusCode == 200;
  } catch (_) {
    return false;
  }
}

/// 잔디식 우측 상단 삼선(햄버거) 메뉴: 계정 정보 + 설정 + 오픈소스 라이선스 + 로그아웃을
/// 아이콘 하나에 모아둔다.
class AccountMenuButton extends StatelessWidget {
  final Session session;
  const AccountMenuButton({super.key, required this.session});

  /// 기본 브라우저로 주소를 여는 함수 — 테스트가 실제 브라우저 대신 연 주소를 기록하도록
  /// 바꿔 끼운다.
  @visibleForTesting
  static Future<bool> Function(Uri uri) openExternal = _launchExternal;

  /// [plainGuideUri]가 응답하는지 확인하는 함수(테스트에서 바꿔 끼운다).
  @visibleForTesting
  static Future<bool> Function(Uri uri) probePlainGuide = _probePlainGuide;

  Future<void> _logout(BuildContext context) async {
    await session.logout();
    // 이 버튼이 push된 화면 위에 있을 수도 있으니, 로그인 화면이 보이도록
    // 루트까지 화면 스택을 걷어낸다.
    if (context.mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  /// 초보자용 "도움말"(server/guide/ — 모든 회원)을 기본 브라우저로 연다. 인증서 경고가 없는
  /// 평문 페어링 서버가 도움말을 서빙하면 그쪽을, 아니면 메인 서버의 /guide/를 연다.
  Future<void> _openGuide(BuildContext context) async {
    final base = session.serverUrl;
    if (base == null) return;
    final plain = plainGuideUri(base);
    final target = await probePlainGuide(plain)
        ? plain
        : Uri.parse(base).replace(path: '/guide/');
    final ok = await openExternal(target);
    if (!ok && context.mounted) {
      showAppToast(context, tr('도움말을 열 수 없습니다.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    // 메뉴가 닫힌 뒤에도(비동기로 링크를 받는 동안) 토스트를 띄울 수 있도록, 팝업 안의
    // context가 아니라 버튼 자신의 context를 쓴다.
    final buttonContext = context;
    // 채팅 목록 우클릭 메뉴와 같은 간결한 모양(compact_menu.dart) — 항목 묶음(내 프로필 /
    // 설정·관리 / 도움말·안내 / 로그아웃) 사이에 구분선.
    return PopupMenuButton<void>(
      icon: const Icon(Icons.menu),
      tooltip: tr('설정'),
      position: PopupMenuPosition.under,
      offset: const Offset(0, 10),
      color: CompactMenu.color(context),
      shape: CompactMenu.shape,
      menuPadding: CompactMenu.menuPadding,
      constraints: CompactMenu.constraints,
      itemBuilder: (context) => [
        PopupMenuItem<void>(
          onTap: () => showDialog(
            context: context,
            builder: (_) => MyProfileDialog(session: session),
          ),
          height: 40,
          padding: CompactMenu.itemPadding,
          child: Row(
            children: [
              MyAvatar(session: session, radius: 12),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  session.name ?? session.username ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CompactMenu.textStyle.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (session.userId != null)
                UserStatusBadge(session: session, userId: session.userId!),
            ],
          ),
        ),
        // 상태 메시지("🗓️ 회의 중")와 방해 금지 — 같은 팀 사람들에게 보이고, 방해 금지 중에는 알림이 오지 않는다.
        CompactMenu.item<void>(
          context,
          icon: Icons.emoji_emotions_outlined,
          label: myStatusMenuLabel(session),
          onTap: () => showStatusDialog(buttonContext, session),
        ),
        CompactMenu.item<void>(
          context,
          icon: session.notificationsPaused
              ? Icons.notifications_paused
              : Icons.notifications_paused_outlined,
          label: myDndMenuLabel(session),
          onTap: () => showDndDialog(buttonContext, session),
        ),
        CompactMenu.divider,
        CompactMenu.item<void>(
          context,
          icon: Icons.settings_outlined,
          label: tr('환경설정'),
          onTap: () => showDialog(
            context: context,
            builder: (_) => SettingsScreen(session: session),
          ),
        ),
        // 서버 운영자·계정 관리자·팀 소유자에게만 보인다(서버도 매 요청마다 다시 확인 —
        // invites.js의 canCreateInviteLink). 관리자 콘솔과 달리 팀 소유자도 만들 수 있어야
        // 해서 서버 운영자 전용인 "서버 관리"와는 다른 조건을 쓴다.
        if (session.canCreateInviteLink)
          CompactMenu.item<void>(
            context,
            icon: Icons.add_link,
            label: tr('초대 링크 생성'),
            onTap: () => showInviteLinkScreen(context, session),
          ),
        // 팀 초대 링크 생성은 팀 설정(팀 정보 탭)으로 옮겼다 — 이미 어느 팀인지 정해진
        // 곳에서 만드는 게 더 자연스러워서(team_settings_dialog.dart).
        // 서버 운영자에게만 보이는 항목(서버도 매 요청마다 다시 확인한다 — admin.js).
        if (session.isServerAdmin)
          CompactMenu.item<void>(
            context,
            icon: Icons.admin_panel_settings_outlined,
            label: tr('서버 관리'),
            onTap: () => showAdminConsole(context, session),
          ),
        CompactMenu.divider,
        // 초보자용 도움말(메신저·프로젝트 이용법 웹페이지) — 모든 회원에게 보인다.
        CompactMenu.item<void>(
          context,
          icon: Icons.help_outline,
          label: tr('도움말'),
          onTap: () => _openGuide(buttonContext),
        ),
        CompactMenu.item<void>(
          context,
          icon: Icons.description_outlined,
          label: tr('오픈소스 라이선스'),
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'TangoTalk',
            applicationVersion: _appVersion,
          ),
        ),
        CompactMenu.divider,
        CompactMenu.item<void>(
          context,
          icon: Icons.logout,
          label: tr('로그아웃'),
          color: Colors.redAccent,
          onTap: () => _logout(context),
        ),
      ],
    );
  }
}
