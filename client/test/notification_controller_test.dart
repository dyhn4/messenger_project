import 'dart:async';

import 'package:client/models/announcement.dart';
import 'package:client/models/app_notification.dart';
import 'package:client/models/room.dart';
import 'package:client/services/notification_controller.dart';
import 'package:client/services/notification_entries.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_notification_api.dart';

/// 알림 센터 컨트롤러 — 탭별 목록 로딩, 무한 스크롤(before 커서), 읽음 처리, 소켓 갱신, 안 읽음 개수, 설정,
/// 프로젝트 알림함, 그리고 탭별로 줄을 섞는 buildCenterEntries.

class _Harness {
  final FakeNotificationApi api;
  final newEvents = StreamController<NotificationNewEvent>.broadcast();
  final syncEvents = StreamController<NotificationCounts>.broadcast();
  final projectEvents = StreamController<Map<String, dynamic>>.broadcast();
  final reconnected = StreamController<void>.broadcast();
  final newSeen = <AppNotification>[];
  final readSeen = <List<AppNotification>>[];
  final syncSeen = <NotificationCounts>[];
  late final NotificationController controller;

  _Harness(this.api) {
    controller = NotificationController(
      apiProvider: () => api,
      newEvents: newEvents.stream,
      syncEvents: syncEvents.stream,
      projectEvents: projectEvents.stream,
      reconnected: reconnected.stream,
      onNew: newSeen.add,
      onRead: readSeen.add,
      onSync: syncSeen.add,
    );
  }

  void dispose() {
    controller.dispose();
    newEvents.close();
    syncEvents.close();
    projectEvents.close();
    reconnected.close();
  }
}

_Harness _make(FakeNotificationApi api) {
  final h = _Harness(api);
  addTearDown(h.dispose);
  return h;
}

Room _room(
  String id, {
  int unread = 0,
  int activityMinutesAgo = 0,
  bool announcement = false,
  int announcementCount = 1,
  String teamId = 't1',
}) {
  final base = DateTime(2026, 9, 30, 12);
  return Room(
    id: id,
    teamId: teamId,
    type: RoomType.topic,
    name: '방-$id',
    members: const [],
    createdAt: DateTime(2026),
    lastRead: {},
    unreadCount: unread,
    lastActivityAt: base.subtract(Duration(minutes: activityMinutesAgo)),
    hasUnreadAnnouncement: announcement,
    unreadAnnouncementCount: announcement ? announcementCount : 0,
    latestAnnouncement: announcement
        ? Announcement(
            id: 'a-$id',
            roomId: id,
            authorName: '팀장',
            text: '공지-$id',
            createdAt: base.subtract(Duration(minutes: activityMinutesAgo + 1)),
          )
        : null,
  );
}

void main() {
  group('탭별 로딩', () {
    test('멘션 탭은 멘션만, 보드 탭은 보드만 받는다', () async {
      final api = FakeNotificationApi(
        items: [
          notif('m1', minutesAgo: 1),
          notif('mall', kind: NotificationKind.mentionAll, minutesAgo: 2),
          notif('b1', kind: NotificationKind.boardPost, minutesAgo: 3),
        ],
      );
      final c = _make(api).controller;
      await c.ensureLoaded(NotificationTab.mention);
      expect(c.itemsFor(NotificationTab.mention).map((n) => n.id), [
        'm1',
        'mall',
      ]);
      expect(api.calls.single, startsWith('fetch kind=mention'));
      await c.ensureLoaded(NotificationTab.board);
      expect(c.itemsFor(NotificationTab.board).map((n) => n.id), ['b1']);
      expect(api.callCount('fetch'), 2);
    });

    test('이미 받은 탭은 다시 받지 않고, refresh는 다시 받는다', () async {
      final api = FakeNotificationApi(items: [notif('m1')]);
      final c = _make(api).controller;
      await c.ensureLoaded(NotificationTab.mention);
      await c.ensureLoaded(NotificationTab.mention);
      expect(api.callCount('fetch'), 1);
      api.items.add(notif('m2', minutesAgo: 5));
      await c.refresh(NotificationTab.mention);
      expect(api.callCount('fetch'), 2);
      expect(c.itemsFor(NotificationTab.mention), hasLength(2));
    });

    test('전체 탭은 멘션+보드를 시간순으로 섞는다', () async {
      final api = FakeNotificationApi(
        items: [
          notif('m-old', minutesAgo: 30),
          notif('b-mid', kind: NotificationKind.boardComment, minutesAgo: 20),
          notif('m-new', minutesAgo: 10),
        ],
      );
      final c = _make(api).controller;
      await c.ensureLoaded(NotificationTab.all);
      expect(c.itemsFor(NotificationTab.all).map((n) => n.id), [
        'm-new',
        'b-mid',
        'm-old',
      ]);
      expect(c.isLoaded(NotificationTab.all), isTrue);
    });

    test('오류는 그 탭의 오류로 남고 다시 받으면 지워진다', () async {
      final api = FakeNotificationApi(items: [notif('m1')])..failWith = '서버 오류';
      final c = _make(api).controller;
      await c.ensureLoaded(NotificationTab.mention);
      expect(c.errorFor(NotificationTab.mention), '서버 오류');
      expect(c.isLoaded(NotificationTab.mention), isFalse);
      api.failWith = null;
      await c.refresh(NotificationTab.mention);
      expect(c.errorFor(NotificationTab.mention), isNull);
      expect(c.itemsFor(NotificationTab.mention), hasLength(1));
    });

    test('받는 동안은 isLoading, 끝나면 false', () async {
      final gate = Completer<void>();
      final api = FakeNotificationApi(items: [notif('m1')])
        ..fetchGate = gate.future;
      final c = _make(api).controller;
      final loading = c.ensureLoaded(NotificationTab.mention);
      expect(c.isLoading(NotificationTab.mention), isTrue);
      gate.complete();
      await loading;
      expect(c.isLoading(NotificationTab.mention), isFalse);
    });
  });

  group('무한 스크롤(before 커서)', () {
    FakeNotificationApi five() => FakeNotificationApi(
      items: [for (var i = 0; i < 5; i++) notif('m$i', minutesAgo: i)],
    );

    test('한 페이지가 차면 hasMore, loadMore가 가장 오래된 시각을 before로 이어 받는다', () async {
      final api = five();
      final c = _make(api).controller;
      // 기본 limit 30이라 한 번에 다 오므로, 페이지 크기를 줄인 가짜로 흉내 내지 않고 직접 쪼갠다.
      // (가짜 API의 limit을 쓰려고 컨트롤러 대신 API를 나눠 부른다.)
      final first = await api.fetchNotifications(kind: 'mention', limit: 2);
      expect(first.items.map((n) => n.id), ['m0', 'm1']);
      expect(first.hasMore, isTrue);
      final next = await api.fetchNotifications(
        kind: 'mention',
        limit: 2,
        before: first.items.last.createdAt.millisecondsSinceEpoch,
      );
      expect(next.items.map((n) => n.id), ['m2', 'm3']);
      await c.ensureLoaded(NotificationTab.mention);
      expect(c.hasMore(NotificationTab.mention), isFalse);
    });

    test('컨트롤러 loadMore — 다음 페이지를 붙이고 중복은 넣지 않는다', () async {
      final api = _PagedApi(
        pageSize: 2,
        items: [for (var i = 0; i < 5; i++) notif('m$i', minutesAgo: i)],
      );
      final c = _make(api).controller;
      await c.ensureLoaded(NotificationTab.mention);
      expect(c.itemsFor(NotificationTab.mention).map((n) => n.id), [
        'm0',
        'm1',
      ]);
      expect(c.hasMore(NotificationTab.mention), isTrue);
      await c.loadMore(NotificationTab.mention);
      expect(c.itemsFor(NotificationTab.mention).map((n) => n.id), [
        'm0',
        'm1',
        'm2',
        'm3',
      ]);
      // 두 번째 요청의 before는 첫 페이지에서 가장 오래된 알림(m1)의 시각이다.
      final second = api.calls.where((x) => x.startsWith('fetch')).last;
      expect(
        second,
        contains(
          'before=${notif('m1', minutesAgo: 1).createdAt.millisecondsSinceEpoch}',
        ),
      );
      await c.loadMore(NotificationTab.mention);
      expect(c.itemsFor(NotificationTab.mention), hasLength(5));
      expect(c.hasMore(NotificationTab.mention), isFalse);
      // 더 없으면 요청하지 않는다.
      final before = api.callCount('fetch');
      await c.loadMore(NotificationTab.mention);
      expect(api.callCount('fetch'), before);
    });

    test('전체 탭 병합 경계 — 더 받을 수 있는 목록의 가장 오래된 알림보다 오래된 줄은 아직 숨긴다', () async {
      final api = _PagedApi(
        pageSize: 2,
        items: [
          notif('m0', minutesAgo: 1),
          notif('m1', minutesAgo: 10),
          notif('m2', minutesAgo: 50),
          notif('b0', kind: NotificationKind.boardPost, minutesAgo: 2),
          notif('b1', kind: NotificationKind.boardPost, minutesAgo: 3),
          notif('b2', kind: NotificationKind.boardPost, minutesAgo: 4),
        ],
      );
      final c = _make(api).controller;
      await c.ensureLoaded(NotificationTab.all);
      // 멘션은 m1(10분 전)까지, 보드는 b1(3분 전)까지 받았고 둘 다 더 있다 → 경계는 더 새로운 3분 전.
      expect(
        c.mergeCutoffFor(NotificationTab.all),
        notif('b1', minutesAgo: 3).createdAt,
      );
      final entries = buildCenterEntries(
        tab: NotificationTab.all,
        center: c,
        unreadRooms: const [],
      );
      expect(entries.whereType<ServerEntry>().map((e) => e.notification.id), [
        'm0',
        'b0',
        'b1',
      ]);
      // 다음 페이지를 받으면 둘 다 끝까지 받았으니 경계가 없어지고 전부 보인다.
      await c.loadMore(NotificationTab.all);
      expect(c.mergeCutoffFor(NotificationTab.all), isNull);
      final all = buildCenterEntries(
        tab: NotificationTab.all,
        center: c,
        unreadRooms: const [],
      );
      expect(all.map((e) => (e as ServerEntry).notification.id), [
        'm0',
        'b0',
        'b1',
        'b2',
        'm1',
        'm2',
      ]);
    });
  });

  group('멘션·보드 알림 줄의 요약(serverNotificationSummary)', () {
    ({String lead, String body}) summary(
      NotificationKind kind, {
      String actor = '김철수',
      String preview = '9월 주간 보고',
    }) => serverNotificationSummary(
      notif('n', kind: kind, actor: actor, preview: preview),
    );

    test('멘션은 "보낸 사람: 미리보기" — "님이 멘션했습니다" 문구 없이 사람 이름을 보여 준다', () {
      for (final kind in [
        NotificationKind.mention,
        NotificationKind.mentionAll,
      ]) {
        final s = summary(kind, preview: '@나 확인 부탁');
        expect(s.lead, '김철수');
        expect(s.body, '@나 확인 부탁');
      }
    });

    test('새 글은 "작성자: 제목" — "새 글" 꼬리표를 붙이지 않는다', () {
      final s = summary(NotificationKind.boardPost);
      expect(s.lead, '김철수');
      expect(s.body, '9월 주간 보고');
    });

    test('글 수정은 "작성자 · 수정: 제목", 댓글은 "작성자 · 댓글: 내용"', () {
      expect(summary(NotificationKind.boardEdit).lead, '김철수 · 수정');
      expect(
        summary(NotificationKind.boardComment, preview: '확인했습니다').lead,
        '김철수 · 댓글',
      );
    });

    test('보낸 사람 이름을 모르면 이름 없이 꼬리표만 남는다', () {
      expect(summary(NotificationKind.mention, actor: '').lead, '');
      expect(summary(NotificationKind.boardEdit, actor: '').lead, '수정');
      expect(summary(NotificationKind.boardPost, actor: '  ').lead, '');
    });
  });

  group('안 읽은 것만 필터', () {
    test('켜면 unreadOnly로 새로 받고, 탭마다 따로다', () async {
      final api = FakeNotificationApi(
        items: [
          notif('m-unread', minutesAgo: 1),
          notif('m-read', minutesAgo: 2, read: true),
        ],
      );
      final c = _make(api).controller;
      await c.ensureLoaded(NotificationTab.mention);
      expect(c.itemsFor(NotificationTab.mention), hasLength(2));
      await c.setUnreadOnly(NotificationTab.mention, true);
      expect(c.unreadOnly(NotificationTab.mention), isTrue);
      expect(api.calls.last, contains('unreadOnly=true'));
      expect(c.itemsFor(NotificationTab.mention).map((n) => n.id), [
        'm-unread',
      ]);
      expect(c.unreadOnly(NotificationTab.board), isFalse);
      await c.setUnreadOnly(NotificationTab.mention, false);
      expect(c.itemsFor(NotificationTab.mention), hasLength(2));
    });

    test('선택은 이 기기에 사용자별로 저장되고, 다시 불러오면 그대로이며 다른 사용자에겐 안 보인다', () async {
      SharedPreferences.setMockInitialValues({});
      NotificationController make(String userId) {
        final c = NotificationController(
          apiProvider: () => FakeNotificationApi(items: []),
          userId: () => userId,
        );
        addTearDown(c.dispose);
        return c;
      }

      final first = make('u1');
      await first.setUnreadOnly(NotificationTab.mention, true);
      await first.setUnreadOnly(NotificationTab.project, true);
      await first.setUnreadOnly(NotificationTab.project, false);

      final again = make('u1');
      expect(again.unreadOnly(NotificationTab.mention), isFalse);
      await again.loadViewPrefs();
      expect(again.unreadOnly(NotificationTab.mention), isTrue);
      expect(again.unreadOnly(NotificationTab.project), isFalse);
      expect(again.unreadOnly(NotificationTab.board), isFalse);

      final other = make('u2');
      await other.loadViewPrefs();
      expect(other.unreadOnly(NotificationTab.mention), isFalse);
    });
  });

  group('멘션 탭 필터(전체 멘션 / @나를 멘션 / @all 멘션)', () {
    FakeNotificationApi mixed() => FakeNotificationApi(
      items: [
        notif('p1', minutesAgo: 1),
        notif('p2', minutesAgo: 4, read: true),
        notif('a1', kind: NotificationKind.mentionAll, minutesAgo: 2),
        notif('a2', kind: NotificationKind.mentionAll, minutesAgo: 3),
        notif('b1', kind: NotificationKind.boardPost, minutesAgo: 5),
      ],
    );

    test('기본은 전체 멘션 — kind=mention 하나로 두 종류를 받는다', () async {
      final api = mixed();
      final c = _make(api).controller;
      expect(c.mentionFilter, MentionFilter.all);
      await c.ensureLoaded(NotificationTab.mention);
      expect(api.calls.single, startsWith('fetch kind=mention '));
      expect(c.itemsFor(NotificationTab.mention).map((n) => n.id), [
        'p1',
        'a1',
        'a2',
        'p2',
      ]);
    });

    test('종류를 고르면 서버의 새 kind로 그 종류만 받고, 종류마다 목록·캐시가 따로다', () async {
      final api = mixed();
      final c = _make(api).controller;
      await c.ensureLoaded(NotificationTab.mention);
      await c.setMentionFilter(MentionFilter.everyone);
      expect(api.calls.last, startsWith('fetch kind=mention_all '));
      expect(c.itemsFor(NotificationTab.mention).map((n) => n.id), [
        'a1',
        'a2',
      ]);
      await c.setMentionFilter(MentionFilter.personal);
      expect(api.calls.last, startsWith('fetch kind=mention_personal '));
      expect(c.itemsFor(NotificationTab.mention).map((n) => n.id), [
        'p1',
        'p2',
      ]);
      // 받아 둔 종류로 돌아가면 다시 받지 않는다.
      final fetches = api.callCount('fetch');
      await c.setMentionFilter(MentionFilter.all);
      await c.setMentionFilter(MentionFilter.everyone);
      expect(api.callCount('fetch'), fetches);
      expect(c.itemsFor(NotificationTab.mention), hasLength(2));
    });

    test('종류별 페이지네이션 — 고른 종류의 before 커서로만 이어 받는다', () async {
      final api = FakeNotificationApi(
        items: [
          for (var i = 0; i < 35; i++)
            notif('a$i', kind: NotificationKind.mentionAll, minutesAgo: i + 10),
          notif('p1', minutesAgo: 1),
        ],
      );
      final c = _make(api).controller;
      await c.setMentionFilter(MentionFilter.everyone);
      expect(c.itemsFor(NotificationTab.mention), hasLength(30));
      expect(c.hasMore(NotificationTab.mention), isTrue);
      await c.loadMore(NotificationTab.mention);
      expect(api.calls.last, startsWith('fetch kind=mention_all before='));
      expect(c.itemsFor(NotificationTab.mention), hasLength(35));
      expect(c.hasMore(NotificationTab.mention), isFalse);
      // 개인 멘션 목록은 건드리지 않았다.
      await c.setMentionFilter(MentionFilter.personal);
      expect(c.itemsFor(NotificationTab.mention).map((n) => n.id), ['p1']);
    });

    test('탭 배지는 고른 종류의 안 읽은 개수, 전체 탭은 필터와 상관없이 합계', () async {
      final api = mixed();
      final c = _make(api).controller;
      await c.refreshCounts();
      expect(c.counts.mention, 3);
      expect(c.counts.mentionPersonal, 1);
      expect(c.counts.mentionAll, 2);
      int badge(NotificationTab t) => notificationTabBadge(
        t,
        center: c,
        unreadRooms: const [],
        projectUnread: 0,
      );
      expect(badge(NotificationTab.mention), 3);
      await c.setMentionFilter(MentionFilter.personal);
      expect(badge(NotificationTab.mention), 1);
      await c.setMentionFilter(MentionFilter.everyone);
      expect(badge(NotificationTab.mention), 2);
      // 전체 탭 = 멘션 3 + 보드 1.
      expect(badge(NotificationTab.all), 4);
    });

    test('전체 탭은 필터와 상관없이 멘션 두 종류를 모두 섞어 받는다', () async {
      final api = mixed();
      final c = _make(api).controller;
      await c.setMentionFilter(MentionFilter.personal);
      api.calls.clear();
      await c.ensureLoaded(NotificationTab.all);
      expect(
        api.calls.where((x) => x.startsWith('fetch kind=mention ')),
        hasLength(1),
      );
      expect(api.calls.where((x) => x.contains('mention_personal')), isEmpty);
      expect(c.itemsFor(NotificationTab.all).map((n) => n.id), [
        'p1',
        'a1',
        'a2',
        'p2',
        'b1',
      ]);
    });

    test('모두 읽음은 고른 종류만 — 서버 kind와 개수·목록 모두', () async {
      final api = mixed();
      final c = _make(api).controller;
      await c.refreshCounts();
      await c.ensureLoaded(NotificationTab.mention);
      await c.setMentionFilter(MentionFilter.everyone);
      await c.markAllRead(NotificationTab.mention);
      expect(api.lastReadKind, 'mention_all');
      expect(c.counts.mentionAll, 0);
      expect(c.counts.mentionPersonal, 1);
      expect(c.counts.mention, 1);
      expect(c.counts.board, 1);
      expect(
        c.itemsFor(NotificationTab.mention).every((n) => n.isRead),
        isTrue,
      );
      // 전체 멘션 목록에서도 개인 멘션은 그대로 안 읽음.
      await c.setMentionFilter(MentionFilter.all);
      final unread = c
          .itemsFor(NotificationTab.mention)
          .where((n) => !n.isRead);
      expect(unread.map((n) => n.id), ['p1']);
      // 개인 멘션만.
      await c.setMentionFilter(MentionFilter.personal);
      await c.markAllRead(NotificationTab.mention);
      expect(api.lastReadKind, 'mention_personal');
      expect(c.counts, const NotificationCounts(board: 1));
    });

    test('전체 멘션의 모두 읽음은 kind=mention — 두 종류 모두', () async {
      final api = mixed();
      final h = _make(api);
      final c = h.controller;
      await c.refreshCounts();
      await c.ensureLoaded(NotificationTab.mention);
      await c.markAllRead(NotificationTab.mention);
      expect(api.lastReadKind, 'mention');
      expect(c.counts.mention, 0);
      expect(c.counts.mentionPersonal, 0);
      expect(c.counts.mentionAll, 0);
      expect(h.syncSeen.last.mention, 0);
    });

    test('안 읽은 것만 표시는 고른 종류를 따른다', () async {
      final api = mixed();
      final c = _make(api).controller;
      await c.setMentionFilter(MentionFilter.personal);
      await c.setUnreadOnly(NotificationTab.mention, true);
      expect(api.calls.last, startsWith('fetch kind=mention_personal '));
      expect(api.calls.last, contains('unreadOnly=true'));
      expect(c.itemsFor(NotificationTab.mention).map((n) => n.id), ['p1']);
    });

    test('하나를 읽으면 그 종류의 개수만 줄고, 소켓으로 온 새 알림은 맞는 종류 목록에만 끼는다', () async {
      final api = mixed();
      final h = _make(api);
      final c = h.controller;
      await c.refreshCounts();
      await c.ensureLoaded(NotificationTab.mention);
      await c.setMentionFilter(MentionFilter.everyone);
      await c.setMentionFilter(MentionFilter.personal);
      final a1 = c.itemsFor(NotificationTab.mention).first; // p1
      await c.markRead(a1);
      expect(c.counts.mentionPersonal, 0);
      expect(c.counts.mentionAll, 2);
      expect(c.counts.mention, 2);

      // 개수 없이 온 @all 알림 — @all 목록(받아 둔)에만 끼고 개인 목록엔 안 낀다.
      final fresh = notif('a-new', kind: NotificationKind.mentionAll);
      h.newEvents.add(NotificationNewEvent(fresh, null));
      await Future<void>.delayed(Duration.zero);
      expect(c.counts.mentionAll, 3);
      expect(c.counts.mentionPersonal, 0);
      expect(c.itemsFor(NotificationTab.mention).map((n) => n.id), [
        'p1',
        'p2',
      ]);
      await c.setMentionFilter(MentionFilter.everyone);
      expect(c.itemsFor(NotificationTab.mention).first.id, 'a-new');
    });

    test('sync로 @all이 0이 되면 받아 둔 @all 줄만 읽음으로', () async {
      final api = mixed();
      final h = _make(api);
      final c = h.controller;
      await c.refreshCounts();
      await c.ensureLoaded(NotificationTab.mention);
      h.syncEvents.add(NotificationCounts.of(mentionPersonal: 1, board: 1));
      await Future<void>.delayed(Duration.zero);
      final items = c.itemsFor(NotificationTab.mention);
      expect(items.where((n) => !n.isRead).map((n) => n.id), ['p1']);
    });

    test('선택은 이 기기에 사용자별로 저장되고 다시 불러오면 그대로, 다른 사용자에겐 기본, reset하면 기본', () async {
      SharedPreferences.setMockInitialValues({});
      NotificationController make(String userId) {
        final c = NotificationController(
          apiProvider: () => FakeNotificationApi(items: []),
          userId: () => userId,
        );
        addTearDown(c.dispose);
        return c;
      }

      final first = make('u1');
      await first.setMentionFilter(MentionFilter.everyone);

      final again = make('u1');
      expect(again.mentionFilter, MentionFilter.all);
      await again.loadViewPrefs();
      expect(again.mentionFilter, MentionFilter.everyone);

      final other = make('u2');
      await other.loadViewPrefs();
      expect(other.mentionFilter, MentionFilter.all);

      // 전체 멘션으로 되돌리면 저장값도 지워진다.
      await first.setMentionFilter(MentionFilter.all);
      final third = make('u1');
      await third.loadViewPrefs();
      expect(third.mentionFilter, MentionFilter.all);

      again.reset();
      expect(again.mentionFilter, MentionFilter.all);
    });

    test('필터 이름·메뉴 글자·서버 kind', () {
      expect(
        [for (final f in MentionFilter.values) f.wire],
        ['mention', 'mention_personal', 'mention_all'],
      );
      expect(
        [for (final f in MentionFilter.values) f.menuLabel],
        ['전체 멘션', '@나를 멘션', '@all 멘션'],
      );
      expect(
        [for (final f in MentionFilter.values) f.tabLabel],
        ['멘션', '@나', '@all'],
      );
    });
  });

  group('읽음 처리', () {
    test('하나 읽음 — 목록·개수를 먼저 바꾸고 서버에 ids로 알린다', () async {
      final api = FakeNotificationApi(
        items: [notif('m1'), notif('m2', minutesAgo: 1)],
      );
      final h = _make(api);
      final c = h.controller;
      await c.refreshCounts();
      await c.ensureLoaded(NotificationTab.mention);
      expect(c.counts.mention, 2);
      final first = c.itemsFor(NotificationTab.mention).first;
      await c.markRead(first);
      expect(first.isRead, isTrue);
      expect(c.counts.mention, 1);
      expect(api.lastReadIds, ['m1']);
      expect(h.readSeen.single.single.id, 'm1');
      // 이미 읽은 것은 다시 보내지 않는다.
      await c.markRead(first);
      expect(api.callCount('read'), 1);
    });

    test('같은 알림이 전체·멘션 목록 양쪽에 있어도 둘 다 읽음으로 바뀐다', () async {
      final api = FakeNotificationApi(items: [notif('m1')]);
      final c = _make(api).controller;
      await c.ensureLoaded(NotificationTab.mention);
      await c.ensureLoaded(NotificationTab.all);
      final inAll = c.itemsFor(NotificationTab.all).single;
      await c.markRead(inAll);
      expect(c.itemsFor(NotificationTab.mention).single.isRead, isTrue);
    });

    test('모두 읽음 — 멘션 탭은 kind=mention만, 전체 탭은 둘 다', () async {
      final api = FakeNotificationApi(
        items: [
          notif('m1'),
          notif('b1', kind: NotificationKind.boardPost, minutesAgo: 1),
        ],
      );
      final c = _make(api).controller;
      await c.refreshCounts();
      await c.ensureLoaded(NotificationTab.all);
      expect(c.totalUnread, 2);
      await c.markAllRead(NotificationTab.mention);
      expect(api.lastReadKind, 'mention');
      expect(c.counts, const NotificationCounts(mention: 0, board: 1));
      await c.markAllRead(NotificationTab.all);
      expect(api.calls.where((x) => x.startsWith('read')).length, 3);
      expect(c.counts, const NotificationCounts());
      expect(c.itemsFor(NotificationTab.all).every((n) => n.isRead), isTrue);
    });

    test('서버가 거절하면 개수를 다시 받아 맞춘다', () async {
      final api = FakeNotificationApi(items: [notif('m1')]);
      final c = _make(api).controller;
      await c.refreshCounts();
      await c.ensureLoaded(NotificationTab.mention);
      api.failWith = '실패';
      await c.markRead(c.itemsFor(NotificationTab.mention).single);
      api.failWith = null;
      // 개수는 서버 기준(아직 안 읽음 1)으로 돌아와야 하지만, 실패 중의 counts 재조회도 실패라 낙관값이 남는다.
      expect(api.callCount('counts'), 2);
    });
  });

  group('소켓', () {
    test('notification:new — 받아 둔 같은 종류 목록 맨 앞에 끼우고 개수를 맞춘다', () async {
      final api = FakeNotificationApi(items: [notif('m1', minutesAgo: 5)]);
      final h = _make(api);
      final c = h.controller;
      await c.ensureLoaded(NotificationTab.mention);
      await c.ensureLoaded(NotificationTab.board);
      h.newEvents.add(
        NotificationNewEvent(
          notif('m2', minutesAgo: 0),
          const NotificationCounts(mention: 2, board: 0),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.itemsFor(NotificationTab.mention).map((n) => n.id), [
        'm2',
        'm1',
      ]);
      expect(c.itemsFor(NotificationTab.board), isEmpty);
      expect(c.counts.mention, 2);
      expect(h.newSeen.single.id, 'm2');
      // 같은 알림이 다시 와도 두 번 넣지 않는다.
      h.newEvents.add(
        NotificationNewEvent(notif('m2'), const NotificationCounts(mention: 2)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.itemsFor(NotificationTab.mention), hasLength(2));
    });

    test('notification:new — 보드 알림은 보드 목록으로, 개수가 없으면 하나 올린다', () async {
      final api = FakeNotificationApi();
      final h = _make(api);
      final c = h.controller;
      await c.ensureLoaded(NotificationTab.board);
      h.newEvents.add(
        NotificationNewEvent(
          notif('b1', kind: NotificationKind.boardComment),
          null,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.itemsFor(NotificationTab.board).single.id, 'b1');
      expect(c.counts.board, 1);
    });

    test('아직 안 받은 탭에는 끼우지 않는다(처음 열 때 서버에서 받는다)', () async {
      final h = _make(FakeNotificationApi());
      h.newEvents.add(NotificationNewEvent(notif('m1'), null));
      await Future<void>.delayed(Duration.zero);
      expect(h.controller.isLoaded(NotificationTab.mention), isFalse);
      expect(h.controller.counts.mention, 1);
    });

    test('notification:sync — 개수를 바꾸고, 0이 되면 받아 둔 목록도 읽음으로', () async {
      final api = FakeNotificationApi(
        items: [notif('m1'), notif('m2', minutesAgo: 1)],
      );
      final h = _make(api);
      final c = h.controller;
      await c.refreshCounts();
      await c.ensureLoaded(NotificationTab.mention);
      h.syncEvents.add(const NotificationCounts(mention: 1, board: 0));
      await Future<void>.delayed(Duration.zero);
      expect(c.counts.mention, 1);
      expect(
        c.itemsFor(NotificationTab.mention).every((n) => !n.isRead),
        isTrue,
      );
      h.syncEvents.add(const NotificationCounts());
      await Future<void>.delayed(Duration.zero);
      expect(c.counts.mention, 0);
      expect(
        c.itemsFor(NotificationTab.mention).every((n) => n.isRead),
        isTrue,
      );
      expect(h.syncSeen.last, const NotificationCounts());
    });

    test('재연결하면 개수와 받아 둔 목록을 다시 받는다', () async {
      final api = FakeNotificationApi(items: [notif('m1')]);
      final h = _make(api);
      await h.controller.ensureLoaded(NotificationTab.mention);
      api.items.add(notif('m2', minutesAgo: 1));
      h.reconnected.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(h.controller.itemsFor(NotificationTab.mention), hasLength(2));
      expect(h.controller.counts.mention, 2);
    });
  });

  group('프로젝트 알림함', () {
    test('불러오기·하나 읽음·전체 읽음', () async {
      final api = FakeNotificationApi(
        project: [projectNotif('p1'), projectNotif('p2', minutesAgo: 1)],
      );
      final c = _make(api).controller;
      await c.ensureLoaded(NotificationTab.project);
      expect(c.project, hasLength(2));
      expect(c.projectUnread, 2);
      final left = await c.markProjectRead(ids: ['p1']);
      expect(left, 1);
      expect(c.project.first.read, isTrue);
      expect(api.calls.last, 'project-read ids=[p1]');
      await c.markProjectRead();
      expect(c.projectUnread, 0);
    });

    test('프로젝트 소켓 알림이 오면(이미 열어 둔 탭만) 다시 받는다', () async {
      final api = FakeNotificationApi(project: [projectNotif('p1')]);
      final h = _make(api);
      h.projectEvents.add({'title': 'x'});
      await Future<void>.delayed(Duration.zero);
      expect(api.callCount('project'), 0);
      await h.controller.ensureLoaded(NotificationTab.project);
      api.project.add(projectNotif('p2', minutesAgo: 3));
      h.projectEvents.add({'title': 'x'});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(h.controller.project, hasLength(2));
    });
  });

  group('설정', () {
    test('불러오고, 바꾸면 서버에 일부 필드만 보낸다', () async {
      final api = FakeNotificationApi(
        settings: const NotificationSettings(
          mentionAll: true,
          boardLevel: BoardNotifyLevel.important,
        ),
      );
      final c = _make(api).controller;
      await c.loadSettings();
      expect(c.settings!.mentionAll, isTrue);
      expect(c.settings!.boardLevel, BoardNotifyLevel.important);
      await c.updateSettings(mentionAll: false);
      expect(api.calls.last, 'update mentionAll=false boardLevel=null');
      expect(c.settings!.mentionAll, isFalse);
      expect(c.settings!.boardLevel, BoardNotifyLevel.important);
      await c.updateSettings(boardLevel: BoardNotifyLevel.newPosts);
      expect(api.calls.last, 'update mentionAll=null boardLevel=new');
      expect(c.settings!.boardLevel, BoardNotifyLevel.newPosts);
    });

    test('서버가 거절하면 되돌리고 예외를 다시 던진다', () async {
      final api = FakeNotificationApi();
      final c = _make(api).controller;
      await c.loadSettings();
      api.failWith = '허용되지 않는 값';
      expect(c.settings!.boardLevel, BoardNotifyLevel.important); // 기본값
      await expectLater(
        c.updateSettings(boardLevel: BoardNotifyLevel.all),
        throwsA(anything),
      );
      expect(c.settings!.boardLevel, BoardNotifyLevel.important);
    });

    test('보드 알림 수준 문구와 와이어 값', () {
      expect(BoardNotifyLevel.all.wire, 'all');
      expect(BoardNotifyLevel.important.wire, 'important');
      expect(BoardNotifyLevel.newPosts.wire, 'new');
      expect(boardLevelFromWire('new'), BoardNotifyLevel.newPosts);
      // 모르는 값·없는 값은 기본값(important).
      expect(boardLevelFromWire('?'), BoardNotifyLevel.important);
      expect(boardLevelFromWire(null), BoardNotifyLevel.important);
      expect(BoardNotifyLevel.values.map((l) => l.label), [
        '전체',
        '중요 알림',
        '새 글 알림',
      ]);
      for (final l in BoardNotifyLevel.values) {
        expect(l.description, isNotEmpty);
      }
    });
  });

  group('로그아웃(reset)', () {
    test('받아 둔 것을 비우고 이전 요청의 늦은 응답은 버린다', () async {
      final gate = Completer<void>();
      final api = FakeNotificationApi(items: [notif('m1')])
        ..fetchGate = gate.future;
      final c = _make(api).controller;
      final loading = c.ensureLoaded(NotificationTab.mention);
      c.reset();
      gate.complete();
      await loading;
      expect(c.itemsFor(NotificationTab.mention), isEmpty);
      expect(c.isLoaded(NotificationTab.mention), isFalse);
      expect(c.counts, const NotificationCounts());
      expect(c.settings, isNull);
    });
  });

  group('알림 JSON', () {
    test('Notification DTO·소켓 이벤트·설정을 규약 모양대로 읽는다', () {
      final n = AppNotification.fromJson({
        'id': 'n1',
        'kind': 'mention_all',
        'teamId': 't1',
        'teamName': '영업팀',
        'roomId': 'r1',
        'roomName': '공지방',
        'messageId': 'm1',
        'commentId': null,
        'actorId': 'u2',
        'actorName': '김철수',
        'preview': '@all 회의',
        'createdAt': 1000,
        'readAt': null,
        'roomType': 'topic',
      });
      expect(n.kind, NotificationKind.mentionAll);
      expect(n.isMention, isTrue);
      expect(n.isBoard, isFalse);
      expect(n.isRead, isFalse);
      expect(n.roomType, 'topic');
      expect(n.createdAt.millisecondsSinceEpoch, 1000);
      final read = AppNotification.fromJson({
        'id': 'n2',
        'kind': 'board_edit',
        'teamId': 't1',
        'createdAt': 1,
        'readAt': 5,
      });
      expect(read.isBoard, isTrue);
      expect(read.isRead, isTrue);
      // 모르는 종류도 깨지지 않는다.
      final other = AppNotification.fromJson({
        'id': 'n3',
        'kind': 'poll_closed',
        'teamId': 't',
        'createdAt': 1,
      });
      expect(other.kind, NotificationKind.other);
      expect(other.kindWire, 'poll_closed');
      expect(other.isMention || other.isBoard, isFalse);

      final event = NotificationNewEvent.fromJson({
        'notification': {
          'id': 'n1',
          'kind': 'mention',
          'teamId': 't1',
          'createdAt': 1,
        },
        'unread': {'mention': 3, 'board': 1},
      });
      expect(event.notification.id, 'n1');
      expect(event.unread, const NotificationCounts(mention: 3, board: 1));
      expect(
        NotificationCounts.fromJson({'mention': 2}),
        const NotificationCounts(mention: 2),
      );
      expect(NotificationCounts.fromJson(null), const NotificationCounts());
      // 새 서버는 종류별 개수를 함께 준다 — 옛 키(mention=합계)도 그대로.
      final split = NotificationCounts.fromJson({
        'mention': 5,
        'board': 1,
        'mentionPersonal': 2,
        'mentionAll': 3,
      });
      expect(split.mention, 5);
      expect(split.mentionPersonal, 2);
      expect(split.mentionAll, 3);
      expect(split.board, 1);
      expect(
        split,
        NotificationCounts.of(mentionPersonal: 2, mentionAll: 3, board: 1),
      );
      // 옛 서버(종류별 개수 없음)는 합계를 전부 개인 멘션으로 본다.
      final legacy = NotificationCounts.fromJson({'mention': 4, 'board': 0});
      expect(legacy.mentionPersonal, 4);
      expect(legacy.mentionAll, 0);

      final s = NotificationSettings.fromJson({
        'mentionAll': false,
        'boardLevel': 'all',
      });
      expect(s.mentionAll, isFalse);
      expect(s.boardLevel, BoardNotifyLevel.all);
      expect(
        NotificationSettings.fromJson(const {}).boardLevel,
        BoardNotifyLevel.important,
      );
    });
  });

  group('buildCenterEntries·notificationTabBadge', () {
    Future<_Harness> loaded() async {
      final api = FakeNotificationApi(
        items: [
          notif('m-old', minutesAgo: 60),
          notif('b-new', kind: NotificationKind.boardPost, minutesAgo: 5),
        ],
        project: [projectNotif('p-mid', minutesAgo: 30)],
      );
      final h = _make(api);
      await h.controller.refreshCounts();
      await h.controller.ensureLoaded(NotificationTab.all);
      await h.controller.ensureLoaded(NotificationTab.project);
      return h;
    }

    final rooms = [
      _room('chat-old', unread: 3, activityMinutesAgo: 40),
      _room('chat-new', unread: 1, activityMinutesAgo: 2),
      _room('ann-only', announcement: true, activityMinutesAgo: 90),
      _room('both', unread: 2, announcement: true, activityMinutesAgo: 15),
    ];

    test('안 읽은 대화 탭 — 예전 알림 센터 그대로: 안 읽은 메시지·공지가 있는 방을 마지막 활동순으로', () async {
      final h = await loaded();
      final entries = buildCenterEntries(
        tab: NotificationTab.unreadChats,
        center: h.controller,
        unreadRooms: rooms,
      );
      expect(entries.every((e) => e is RoomEntry), isTrue);
      expect(entries.map((e) => (e as RoomEntry).room.id), [
        'chat-new',
        'both',
        'chat-old',
        'ann-only',
      ]);
    });

    test('멘션 탭은 서버 멘션만', () async {
      final h = await loaded();
      final entries = buildCenterEntries(
        tab: NotificationTab.mention,
        center: h.controller,
        unreadRooms: rooms,
      );
      expect(entries.map((e) => (e as ServerEntry).notification.id), ['m-old']);
    });

    test('보드·공지 탭은 보드 알림 + 안 읽은 공지를 공지 시각순으로', () async {
      final h = await loaded();
      final entries = buildCenterEntries(
        tab: NotificationTab.board,
        center: h.controller,
        unreadRooms: rooms,
      );
      expect(
        entries.map(
          (e) => switch (e) {
            ServerEntry(:final notification) => notification.id,
            AnnouncementEntry(:final room) => 'ann:${room.id}',
            _ => '?',
          },
        ),
        ['b-new', 'ann:both', 'ann:ann-only'],
      );
    });

    test('프로젝트 탭은 프로젝트 알림함 — 안 읽은 것만 필터를 따른다', () async {
      final h = await loaded();
      var entries = buildCenterEntries(
        tab: NotificationTab.project,
        center: h.controller,
        unreadRooms: rooms,
      );
      expect(entries.single, isA<ProjectEntry>());
      await h.controller.markProjectRead();
      await h.controller.setUnreadOnly(NotificationTab.project, true);
      entries = buildCenterEntries(
        tab: NotificationTab.project,
        center: h.controller,
        unreadRooms: rooms,
      );
      expect(entries, isEmpty);
    });

    test('전체 탭은 넷을 시간순으로 — 공지만 안 읽은 방은 대화 줄 없이 공지 줄로만', () async {
      final h = await loaded();
      final entries = buildCenterEntries(
        tab: NotificationTab.all,
        center: h.controller,
        unreadRooms: rooms,
      );
      String label(CenterEntry e) => switch (e) {
        ServerEntry(:final notification) => notification.id,
        RoomEntry(:final room) => 'chat:${room.id}',
        AnnouncementEntry(:final room) => 'ann:${room.id}',
        ProjectEntry(:final notification) => notification.id,
      };
      // chat-new 2분 전, b-new 5분 전, both의 공지 16분 전, both 대화 15분 전, p-mid 30분 전, chat-old 40분 전,
      // m-old 60분 전, ann-only 공지 91분 전.
      expect(entries.map(label), [
        'chat:chat-new',
        'b-new',
        'chat:both',
        'ann:both',
        'p-mid',
        'chat:chat-old',
        'm-old',
        'ann:ann-only',
      ]);
      expect(
        entries.whereType<RoomEntry>().any((e) => e.room.id == 'ann-only'),
        isFalse,
      );
    });

    test('탭 배지 — 멘션·보드(+공지)·안 읽은 대화·프로젝트·전체', () async {
      final h = await loaded();
      int badge(NotificationTab t) => notificationTabBadge(
        t,
        center: h.controller,
        unreadRooms: rooms,
        projectUnread: 4,
      );
      expect(badge(NotificationTab.mention), 1);
      // 보드 1 + 공지 2곳(각 1).
      expect(badge(NotificationTab.board), 3);
      expect(badge(NotificationTab.unreadChats), 4);
      expect(badge(NotificationTab.project), 4);
      // 멘션 1 + 보드 3 + 메시지가 있는 방 3 + 프로젝트 4.
      expect(badge(NotificationTab.all), 1 + 3 + 3 + 4);
    });
  });
}

/// 페이지 크기를 고정한 가짜 — 컨트롤러의 기본 limit(30) 대신 작은 페이지로 무한 스크롤을 시험한다.
class _PagedApi extends FakeNotificationApi {
  final int pageSize;
  _PagedApi({required this.pageSize, super.items});

  @override
  Future<({List<AppNotification> items, bool hasMore})> fetchNotifications({
    required String kind,
    int? before,
    int limit = 30,
    bool unreadOnly = false,
  }) => super.fetchNotifications(
    kind: kind,
    before: before,
    limit: pageSize,
    unreadOnly: unreadOnly,
  );
}
