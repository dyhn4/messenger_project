import 'package:flutter/material.dart';

import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/floating_dialog.dart';
import '../../widgets/muted_scrollbar.dart';

/// 공개 프로젝트 둘러보기 — 아직 참여하지 않은 이 팀의 공개 프로젝트를 보고 초대 없이 "참여"한다
/// (정회원 이상만 목록이 보인다). 참여하면 그 프로젝트를 돌려준다.
Future<Project?> showBrowseProjectsDialog(
  BuildContext context,
  Session session,
  String teamId,
) {
  return showDialog<Project>(
    context: context,
    builder: (_) => _BrowseProjectsDialog(session: session, teamId: teamId),
  );
}

class _BrowseProjectsDialog extends StatefulWidget {
  final Session session;
  final String teamId;
  const _BrowseProjectsDialog({required this.session, required this.teamId});

  @override
  State<_BrowseProjectsDialog> createState() => _BrowseProjectsDialogState();
}

class _BrowseProjectsDialogState extends State<_BrowseProjectsDialog> {
  List<Project>? _projects;
  String? _error;
  String? _joiningId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.session.api!.browsePublicProjects(
        widget.teamId,
      );
      if (mounted) setState(() => _projects = list);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _join(Project project) async {
    setState(() => _joiningId = project.id);
    try {
      final joined = await widget.session.api!.joinProject(project.id);
      if (mounted) Navigator.of(context).pop(joined);
    } catch (e) {
      if (mounted) {
        setState(() => _joiningId = null);
        showAppToast(context, '참여하지 못했습니다: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final projects = _projects;
    return FloatingDialog(
      title: '공개 프로젝트 둘러보기',
      maxWidth: 480,
      maxHeight: 560,
      child: _error != null
          ? Center(child: Text(_error!))
          : projects == null
          ? const Center(child: CircularProgressIndicator())
          : projects.isEmpty
          ? Center(
              child: Text(
                '참여할 수 있는 공개 프로젝트가 없습니다.',
                style: TextStyle(color: hint),
              ),
            )
          : MutedScrollbar(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: projects.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final p = projects[i];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: parseTypeColor(p.color),
                        shape: BoxShape.circle,
                      ),
                    ),
                    title: Text(
                      p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      [
                        p.identifier,
                        if (p.memberCount != null) '구성원 ${p.memberCount}명',
                        if (p.description != null) p.description!,
                      ].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: FilledButton(
                      onPressed: _joiningId == null ? () => _join(p) : null,
                      child: _joiningId == p.id
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('참여'),
                    ),
                  );
                },
              ),
            ),
    );
  }
}
