import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/album.dart';
import 'album_api.dart';
import 'album_media.dart';
import 'api_client.dart' show ApiException, UploadCancelToken;

/// 올리는 중인 파일 하나의 상태.
enum AlbumUploadStatus { queued, uploading, done, failed }

class AlbumUpload {
  AlbumUpload({
    required this.id,
    required this.albumId,
    required this.file,
    required this.name,
    required this.size,
    required this.mimeType,
    required this.kind,
  });

  final int id;
  final String albumId;
  final File file;
  final String name;
  final int size;
  final String mimeType;
  final AlbumItemKind kind;
  final UploadCancelToken token = UploadCancelToken();

  AlbumUploadStatus status = AlbumUploadStatus.queued;
  int sent = 0;
  int total = 0;
  String? error;

  /// 파일이 서버에 올라간 뒤의 앨범 항목 요청 값 — 앨범에 담지 못하고 실패했을 때 다시 올리지 않고 재시도하는 데 쓴다.
  AlbumItemDraft? draft;

  /// 지금 앨범에 담는 요청에 실려 가는 중 — 같은 파일이 두 번 담기지 않게.
  bool committing = false;

  double? get progress {
    final all = total > 0 ? total : size;
    return all > 0 ? (sent / all).clamp(0.0, 1.0) : null;
  }

  bool get isActive =>
      status == AlbumUploadStatus.queued ||
      status == AlbumUploadStatus.uploading;
}

/// [AlbumController.addFiles]가 파일을 골라낸 결과.
class AlbumAddResult {
  /// 올리기 시작한 개수.
  final int accepted;

  /// 한 번에 올릴 수 있는 100개를 넘어 빠진 개수.
  final int overLimit;

  /// 이미지·영상이 아니라서 빠진 개수.
  final int unsupported;
  const AlbumAddResult({
    this.accepted = 0,
    this.overLimit = 0,
    this.unsupported = 0,
  });
}

/// 앨범 패널의 상태: 앨범 목록(방별 보기·이어 받기), 열어 본 앨범과 그 항목(이어 받기), 올리는 중인 파일들(동시에 여러 개,
/// 실패 재시도), 선택 모드, 소켓 `album:changed`로 열려 있는 화면 새로 고침.
///
/// Session이 하나만 들고 있고(`session.albums`) 로그아웃하면 [reset]이 비운다. 서버 호출은 [AlbumApi]로만 해서
/// 테스트가 가짜를 끼운다.
class AlbumController extends ChangeNotifier {
  AlbumController({
    required this.apiProvider,
    required this.teamIdProvider,
    Stream<AlbumChangedEvent>? changed,
    Stream<void>? reconnected,
    AlbumMediaPreparer? preparer,
    this.uploadConcurrency = 3,
  }) : _preparer = preparer ?? defaultAlbumMediaPreparer {
    _changedSub = changed?.listen(handleChanged);
    _reconnectSub = reconnected?.listen((_) => refreshOpen());
  }

  final AlbumApi Function() apiProvider;

  /// 지금 보고 있는 팀 — 목록은 팀 단위다.
  final String? Function() teamIdProvider;
  final AlbumMediaPreparer _preparer;
  final int uploadConcurrency;

  StreamSubscription<AlbumChangedEvent>? _changedSub;
  StreamSubscription<void>? _reconnectSub;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ---- 목록 ----

  final List<Album> albums = [];
  bool listLoaded = false;
  bool listLoading = false;
  bool listHasMore = false;
  String? listError;

  /// 목록을 거른 방(null이면 내가 멤버인 모든 방).
  String? listRoomId;
  static const _listPageSize = 30;

  /// 목록을 처음부터 새로 받는다. [roomId]를 주면 그 방으로 거르고(null이면 전체), [silent]면 지금 목록을 지우지 않고
  /// 받는 대로 바꿔 끼운다(소켓으로 새로 고칠 때 깜박이지 않게).
  Future<void> loadAlbums({String? roomId, bool silent = false}) async {
    final teamId = teamIdProvider();
    if (teamId == null) return;
    listRoomId = roomId;
    final epoch = ++_listEpoch;
    if (!silent) {
      albums.clear();
      listLoaded = false;
      listHasMore = false;
    }
    listLoading = true;
    listError = null;
    _notify();
    try {
      final page = await apiProvider().fetchAlbums(
        teamId: teamId,
        roomId: roomId,
        limit: _listPageSize,
      );
      if (epoch != _listEpoch || _disposed) return;
      albums
        ..clear()
        ..addAll(page.albums);
      listHasMore = page.hasMore;
      listLoaded = true;
    } catch (e) {
      if (epoch != _listEpoch || _disposed) return;
      listError = '$e';
      listLoaded = true;
    } finally {
      if (epoch == _listEpoch) {
        listLoading = false;
        _notify();
      }
    }
  }

  int _listEpoch = 0;

  /// 목록의 다음 쪽을 이어 붙인다.
  Future<void> loadMoreAlbums() async {
    final teamId = teamIdProvider();
    if (teamId == null || listLoading || !listHasMore || albums.isEmpty) return;
    final epoch = ++_listEpoch;
    listLoading = true;
    _notify();
    try {
      final page = await apiProvider().fetchAlbums(
        teamId: teamId,
        roomId: listRoomId,
        before: albums.last.createdAt.millisecondsSinceEpoch,
        limit: _listPageSize,
      );
      if (epoch != _listEpoch || _disposed) return;
      final known = {for (final a in albums) a.id};
      albums.addAll(page.albums.where((a) => !known.contains(a.id)));
      listHasMore = page.hasMore;
    } catch (e) {
      if (epoch != _listEpoch || _disposed) return;
      listError = '$e';
    } finally {
      if (epoch == _listEpoch) {
        listLoading = false;
        _notify();
      }
    }
  }

  // ---- 열어 본 앨범 ----

  /// 지금 열어 본 앨범(없으면 목록 화면).
  Album? album;
  final List<AlbumItem> items = [];
  bool itemsLoading = false;
  bool itemsHasMore = false;
  bool itemsLoaded = false;
  String? detailError;

  /// 열어 둔 앨범이 (다른 사람에 의해) 지워졌다 — 화면이 안내하고 목록으로 돌아간다.
  bool albumGone = false;
  int _detailEpoch = 0;
  static const _itemsPageSize = 60;

  /// 앨범을 연다 — 목록에서 받은 [summary]를 바로 보여 주고, 상세(내 권한)와 항목 첫 쪽을 받는다.
  Future<void> openAlbum(Album summary) async {
    album = summary;
    albumGone = false;
    detailError = null;
    items.clear();
    itemsLoaded = false;
    itemsHasMore = false;
    clearSelection();
    final epoch = ++_detailEpoch;
    _notify();
    await _loadDetail(epoch);
  }

  /// 앨범 id만 아는 경우(알림 등) — 상세부터 받아 연다.
  Future<void> openAlbumById(String albumId) async {
    final epoch = ++_detailEpoch;
    items.clear();
    itemsLoaded = false;
    album = null;
    albumGone = false;
    detailError = null;
    clearSelection();
    _notify();
    try {
      final detail = await apiProvider().fetchAlbum(albumId);
      if (epoch != _detailEpoch || _disposed) return;
      album = detail;
    } catch (e) {
      if (epoch != _detailEpoch || _disposed) return;
      detailError = '$e';
      itemsLoaded = true;
      _notify();
      return;
    }
    await _loadDetail(epoch, fetchDetail: false);
  }

  Future<void> _loadDetail(int epoch, {bool fetchDetail = true}) async {
    final current = album;
    if (current == null) return;
    itemsLoading = true;
    _notify();
    try {
      final api = apiProvider();
      if (fetchDetail) {
        final detail = await api.fetchAlbum(current.id);
        if (epoch != _detailEpoch || _disposed) return;
        album = detail;
        _syncSummary(detail);
      }
      final page = await api.fetchItems(current.id, limit: _itemsPageSize);
      if (epoch != _detailEpoch || _disposed) return;
      items
        ..clear()
        ..addAll(page.items);
      itemsHasMore = page.hasMore;
      itemsLoaded = true;
      detailError = null;
    } catch (e) {
      if (epoch != _detailEpoch || _disposed) return;
      if (e is ApiException && _isGone(e)) {
        albumGone = true;
      } else {
        detailError = '$e';
      }
      itemsLoaded = true;
    } finally {
      if (epoch == _detailEpoch) {
        itemsLoading = false;
        _notify();
      }
    }
  }

  bool _isGone(ApiException e) => e.message.contains('찾을 수 없');

  /// 열어 둔 앨범을 닫고 목록으로 돌아간다. [notify]가 false면 알리지 않는다(화면을 그리는 도중에 부를 때).
  void closeAlbum({bool notify = true}) {
    _detailEpoch++;
    album = null;
    albumGone = false;
    detailError = null;
    items.clear();
    itemsLoaded = false;
    itemsHasMore = false;
    itemsLoading = false;
    _selected.clear();
    selecting = false;
    if (notify) _notify();
  }

  /// 열어 둔 앨범과 항목을 새로 받는다 — 지금까지 이어 받은 만큼(최소 한 쪽)을 다시 채운다. 서명 링크도 새것이 된다.
  Future<void> reloadAlbum() async {
    final current = album;
    if (current == null) return;
    final epoch = ++_detailEpoch;
    final want = items.length < _itemsPageSize ? _itemsPageSize : items.length;
    try {
      final api = apiProvider();
      final detail = await api.fetchAlbum(current.id);
      if (epoch != _detailEpoch || _disposed) return;
      final fresh = <AlbumItem>[];
      var hasMore = true;
      while (hasMore && fresh.length < want) {
        final page = await api.fetchItems(
          current.id,
          before: fresh.isEmpty
              ? null
              : fresh.last.createdAt.millisecondsSinceEpoch,
          limit: _itemsPageSize,
        );
        if (epoch != _detailEpoch || _disposed) return;
        fresh.addAll(page.items);
        hasMore = page.hasMore && page.items.isNotEmpty;
      }
      album = detail;
      _syncSummary(detail);
      items
        ..clear()
        ..addAll(fresh);
      itemsHasMore = hasMore;
      itemsLoaded = true;
      detailError = null;
      // 지워진 항목이 선택에 남아 있지 않게.
      final ids = {for (final i in items) i.id};
      _selected.removeWhere((id) => !ids.contains(id));
    } catch (e) {
      if (epoch != _detailEpoch || _disposed) return;
      if (e is ApiException && _isGone(e)) {
        albumGone = true;
      } else {
        detailError = '$e';
      }
    }
    _notify();
  }

  /// 항목의 다음 쪽을 이어 붙인다.
  Future<void> loadMoreItems() async {
    final current = album;
    if (current == null || itemsLoading || !itemsHasMore || items.isEmpty) {
      return;
    }
    final epoch = _detailEpoch;
    itemsLoading = true;
    _notify();
    try {
      final page = await apiProvider().fetchItems(
        current.id,
        before: items.last.createdAt.millisecondsSinceEpoch,
        limit: _itemsPageSize,
      );
      if (epoch != _detailEpoch || _disposed) return;
      final known = {for (final i in items) i.id};
      items.addAll(page.items.where((i) => !known.contains(i.id)));
      itemsHasMore = page.hasMore;
    } catch (e) {
      if (epoch != _detailEpoch || _disposed) return;
      detailError = '$e';
    } finally {
      if (epoch == _detailEpoch) {
        itemsLoading = false;
        _notify();
      }
    }
  }

  /// 항목을 끝까지 이어 받아 전부 돌려준다(전체 다운로드용).
  Future<List<AlbumItem>> loadAllItems() async {
    while (itemsHasMore && album != null) {
      final before = items.length;
      await loadMoreItems();
      if (items.length == before) break; // 더 못 받으면(오류) 멈춘다.
    }
    return List.of(items);
  }

  /// 목록에 든 같은 앨범의 요약(제목·개수·대표 이미지)을 상세 값으로 맞춘다.
  void _syncSummary(Album detail) {
    final i = albums.indexWhere((a) => a.id == detail.id);
    if (i >= 0) albums[i] = detail;
  }

  // ---- 만들기·고치기·지우기 ----

  Future<Album> createAlbum(
    String roomId, {
    required String title,
    String? description,
  }) async {
    final created = await apiProvider().createAlbum(
      roomId,
      title: title.trim(),
      description: description?.trim(),
    );
    if (listLoaded && (listRoomId == null || listRoomId == roomId)) {
      albums.insert(0, created);
      _notify();
    }
    return created;
  }

  /// 열어 둔 앨범의 제목·설명·대표 이미지를 바꾼다([coverItemId]를 `''`로 주면 대표를 비운다).
  Future<void> updateAlbum({
    String? title,
    String? description,
    String? coverItemId,
  }) async {
    final current = album;
    if (current == null) return;
    final updated = await apiProvider().updateAlbum(
      current.id,
      title: title?.trim(),
      description: description?.trim(),
      coverItemId: coverItemId,
    );
    album = updated;
    _syncSummary(updated);
    _notify();
  }

  /// 열어 둔 앨범을 지우고 목록으로 돌아간다.
  Future<void> deleteAlbum() async {
    final current = album;
    if (current == null) return;
    await apiProvider().deleteAlbum(current.id);
    albums.removeWhere((a) => a.id == current.id);
    closeAlbum();
  }

  /// 항목을 지운다 — 권한 있는 것만 지워지고 나머지는 skipped로 센다.
  Future<({int deleted, int skipped})> deleteItems(List<String> itemIds) async {
    final current = album;
    if (current == null) return (deleted: 0, skipped: 0);
    final result = await apiProvider().deleteItems(current.id, itemIds);
    // 서버가 어느 것을 지웠는지는 응답에 없으므로(개수만) 새로 받아 맞춘다.
    _selected.removeAll(itemIds);
    await reloadAlbum();
    return result;
  }

  /// 선택한 항목(최대 10개)을 [roomId] 대화방에 이미지/영상 메시지로 보낸다.
  Future<void> shareItems(String roomId, List<String> itemIds) async {
    final current = album;
    if (current == null) return;
    await apiProvider().share(current.id, roomId: roomId, itemIds: itemIds);
  }

  // ---- 선택 모드 ----

  final Set<String> _selected = {};
  bool selecting = false;

  Set<String> get selectedIds => Set.unmodifiable(_selected);
  bool isSelected(String itemId) => _selected.contains(itemId);

  /// 선택한 항목들(화면에 보이는 순서대로).
  List<AlbumItem> get selectedItems => [
    for (final i in items)
      if (_selected.contains(i.id)) i,
  ];

  void startSelecting() {
    selecting = true;
    _notify();
  }

  void toggleSelected(String itemId) {
    if (!_selected.remove(itemId)) _selected.add(itemId);
    _notify();
  }

  void selectAll() {
    _selected
      ..clear()
      ..addAll(items.map((i) => i.id));
    _notify();
  }

  /// 선택 모드는 그대로 두고 체크만 모두 푼다.
  void deselectAll() {
    _selected.clear();
    _notify();
  }

  void clearSelection() {
    final changed = selecting || _selected.isNotEmpty;
    selecting = false;
    _selected.clear();
    if (changed) _notify();
  }

  // ---- 올리기 ----

  final List<AlbumUpload> uploads = [];
  int _uploadSeq = 0;
  int _runningWorkers = 0;

  /// 열어 둔 앨범에 올리는 파일들.
  List<AlbumUpload> get currentUploads => [
    for (final u in uploads)
      if (u.albumId == album?.id) u,
  ];

  /// 올리는 중(대기 포함)인 파일이 있는지.
  bool get uploading => uploads.any((u) => u.isActive);

  /// 파일들을 열어 둔 앨범에 올리기 시작한다 — 한 번에 100개까지(넘는 만큼은 빼고 결과로 알린다), 이미지·영상만.
  /// 파일은 [uploadConcurrency]개씩 동시에 올리고, 끝나면 올라간 것을 한꺼번에 앨범에 담는다.
  AlbumAddResult addFiles(List<File> files) {
    final current = album;
    if (current == null || files.isEmpty) return const AlbumAddResult();
    var unsupported = 0;
    var over = 0;
    var accepted = 0;
    for (final f in files) {
      final mime = albumMimeForPath(f.path);
      final kind = albumKindForMime(mime);
      if (mime == null || kind == null) {
        unsupported++;
        continue;
      }
      if (accepted >= albumUploadMaxCount) {
        over++;
        continue;
      }
      int size = 0;
      try {
        size = f.lengthSync();
      } catch (_) {}
      uploads.add(
        AlbumUpload(
          id: ++_uploadSeq,
          albumId: current.id,
          file: f,
          name: albumFileName(f.path),
          size: size,
          mimeType: mime,
          kind: kind,
        ),
      );
      accepted++;
    }
    if (accepted > 0) {
      _notify();
      _startWorkers();
    }
    return AlbumAddResult(
      accepted: accepted,
      overLimit: over,
      unsupported: unsupported,
    );
  }

  void _startWorkers() {
    while (_runningWorkers < uploadConcurrency &&
        uploads.any((u) => u.status == AlbumUploadStatus.queued)) {
      _runningWorkers++;
      unawaited(_worker());
    }
  }

  Future<void> _worker() async {
    try {
      while (!_disposed) {
        final next = uploads
            .where((u) => u.status == AlbumUploadStatus.queued)
            .firstOrNull;
        if (next == null) break;
        next.status = AlbumUploadStatus.uploading;
        next.error = null;
        _notify();
        try {
          next.draft ??= await _uploadOne(next);
          if (next.token.isCancelled) {
            uploads.remove(next);
          } else {
            next.status = AlbumUploadStatus.done;
          }
        } catch (e) {
          if (next.token.isCancelled) {
            uploads.remove(next);
          } else {
            next.status = AlbumUploadStatus.failed;
            next.error = '$e';
          }
        }
        _notify();
      }
    } finally {
      _runningWorkers--;
    }
    // 마지막 일꾼이 끝났으면(더 올릴 게 없으면) 올라간 것들을 앨범에 담는다.
    if (_runningWorkers == 0) await _commitDone();
  }

  Future<AlbumItemDraft> _uploadOne(AlbumUpload u) async {
    final api = apiProvider();
    final prep = await _preparer(u.file, u.kind);
    String? thumbUrl;
    final thumb = prep.thumbnail;
    if (thumb != null) {
      final dir = await Directory.systemTemp.createTemp('album_thumb_');
      final thumbFile = File('${dir.path}${Platform.pathSeparator}thumb.jpg');
      try {
        await thumbFile.writeAsBytes(thumb);
        thumbUrl = (await api.uploadFile(thumbFile)).url;
      } catch (_) {
        thumbUrl = null; // 썸네일은 없어도 된다 — 격자가 원본을 대신 그린다.
      } finally {
        unawaited(dir.delete(recursive: true).catchError((_) => dir));
      }
    }
    final result = await api.uploadFile(
      u.file,
      cancelToken: u.token,
      onProgress: (sent, total) {
        u.sent = sent;
        u.total = total;
        _notify();
      },
    );
    return AlbumItemDraft(
      kind: u.kind,
      fileUrl: result.url,
      fileName: u.name,
      fileSize: result.size,
      mimeType: u.mimeType,
      thumbnailUrl: thumbUrl,
      width: prep.width,
      height: prep.height,
    );
  }

  /// 올라간(done) 파일들을 앨범별로 모아 100개씩 한꺼번에 담는다. 담기에 실패하면 그 파일들을 failed로 돌려 다시 시도할 수 있게 둔다.
  Future<void> _commitDone() async {
    final byAlbum = <String, List<AlbumUpload>>{};
    for (final u in uploads) {
      if (u.status == AlbumUploadStatus.done &&
          u.draft != null &&
          !u.committing) {
        (byAlbum[u.albumId] ??= []).add(u);
      }
    }
    for (final entry in byAlbum.entries) {
      for (var i = 0; i < entry.value.length; i += albumUploadMaxCount) {
        final chunk = entry.value.skip(i).take(albumUploadMaxCount).toList();
        for (final u in chunk) {
          u.committing = true;
        }
        try {
          await apiProvider().addItems(entry.key, [
            for (final u in chunk) u.draft!,
          ]);
          uploads.removeWhere(chunk.contains);
        } catch (e) {
          for (final u in chunk) {
            u.committing = false;
            u.status = AlbumUploadStatus.failed;
            u.error = '앨범에 담지 못했습니다: $e';
          }
        }
        _notify();
      }
    }
    if (album != null && byAlbum.containsKey(album!.id)) {
      await reloadAlbum();
    }
  }

  /// 실패한 파일을 다시 올린다(파일은 올라갔는데 앨범에 담기만 실패했다면 담기만 다시).
  void retryUpload(int uploadId) {
    final u = uploads.where((u) => u.id == uploadId).firstOrNull;
    if (u == null || u.status != AlbumUploadStatus.failed) return;
    u.status = u.draft != null
        ? AlbumUploadStatus.done
        : AlbumUploadStatus.queued;
    u.error = null;
    _notify();
    if (u.status == AlbumUploadStatus.queued) {
      _startWorkers();
    } else if (_runningWorkers == 0) {
      unawaited(_commitDone());
    }
  }

  /// 실패한 파일을 건너뛴다(목록에서 뺀다). 올리는 중이면 취소한다.
  void skipUpload(int uploadId) {
    final u = uploads.where((u) => u.id == uploadId).firstOrNull;
    if (u == null) return;
    u.token.cancel();
    if (u.status != AlbumUploadStatus.uploading) uploads.remove(u);
    _notify();
  }

  /// 실패한 파일을 모두 건너뛴다.
  void skipFailedUploads() {
    uploads.removeWhere((u) => u.status == AlbumUploadStatus.failed);
    _notify();
  }

  // ---- 소켓·재연결 ----

  /// 소켓 `album:changed` — 열려 있는 목록·상세를 새로 받는다.
  void handleChanged(AlbumChangedEvent event) {
    final teamId = teamIdProvider();
    if (teamId != null && event.teamId.isNotEmpty && event.teamId != teamId) {
      return;
    }
    if (listLoaded) {
      if (event.kind == AlbumChangeKind.deleted) {
        albums.removeWhere((a) => a.id == event.albumId);
        _notify();
      }
      if (listRoomId == null || listRoomId == event.roomId) {
        unawaited(loadAlbums(roomId: listRoomId, silent: true));
      }
    }
    final open = album;
    if (open != null && open.id == event.albumId) {
      if (event.kind == AlbumChangeKind.deleted) {
        albumGone = true;
        _notify();
      } else {
        unawaited(reloadAlbum());
      }
    }
  }

  /// 소켓이 다시 붙었을 때 — 그동안 놓친 변경을 따라잡는다.
  void refreshOpen() {
    if (listLoaded) unawaited(loadAlbums(roomId: listRoomId, silent: true));
    if (album != null) unawaited(reloadAlbum());
  }

  /// 팀을 바꿨을 때 — 이전 팀의 목록·열어 둔 앨범을 비운다(올리는 중인 파일은 그대로 마친다).
  void invalidate() {
    _listEpoch++;
    _detailEpoch++;
    albums.clear();
    listLoaded = false;
    listLoading = false;
    listHasMore = false;
    listError = null;
    listRoomId = null;
    album = null;
    albumGone = false;
    items.clear();
    itemsLoaded = false;
    itemsHasMore = false;
    itemsLoading = false;
    _selected.clear();
    selecting = false;
    _notify();
  }

  /// 로그아웃 — 올리는 중인 것도 모두 취소하고 비운다.
  void reset() {
    for (final u in uploads) {
      u.token.cancel();
    }
    uploads.clear();
    invalidate();
  }

  @override
  void dispose() {
    _disposed = true;
    _changedSub?.cancel();
    _reconnectSub?.cancel();
    for (final u in uploads) {
      u.token.cancel();
    }
    super.dispose();
  }
}
