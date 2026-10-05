import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/bookmark.dart';
import '../models/team.dart' show AccountRole;
import '../services/app_platform.dart';
import '../services/bookmark_controller.dart';
import '../services/session.dart';
import '../widgets/bookmark_image.dart';

/// 북마크 추가/수정 창. PC는 대화상자, 모바일은 전체 화면([fullScreen]으로 바꿀 수 있다). 저장했으면 true.
///
/// - 종류(팀/개인)는 만들 때만 고른다 — 수정할 때는 잠겨 있다. 준회원은 개인 북마크만 만들 수 있다.
/// - 주소를 붙여넣으면 잠시 뒤 자동으로 "링크 정보 가져오기"를 해서 제목·이미지를 채운다. 사용자가 직접 쓴 제목이나
///   고른/지운 이미지는 덮어쓰지 않고(자동일 때), "링크 정보 가져오기" 단추를 직접 누르면 새 값으로 바꾼다.
/// - 이미지는 자동 미리보기를 쓰거나 "이미지 선택"으로 직접 올린다(/api/upload). 서버 오류 문구는 창 안에 보여 준다.
Future<bool> showBookmarkEditor(
  BuildContext context, {
  required Session session,
  required BookmarkController controller,
  Bookmark? editing,
  BookmarkKind initialKind = BookmarkKind.team,
  bool? fullScreen,
  Future<File?> Function()? pickImage,
}) async {
  final full = fullScreen ?? (AppPlatform.isAndroid || AppPlatform.isIOS);
  final result = full
      ? await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (routeContext) => BookmarkEditor(
              session: session,
              controller: controller,
              editing: editing,
              initialKind: initialKind,
              pickImage: pickImage,
              asPage: true,
              onDone: (saved) => Navigator.of(routeContext).pop(saved),
            ),
          ),
        )
      : await showDialog<bool>(
          context: context,
          builder: (dialogContext) => Dialog(
            insetPadding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: BookmarkEditor(
                session: session,
                controller: controller,
                editing: editing,
                initialKind: initialKind,
                pickImage: pickImage,
                onDone: (saved) => Navigator.of(dialogContext).pop(saved),
              ),
            ),
          ),
        );
  return result ?? false;
}

/// 직접 올렸거나 자동으로 가져온 이미지 한 장 — 저장할 때 보낼 값과 미리보기로 그릴 값.
class _PickedImage {
  /// 서버에 보낼 값 — 올린 사진은 미서명 /uploads/ 경로, 자동 이미지는 외부 주소, 기존 이미지는 받은 그대로.
  final String saveUrl;

  /// 미리보기로 그릴 주소(올린 사진은 서명된 /files/ 링크).
  final String previewUrl;
  const _PickedImage(this.saveUrl, this.previewUrl);
}

/// 추가/수정 창의 본문. [asPage]면 앱바가 있는 화면 모양, 아니면 대화상자 안의 모양이다.
class BookmarkEditor extends StatefulWidget {
  final Session session;
  final BookmarkController controller;
  final Bookmark? editing;
  final BookmarkKind initialKind;
  final bool asPage;

  /// 닫을 때 — 저장했으면 true.
  final void Function(bool saved) onDone;

  /// "이미지 선택"을 대신하는 선택기(테스트용). 없으면 파일 선택 창을 연다.
  final Future<File?> Function()? pickImage;

  const BookmarkEditor({
    super.key,
    required this.session,
    required this.controller,
    required this.onDone,
    this.editing,
    this.initialKind = BookmarkKind.team,
    this.asPage = false,
    this.pickImage,
  });

  @override
  State<BookmarkEditor> createState() => _BookmarkEditorState();
}

class _BookmarkEditorState extends State<BookmarkEditor> {
  static const _titleMax = 50;
  static const _autoFetchDelay = Duration(milliseconds: 600);

  final _titleController = TextEditingController();
  final _urlController = TextEditingController();
  late BookmarkKind _kind;
  _PickedImage? _image;

  /// 자동으로 채운 제목(사용자가 이 값에서 고치면 "직접 쓴 제목"으로 보고 자동으로는 안 덮어쓴다).
  String? _autoTitle;
  bool _titleTouched = false;
  bool _imageTouched = false;

  Timer? _debounce;
  int _fetchSeq = 0;
  bool _fetching = false;
  bool _uploading = false;
  bool _saving = false;
  String? _error;
  String? _fetchNote;

  Bookmark? get _editing => widget.editing;
  bool get _isEdit => _editing != null;
  bool get _canMakeTeam => widget.session.accountRole != AccountRole.guest;

  @override
  void initState() {
    super.initState();
    final editing = _editing;
    if (editing != null) {
      _kind = editing.kind;
      _titleController.text = editing.title;
      _urlController.text = editing.url;
      _titleTouched = true;
      _imageTouched = true;
      final image = editing.imageUrl;
      if (image != null && image.isNotEmpty) {
        _image = _PickedImage(image, image);
      }
    } else {
      _kind = _canMakeTeam ? widget.initialKind : BookmarkKind.personal;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _titleController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  /// http/https 주소로 읽히는지.
  bool _validUrl(String text) {
    final value = text.trim();
    if (value.isEmpty || value.length > 2000) return false;
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  bool get _canSave =>
      !_saving &&
      !_uploading &&
      _titleController.text.trim().isNotEmpty &&
      _validUrl(_urlController.text);

  void _onUrlChanged(String _) {
    _debounce?.cancel();
    setState(() {
      _error = null;
      _fetchNote = null;
    });
    if (!_validUrl(_urlController.text)) return;
    _debounce = Timer(_autoFetchDelay, () => _fetchPreview(manual: false));
  }

  /// 주소의 제목·이미지를 가져와 채운다. 자동([manual]=false)이면 사용자가 손댄 칸은 그대로 둔다.
  Future<void> _fetchPreview({required bool manual}) async {
    final url = _urlController.text.trim();
    if (!_validUrl(url)) return;
    _debounce?.cancel();
    final seq = ++_fetchSeq;
    setState(() {
      _fetching = true;
      _fetchNote = null;
    });
    BookmarkPreview? preview;
    try {
      preview = await widget.controller.api.preview(url);
    } catch (_) {
      preview = null;
    }
    // 그 사이 주소가 또 바뀌었거나 창이 닫혔으면 버린다.
    if (!mounted || seq != _fetchSeq) return;
    setState(() {
      _fetching = false;
      final p = preview;
      if (p == null || p.isEmpty) {
        if (manual) _fetchNote = '이 주소에서 가져올 수 있는 정보가 없어요. 직접 입력해 주세요.';
        return;
      }
      if (manual) {
        _titleTouched = false;
        _imageTouched = false;
      }
      final title = (p.title ?? '').trim();
      if (title.isNotEmpty && !_titleTouched) {
        final cut = title.characters.take(_titleMax).toString();
        _autoTitle = cut;
        _titleController.text = cut;
      }
      final image = p.imageUrl ?? '';
      if (image.isNotEmpty && !_imageTouched) {
        _image = _PickedImage(image, image);
      }
    });
  }

  Future<void> _chooseImage() async {
    File? file;
    final custom = widget.pickImage;
    if (custom != null) {
      file = await custom();
    } else {
      final result = await FilePicker.pickFiles(type: FileType.image);
      final path = result?.files.single.path;
      if (path != null) file = File(path);
    }
    if (file == null || !mounted) return;
    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      final uploaded = await widget.controller.api.uploadImage(file);
      if (!mounted) return;
      setState(() {
        _image = _PickedImage(uploaded.url, uploaded.signedUrl ?? uploaded.url);
        _imageTouched = true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '이미지를 올리지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final title = _titleController.text.trim();
    final url = _urlController.text.trim();
    try {
      final editing = _editing;
      if (editing == null) {
        await widget.controller.create(
          kind: _kind,
          title: title,
          url: url,
          imageUrl: _image?.saveUrl,
        );
      } else {
        await widget.controller.update(
          editing,
          title: title,
          url: url,
          imageUrl: _image?.saveUrl,
        );
      }
      if (mounted) widget.onDone(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e';
        });
      }
    }
  }

  Widget _kindSelector(BuildContext context) {
    final locked = _isEdit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<BookmarkKind>(
          key: const ValueKey('bookmark-kind'),
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: BookmarkKind.team,
              label: Text(BookmarkKind.team.label),
              enabled: !locked && _canMakeTeam,
            ),
            ButtonSegment(
              value: BookmarkKind.personal,
              label: Text(BookmarkKind.personal.label),
              enabled: !locked,
            ),
          ],
          selected: {_kind},
          onSelectionChanged: locked
              ? null
              : (s) => setState(() => _kind = s.first),
        ),
        const SizedBox(height: 4),
        Text(
          locked
              ? '북마크 종류는 만든 뒤에 바꿀 수 없어요.'
              : !_canMakeTeam
              ? '준회원은 개인 북마크만 만들 수 있어요.'
              : _kind == BookmarkKind.team
              ? '팀 멤버 모두에게 보여요.'
              : '나에게만 보여요.',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
        ),
      ],
    );
  }

  Widget _imageRow(BuildContext context) {
    final image = _image;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        BookmarkImage(
          key: const ValueKey('bookmark-editor-image'),
          session: widget.session,
          imageUrl: image?.previewUrl,
          size: 72,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('bookmark-pick-image'),
                onPressed: _uploading ? null : _chooseImage,
                icon: _uploading
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.image_outlined, size: 18),
                label: const Text('이미지 선택'),
              ),
              if (image != null)
                TextButton(
                  key: const ValueKey('bookmark-clear-image'),
                  onPressed: () => setState(() {
                    _image = null;
                    _imageTouched = true;
                  }),
                  child: const Text('지우기'),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _kindSelector(context),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('bookmark-url'),
          controller: _urlController,
          keyboardType: TextInputType.url,
          autocorrect: false,
          onChanged: _onUrlChanged,
          decoration: InputDecoration(
            labelText: 'URL',
            hintText: 'https://',
            border: const OutlineInputBorder(),
            isDense: true,
            errorText:
                _urlController.text.trim().isNotEmpty &&
                    !_validUrl(_urlController.text)
                ? 'http:// 또는 https://로 시작하는 주소를 입력하세요.'
                : null,
            suffixIcon: _fetching
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : null,
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('bookmark-fetch'),
            onPressed: _fetching || !_validUrl(_urlController.text)
                ? null
                : () => _fetchPreview(manual: true),
            icon: const Icon(Icons.travel_explore, size: 18),
            label: const Text('링크 정보 가져오기'),
          ),
        ),
        if (_fetchNote != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              _fetchNote!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('bookmark-title'),
          controller: _titleController,
          maxLength: _titleMax,
          onChanged: (text) => setState(() {
            _error = null;
            _titleTouched = text.isNotEmpty && text != _autoTitle;
          }),
          decoration: const InputDecoration(
            labelText: '제목',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 8),
        _imageRow(context),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            key: const ValueKey('bookmark-error'),
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = _isEdit ? '북마크 수정' : '북마크 추가';
    final saveLabel = _isEdit ? '저장' : '추가';
    final saveButton = FilledButton(
      key: const ValueKey('bookmark-save'),
      onPressed: _canSave ? _save : null,
      child: _saving
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : Text(saveLabel),
    );

    if (widget.asPage) {
      return Scaffold(
        appBar: AppBar(
          title: Text(title),
          leading: CloseButton(onPressed: () => widget.onDone(false)),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: saveButton,
            ),
          ],
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: _body(context),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          Flexible(child: SingleChildScrollView(child: _body(context))),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _saving ? null : () => widget.onDone(false),
                child: const Text('취소'),
              ),
              const SizedBox(width: 8),
              saveButton,
            ],
          ),
        ],
      ),
    );
  }
}
