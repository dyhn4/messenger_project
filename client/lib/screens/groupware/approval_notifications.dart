import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../project/project_notifications.dart' show projectNotificationAgo;
import 'approval_tab.dart' show showApprovalDetail;
import '../../l10n/tr.dart';

/// 결재 알림 종류의 아이콘과 색 — 알림 센터 "결재" 탭의 줄 앞 동그라미.
({IconData icon, Color color}) approvalNotificationLook(
  ApprovalNotificationKind kind,
  ColorScheme scheme,
) => switch (kind) {
  ApprovalNotificationKind.request => (
    icon: Icons.approval_outlined,
    color: scheme.primary,
  ),
  ApprovalNotificationKind.approved => (
    icon: Icons.check_circle_outline,
    color: Colors.green,
  ),
  ApprovalNotificationKind.rejected => (
    icon: Icons.cancel_outlined,
    color: Colors.redAccent,
  ),
  ApprovalNotificationKind.withdrawn => (
    icon: Icons.undo,
    color: scheme.outline,
  ),
  ApprovalNotificationKind.canceled => (
    icon: Icons.block,
    color: Colors.orange,
  ),
  ApprovalNotificationKind.other => (
    icon: Icons.notifications_none,
    color: scheme.outline,
  ),
};

/// 결재 알림 한 줄(알림 센터 "결재"·"전체" 탭) — 프로젝트 알림 줄(ProjectNotificationTile)과 같은 모양. 지금 내 결재 차례인 요청
/// 알림에는 "결재 차례" 꼬리표가 붙고(처리했거나 회수되면 사라진다), 팀 단위 결재면 팀 이름이 본문 앞에 붙는다.
class ApprovalNotificationTile extends StatelessWidget {
  final ApprovalNotification notification;
  final VoidCallback onTap;
  const ApprovalNotificationTile({
    super.key,
    required this.notification,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final n = notification;
    final scheme = Theme.of(context).colorScheme;
    final hint = Theme.of(context).hintColor;
    final look = approvalNotificationLook(n.kind, scheme);
    final team = (n.teamName ?? '').trim();
    return ListTile(
      dense: true,
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: look.color.withValues(alpha: 0.15),
        child: Icon(look.icon, size: 16, color: look.color),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              n.title.isNotEmpty ? trServer(n.title) : tr('결재'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: n.read ? FontWeight.normal : FontWeight.bold,
              ),
            ),
          ),
          if (n.actionable)
            Container(
              key: ValueKey('approval-notif-turn-${n.id}'),
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                tr('결재 차례'),
                style: TextStyle(
                  fontSize: 10,
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
        ],
      ),
      subtitle: Text(
        team.isEmpty ? trServer(n.body) : '[$team] ${trServer(n.body)}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: n.read ? hint : null),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            projectNotificationAgo(n.createdAt),
            style: TextStyle(color: hint, fontSize: 11),
          ),
          if (!n.read)
            Container(
              margin: const EdgeInsets.only(top: 6),
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: Colors.redAccent,
                shape: BoxShape.circle,
              ),
            ),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// 알림 센터 결재 탭의 줄을 눌렀을 때 — 그 문서 상세를 연다(읽음 처리는 부른 쪽이 먼저 한다).
Future<void> openApprovalFromNotification(
  BuildContext context,
  Session session,
  ApprovalNotification n,
) => openApprovalDocument(
  context,
  session,
  documentId: n.documentId,
  teamId: n.teamId,
);

/// 결재 문서 [documentId]의 상세를 연다 — 문서의 팀 [teamId](회사 전체 범위면 null — 지금 팀)로 그룹웨어 범위를 받아서. 상세에서
/// 승인·반려 등을 했으면 메뉴의 결재 뱃지를 다시 센다. 열었으면 true.
///
/// [markRead]면(푸시·PC 알림을 눌러 온 경우) 그 문서의 내 결재 알림을 읽음으로 바꾼다 — 알림 센터 줄을 누른 게 아니라 어느 알림
/// 줄인지 모른다. 못 열면 [onError]로 사유를 알린다(없으면 [context]에 토스트 — 앱 최상단 Navigator의 context처럼 토스트를 그릴
/// 수 없는 곳에서는 Session.showToast를 넘긴다).
Future<bool> openApprovalDocument(
  BuildContext context,
  Session session, {
  required String documentId,
  String? teamId,
  bool markRead = false,
  void Function(String message)? onError,
}) async {
  final client = session.api;
  if (client == null) return false;
  final api = GroupwareApi(client, teamId: teamId ?? session.currentTeam?.id);
  if (markRead) {
    unawaited(
      api
          .markNotificationsRead(documentId: documentId)
          .then((_) => session.refreshApprovalUnread())
          .catchError((_) {}),
    );
  }
  final GroupwareContext ctx;
  try {
    ctx = await api.context();
  } catch (e) {
    final message = tr('결재 문서를 열지 못했습니다: {e}', {'e': e});
    if (onError != null) {
      onError(message);
    } else if (context.mounted) {
      showAppToast(context, message);
    }
    return false;
  }
  if (!context.mounted) return false;
  final changed = await showApprovalDetail(
    context,
    api: api,
    ctx: ctx,
    session: session,
    documentId: documentId,
  );
  if (changed) unawaited(session.refreshGroupwarePending());
  return true;
}
