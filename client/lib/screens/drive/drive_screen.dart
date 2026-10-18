import 'dart:async';

import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../models/drive.dart';
import '../../services/api_client.dart' show ApiClient, ApiException;
import '../../services/app_platform.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/attachment_widgets.dart'
    show DropZoneOverlay, saveAttachment;
import '../../widgets/dropped_files.dart';
import '../../l10n/tr.dart';

/// 팀 공유 드라이브 열기 — 지금 팀의 드라이브(서버 drive.js).
Future<void> openDriveScreen(BuildContext context, Session session) {
  final team = session.currentTeam;
  if (team == null) {
    showAppToast(context, tr('팀을 먼저 고르세요.'));
    return Future.value();
  }
  return Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) =>
          DriveScreen(session: session, teamId: team.id, teamName: team.name),
    ),
  );
}

String _date(DateTime? d) => d == null ? '' : '${d.year}/${d.month}/${d.day}';

IconData driveFileIcon(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return switch (ext) {
    'png' ||
    'jpg' ||
    'jpeg' ||
    'gif' ||
    'webp' ||
    'bmp' => Icons.image_outlined,
    'pdf' => Icons.picture_as_pdf_outlined,
    'doc' ||
    'docx' ||
    'hwp' ||
    'hwpx' ||
    'txt' ||
    'md' => Icons.description_outlined,
    'xls' || 'xlsx' || 'csv' => Icons.table_chart_outlined,
    'ppt' || 'pptx' => Icons.slideshow_outlined,
    'zip' || '7z' || 'rar' => Icons.folder_zip_outlined,
    'mp4' || 'mov' || 'webm' => Icons.movie_outlined,
    'mp3' || 'wav' || 'm4a' => Icons.audiotrack_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}

/// 팀 공유 드라이브 — 폴더를 오가며 파일을 올리고(같은 이름이면 새 판), 내려받고, 판 기록을 보고 되돌리고, 이름 바꾸기·옮기기·
/// 휴지통을 한다. PC는 화면에 파일을 끌어다 놓아도 올라간다. 다른 사람이 바꾸면 drive:changed로 바로 다시 받는다.
class DriveScreen extends StatefulWidget {
  final Session session;
  final String teamId;
  final String teamName;
  const DriveScreen({
    super.key,
    required this.session,
    required this.teamId,
    required this.teamName,
  });

  @override
  State<DriveScreen> createState() => DriveScreenState();
}

class DriveScreenState extends State<DriveScreen> {
  String? _folderId;
  DriveListing? _listing;
  String? _error;
  StreamSubscription<String>? _sub;
  bool _dragHovering = false;

  /// 올리는 중인 파일 이름(위에 진행 줄).
  final _uploading = <String>[];

  ApiClient get _api => widget.session.api!;

  @override
  void initState() {
    super.initState();
    _sub = widget.session.chatSocket.driveChanged.listen((teamId) {
      if (teamId == widget.teamId) _load();
    });
    _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final folderId = _folderId;
    try {
      final listing = await _api.fetchDrive(widget.teamId, folderId: folderId);
      if (!mounted || folderId != _folderId) return;
      setState(() {
        _listing = listing;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      // 보던 폴더가 지워졌으면 맨 위로.
      if (e.statusCode == 404 && folderId != null) {
        _open(null);
        return;
      }
      setState(() => _error = '$e');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _open(String? folderId) {
    setState(() {
      _folderId = folderId;
      _listing = null;
    });
    _load();
  }

  Future<String?> _askName(
    String title, {
    String initial = '',
    String action = '확인',
  }) => showDriveNameDialog(context, title, initial: initial, action: action);

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    try {
      await action();
      if (done != null && mounted) showAppToast(context, done);
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '$e');
    }
  }

  Future<void> _newFolder() async {
    final name = await _askName(tr('새 폴더'), action: tr('만들기'));
    if (name == null || name.isEmpty) return;
    await _run(
      () => _api.createDriveFolder(widget.teamId, name, parentId: _folderId),
    );
  }

  Future<void> _pickAndUpload() async {
    final result = await FilePicker.pickFiles(allowMultiple: true);
    final picked = [
      for (final f in result?.files ?? const <PlatformFile>[])
        if (f.path != null || f.bytes != null) f.xFile,
    ];
    await uploadFiles(picked);
  }

  /// 파일들을 지금 폴더에 차례로 올린다 — 같은 이름이 있으면 "새 판으로 올리기"를 묻는다.
  Future<void> uploadFiles(List<XFile> files) async {
    final listing = _listing;
    if (files.isEmpty || listing == null || !listing.canWrite) return;
    final folderId = _folderId;
    for (final f in files) {
      setState(() => _uploading.add(f.name));
      try {
        final upload = await _api.uploadFile(f);
        try {
          await _api.addDriveFile(widget.teamId, upload, folderId: folderId);
        } on ApiException catch (e) {
          if (e.statusCode != 409) rethrow;
          // 같은 이름 — 지금 목록에서 그 파일을 찾아 새 판으로 올릴지 묻는다(폴더와 겹치면 그대로 알린다).
          final existing = _listing?.files
              .where(
                (x) => driveNameKey(x.name) == driveNameKey(upload.fileName),
              )
              .firstOrNull;
          if (existing == null || !mounted) rethrow;
          final asVersion = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: Text(tr('같은 이름의 파일')),
              content: Text(
                tr('\'{existing.name}\'이(가) 이미 있습니다. 새 판(판 {p0})으로 올릴까요?', {
                  'existing.name': existing.name,
                  'p0': existing.version + 1,
                }),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(c).pop(false),
                  child: Text(tr('건너뛰기')),
                ),
                FilledButton(
                  key: const ValueKey('drive-upload-as-version'),
                  onPressed: () => Navigator.of(c).pop(true),
                  child: Text(tr('새 판으로 올리기')),
                ),
              ],
            ),
          );
          if (asVersion == true) {
            await _api.addDriveFileVersion(existing.id, upload);
          }
        }
      } catch (e) {
        if (mounted) showAppToast(context, '${f.name}: $e');
      } finally {
        if (mounted) setState(() => _uploading.remove(f.name));
      }
    }
    await _load();
  }

  Future<void> _download(DriveFile f, {String? url, String? name}) async {
    final link = url ?? f.url;
    if (link == null) return;
    try {
      final saved = await saveAttachment(
        session: widget.session,
        url: link,
        fileName: name ?? f.name,
      );
      if (saved != null && mounted) showAppToast(context, tr('내려받았습니다.'));
    } catch (e) {
      if (mounted) showAppToast(context, tr('내려받지 못했습니다: {e}', {'e': e}));
    }
  }

  /// 옮길 폴더 고르기 — null이면 취소, (id: null)이면 맨 위.
  Future<({String? id})?> _pickFolder({String? excludeId}) =>
      showDialog<({String? id})>(
        context: context,
        builder: (_) => _FolderPickerDialog(
          api: _api,
          teamId: widget.teamId,
          excludeId: excludeId,
        ),
      );

  Future<void> _folderAction(DriveFolder f, String action) async {
    switch (action) {
      case 'rename':
        final name = await _askName(
          tr('폴더 이름 바꾸기'),
          initial: f.name,
          action: tr('바꾸기'),
        );
        if (name == null || name.isEmpty || name == f.name) return;
        await _run(() => _api.updateDriveFolder(f.id, name: name));
      case 'move':
        final target = await _pickFolder(excludeId: f.id);
        if (target == null) return;
        await _run(
          () => _api.updateDriveFolder(f.id, move: true, parentId: target.id),
          done: tr('옮겼습니다.'),
        );
      case 'delete':
        await _run(
          () => _api.deleteDriveFolder(widget.teamId, f.id),
          done: tr('\'{f.name}\'을(를) 휴지통으로 옮겼습니다.', {'f.name': f.name}),
        );
    }
  }

  Future<void> _openFile(DriveFile f) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _FileDialog(
        api: _api,
        teamId: widget.teamId,
        fileId: f.id,
        onDownload: (url, name) => _download(f, url: url, name: name),
        onPickFolder: () => _pickFolder(),
      ),
    );
    await _load();
  }

  Future<void> _search() async {
    final picked = await showDialog<({String? folderId, DriveFile? file})>(
      context: context,
      builder: (_) => _SearchDialog(api: _api, teamId: widget.teamId),
    );
    if (picked == null || !mounted) return;
    _open(picked.folderId);
    if (picked.file != null) unawaited(_openFile(picked.file!));
  }

  Future<void> _openTrash() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _TrashScreen(api: _api, teamId: widget.teamId),
      ),
    );
    await _load();
  }

  Widget _body(DriveListing listing) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final empty = listing.folders.isEmpty && listing.files.isEmpty;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const ValueKey('drive-list'),
        children: [
          // 빵부스러기 — 드라이브 / 기획 / 2026.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Row(
              children: [
                TextButton(
                  key: const ValueKey('drive-crumb-root'),
                  onPressed: listing.path.isEmpty ? null : () => _open(null),
                  child: Text(tr('드라이브')),
                ),
                for (final p in listing.path) ...[
                  Icon(Icons.chevron_right, size: 16, color: hint),
                  TextButton(
                    key: ValueKey('drive-crumb-${p.id}'),
                    onPressed: p.id == _folderId ? null : () => _open(p.id),
                    child: Text(p.name),
                  ),
                ],
              ],
            ),
          ),
          for (final name in _uploading)
            ListTile(
              dense: true,
              leading: const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text(tr('올리는 중: {name}', {'name': name})),
            ),
          if (empty)
            Padding(
              padding: const EdgeInsets.all(40),
              child: Text(
                listing.canWrite
                    ? tr('비어 있습니다. 파일을 올리거나 폴더를 만드세요.')
                    : tr('비어 있습니다.'),
                textAlign: TextAlign.center,
                style: TextStyle(color: hint),
              ),
            ),
          for (final f in listing.folders)
            ListTile(
              key: ValueKey('drive-folder-${f.id}'),
              leading: Icon(Icons.folder, color: Colors.amber.shade700),
              title: Text(f.name),
              subtitle: Text(_date(f.updatedAt)),
              onTap: () => _open(f.id),
              trailing: !listing.canWrite
                  ? null
                  : PopupMenuButton<String>(
                      tooltip: tr('더보기'),
                      onSelected: (a) => _folderAction(f, a),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'rename',
                          child: Text(tr('이름 바꾸기')),
                        ),
                        PopupMenuItem(value: 'move', child: Text(tr('옮기기'))),
                        if (listing.isManager ||
                            f.createdBy == widget.session.userId)
                          PopupMenuItem(
                            value: 'delete',
                            child: Text(tr('휴지통으로')),
                          ),
                      ],
                    ),
            ),
          for (final f in listing.files)
            ListTile(
              key: ValueKey('drive-file-${f.id}'),
              leading: Icon(
                driveFileIcon(f.name),
                color: theme.colorScheme.primary,
              ),
              title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                [
                  if (f.version > 1)
                    tr('판 {f.version}', {'f.version': f.version}),
                  formatBytes(f.size),
                  if (f.updatedByName != null) f.updatedByName!,
                  _date(f.updatedAt),
                ].where((s) => s.isNotEmpty).join(' · '),
              ),
              onTap: () => _openFile(f),
              trailing: IconButton(
                tooltip: tr('내려받기'),
                onPressed: () => _download(f),
                icon: const Icon(Icons.download_outlined),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              tr('드라이브 사용량 {p0}(판 기록 포함)', {
                'p0': formatBytes(listing.usageBytes),
              }),
              key: const ValueKey('drive-usage'),
              style: TextStyle(fontSize: 12, color: hint),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final listing = _listing;
    final scaffold = Scaffold(
      appBar: AppBar(
        title: Text(
          tr('드라이브 · {widget.teamName}', {'widget.teamName': widget.teamName}),
        ),
        actions: [
          IconButton(
            key: const ValueKey('drive-search'),
            tooltip: tr('찾기'),
            onPressed: _search,
            icon: const Icon(Icons.search),
          ),
          IconButton(
            key: const ValueKey('drive-trash'),
            tooltip: tr('휴지통'),
            onPressed: _openTrash,
            icon: const Icon(Icons.delete_outline),
          ),
          if (listing?.canWrite ?? false) ...[
            IconButton(
              key: const ValueKey('drive-new-folder'),
              tooltip: tr('새 폴더'),
              onPressed: _newFolder,
              icon: const Icon(Icons.create_new_folder_outlined),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.icon(
                key: const ValueKey('drive-upload'),
                onPressed: _pickAndUpload,
                icon: const Icon(Icons.upload_file, size: 18),
                label: Text(tr('올리기')),
              ),
            ),
          ],
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: listing == null
                ? Center(
                    child: _error != null
                        ? Text(_error!)
                        : const CircularProgressIndicator(),
                  )
                : _body(listing),
          ),
          if (_dragHovering)
            const Positioned.fill(
              child: IgnorePointer(child: DropZoneOverlay()),
            ),
        ],
      ),
    );
    // 끌어다 놓기는 PC(윈도우)·웹에서, 올릴 수 있는 사람에게만.
    final canDrop = AppPlatform.isWindows || kIsWeb;
    if (!canDrop || !(listing?.canWrite ?? false)) return scaffold;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragHovering = true),
      onDragExited: (_) => setState(() => _dragHovering = false),
      onDragDone: (details) {
        setState(() => _dragHovering = false);
        uploadFiles(droppedFiles(details));
      },
      child: scaffold,
    );
  }
}

/// 파일 하나 — 판 기록(판마다 내려받기·되돌리기), 새 판 올리기, 이름 바꾸기, 옮기기, 휴지통.
class _FileDialog extends StatefulWidget {
  final ApiClient api;
  final String teamId;
  final String fileId;
  final void Function(String url, String name) onDownload;
  final Future<({String? id})?> Function() onPickFolder;
  const _FileDialog({
    required this.api,
    required this.teamId,
    required this.fileId,
    required this.onDownload,
    required this.onPickFolder,
  });

  @override
  State<_FileDialog> createState() => _FileDialogState();
}

class _FileDialogState extends State<_FileDialog> {
  DriveFileDetail? _d;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.api.fetchDriveFile(widget.teamId, widget.fileId);
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _do(
    Future<void> Function() action, {
    String? done,
    bool close = false,
  }) async {
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      if (done != null) showAppToast(context, done);
      if (close) {
        Navigator.of(context).pop();
        return;
      }
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _newVersion() async {
    final result = await FilePicker.pickFiles();
    final f = result?.files.firstOrNull;
    if (f == null || (f.path == null && f.bytes == null)) return;
    await _do(() async {
      final upload = await widget.api.uploadFile(f.xFile);
      await widget.api.addDriveFileVersion(widget.fileId, upload);
    }, done: tr('새 판을 올렸습니다.'));
  }

  Future<void> _rename(DriveFile file) async {
    final name = await showDriveNameDialog(
      context,
      tr('이름 바꾸기'),
      initial: file.name,
      action: tr('바꾸기'),
    );
    if (name == null || name.isEmpty || name == file.name) return;
    await _do(() => widget.api.updateDriveFile(file.id, name: name));
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final hint = Theme.of(context).hintColor;
    return AlertDialog(
      title: Text(
        d?.file.name ?? tr('파일'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: 460,
        height: 420,
        child: d == null
            ? Center(
                child: _error != null
                    ? Text(_error!)
                    : const CircularProgressIndicator(),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    [tr('드라이브'), ...d.path.map((p) => p.name)].join(' / '),
                    style: TextStyle(fontSize: 12, color: hint),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      FilledButton.tonalIcon(
                        key: const ValueKey('drive-file-download'),
                        onPressed: d.file.url == null
                            ? null
                            : () => widget.onDownload(d.file.url!, d.file.name),
                        icon: const Icon(Icons.download, size: 18),
                        label: Text(tr('내려받기')),
                      ),
                      if (d.canWrite) ...[
                        OutlinedButton.icon(
                          key: const ValueKey('drive-file-new-version'),
                          onPressed: _busy ? null : _newVersion,
                          icon: const Icon(Icons.upload, size: 18),
                          label: Text(tr('새 판 올리기')),
                        ),
                        TextButton(
                          onPressed: _busy ? null : () => _rename(d.file),
                          child: Text(tr('이름 바꾸기')),
                        ),
                        TextButton(
                          key: const ValueKey('drive-file-move'),
                          onPressed: _busy
                              ? null
                              : () async {
                                  final target = await widget.onPickFolder();
                                  if (target == null) return;
                                  await _do(
                                    () => widget.api.updateDriveFile(
                                      d.file.id,
                                      move: true,
                                      folderId: target.id,
                                    ),
                                    done: tr('옮겼습니다.'),
                                    close: true,
                                  );
                                },
                          child: Text(tr('옮기기')),
                        ),
                      ],
                      if (d.canRemove)
                        TextButton(
                          key: const ValueKey('drive-file-delete'),
                          onPressed: _busy
                              ? null
                              : () => _do(
                                  () => widget.api.deleteDriveFile(
                                    widget.teamId,
                                    d.file.id,
                                  ),
                                  done: tr('휴지통으로 옮겼습니다.'),
                                  close: true,
                                ),
                          child: Text(tr('휴지통으로')),
                        ),
                    ],
                  ),
                  const Divider(height: 20),
                  Text(
                    tr('판 기록 {d.versions.length}', {
                      'd.versions.length': d.versions.length,
                    }),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final v in d.versions)
                          ListTile(
                            key: ValueKey('drive-version-${v.version}'),
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: CircleAvatar(
                              radius: 14,
                              backgroundColor: v.version == d.file.version
                                  ? Theme.of(
                                      context,
                                    ).colorScheme.primaryContainer
                                  : null,
                              child: Text(
                                '${v.version}',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            title: Text(
                              [
                                v.uploaderName,
                                _date(v.createdAt),
                                formatBytes(v.size),
                              ].where((s) => s.isNotEmpty).join(' · '),
                            ),
                            subtitle: v.note == null ? null : Text(v.note!),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: tr('이 판 내려받기'),
                                  onPressed: v.url == null
                                      ? null
                                      : () => widget.onDownload(
                                          v.url!,
                                          d.file.name,
                                        ),
                                  icon: const Icon(
                                    Icons.download_outlined,
                                    size: 18,
                                  ),
                                ),
                                if (d.canWrite && v.version != d.file.version)
                                  IconButton(
                                    key: ValueKey(
                                      'drive-version-restore-${v.version}',
                                    ),
                                    tooltip: tr('이 판으로 되돌리기'),
                                    onPressed: _busy
                                        ? null
                                        : () => _do(
                                            () => widget.api
                                                .restoreDriveFileVersion(
                                                  d.file.id,
                                                  v.version,
                                                ),
                                            done: tr('판 {v.version}로 되돌렸습니다.', {
                                              'v.version': v.version,
                                            }),
                                          ),
                                    icon: const Icon(Icons.restore, size: 18),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('닫기')),
        ),
      ],
    );
  }
}

/// 옮길 폴더 고르기 — 폴더를 따라 들어가 "여기로 옮기기". [excludeId](옮기는 폴더 자신)는 들어갈 수 없다.
class _FolderPickerDialog extends StatefulWidget {
  final ApiClient api;
  final String teamId;
  final String? excludeId;
  const _FolderPickerDialog({
    required this.api,
    required this.teamId,
    this.excludeId,
  });

  @override
  State<_FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<_FolderPickerDialog> {
  String? _at;
  DriveListing? _l;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final at = _at;
    final l = await widget.api
        .fetchDrive(widget.teamId, folderId: at)
        .catchError((Object _) => const DriveListing());
    if (mounted && at == _at) setState(() => _l = l);
  }

  void _go(String? id) {
    setState(() {
      _at = id;
      _l = null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final l = _l;
    return AlertDialog(
      title: Text(tr('옮길 곳')),
      content: SizedBox(
        width: 360,
        height: 360,
        child: l == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                children: [
                  Text([tr('드라이브'), ...l.path.map((p) => p.name)].join(' / ')),
                  if (_at != null)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.arrow_upward),
                      title: Text(tr('위 폴더로')),
                      onTap: () => _go(
                        l.path.length >= 2
                            ? l.path[l.path.length - 2].id
                            : null,
                      ),
                    ),
                  for (final f in l.folders)
                    if (f.id != widget.excludeId)
                      ListTile(
                        key: ValueKey('drive-pick-${f.id}'),
                        dense: true,
                        leading: Icon(
                          Icons.folder,
                          color: Colors.amber.shade700,
                        ),
                        title: Text(f.name),
                        onTap: () => _go(f.id),
                      ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('drive-pick-here'),
          onPressed: () => Navigator.of(context).pop((id: _at)),
          child: Text(tr('여기로 옮기기')),
        ),
      ],
    );
  }
}

/// 이름으로 찾기 — 누르면 그 폴더로 가고(파일이면 그 파일도 연다).
class _SearchDialog extends StatefulWidget {
  final ApiClient api;
  final String teamId;
  const _SearchDialog({required this.api, required this.teamId});

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  ({List<DriveFolder> folders, List<DriveFile> files})? _r;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _changed(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      if (q.trim().isEmpty) {
        if (mounted) setState(() => _r = null);
        return;
      }
      final r = await widget.api
          .searchDrive(widget.teamId, q.trim())
          .catchError(
            (Object _) => (folders: <DriveFolder>[], files: <DriveFile>[]),
          );
      if (mounted) setState(() => _r = r);
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    final hint = Theme.of(context).hintColor;
    return AlertDialog(
      title: Text(tr('드라이브에서 찾기')),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          children: [
            TextField(
              key: const ValueKey('drive-search-input'),
              autofocus: true,
              decoration: InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: tr('파일·폴더 이름'),
              ),
              onChanged: _changed,
            ),
            Expanded(
              child: r == null
                  ? const SizedBox.shrink()
                  : r.folders.isEmpty && r.files.isEmpty
                  ? Center(
                      child: Text(
                        tr('찾는 항목이 없습니다.'),
                        style: TextStyle(color: hint),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final f in r.folders)
                          ListTile(
                            dense: true,
                            leading: Icon(
                              Icons.folder,
                              color: Colors.amber.shade700,
                            ),
                            title: Text(f.name),
                            subtitle: Text(
                              (f.path ?? '').isEmpty ? tr('드라이브') : f.path!,
                            ),
                            onTap: () => Navigator.of(
                              context,
                            ).pop((folderId: f.id, file: null)),
                          ),
                        for (final f in r.files)
                          ListTile(
                            key: ValueKey('drive-search-file-${f.id}'),
                            dense: true,
                            leading: Icon(driveFileIcon(f.name)),
                            title: Text(f.name),
                            subtitle: Text(
                              (f.path ?? '').isEmpty ? tr('드라이브') : f.path!,
                            ),
                            onTap: () => Navigator.of(
                              context,
                            ).pop((folderId: f.folderId, file: f)),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('닫기')),
        ),
      ],
    );
  }
}

/// 휴지통 — 되살리기(원래 자리, 없으면 맨 위·겹치면 "이름 (2)"), 영구 삭제(폴더면 그 아래까지).
class _TrashScreen extends StatefulWidget {
  final ApiClient api;
  final String teamId;
  const _TrashScreen({required this.api, required this.teamId});

  @override
  State<_TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<_TrashScreen> {
  DriveTrash? _t;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await widget.api.fetchDriveTrash(widget.teamId);
      if (mounted) setState(() => _t = t);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _restore(bool folder, String id) async {
    try {
      await widget.api.restoreDriveItem(folder: folder, id: id);
      if (mounted) showAppToast(context, tr('되살렸습니다.'));
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '$e');
    }
  }

  Future<void> _purge(bool folder, String id, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('영구 삭제')),
        content: Text(
          folder
              ? tr('\'{name}\' 폴더와 그 안의 모든 파일을 영구 삭제할까요? 되돌릴 수 없습니다.', {
                  'name': name,
                })
              : tr('\'{name}\'을(를) 영구 삭제할까요? 되돌릴 수 없습니다.', {'name': name}),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: Text(tr('취소')),
          ),
          TextButton(
            key: const ValueKey('drive-purge-ok'),
            onPressed: () => Navigator.of(c).pop(true),
            child: Text(
              tr('영구 삭제'),
              style: TextStyle(color: Theme.of(c).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.api.purgeDriveItem(widget.teamId, folder: folder, id: id);
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '$e');
    }
  }

  Widget _row({
    required bool folder,
    required String id,
    required String name,
    String? path,
    DateTime? deletedAt,
  }) {
    return ListTile(
      key: ValueKey('drive-trash-$id'),
      leading: Icon(
        folder ? Icons.folder : driveFileIcon(name),
        color: folder ? Colors.amber.shade700 : null,
      ),
      title: Text(name),
      subtitle: Text(
        tr('{p0} · {p1} 삭제', {
          'p0': (path ?? '').isEmpty ? tr('드라이브') : path,
          'p1': _date(deletedAt),
        }),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            key: ValueKey('drive-restore-$id'),
            onPressed: () => _restore(folder, id),
            child: Text(tr('되살리기')),
          ),
          IconButton(
            key: ValueKey('drive-purge-$id'),
            tooltip: tr('영구 삭제'),
            onPressed: () => _purge(folder, id, name),
            icon: const Icon(Icons.delete_forever_outlined),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(title: Text(tr('드라이브 휴지통'))),
      body: t == null
          ? Center(
              child: _error != null
                  ? Text(_error!)
                  : const CircularProgressIndicator(),
            )
          : t.folders.isEmpty && t.files.isEmpty
          ? Center(
              child: Text(
                tr('휴지통이 비어 있습니다.'),
                style: TextStyle(color: Theme.of(context).hintColor),
              ),
            )
          : ListView(
              children: [
                for (final f in t.folders)
                  _row(
                    folder: true,
                    id: f.id,
                    name: f.name,
                    path: f.path,
                    deletedAt: f.deletedAt,
                  ),
                for (final f in t.files)
                  _row(
                    folder: false,
                    id: f.id,
                    name: f.name,
                    path: f.path,
                    deletedAt: f.deletedAt,
                  ),
              ],
            ),
    );
  }
}

/// 이름 하나 묻기(새 폴더·이름 바꾸기) — 취소하면 null. 입력칸은 창이 닫히는 애니메이션이 끝난 뒤에 정리되게 창이 들고 있는다.
Future<String?> showDriveNameDialog(
  BuildContext context,
  String title, {
  String initial = '',
  String action = '확인',
}) => showDialog<String>(
  context: context,
  builder: (_) => _NameDialog(title: title, initial: initial, action: action),
);

class _NameDialog extends StatefulWidget {
  final String title;
  final String initial;
  final String action;
  const _NameDialog({
    required this.title,
    required this.initial,
    required this.action,
  });

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: const ValueKey('drive-name-input'),
      controller: _c,
      autofocus: true,
      maxLength: 120,
      onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(tr('취소')),
      ),
      FilledButton(
        key: const ValueKey('drive-name-ok'),
        onPressed: () => Navigator.of(context).pop(_c.text.trim()),
        child: Text(tr(widget.action)),
      ),
    ],
  );
}
