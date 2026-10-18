import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../services/session.dart';
import 'muted_scrollbar.dart';
import 'pagination.dart';
import 'user_avatar.dart';
import 'user_status_dialogs.dart';
import '../l10n/tr.dart';

/// 상단 "팀 멤버" 버튼으로 여는 우측 패널(side_panels.dart의 'members'). 검색 패널과 같은 틀(헤더+검색창+목록)을 쓰고,
/// 각 멤버를 카드로 보여준다. 카드를 누르면 프로필 플로팅 다이얼로그가 뜬다.
class TeamMembersPanel extends StatefulWidget {
  final Session session;
  final VoidCallback onClose;
  final ValueChanged<AppUser> onSelectMember;
  const TeamMembersPanel({
    super.key,
    required this.session,
    required this.onClose,
    required this.onSelectMember,
  });

  @override
  State<TeamMembersPanel> createState() => _TeamMembersPanelState();
}

class _TeamMembersPanelState extends State<TeamMembersPanel> {
  final _listScrollController = ScrollController();
  List<AppUser>? _users;
  String? _error;
  String _filter = '';
  int _page = 0; // 0-based.

  @override
  void initState() {
    super.initState();
    _load();
    // onlineUserIds가 바뀔 때마다(누가 접속/해제) 초록 점을 다시 그리도록 다시 빌드한다.
    widget.session.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    _listScrollController.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final users = await widget.session.fetchTeamMembers();
      users.sort((a, b) => a.name.compareTo(b.name));
      if (!mounted) return;
      setState(() => _users = users);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = (_users ?? const <AppUser>[])
        .where(
          (u) =>
              _filter.isEmpty ||
              u.name.toLowerCase().contains(_filter.toLowerCase()),
        )
        .toList();
    final totalPages = list.isEmpty
        ? 1
        : (list.length / paginationPageSize).ceil();
    final page = _page.clamp(0, totalPages - 1);
    final pageItems = list
        .skip(page * paginationPageSize)
        .take(paginationPageSize)
        .toList();

    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _users == null
                        ? tr('팀 멤버')
                        : tr('팀 멤버 총 {p0}명', {'p0': _users!.length}),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              decoration: InputDecoration(
                hintText: tr('멤버 검색'),
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18),
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() {
                _filter = v;
                _page = 0;
              }),
            ),
          ),
          Expanded(
            child: _error != null
                ? Center(child: Text(_error!))
                : _users == null
                ? const Center(child: CircularProgressIndicator())
                : list.isEmpty
                ? Center(child: Text(tr('검색 결과가 없습니다.')))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Divider(height: 1),
                      Expanded(
                        child: MutedScrollbar(
                          controller: _listScrollController,
                          child: ListView.separated(
                            controller: _listScrollController,
                            itemCount: pageItems.length,
                            // 오른쪽 끝에 겹치는 스크롤바 아래로 선이 파고들지 않도록 그만큼 짧게 그린다.
                            separatorBuilder: (_, _) => const Padding(
                              padding: EdgeInsets.only(right: 12),
                              child: Divider(height: 1),
                            ),
                            itemBuilder: (context, i) => TeamMemberRow(
                              session: widget.session,
                              user: pageItems[i],
                              resolveUrl: widget.session.resolveUrl,
                              online: widget.session.onlineUserIds.contains(
                                pageItems[i].id,
                              ),
                              onTap: () => widget.onSelectMember(pageItems[i]),
                            ),
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      Pagination(
                        currentPage: page,
                        totalPages: totalPages,
                        onPageSelected: (p) => setState(() => _page = p),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// 멤버 목록 한 줄: 아바타 + 이름. 카드 테두리 없이 ListView.separated의 Divider로만
/// 서로 구분한다(검색 결과 화면과 같은 스타일).
class TeamMemberRow extends StatelessWidget {
  /// 상태 메시지·방해 금지를 보여 주는 데 쓴다(없으면 안 보인다).
  final Session? session;
  final AppUser user;
  final String Function(String relative) resolveUrl;
  final bool online;
  final VoidCallback onTap;
  const TeamMemberRow({
    super.key,
    this.session,
    required this.user,
    required this.resolveUrl,
    required this.online,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            UserAvatar(
              user: user,
              resolveUrl: resolveUrl,
              radius: 20,
              online: online,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          user.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      // 상태 이모지·방해 금지 달(마우스를 올리면 상태 글).
                      if (session != null)
                        UserStatusBadge(session: session!, userId: user.id),
                    ],
                  ),
                  // 부서·직책이 등록돼 있으면 조직도답게 이름 아래 같이 보여준다.
                  if (user.orgLine != null)
                    Text(
                      user.orgLine!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                  // 상태 글이 있으면 한 줄로(이름 옆 이모지만으로는 무슨 상태인지 모른다).
                  if (session?.statusOf(user.id)?.text case final text?)
                    Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
