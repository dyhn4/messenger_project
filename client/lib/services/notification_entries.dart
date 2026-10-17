import '../models/app_notification.dart';
import '../models/groupware.dart' show ApprovalNotification;
import '../models/project.dart' show ProjectNotification;
import '../models/room.dart';
import 'notification_controller.dart';

/// 메시지 탭(안 읽은 대화)에 보여 줄 안 읽은 방인지.
///   - 보드 뷰 토픽은 뺀다 — 거기 올라온 새 글·수정·댓글은 보드 알림(보드·공지 탭)으로 따로 오고, 채팅이 아니다.
///   - 안 읽은 메시지가 전부 나를 멘션한 것이면(안 읽은 멘션 수만큼) 그 알림이 멘션 탭에 이미 있어서 뺀다.
///     멘션 말고도 안 읽은 메시지가 있으면 방은 그대로 보인다. [Room.unreadMentionCount]는 서버가 센 이 방의
///     안 읽은 멘션 알림 수다.
bool isUnreadChatRoom(Room room) =>
    !room.isBoard && room.unreadCount > room.unreadMentionCount;

/// 메시지 탭 줄의 미리보기 한 줄 — 사람이 여럿인 방(그룹채팅·토픽)에서는 "보낸 사람: 미리보기"로, 1:1이나
/// 비밀 대화는 미리보기만(상대가 뻔하거나 서버가 내용을 모른다).
String roomPreviewLine(Room room) {
  final preview = room.lastMessagePreview ?? '';
  final sender = room.lastMessageSenderName;
  final multi = room.type == RoomType.group || room.type == RoomType.topic;
  if (!multi || room.isSecret || sender == null || sender.isEmpty) {
    return preview;
  }
  return preview.isEmpty ? preview : '$sender: $preview';
}

/// 멘션·보드 알림 줄의 두 번째 줄 — [lead]는 굵게 보이는 앞부분(보낸 사람 이름 + 필요하면 " · 수정"/" · 댓글"),
/// [body]는 미리보기다. 화면은 `$lead: $body`로 이어서 그린다.
///   - 멘션(@all 포함)·새 글: "보낸 사람: 미리보기" — 새 글에는 "새 글" 같은 꼬리표를 붙이지 않는다.
///   - 글 수정: "작성자 · 수정: 미리보기", 댓글: "작성자 · 댓글: 미리보기".
/// 보낸 사람 이름을 모르면(탈퇴 등) 이름 없이 꼬리표만 남는다.
({String lead, String body}) serverNotificationSummary(AppNotification n) {
  final actor = (n.actorName ?? '').trim();
  final label = switch (n.kind) {
    NotificationKind.boardEdit => '수정',
    NotificationKind.boardComment => '댓글',
    _ => '',
  };
  final lead = [
    if (actor.isNotEmpty) actor,
    if (label.isNotEmpty) label,
  ].join(' · ');
  return (lead: lead, body: n.preview);
}

/// 알림 센터 목록의 한 줄 — 서로 다른 출처(서버 알림·안 읽은 대화·안 읽은 공지·프로젝트 알림·결재 알림)를 한 목록에 섞어
/// 보여 주려고 같은 모양으로 감싼다. 어느 줄이든 [time](정렬 기준)과 [unread]가 있다.
sealed class CenterEntry {
  const CenterEntry();
  DateTime get time;
  bool get unread;
}

/// 멘션·보드 알림 한 건(서버 notifications 표).
final class ServerEntry extends CenterEntry {
  final AppNotification notification;
  const ServerEntry(this.notification);
  @override
  DateTime get time => notification.createdAt;
  @override
  bool get unread => !notification.isRead;
}

/// 안 읽은 메시지가 있는 방 — 시각은 마지막 활동 시각.
final class RoomEntry extends CenterEntry {
  final Room room;
  const RoomEntry(this.room);
  @override
  DateTime get time => room.lastActivityAt;
  @override
  bool get unread => true;
}

/// 안 읽은 공지가 있는 방 — 시각은 공지가 올라온 시각(없으면 마지막 활동 시각).
final class AnnouncementEntry extends CenterEntry {
  final Room room;
  const AnnouncementEntry(this.room);
  @override
  DateTime get time =>
      room.latestAnnouncement?.createdAt ?? room.lastActivityAt;
  @override
  bool get unread => true;
}

/// 프로젝트 알림함의 한 건.
final class ProjectEntry extends CenterEntry {
  final ProjectNotification notification;
  const ProjectEntry(this.notification);
  @override
  DateTime get time => notification.createdAt;
  @override
  bool get unread => !notification.read;
}

/// 결재 알림함의 한 건(결재 요청·승인·반려·회수·취소).
final class ApprovalEntry extends CenterEntry {
  final ApprovalNotification notification;
  const ApprovalEntry(this.notification);
  @override
  DateTime get time => notification.createdAt;
  @override
  bool get unread => !notification.read;
}

/// [tab]에 보여 줄 줄들(최신순).
///
///   - 안 읽은 대화(메시지 탭): 안 읽은 메시지가 있는 방 전부(지금 팀도, 여러 팀에 걸쳐), 마지막 활동순. 공지는 메시지가
///     아니라 보드·공지 탭(공지 줄)으로만 간다 — 공지만 안 읽은 방은 여기 없다.
///   - 멘션: 서버 멘션 알림(멘션 탭 드롭다운에서 고른 종류만 — [NotificationController.mentionFilter]).
///   - 보드·공지: 서버 보드 알림 + 안 읽은 공지가 있는 방(공지 시각).
///   - 프로젝트: 프로젝트 알림함.
///   - 결재: 결재 알림함(그룹웨어 전자결재).
///   - 전체: 위 다섯을 시간순으로 섞는다.
///
/// [unreadRooms]는 Session.unreadRooms. [center]의 "안 읽은 것만" 필터가 켜져 있으면 서버 목록은 이미 안
/// 읽은 것만 받아 왔고, 프로젝트·결재 알림은 여기서 걸러낸다(방·공지는 원래 전부 안 읽은 것이다).
List<CenterEntry> buildCenterEntries({
  required NotificationTab tab,
  required NotificationController center,
  required List<Room> unreadRooms,
}) {
  final unreadOnly = center.unreadOnly(tab);
  List<ProjectEntry> project() => [
    for (final n in center.project)
      if (!unreadOnly || !n.read) ProjectEntry(n),
  ];
  List<ApprovalEntry> approval() => [
    for (final n in center.approval)
      if (!unreadOnly || !n.read) ApprovalEntry(n),
  ];
  List<AnnouncementEntry> announcements() => [
    for (final r in unreadRooms)
      if (r.hasUnreadAnnouncement) AnnouncementEntry(r),
  ];

  switch (tab) {
    case NotificationTab.unreadChats:
      // 안 읽은 메시지가 있는 방(멘션만 안 읽은 방은 멘션 탭에 있으니 뺀다). 공지는 보드·공지 탭 몫이다.
      return [
        for (final r in _byActivity(unreadRooms))
          if (isUnreadChatRoom(r)) RoomEntry(r),
      ];
    case NotificationTab.mention:
      return [for (final n in center.itemsFor(tab)) ServerEntry(n)];
    case NotificationTab.project:
      return project();
    case NotificationTab.approval:
      return approval();
    case NotificationTab.board:
    case NotificationTab.all:
      final entries = <CenterEntry>[
        for (final n in center.itemsFor(tab)) ServerEntry(n),
        ...announcements(),
        if (tab == NotificationTab.all) ...[
          for (final r in unreadRooms)
            if (isUnreadChatRoom(r)) RoomEntry(r),
          ...project(),
          ...approval(),
        ],
      ]..sort((a, b) => b.time.compareTo(a.time));
      // 서버 목록이 아직 더 있으면, 받아 둔 가장 오래된 알림보다 오래된 줄은 그 뒤에 나올 새 알림이 끼어들 자리라
      // 미리 보이지 않게 한다(순서가 뒤집히지 않게 — NotificationController.mergeCutoffFor).
      final cutoff = center.mergeCutoffFor(tab);
      if (cutoff == null) return entries;
      return [
        for (final e in entries)
          if (!e.time.isBefore(cutoff)) e,
      ];
  }
}

List<Room> _byActivity(List<Room> rooms) =>
    [...rooms]..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));

/// 탭 배지에 쓸 안 읽음 수.
///   - 멘션·보드: 서버가 센 개수(멘션은 고른 필터 종류만 — 전체 멘션/@나를 멘션/@all 멘션, 보드는 안 읽은 공지 수를
///     더한다). 전체 탭은 멘션 필터와 상관없이 멘션 두 종류의 합이다.
///   - 안 읽은 대화: 안 읽은 메시지가 있는 방의 수(공지는 보드에 센다).
///   - 프로젝트: [projectUnread](Session.projectUnread — 소켓으로 실시간).
///   - 결재: [approvalUnread](Session.approvalUnread — 소켓으로 실시간).
///   - 전체: 다섯의 합.
int notificationTabBadge(
  NotificationTab tab, {
  required NotificationController center,
  required List<Room> unreadRooms,
  required int projectUnread,
  int approvalUnread = 0,
}) {
  final announcements = unreadRooms
      .where((r) => r.hasUnreadAnnouncement)
      .fold<int>(
        0,
        (sum, r) =>
            sum +
            (r.unreadAnnouncementCount > 0 ? r.unreadAnnouncementCount : 1),
      );
  final board = center.counts.board + announcements;
  return switch (tab) {
    NotificationTab.mention => center.mentionUnread(center.mentionFilter),
    NotificationTab.board => board,
    NotificationTab.unreadChats => unreadRooms.where(isUnreadChatRoom).length,
    NotificationTab.project => projectUnread,
    NotificationTab.approval => approvalUnread,
    NotificationTab.all =>
      center.counts.mention +
          board +
          unreadRooms.where(isUnreadChatRoom).length +
          projectUnread +
          approvalUnread,
  };
}
