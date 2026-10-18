import 'package:flutter/material.dart';

import '../services/session.dart';
import 'update_dialog.dart';
import '../l10n/tr.dart';

/// 앱을 쓰는 동안 화면 위쪽 가운데에 계속 떠 있는 업데이트 알림 알약 — 로그인 화면/홈 화면이
/// 앱을 막 열었을 때 한 번 띄우는 모달(UpdateDialog)과 달리, 그걸 "나중에"로 닫고 계속
/// 쓰는 동안에도 잊지 않도록 은근하게 계속 보여준다. main.dart의 MaterialApp.builder에서
/// 전체 화면 위에 얹어서, 어느 화면(채팅방, 다이얼로그 포함)에 있든 항상 보인다. 누르면
/// 설치 대화상자(UpdateDialog)를 열고, X를 누르면 이번 실행 동안만(재시작하면 다시 보임)
/// 닫는다.
class UpdateBanner extends StatefulWidget {
  final Session session;

  /// main.dart의 MaterialApp에 물린 것과 같은 키 — 이 배너 자체가 Navigator와 형제 자리라
  /// (아래 InkWell.onTap 주석 참고) 자기 build context로 showDialog를 열면 "No Navigator
  /// found"로 조용히 실패한다. 알림 눌러 통화 화면을 여는 main.dart의 showCallScreen 호출과
  /// 같은 방식으로, 이 키의 currentContext(Navigator 위젯 자신의 context — Navigator.of()가
  /// 자기 자신도 찾아주므로 유효하다)를 대신 쓴다.
  final GlobalKey<NavigatorState> navigatorKey;
  const UpdateBanner({
    super.key,
    required this.session,
    required this.navigatorKey,
  });

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final version = widget.session.updateAvailableVersion;
        if (version == null || _dismissed) return const SizedBox.shrink();
        final colors = Theme.of(context).colorScheme;
        return SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Material(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(24),
                elevation: 3,
                child: InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: () {
                    final dialogContext =
                        widget.navigatorKey.currentContext ?? context;
                    showDialog<void>(
                      context: dialogContext,
                      builder: (_) => UpdateDialog(
                        session: widget.session,
                        version: version,
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 6, 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.system_update_outlined,
                          size: 18,
                          color: colors.onPrimaryContainer,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          tr('v{version} 업데이트가 있습니다.', {'version': version}),
                          style: TextStyle(
                            color: colors.onPrimaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 2),
                        IconButton(
                          icon: Icon(
                            Icons.close,
                            size: 16,
                            color: colors.onPrimaryContainer,
                          ),
                          // tooltip을 넣으면 안 된다 — 이 배너는 main.dart의
                          // MaterialApp.builder에서 Navigator와 형제로 붙는 자리라
                          // (다이얼로그 위에도 계속 떠 있어야 해서 일부러 그렇게 뒀다) Navigator가
                          // 만드는 Overlay의 자손이 아니다. Tooltip은 Overlay 조상이 꼭 있어야
                          // 해서 "No Overlay widget found" 에러로 화면이 깨진다.
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 28,
                            minHeight: 28,
                          ),
                          onPressed: () => setState(() => _dismissed = true),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
